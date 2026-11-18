import CryptoKit
import Foundation
import Network
import Security
import UIKit

/// Connection to the PhoneBox agent on the PC (port of the Android shell's AgentLink.kt).
///
/// 1. USB: http://127.0.0.1:8765. Android reaches it through "adb reverse"; an iPhone has no such tunnel, so on iOS this
///    route only answers when something on the phone forwards that port. It is refused at once otherwise.
/// 2. Wi-Fi / Tailscale: https://<pc-address>:<port>. The address list, a token and the SHA-256 fingerprint of the
///    agent's self-signed certificate come from pairing (the QR code, or the USB route) and are stored in the Keychain.
///    Only that exact certificate is trusted (pinning), and every request carries the token.
///
/// The phone remembers every computer it was paired with; one is active over Wi-Fi (the one last paired, or the one
/// picked in the panel's page overview).
///
/// Every request blocks its thread (like HttpURLConnection on Android): call it off the main thread.
final class AgentLink {

    struct Reply {
        let code: Int
        let contentType: String?
        let body: Data
    }

    enum Route: String { case usb, wifi, none }

    /// A computer this phone is paired with; the certificate fingerprint is its id.
    struct Pc: Codable {
        let id: String
        let name: String
        let hosts: [String]
        let port: Int
        let token: String
    }

    /// Called (on any thread) when the route used for the last request changes.
    var onRouteChange: ((Route) -> Void)?

    private let lock = NSLock()
    private var _route: Route = .none
    private var pcs: [Pc]
    private var activeId: String?
    private var preferredHost = 0
    private var wifiSession: (pin: String, session: URLSession, delegate: PinningDelegate)?
    private var lastPair = Date.distantPast
    private var probed: [String: Date] = [:]

    private let usbSession: URLSession
    private let background = DispatchQueue(label: "agent-link.pair")
    private let probeQueue = DispatchQueue(label: "agent-link.probe")

    private let appVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? ""
    /// Identifies this phone to the agent (several phones can show different pages): a short hash of the app-scoped
    /// vendor id, and the model name.
    private let deviceId: String
    private let deviceModel: String

    var route: Route { locked { _route } }

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.waitsForConnectivity = false
        usbSession = URLSession(configuration: config)

        let vendor = UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
        deviceId = SHA256.hash(data: Data(vendor.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        deviceModel = String("Apple \(AgentLink.machine())".filter { $0 >= " " && $0 <= "~" }.trimmingCharacters(in: .whitespaces).prefix(40))

        pcs = Store.loadPcs()
        activeId = UserDefaults.standard.string(forKey: Store.activeKey)
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func setRoute(_ r: Route) {
        let changed: Bool = locked {
            let c = _route != r
            _route = r
            return c
        }
        if changed { onRouteChange?(r) }
    }

    // ------------------------------------------------------------------------------------------- paired computers

    private func savePcs(_ list: [Pc], active: String?) {
        // caller holds the lock
        pcs = list
        activeId = active
        Store.savePcs(list)
        UserDefaults.standard.set(active, forKey: Store.activeKey)
    }

    private func activePc() -> Pc? {
        locked { pcs.first { $0.id == activeId } ?? pcs.first }
    }

    /// The paired computers for the panel: [{"id", "name", "active"}].
    func pcsJson() -> String {
        let list = locked { pcs }
        let active = activePc()?.id
        let arr = list.map { ["id": $0.id, "name": $0.name, "active": $0.id == active] as [String: Any] }
        return Json.string(arr) ?? "[]"
    }

    /// Makes another paired computer the one used over Wi-Fi.
    func select(_ id: String) -> Bool {
        locked {
            guard pcs.contains(where: { $0.id == id }) else { return false }
            savePcs(pcs, active: id)
            dropWifiSession()
            preferredHost = 0
            return true
        }
    }

    func forget(_ id: String) {
        locked {
            let rest = pcs.filter { $0.id != id }
            savePcs(rest, active: activeId == id ? rest.first?.id : activeId)
        }
    }

    func pairedPc() -> String? { activePc()?.name }

    private func dropWifiSession() {
        // caller holds the lock
        wifiSession?.session.invalidateAndCancel()
        wifiSession = nil
    }

    // ------------------------------------------------------------------------------------------- requests

    /// Opens a long-lived GET (the live stream) over the best route; nil when the PC is unreachable.
    func stream(_ path: String) -> (Route, StreamConnection)? {
        if let url = URL(string: AgentLink.usbBase + path) {
            let c = StreamConnection(request: makeRequest(url, method: "GET", timeout: AgentLink.streamReadTimeout), pin: nil)
            if c.waitForResponse(timeout: 4) != nil {
                setRoute(.usb)
                return (.usb, c)
            }
            c.close()
        }
        guard let pc = activePc(), !pc.hosts.isEmpty else { return nil }
        for i in hostOrder(pc) {
            guard reachable(pc.hosts[i], pc.port, timeout: 1.5),
                  let url = URL(string: "https://\(AgentLink.urlHost(pc.hosts[i])):\(pc.port)\(path)") else { continue }
            var req = makeRequest(url, method: "GET", timeout: AgentLink.streamReadTimeout)
            req.setValue("Bearer \(pc.token)", forHTTPHeaderField: "Authorization")
            let c = StreamConnection(request: req, pin: pc.id)
            if c.waitForResponse(timeout: 4) != nil {
                locked { preferredHost = i }
                setRoute(.wifi)
                return (.wifi, c)
            }
            c.close()
            forgetProbe(pc.hosts[i], pc.port)
        }
        return nil
    }

    /// Forwards a request (method + path with query) to the agent over the best available route.
    func request(_ method: String, _ pathAndQuery: String) -> Reply {
        if let r = usb(method, pathAndQuery) {
            setRoute(.usb)
            maybePair()
            return r
        }
        if let r = wifi(method, pathAndQuery) {
            setRoute(.wifi)
            return r
        }
        setRoute(.none)
        return Reply(code: 503, contentType: "application/json", body: Data(#"{"error":"offline"}"#.utf8))
    }

    private func usb(_ method: String, _ pathAndQuery: String) -> Reply? {
        guard let url = URL(string: AgentLink.usbBase + pathAndQuery) else { return nil }
        // refused instantly when nothing listens on the phone's own port 8765
        return send(makeRequest(url, method: method, timeout: method == "POST" ? 30 : 4), session: usbSession)
    }

    private func wifi(_ method: String, _ pathAndQuery: String) -> Reply? {
        guard let pc = activePc(), !pc.hosts.isEmpty else { return nil }
        // Reuse one session per pinned certificate so HTTPS connections are kept alive between requests.
        let session: URLSession = locked {
            if let s = wifiSession, s.pin == pc.id { return s.session }
            dropWifiSession()
            let d = PinningDelegate(pin: pc.id)
            let s = URLSession(configuration: AgentLink.pinnedConfig(), delegate: d, delegateQueue: nil)
            wifiSession = (pc.id, s, d)
            return s
        }
        for i in hostOrder(pc) {
            let host = pc.hosts[i]
            // Android's 1.5 s connect timeout: a computer that is off must not hold every request for the full read timeout
            guard reachable(host, pc.port, timeout: 1.5),
                  let url = URL(string: "https://\(AgentLink.urlHost(host)):\(pc.port)\(pathAndQuery)") else { continue }
            var req = makeRequest(url, method: method, timeout: method == "POST" ? 30 : 4)
            req.setValue("Bearer \(pc.token)", forHTTPHeaderField: "Authorization")
            if let r = send(req, session: session) {
                locked { preferredHost = i }
                return r
            }
            forgetProbe(host, pc.port)
            // try the next address
        }
        return nil
    }

    /// Start with the address that worked last time.
    private func hostOrder(_ pc: Pc) -> [Int] {
        let preferred = locked { preferredHost }
        return pc.hosts.indices.sorted { a, b in (a == preferred ? -1 : a) < (b == preferred ? -1 : b) }
    }

    private func makeRequest(_ url: URL, method: String, timeout: TimeInterval) -> URLRequest {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue(appVersion, forHTTPHeaderField: "X-PhoneBox-App") // the agent knows a phone is looking
        req.setValue("ios", forHTTPHeaderField: "X-PhoneBox-Platform") // no APK update offers for this phone
        req.setValue(deviceId, forHTTPHeaderField: "X-PhoneBox-Device")
        req.setValue(deviceModel, forHTTPHeaderField: "X-PhoneBox-Model")
        if method == "POST" { req.httpBody = Data() }
        return req
    }

    /// nil when the request never reached the agent (so another route may be tried).
    private func send(_ req: URLRequest, session: URLSession) -> Reply? {
        let (data, response, error) = AgentLink.perform(req, session: session)
        if let http = response {
            return Reply(code: http.statusCode, contentType: http.value(forHTTPHeaderField: "Content-Type"), body: data ?? Data())
        }
        // every POST acts on the computer (a container restart, a Home Assistant switch, a macro): none may run twice
        if req.httpMethod == "POST", let e = error as? URLError, AgentLink.mayHaveArrived(e) {
            // The command was already submitted. Trying another route now could run a macro or toggle twice.
            return Reply(code: 504, contentType: "application/json",
                         body: Data(#"{"ok":false,"error":"The command result is unknown; check the computer before retrying"}"#.utf8))
        }
        return nil
    }

    /// Errors after which the request may already have reached the agent.
    private static func mayHaveArrived(_ e: URLError) -> Bool {
        switch e.code {
        case .timedOut, .networkConnectionLost, .badServerResponse, .cannotParseResponse, .zeroByteResource: return true
        default: return false
        }
    }

    /// A TCP connect with a short timeout, remembered for a few seconds (URLSession has no separate connect timeout).
    private func reachable(_ host: String, _ port: Int, timeout: TimeInterval) -> Bool {
        let key = "\(host):\(port)"
        if let at = locked({ probed[key] }), Date().timeIntervalSince(at) < 15 { return true }
        guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return false }
        let done = DispatchSemaphore(value: 0)
        var ok = false
        let c = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
        c.stateUpdateHandler = { state in
            switch state {
            case .ready: ok = true; done.signal()
            case .failed, .cancelled: done.signal()
            default: break
            }
        }
        c.start(queue: probeQueue)
        _ = done.wait(timeout: .now() + timeout)
        let result: Bool = probeQueue.sync {
            c.stateUpdateHandler = nil
            c.cancel()
            return ok
        }
        if result { locked { probed[key] = Date() } }
        return result
    }

    private func forgetProbe(_ host: String, _ port: Int) {
        _ = locked { probed.removeValue(forKey: "\(host):\(port)") }
    }

    /// While on USB, refresh the Wi-Fi pairing data about once a minute.
    private func maybePair() {
        let due: Bool = locked {
            guard Date().timeIntervalSince(lastPair) >= 60 else { return false }
            lastPair = Date()
            return true
        }
        guard due else { return }
        background.async { [self] in
            guard let url = URL(string: AgentLink.usbBase + "/api/pair") else { return }
            let (data, response, _) = AgentLink.perform(makeRequest(url, method: "GET", timeout: 3), session: usbSession)
            guard response?.statusCode == 200, let data, let j = Json.object(data) else { return }
            let name = j["pc"] as? String ?? ""
            if j["enabled"] as? Bool == true {
                guard let fp = j["fingerprint"] as? String, let hosts = j["hosts"] as? [String],
                      let port = j["port"] as? Int, let token = j["token"] as? String else { return }
                // add or refresh this computer and make it the active one
                let pc = Pc(id: fp, name: name, hosts: hosts, port: port, token: token)
                locked {
                    savePcs(pcs.filter { $0.id != pc.id && !(!name.isEmpty && $0.name == name) } + [pc], active: pc.id)
                }
            } else if !name.isEmpty {
                // Wi-Fi was turned off on this computer: forget its pairing, keep the others
                locked {
                    let rest = pcs.filter { $0.name != name }
                    if rest.count != pcs.count {
                        savePcs(rest, active: rest.first { $0.id == activeId }?.id ?? rest.first?.id)
                    }
                }
            }
        }
    }

    // ------------------------------------------------------------------------------------------- QR pairing

    /// Why a pairing failed, so the shell can say it in the phone's language.
    enum PairFailure {
        /// No address answered: not the same network, or the firewall blocked PhoneBox.
        case unreachable(pc: String, hosts: [String])
        /// The agent refused the one-time code (it works once, for five minutes).
        case codeRejected(pc: String)
        /// The agent answered, but with an HTTP status the pairing flow does not know.
        case badAnswer(pc: String, code: Int)
        /// The certificate is not the one in the QR code, so this is not the computer the user confirmed.
        case wrongCertificate(pc: String)

        var message: String {
            switch self {
            case let .unreachable(pc, hosts): return L.format("pair_failed_unreachable", pc, hosts.joined(separator: ", "))
            case let .codeRejected(pc): return L.format("pair_failed_code", pc)
            case let .badAnswer(pc, code): return L.format("pair_failed_answer", pc, code)
            case .wrongCertificate: return L.text("pair_failed_certificate")
            }
        }
    }

    /// Pairing without USB: the computer's settings page shows a QR code with this link, and the phone trades the
    /// one-time code for the Wi-Fi key. The certificate fingerprint in the link is pinned from the first connection,
    /// so the key only ever goes to that computer.
    struct PairLink {
        let pc: String
        let fingerprint: String
        let port: Int
        let hosts: [String]
        let code: String

        /// The start of the certificate fingerprint, shown on the computer next to the QR code and in the phone's
        /// confirmation: a link from anyone else (another computer, a message) shows a different code.
        var check: String {
            let s = Array(fingerprint.prefix(8).uppercased())
            return stride(from: 0, to: s.count, by: 4).map { String(s[$0..<min($0 + 4, s.count)]) }.joined(separator: " ")
        }

        /// Only the addresses the agent offers: private network (10/8, 172.16/12, 192.168/16) and Tailscale
        /// (100.64/10) IPv4. A link pointing anywhere else is not a PhoneBox pairing link.
        static func isLocalAddress(_ host: String) -> Bool {
            let p = host.split(separator: ".", omittingEmptySubsequences: false)
            guard p.count == 4 else { return false }
            var b: [Int] = []
            for s in p {
                guard (1...3).contains(s.count), s.allSatisfy({ $0.isASCII && $0.isNumber }), let v = Int(s), (0...255).contains(v) else { return false }
                b.append(v)
            }
            return b[0] == 10 || (b[0] == 172 && (16...31).contains(b[1])) || (b[0] == 192 && b[1] == 168) || (b[0] == 100 && (64...127).contains(b[1]))
        }

        /// Reads https://ersinkoc.github.io/phonebox/pair/#v=1&... (the QR code; the data is in the fragment so it
        /// never reaches a web server) or phonebox://pair?v=1&... (the "Open in PhoneBox" button on that page).
        /// Anything malformed returns nil.
        static func parse(_ url: URL?) -> PairLink? {
            guard let url, let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            let raw: String?
            if c.scheme == "https" && c.host == "ersinkoc.github.io" && c.path.hasPrefix("/phonebox/pair") {
                raw = c.percentEncodedFragment
            } else if c.scheme == "phonebox" && c.host == "pair" {
                raw = c.percentEncodedQuery
            } else {
                raw = nil
            }
            guard let raw else { return nil }
            var q: [String: String] = [:]
            for part in raw.split(separator: "&") {
                guard let i = part.firstIndex(of: "="), i != part.startIndex else { continue }
                q[String(part[..<i])] = String(part[part.index(after: i)...]).removingPercentEncoding
            }
            guard q["v"] == "1" else { return nil }
            guard let fp = q["fp"]?.lowercased(), fp.count == 64, fp.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
            guard let port = q["port"].flatMap({ Int($0) }), (1...65535).contains(port) else { return nil }
            guard let code = q["c"], (16...64).contains(code.count),
                  code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else { return nil }
            let hosts = Array((q["h"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { isLocalAddress($0) }.prefix(8))
            guard !hosts.isEmpty else { return nil }
            var pc = String((q["pc"] ?? "").filter { $0 >= " " }.prefix(64))
            if pc.trimmingCharacters(in: .whitespaces).isEmpty { pc = "your computer" }
            return PairLink(pc: pc, fingerprint: fp, port: port, hosts: hosts, code: code)
        }
    }

    /// Trades the link's one-time code for the Wi-Fi key and makes that computer the active one. Blocks (network):
    /// call it off the main thread. Returns nil when paired, otherwise why it failed.
    func claim(_ link: PairLink) -> PairFailure? {
        var problem = PairFailure.unreachable(pc: link.pc, hosts: link.hosts)
        for host in link.hosts {
            guard reachable(host, link.port, timeout: 3),
                  let url = URL(string: "https://\(host):\(link.port)/api/pair/claim") else { continue }
            let delegate = PinningDelegate(pin: link.fingerprint)
            let session = URLSession(configuration: AgentLink.pinnedConfig(), delegate: delegate, delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(deviceModel, forHTTPHeaderField: "X-PhoneBox-Model")
            req.httpBody = Json.data(["code": link.code])
            let (data, response, _) = AgentLink.perform(req, session: session)
            if delegate.mismatch { problem = .wrongCertificate(pc: link.pc); continue }
            guard let response else { continue } // try the next address
            switch response.statusCode {
            case 200: break
            case 403: return .codeRejected(pc: link.pc)
            default: problem = .badAnswer(pc: link.pc, code: response.statusCode); continue
            }
            guard let data, let j = Json.object(data), let token = j["token"] as? String else { continue }
            if (j["fingerprint"] as? String)?.lowercased() != link.fingerprint.lowercased() { return .wrongCertificate(pc: link.pc) }
            let offered = (j["hosts"] as? [String])?.filter { PairLink.isLocalAddress($0) } ?? []
            // the name the user confirmed; only an entry for this very certificate is replaced, never one that merely
            // has the same name
            let pc = Pc(id: link.fingerprint.lowercased(), name: link.pc, hosts: offered.isEmpty ? link.hosts : offered,
                        port: j["port"] as? Int ?? link.port, token: token)
            locked {
                savePcs(pcs.filter { $0.id != pc.id } + [pc], active: pc.id)
                dropWifiSession()
                preferredHost = 0
            }
            return nil
        }
        return problem
    }

    // ------------------------------------------------------------------------------------------- helpers

    static let usbBase = "http://127.0.0.1:8765"
    /// The agent sends "state" every second, so a silent connection for this long is dead.
    static let streamReadTimeout: TimeInterval = 8

    static func pinnedConfig() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.waitsForConnectivity = false
        return config
    }

    /// IPv6 literals need brackets in a URL.
    static func urlHost(_ host: String) -> String { host.contains(":") ? "[\(host)]" : host }

    /// Runs a request and waits for it (never on the main thread).
    static func perform(_ req: URLRequest, session: URLSession) -> (Data?, HTTPURLResponse?, Error?) {
        let done = DispatchSemaphore(value: 0)
        var out: (Data?, HTTPURLResponse?, Error?) = (nil, nil, nil)
        session.dataTask(with: req) { data, response, error in
            out = (data, response as? HTTPURLResponse, error)
            done.signal()
        }.resume()
        done.wait()
        return out
    }

    private static func machine() -> String {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return sim }
        var u = utsname()
        uname(&u)
        return withUnsafeBytes(of: &u.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// Paired computers live in the Keychain (they hold the Wi-Fi tokens); which one is active, in UserDefaults.
    private enum Store {
        static let activeKey = "pairing.active"
        private static let service = "net.oxog.phonebox.pairing"
        private static let account = "pcs"

        static func loadPcs() -> [Pc] {
            var q = base()
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return [] }
            return (try? JSONDecoder().decode([Pc].self, from: data)) ?? []
        }

        static func savePcs(_ list: [Pc]) {
            guard let data = try? JSONEncoder().encode(list) else { return }
            let attrs: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            let status = SecItemUpdate(base() as CFDictionary, attrs as CFDictionary)
            if status == errSecItemNotFound {
                SecItemAdd(base().merging(attrs) { $1 } as CFDictionary, nil)
            }
        }

        private static func base() -> [String: Any] {
            [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        }
    }
}

/// Trusts exactly one certificate: the one whose SHA-256 fingerprint was paired (the agent's is self-signed). The host
/// name is not checked: the identity is the pinned certificate.
final class PinningDelegate: NSObject, URLSessionDataDelegate {
    let pin: String
    private(set) var mismatch = false

    init(pin: String) { self.pin = pin.lowercased() }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let (disposition, credential) = PinningDelegate.evaluate(challenge, pin: pin)
        if disposition == .cancelAuthenticationChallenge { mismatch = true }
        completionHandler(disposition, credential)
    }

    static func evaluate(_ challenge: URLAuthenticationChallenge, pin: String) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else { return (.performDefaultHandling, nil) }
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
            return (.cancelAuthenticationChallenge, nil)
        }
        let der = SecCertificateCopyData(leaf) as Data
        let fp = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        guard fp == pin.lowercased() else { return (.cancelAuthenticationChallenge, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }
}

/// A long-lived response read line by line (server-sent events), like a BufferedReader over the response body.
final class StreamConnection: NSObject, URLSessionDataDelegate {
    private let cond = NSCondition()
    private var buffer = Data()
    private var finished = false
    private var status: Int?
    private var session: URLSession!
    private let pin: String?

    init(request: URLRequest, pin: String?) {
        self.pin = pin
        super.init()
        let config = AgentLink.pinnedConfig()
        config.timeoutIntervalForRequest = AgentLink.streamReadTimeout // idle time between chunks
        config.timeoutIntervalForResource = 7 * 24 * 3600
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        session.dataTask(with: request).resume()
    }

    /// The HTTP status, or nil when the connection failed or nothing answered in time.
    func waitForResponse(timeout: TimeInterval) -> Int? {
        let deadline = Date().addingTimeInterval(timeout)
        cond.lock()
        defer { cond.unlock() }
        while status == nil && !finished {
            if !cond.wait(until: deadline) { break }
        }
        return status
    }

    /// The next line without its line break; nil at the end of the stream or after the read timeout.
    func readLine() -> String? {
        cond.lock()
        defer { cond.unlock() }
        while true {
            if let i = buffer.firstIndex(of: 10) {
                var line = String(decoding: buffer[buffer.startIndex..<i], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...i)
                if line.hasSuffix("\r") { line.removeLast() }
                return line
            }
            if finished { return nil }
            if !cond.wait(until: Date().addingTimeInterval(AgentLink.streamReadTimeout)) { return nil }
        }
    }

    func close() {
        session.invalidateAndCancel()
        cond.lock()
        finished = true
        cond.broadcast()
        cond.unlock()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        cond.lock()
        status = (response as? HTTPURLResponse)?.statusCode ?? 0
        cond.broadcast()
        cond.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        cond.lock()
        buffer.append(data)
        cond.broadcast()
        cond.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        cond.lock()
        finished = true
        cond.broadcast()
        cond.unlock()
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let pin else { completionHandler(.performDefaultHandling, nil); return }
        let (d, c) = PinningDelegate.evaluate(challenge, pin: pin)
        completionHandler(d, c)
    }
}

/// Small JSON helpers.
enum Json {
    static func string(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value), let d = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func data(_ value: Any) -> Data? {
        guard JSONSerialization.isValidJSONObject(value) else { return nil }
        return try? JSONSerialization.data(withJSONObject: value)
    }

    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// A JavaScript string literal.
    static func quote(_ s: String) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: [s]), let a = String(data: d, encoding: .utf8) else { return "\"\"" }
        return String(a.dropFirst().dropLast())
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
}

/// Localized strings of the native shell (Localizable.strings).
enum L {
    static func text(_ key: String) -> String { NSLocalizedString(key, comment: "") }
    static func format(_ key: String, _ args: CVarArg...) -> String { String(format: text(key), arguments: args) }
}
