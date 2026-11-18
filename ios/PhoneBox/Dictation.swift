import AVFoundation
import Foundation
import Speech

/// Speech to text for the Dictation widget (port of Dictation.kt), with Apple's speech recognizer, which may use
/// Apple's servers. "On the phone only" asks for on-device recognition and is refused where the language has none.
///
/// One session at a time, at most `maxSeconds` long, cancelled when the panel pauses (another app in front, screen
/// locked). Every session has an id: events go to the panel's main frame as window.onAndroidSpeech(kind, text, id), and
/// stop or cancel act only on the session they name, so one widget can never end another's. A sandboxed widget frame
/// never sees the results. Nothing is stored. Everything here runs on the main thread.
///
/// Error kinds are the ones the panel already knows from Android: "permission", "permission-blocked", "unavailable",
/// "offline-unavailable", "cancelled", and Android's SpeechRecognizer codes "2" (network) and "7" (nothing heard).
final class Dictation {
    private struct Request {
        let id: Int
        let lang: String
        let offline: Bool
    }

    private let js: (String) -> Void
    /// Called when the microphone is released, so the volume keys can take the audio session back.
    var onAudioReleased: (() -> Void)?

    private let engine = AVAudioEngine()
    private var tapInstalled = false
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var session = 0
    private var waitingFor: Request?
    private var timers: [Timer] = []
    private var heard = false
    private var lastHeard = Date()
    private var startedAt = Date()
    private var lastText = ""

    private static let maxSeconds: TimeInterval = 60
    private static let maxChars = 2000
    /// Android's recognizer ends by itself after a pause; this one is told to.
    private static let pauseSeconds: TimeInterval = 2
    private static let nothingSeconds: TimeInterval = 8

    init(js: @escaping (String) -> Void) { self.js = js }

    func available() -> Bool { SFSpeechRecognizer()?.isAvailable ?? false }

    private enum Permission { case granted, denied, unknown }

    private func permission() -> Permission {
        let speech = SFSpeechRecognizer.authorizationStatus()
        let mic = AVAudioSession.sharedInstance().recordPermission
        if speech == .denied || speech == .restricted || mic == .denied { return .denied }
        if speech == .authorized && mic == .granted { return .granted }
        return .unknown
    }

    /// Starts session `id`; asks for the microphone and speech recognition first if needed. `lang` is BCP 47 or "".
    func start(id: Int, lang: String, offline: Bool) {
        let request = Request(id: id, lang: lang, offline: offline)
        switch permission() {
        case .granted:
            begin(request)
        case .denied:
            // iOS asks only once; after that only Settings can turn the microphone or speech recognition on
            send("error", "permission-blocked", id)
        case .unknown:
            // a newer request replaces one still waiting for the permission prompt
            if let w = waitingFor { send("error", "cancelled", w.id) }
            let asking = waitingFor != nil
            waitingFor = request
            if !asking { ask() }
        }
    }

    private func ask() {
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else {
                DispatchQueue.main.async { self.onPermission(false) }
                return
            }
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                DispatchQueue.main.async { self.onPermission(granted) }
            }
        }
    }

    private func onPermission(_ granted: Bool) {
        guard let request = waitingFor else { return }
        waitingFor = nil
        if granted { begin(request) } else { send("error", "permission", request.id) }
    }

    /// Stops listening and delivers what was heard so far, if `id` is the session running.
    func stop(_ id: Int) {
        if id == session { finishAudio(id) }
    }

    /// Drops the session without a result, if `id` is the one running or waiting. 0 = whatever runs (the panel
    /// paused): a request waiting for the permission prompt stays, as that prompt itself pauses the panel.
    func cancel(_ id: Int) {
        if id != 0, let w = waitingFor, w.id == id {
            waitingFor = nil
            send("error", "cancelled", w.id)
        }
        if session != 0 && (id == 0 || id == session) {
            let was = session
            end()
            send("error", "cancelled", was)
        }
    }

    private func begin(_ r: Request) {
        if session != 0 {
            let was = session
            end()
            send("error", "cancelled", was)
        }
        let rec = r.lang.isEmpty ? SFSpeechRecognizer() : SFSpeechRecognizer(locale: Locale(identifier: r.lang))
        guard let rec, rec.isAvailable else { send("error", "unavailable", r.id); return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if r.offline {
            // "on the phone only" is a promise: only on-device recognition keeps it
            guard rec.supportsOnDeviceRecognition else { send("error", "offline-unavailable", r.id); return }
            req.requiresOnDeviceRecognition = true
        }

        let audio = AVAudioSession.sharedInstance()
        do {
            try audio.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try audio.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            releaseAudio()
            send("error", "unavailable", r.id)
            return
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            releaseAudio()
            send("error", "unavailable", r.id)
            return
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak req] buffer, _ in req?.append(buffer) }
        tapInstalled = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            tapInstalled = false
            releaseAudio()
            send("error", "unavailable", r.id)
            return
        }

        recognizer = rec
        request = req
        session = r.id
        heard = false
        lastText = ""
        startedAt = Date()
        lastHeard = Date()
        let id = r.id
        task = rec.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async { self?.onResult(id, result, error) }
        }
        send("ready", "", id)
        timers.append(Timer.scheduledTimer(withTimeInterval: Dictation.maxSeconds, repeats: false) { [weak self] _ in self?.finishAudio(id) })
        timers.append(Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, self.session == id, self.tapInstalled else { return }
            let now = Date()
            if self.heard ? now.timeIntervalSince(self.lastHeard) > Dictation.pauseSeconds
                          : now.timeIntervalSince(self.startedAt) > Dictation.nothingSeconds {
                self.finishAudio(id)
            }
        })
    }

    private func onResult(_ id: Int, _ result: SFSpeechRecognitionResult?, _ error: Error?) {
        guard id == session else { return }
        if let result {
            let text = result.bestTranscription.formattedString
            if text != lastText {
                lastText = text
                if !text.isEmpty { heard = true; lastHeard = Date() }
            }
            if result.isFinal {
                end()
                send("final", text, id)
            } else {
                send("partial", text, id)
            }
            return
        }
        if let error {
            let text = lastText
            end()
            if !text.isEmpty { send("final", text, id); return }
            let ns = error as NSError
            send("error", ns.domain == NSURLErrorDomain ? "2" : "7", id)
        }
    }

    /// Closes the microphone; the recognizer then delivers its final result.
    private func finishAudio(_ id: Int) {
        guard id == session, tapInstalled else { return }
        stopEngine()
        request?.endAudio()
        send("end", "", id)
        // the final result normally follows at once; never leave the widget waiting
        timers.append(Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            guard let self, self.session == id else { return }
            let text = self.lastText
            self.end()
            if text.isEmpty { self.send("error", "7", id) } else { self.send("final", text, id) }
        })
    }

    private func stopEngine() {
        if engine.isRunning { engine.stop() }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        releaseAudio()
    }

    private func releaseAudio() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        onAudioReleased?()
    }

    private func end() {
        timers.forEach { $0.invalidate() }
        timers.removeAll()
        let hadAudio = tapInstalled
        if engine.isRunning { engine.stop() }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        recognizer = nil
        session = 0
        lastText = ""
        if hadAudio { releaseAudio() }
    }

    private func send(_ kind: String, _ text: String, _ id: Int) {
        js("window.onAndroidSpeech && window.onAndroidSpeech(\(Json.quote(kind)), \(Json.quote(String(text.prefix(Dictation.maxChars)))), \(id))")
    }
}
