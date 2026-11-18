import Foundation
import Network

/// USB connection to the computer: the iOS side of what "adb reverse tcp:8765 tcp:8765" does for the Android app.
///
/// iOS has no adb, but the computer can open TCP connections to the phone over the cable (Apple's usbmuxd). While the
/// panel is open, the agent (IosUsb.cs) keeps a few such connections, "pipes", waiting on 127.0.0.1:8767. This class
/// also listens on 127.0.0.1:8765, where AgentLink's USB route connects as it does on Android, and joins each of those
/// connections to a waiting pipe. The bytes then go to the agent's own 127.0.0.1:8765 on the computer unchanged.
///
/// Only loopback is used: nothing on the network can reach either port.
final class UsbTunnel {
    static let pipePort: UInt16 = 8767
    static let localPort: UInt16 = 8765
    /// The agent sends this first on every pipe (IosUsb.Hello), so only a PhoneBox agent's pipes are used.
    private static let hello = Data("PHONEBOX-USB/1\n".utf8)

    /// Whether a pipe is waiting (the cable is in and the agent is running): AgentLink tries USB only then.
    var ready: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _ready
    }

    /// Called on the main thread when `ready` changes.
    var onReadyChange: ((Bool) -> Void)?

    private final class Pipe {
        let connection: NWConnection
        var peer: NWConnection?
        init(_ c: NWConnection) { connection = c }
    }

    private let queue = DispatchQueue(label: "usb-tunnel")
    private let lock = NSLock()
    private var _ready = false
    private var running = false
    private var pipeListener: NWListener?
    private var localListener: NWListener?
    private var idle: [Pipe] = []
    private var busy: [ObjectIdentifier: Pipe] = [:]
    private var waiting: [NWConnection] = []

    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            pipeListener = listen(UsbTunnel.pipePort) { [weak self] c in self?.acceptPipe(c) }
            localListener = listen(UsbTunnel.localPort) { [weak self] c in self?.acceptLocal(c) }
        }
    }

    func stop() {
        queue.async { [self] in
            guard running else { return }
            running = false
            pipeListener?.cancel()
            localListener?.cancel()
            pipeListener = nil
            localListener = nil
            idle.forEach { $0.connection.cancel() }
            busy.values.forEach { $0.connection.cancel(); $0.peer?.cancel() }
            waiting.forEach { $0.cancel() }
            idle.removeAll()
            busy.removeAll()
            waiting.removeAll()
            publish()
        }
    }

    private func listen(_ port: UInt16, accept: @escaping (NWConnection) -> Void) -> NWListener? {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        guard let listener = try? NWListener(using: params) else { return nil }
        listener.newConnectionHandler = accept
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            // the port can be briefly taken after a quick restart: try again
            if case .failed = state {
                listener?.cancel()
                self?.queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.relisten(port) }
            }
        }
        listener.start(queue: queue)
        return listener
    }

    private func relisten(_ port: UInt16) {
        guard running else { return }
        if port == UsbTunnel.pipePort {
            pipeListener = listen(port) { [weak self] c in self?.acceptPipe(c) }
        } else {
            localListener = listen(port) { [weak self] c in self?.acceptLocal(c) }
        }
    }

    // ------------------------------------------------------------------------------------------- pipes from the computer

    private func acceptPipe(_ c: NWConnection) {
        guard running else { c.cancel(); return }
        c.start(queue: queue)
        let timeout = DispatchWorkItem { c.cancel() }
        queue.asyncAfter(deadline: .now() + 3, execute: timeout)
        c.receive(minimumIncompleteLength: UsbTunnel.hello.count, maximumLength: UsbTunnel.hello.count) { [weak self] data, _, _, _ in
            timeout.cancel()
            guard let self, self.running, data == UsbTunnel.hello else { c.cancel(); return }
            let pipe = Pipe(c)
            self.readPipe(pipe)
            if !self.waiting.isEmpty {
                self.join(pipe, self.waiting.removeFirst())
            } else {
                self.idle.append(pipe)
                self.publish()
            }
        }
    }

    /// Everything the computer sends goes to the joined local connection. An idle pipe never receives anything until it
    /// is used, so data there, or the computer closing it, ends it.
    private func readPipe(_ pipe: Pipe) {
        pipe.connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty, let peer = pipe.peer {
                peer.send(content: data, completion: .contentProcessed { _ in })
            } else if let data, !data.isEmpty {
                self.close(pipe)
                return
            }
            if complete || error != nil {
                self.close(pipe)
                return
            }
            self.readPipe(pipe)
        }
    }

    // ------------------------------------------------------------------------------------------- local connections

    private func acceptLocal(_ c: NWConnection) {
        guard running else { c.cancel(); return }
        c.start(queue: queue)
        if !idle.isEmpty {
            join(idle.removeFirst(), c)
            publish()
            return
        }
        // the agent opens a new pipe as soon as one is used: wait a moment for it
        waiting.append(c)
        queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, let i = self.waiting.firstIndex(where: { $0 === c }) else { return }
            self.waiting.remove(at: i)
            c.cancel()
        }
    }

    private func join(_ pipe: Pipe, _ local: NWConnection) {
        pipe.peer = local
        busy[ObjectIdentifier(pipe)] = pipe
        readLocal(pipe, local)
    }

    private func readLocal(_ pipe: Pipe, _ local: NWConnection) {
        local.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                pipe.connection.send(content: data, completion: .contentProcessed { _ in })
            }
            if complete || error != nil {
                self.close(pipe)
                return
            }
            self.readLocal(pipe, local)
        }
    }

    private func close(_ pipe: Pipe) {
        pipe.connection.cancel()
        pipe.peer?.cancel()
        pipe.peer = nil
        busy.removeValue(forKey: ObjectIdentifier(pipe))
        idle.removeAll { $0 === pipe }
        publish()
    }

    private func publish() {
        let now = running && !idle.isEmpty
        lock.lock()
        let changed = now != _ready
        _ready = now
        lock.unlock()
        if changed {
            DispatchQueue.main.async { [weak self] in self?.onReadyChange?(now) }
        }
    }
}
