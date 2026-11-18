import Foundation
import WebKit

/// Serves the panel and proxies its "/agent/..." requests (the iOS counterpart of MainActivity.shouldInterceptRequest).
///
/// The panel is loaded from phonebox-panel://app/www/index.html: the files come from the app bundle (the same www folder
/// the Android app ships), and "/agent/..." is forwarded to the PhoneBox agent on the PC through AgentLink. The web view
/// itself therefore never makes local-network requests (no CORS, mixed-content or certificate issues).
final class PanelSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "phonebox-panel"
    static let host = "app"
    static let indexURL = URL(string: "\(scheme)://\(host)/www/index.html")!

    private static let panelHeader = "X-PhoneBox-Panel"
    private static let readOnlyImages: Set<String> = [
        "/agent/api/art", "/agent/api/procs/icon", "/agent/api/controls/radio-logo", "/agent/api/apps/icon",
        "/agent/api/discord/img", "/agent/api/shortcuts/icon",
    ]

    private let link: AgentLink
    private let proxyQueue = DispatchQueue(label: "agent-proxy", qos: .userInitiated, attributes: .concurrent)
    private let wwwRoot: URL?
    /// Tasks WebKit has not stopped yet (main thread only): answering a stopped task raises an exception.
    private var live = Set<ObjectIdentifier>()

    init(link: AgentLink) {
        self.link = link
        wwwRoot = Bundle.main.resourceURL?.appendingPathComponent("www", isDirectory: true).standardizedFileURL
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        live.insert(id)
        guard let url = task.request.url, url.host == PanelSchemeHandler.host,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            respond(task, code: 404, type: "text/plain", body: Data())
            return
        }
        let path = parts.path
        if path.hasPrefix("/agent/") {
            guard fromPanel(task.request, path: path) else {
                respond(task, code: 403, type: "text/plain", body: Data())
                return
            }
            let method = task.request.httpMethod ?? "GET"
            let encodedPath = String(parts.percentEncodedPath.dropFirst("/agent".count))
            let query = parts.percentEncodedQuery.map { "?\($0)" } ?? ""
            proxyQueue.async { [link] in
                let r = link.request(method, encodedPath + query)
                DispatchQueue.main.async {
                    self.respond(task, code: r.code, type: r.contentType ?? "application/octet-stream", body: r.body)
                }
            }
            return
        }
        if path.hasPrefix("/www/"), let file = bundleFile(String(path.dropFirst("/www/".count))),
           let data = try? Data(contentsOf: file) {
            respond(task, code: 200, type: PanelSchemeHandler.mimeType(file.pathExtension), body: data)
            return
        }
        respond(task, code: 404, type: "text/plain", body: Data())
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        live.remove(ObjectIdentifier(task))
    }

    /// Only the panel itself may reach the agent. Every frame of the web view comes through here, including the
    /// sandboxed iframe of a Custom HTML widget, which is meant to talk to the panel through postMessage only. The panel
    /// sends X-PhoneBox-Panel on its requests; a sandboxed frame cannot add it without a CORS preflight, which is
    /// refused. Images (album art, process icons) cannot carry headers, but they are read-only GETs.
    private func fromPanel(_ req: URLRequest, path: String) -> Bool {
        let headers = req.allHTTPHeaderFields ?? [:]
        if headers.keys.contains(where: { $0.caseInsensitiveCompare(PanelSchemeHandler.panelHeader) == .orderedSame }) { return true }
        return (req.httpMethod ?? "GET") == "GET" && PanelSchemeHandler.readOnlyImages.contains(path)
    }

    /// A file inside the bundled www folder; nothing outside it.
    private func bundleFile(_ relative: String) -> URL? {
        guard let root = wwwRoot, !relative.isEmpty else { return nil }
        let file = root.appendingPathComponent(relative).standardizedFileURL
        guard file.path.hasPrefix(root.path + "/") else { return nil }
        var dir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &dir), !dir.boolValue else { return nil }
        return file
    }

    private func respond(_ task: WKURLSchemeTask, code: Int, type: String, body: Data) {
        let id = ObjectIdentifier(task)
        guard live.remove(id) != nil, let url = task.request.url else { return }
        let headers = ["Content-Type": type, "Cache-Control": "no-store", "Content-Length": String(body.count)]
        guard let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        task.didReceive(response)
        task.didReceive(body)
        task.didFinish()
    }

    /// The panel is made of ES modules, which need a JavaScript MIME type.
    static func mimeType(_ ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "ico": return "image/x-icon"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "txt": return "text/plain; charset=utf-8"
        default: return "application/octet-stream"
        }
    }
}
