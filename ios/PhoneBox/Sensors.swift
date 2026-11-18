import AVFoundation
import ImageIO
import UIKit

/// Room light and proximity for the panel (Android's light and proximity sensors in MainActivity.onSensorChanged):
/// brightness that follows the room, the night screen when the room goes dark, and waking the night screen with a wave
/// of the hand. Events go to window.onAndroidSensor(kind, value) exactly as on Android.
///
/// iOS gives apps no ambient light sensor, so the room's light is measured with the front camera's exposure meter
/// (the brightness value of its frames, converted to lux). No picture is kept or sent anywhere. The camera only runs
/// while the panel uses the light (auto brightness or "night screen when the room is dark"), the panel is in front, and
/// the camera may be used; iOS then shows its camera indicator.
///
/// Proximity uses iOS's proximity monitoring, which turns the screen off while something is near the phone. It is
/// therefore on only while the night screen or the idle dim is showing, which is when a wave of the hand wakes it.
final class Sensors: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var send: ((String, String) -> Void)?

    private var wantLight = false
    private var wantProximity = false
    private var active = false

    private let cameraQueue = DispatchQueue(label: "light-sensor")
    private var session: AVCaptureSession?
    private var lastSample = Date.distantPast
    private var lastLux: Double = -1
    private var lastLuxAt = Date.distantPast
    private var near: Bool?

    /// Which sensors the phone has, as Android reports them: {"light": true, "proximity": true}.
    static func available() -> String {
        let light = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) != nil
            && AVCaptureDevice.authorizationStatus(for: .video) != .denied
            && AVCaptureDevice.authorizationStatus(for: .video) != .restricted
        return Json.string(["light": light, "proximity": hasProximity]) ?? "{}"
    }

    /// Checked once: turning proximity monitoring on to test it could blank the screen for a moment.
    private static let hasProximity: Bool = {
        let device = UIDevice.current
        let was = device.isProximityMonitoringEnabled
        device.isProximityMonitoringEnabled = true
        let has = device.isProximityMonitoringEnabled
        device.isProximityMonitoringEnabled = was
        return has
    }()

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(proximityChanged),
                                               name: UIDevice.proximityStateDidChangeNotification, object: nil)
    }

    /// From the panel (bridge.sensorNeeds): what it uses right now.
    func setNeeds(light: Bool, proximity: Bool) {
        wantLight = light
        wantProximity = proximity
        apply()
    }

    func resume() {
        active = true
        apply()
    }

    func pause() {
        active = false
        apply()
    }

    private func apply() {
        let proximity = active && wantProximity
        if UIDevice.current.isProximityMonitoringEnabled != proximity {
            UIDevice.current.isProximityMonitoringEnabled = proximity
            near = nil
        }
        if active && wantLight { startCamera() } else { stopCamera() }
    }

    @objc private func proximityChanged() {
        guard UIDevice.current.isProximityMonitoringEnabled else { return }
        let isNear = UIDevice.current.proximityState
        guard isNear != near else { return }
        near = isNear
        send?("proximity", isNear ? "true" : "false")
    }

    // ------------------------------------------------------------------------------------------- light

    private func startCamera() {
        guard session == nil else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { if granted { self.apply() } }
            }
            return
        default:
            return
        }
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let input = try? AVCaptureDeviceInput(device: camera) else { return }
        let s = AVCaptureSession()
        s.sessionPreset = .low
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: cameraQueue)
        guard s.canAddInput(input), s.canAddOutput(output) else { return }
        s.addInput(input)
        s.addOutput(output)
        // the lowest frame rate the camera offers: only the exposure meter is needed
        if (try? camera.lockForConfiguration()) != nil {
            if let range = camera.activeFormat.videoSupportedFrameRateRanges.min(by: { $0.minFrameRate < $1.minFrameRate }) {
                let fps = max(range.minFrameRate, 2)
                if fps <= range.maxFrameRate {
                    camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
                    camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
                }
            }
            camera.unlockForConfiguration()
        }
        session = s
        cameraQueue.async { s.startRunning() }
    }

    private func stopCamera() {
        guard let s = session else { return }
        session = nil
        cameraQueue.async { s.stopRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = Date()
        guard now.timeIntervalSince(lastSample) >= 0.5 else { return }
        lastSample = now
        guard let attachments = CMCopyDictionaryOfAttachments(allocator: nil, target: sampleBuffer,
                                                              attachmentMode: kCMAttachmentMode_ShouldPropagate) as? [String: Any],
              let exif = attachments[kCGImagePropertyExifDictionary as String] as? [String: Any],
              let bv = (exif[kCGImagePropertyExifBrightnessValue as String] as? NSNumber)?.doubleValue else { return }
        // APEX brightness value to illuminance: about 2.5 · 2^Bv lux
        let lux = max(0, 2.5 * pow(2, bv))
        DispatchQueue.main.async { self.light(lux) }
    }

    /// Passed on when it changes noticeably, as on Android.
    private func light(_ lux: Double) {
        guard session != nil else { return }
        let now = Date()
        let jump = lastLux < 0 || abs(lux - lastLux) > max(3, lastLux * 0.15)
        if !jump && now.timeIntervalSince(lastLuxAt) < 10 { return }
        if now.timeIntervalSince(lastLuxAt) < 0.7 { return }
        lastLux = lux
        lastLuxAt = now
        send?("light", String(format: "%.1f", lux))
    }
}
