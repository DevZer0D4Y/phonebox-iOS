import AudioToolbox
import AVFoundation
import CoreHaptics
import MediaPlayer
import UIKit

/// The tap feedback and notification vibrations of the bridge (haptic / buzz).
final class Haptics {
    private let light = UIImpactFeedbackGenerator(style: .light)
    private var engine: CHHapticEngine?

    func tap() {
        light.impactOccurred()
        light.prepare()
    }

    /// Notification vibration; `pattern` is a "wait,vibrate,wait,vibrate..." list of milliseconds (as on Android).
    func buzz(_ pattern: String) {
        let timings = pattern.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.prefix(64)
        guard !timings.isEmpty else { return }
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            return
        }
        var events: [CHHapticEvent] = []
        var at: TimeInterval = 0
        for (i, ms) in timings.enumerated() {
            let d = TimeInterval(max(0, min(ms, 10_000))) / 1000
            if i % 2 == 1 && d > 0 {
                events.append(CHHapticEvent(eventType: .hapticContinuous, parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.4),
                ], relativeTime: at, duration: d))
            }
            at += d
        }
        guard !events.isEmpty else { return }
        do {
            if engine == nil {
                let e = try CHHapticEngine()
                e.isAutoShutdownEnabled = true
                e.playsHapticsOnly = true
                e.resetHandler = { [weak e] in try? e?.start() }
                engine = e
            }
            guard let engine else { return }
            try engine.start()
            let player = try engine.makePlayer(with: CHHapticPattern(events: events, parameters: []))
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        }
    }
}

/// Volume up / down flip to the previous / next page (unless turned off in the settings), as on Android.
///
/// iOS has no key events for the volume buttons, so this watches the output volume: a change is a key press, and the
/// volume is put back right away through a hidden system volume view (which also keeps the volume overlay away).
final class VolumeKeys: NSObject {
    var onKey: ((String) -> Void)?

    private let volumeView = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
    private var observation: NSKeyValueObservation?
    private var enabled = true
    private var wanted = false
    private var level: Float = 0.5

    func attach(to view: UIView) {
        volumeView.alpha = 0.0001
        volumeView.isUserInteractionEnabled = false
        view.addSubview(volumeView)
    }

    /// From the bridge: whether the keys flip pages (true) or change the phone's volume (false).
    func setEnabled(_ on: Bool) {
        enabled = on
        on && wanted ? activate() : deactivate()
    }

    /// The panel is in front.
    func resume() {
        wanted = true
        if enabled { activate() }
    }

    /// The panel is in the background.
    func pause() {
        wanted = false
        deactivate()
    }

    /// The microphone was released (Dictation): take the audio session back.
    func audioReleased() {
        guard let o = observation else { return }
        o.invalidate()
        observation = nil
        activate()
    }

    private func activate() {
        guard observation == nil else { return }
        let audio = AVAudioSession.sharedInstance()
        do {
            // ambient and mixed: music playing on the phone goes on undisturbed
            try audio.setCategory(.ambient, options: [.mixWithOthers])
            try audio.setActive(true)
        } catch {
            return
        }
        level = audio.outputVolume
        // at either end a press in that direction would change nothing
        if level <= 0.07 || level >= 0.93 { setVolume(0.5) }
        observation = audio.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let v = change.newValue else { return }
            DispatchQueue.main.async { self?.changed(v) }
        }
    }

    private func deactivate() {
        guard let o = observation else { return }
        o.invalidate()
        observation = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func changed(_ v: Float) {
        guard observation != nil, abs(v - level) > 0.001 else { return }
        onKey?(v > level ? "prev" : "next")
        setVolume(level)
    }

    private func setVolume(_ v: Float) {
        level = v
        let slider = volumeView.subviews.compactMap { $0 as? UISlider }.first
        // the slider applies the value on the next run loop pass after it is created
        DispatchQueue.main.async { slider?.setValue(v, animated: false) }
    }
}

/// The phone's battery for the bridge (battery()): the same JSON shape as on Android. iOS has no battery temperature or
/// charger type, and no view of the USB data link.
enum Battery {
    static func json() -> String {
        let d = UIDevice.current
        d.isBatteryMonitoringEnabled = true
        let level = d.batteryLevel < 0 ? -1 : Int((d.batteryLevel * 100).rounded())
        let plugged = d.batteryState == .charging || d.batteryState == .full
        return Json.string(["level": level, "plugged": plugged, "temp": 0, "source": "", "usb": NSNull()] as [String: Any]) ?? "{}"
    }
}
