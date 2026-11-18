import Foundation

/// Keeps one live connection to the agent's /api/stream (server-sent events) and hands every event to `deliver`
/// (port of AgentStream.kt). Reconnects after errors. On Wi-Fi it reconnects every minute so the USB route is preferred
/// again when it appears. "open" / "close" pseudo-events tell the panel when to stop or resume its polling fallback.
final class AgentStream {
    private let link: AgentLink
    private let deliver: (_ event: String, _ data: String) -> Void

    private let lock = NSLock()
    private var running = false
    // each start() gets a new generation; a thread from an earlier one (still connecting after a quick pause/resume)
    // sees the change and ends, so there is never more than one stream
    private var generation = 0
    private var current: StreamConnection?

    init(link: AgentLink, deliver: @escaping (_ event: String, _ data: String) -> Void) {
        self.link = link
        self.deliver = deliver
    }

    func start() {
        lock.lock()
        if running { lock.unlock(); return }
        running = true
        generation += 1
        let gen = generation
        lock.unlock()
        let thread = Thread { [weak self] in self?.loop(gen) }
        thread.name = "agent-stream"
        thread.start()
    }

    func stop() {
        lock.lock()
        running = false
        let c = current
        current = nil
        lock.unlock()
        c?.close()
    }

    private func alive(_ gen: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running && gen == generation
    }

    private func loop(_ gen: Int) {
        while alive(gen) {
            var opened = false
            if let opening = link.stream("/api/stream") {
                let (route, c) = opening
                if c.waitForResponse(timeout: 0) != 200 || !alive(gen) {
                    c.close()
                } else {
                    lock.lock()
                    current = c
                    lock.unlock()
                    opened = true
                    deliver("open", "{\"route\":\"\(route.rawValue)\"}")
                    let since = Date()
                    var event = "message"
                    var data = ""
                    while alive(gen), let line = c.readLine() {
                        if line.isEmpty {
                            if !data.isEmpty { deliver(event, data) }
                            event = "message"
                            data = ""
                            if route == .wifi && Date().timeIntervalSince(since) > 60 { break }
                        } else if line.hasPrefix("event:") {
                            event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:") {
                            data += String(line.dropFirst(5).drop { $0 == " " || $0 == "\t" })
                        }
                    }
                    c.close()
                    lock.lock()
                    if current === c { current = nil } // a newer thread may own it already
                    lock.unlock()
                }
            }
            if opened { deliver("close", "{}") }
            if alive(gen) { Thread.sleep(forTimeInterval: opened ? 0.3 : 2) }
        }
    }
}
