import UIKit
import WebKit

/// Full-screen desk panel (port of MainActivity.kt). The UI is the plain HTML/JS panel of the Android app, bundled as
/// www. The UI calls "/agent/..." URLs; PanelSchemeHandler forwards them to the PhoneBox agent on the PC (see
/// AgentLink). The native side is reached through window.Android, the same bridge the Android shell offers.
final class PanelViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {

    private var web: WKWebView!
    private let link = AgentLink()
    private lazy var stream = AgentStream(link: link) { [weak self] event, data in
        let js = "window.onAgentStream && window.onAgentStream(\(Json.quote(event)), \(Json.quote(data)))"
        DispatchQueue.main.async { self?.evaluate(js) }
    }
    private lazy var dictation = Dictation { [weak self] script in self?.evaluate(script) }
    private let haptics = Haptics()
    private let volumeKeys = VolumeKeys()
    private let tunnel = UsbTunnel()
    private let sensors = Sensors()
    private let location = PhoneLocation()
    private lazy var scheme = PanelSchemeHandler(link: link)

    /// Key for the bridge: WebKit's message handlers are reachable from EVERY frame, including the sandboxed iframe of a
    /// Custom HTML widget. Each call therefore carries this key, which only the panel's main frame receives (a
    /// document-start script for the main frame only). Calls without it do nothing (fail closed).
    private let bridgeKey = UUID().uuidString

    private var orientationMask: UIInterfaceOrientationMask = .landscape
    private var systemBrightness: CGFloat?
    private var wantedBrightness: CGFloat?
    private var active = false
    private var pendingPairing: AgentLink.PairLink?
    private var toastView: UIView?

    // ------------------------------------------------------------------------------------------- setup

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(scheme, forURLScheme: PanelSchemeHandler.scheme)
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(WeakMessageHandler(self), name: "phonebox")
        config.preferences.javaScriptCanOpenWindowsAutomatically = false

        web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.backgroundColor = .black
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        web.scrollView.showsVerticalScrollIndicator = false
        web.scrollView.showsHorizontalScrollIndicator = false
        web.scrollView.pinchGestureRecognizer?.isEnabled = false
        web.allowsLinkPreview = false
        web.allowsBackForwardNavigationGestures = false
        web.navigationDelegate = self
        web.uiDelegate = self
        #if DEBUG
        // Lets you debug the panel from a Mac (Safari › Develop).
        if #available(iOS 16.4, *) { web.isInspectable = true }
        #endif

        let root = UIView()
        root.backgroundColor = .black
        web.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(web)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            web.topAnchor.constraint(equalTo: root.topAnchor),
            web.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        volumeKeys.attach(to: root)
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        link.onRouteChange = { [weak self] _ in DispatchQueue.main.async { self?.pushState() } }
        let tunnel = self.tunnel
        link.usbAvailable = { tunnel.ready }
        // plugged in: move the live stream to USB now (Android's stream does so within a minute)
        tunnel.onReadyChange = { [weak self] ready in
            guard let self, ready, self.active, self.link.route != .usb else { return }
            self.stream.stop()
            self.stream.start()
        }
        location.onChange = { [weak self] in
            self?.pushState()
            self?.evaluate("window.onPhoneLocation && window.onPhoneLocation()")
        }
        sensors.send = { [weak self] kind, value in
            self?.evaluate("window.onAndroidSensor && window.onAndroidSensor('\(kind)', \(value))")
        }
        // Back: iOS has no Back button; the swipe in from the left edge is iOS's back gesture
        let back = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(backSwipe(_:)))
        back.edges = .left
        view.addGestureRecognizer(back)
        volumeKeys.onKey = { [weak self] key in self?.evaluate("window.onAndroidKey && window.onAndroidKey('\(key)')") }
        dictation.onAudioReleased = { [weak self] in self?.volumeKeys.audioReleased() }

        let nc = NotificationCenter.default
        UIDevice.current.isBatteryMonitoringEnabled = true
        for name in [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification,
                     NSLocale.currentLocaleDidChangeNotification, UIApplication.significantTimeChangeNotification] {
            nc.addObserver(self, selector: #selector(stateChanged), name: name, object: nil)
        }

        installBridge()
        web.load(URLRequest(url: PanelSchemeHandler.indexURL))
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let p = pendingPairing {
            pendingPairing = nil
            askToPair(p)
        }
    }

    // Kiosk look: no status bar, the home indicator fades, and edge swipes reach the panel first.
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { orientationMask }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        orientationMask.contains(.landscapeRight) ? .landscapeRight : .portrait
    }

    // ------------------------------------------------------------------------------------------- lifecycle

    /// The scene is in front (Android's onResume).
    func resume() {
        guard !active else { return }
        active = true
        UIApplication.shared.isIdleTimerDisabled = true // keep the screen on
        tunnel.start()
        stream.start()
        volumeKeys.resume()
        sensors.resume()
        location.resume()
        if let w = wantedBrightness {
            systemBrightness = UIScreen.main.brightness
            UIScreen.main.brightness = w
        }
        pushState()
    }

    /// Another app, the lock screen or Control Center is in front (Android's onPause).
    func pause() {
        guard active else { return }
        active = false
        dictation.cancel(0) // the microphone is never left open behind another app or a locked screen
        stream.stop()
        tunnel.stop()
        volumeKeys.pause()
        sensors.pause()
        location.pause()
        // the brightness of an iPhone is system-wide: give the phone its own back while the panel is away
        if let s = systemBrightness {
            UIScreen.main.brightness = s
            systemBrightness = nil
        }
    }

    private func reloadPanel() {
        dictation.cancel(0)
        installBridge()
        web.reload()
    }

    // ------------------------------------------------------------------------------------------- pairing

    /// A pairing link from the computer's QR code (Settings › Wi-Fi › Pair a phone over Wi-Fi): ask, then pair.
    func handlePairingLink(_ url: URL) {
        guard let pairing = AgentLink.PairLink.parse(url) else { return }
        if viewIfLoaded?.window == nil || presentedViewController != nil {
            pendingPairing = pairing
            if presentedViewController != nil { presentedViewController?.dismiss(animated: false) { [weak self] in self?.flushPending() } }
            return
        }
        askToPair(pairing)
    }

    private func flushPending() {
        guard let p = pendingPairing, viewIfLoaded?.window != nil else { return }
        pendingPairing = nil
        askToPair(p)
    }

    private func askToPair(_ pairing: AgentLink.PairLink) {
        let message = L.format("pair_message", pairing.pc, pairing.hosts.joined(separator: ", "), pairing.port, pairing.check)
        let alert = UIAlertController(title: L.text("pair_title"), message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L.text("pair_negative"), style: .cancel))
        alert.addAction(UIAlertAction(title: L.text("pair_positive"), style: .default) { [weak self] _ in self?.pair(pairing) })
        present(alert, animated: true)
    }

    private func pair(_ pairing: AgentLink.PairLink) {
        toast(L.format("pair_progress", pairing.pc), seconds: 2)
        let link = self.link
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let problem = link.claim(pairing)
            DispatchQueue.main.async {
                guard let self else { return } // the pairing is stored; there is no window to show it in
                if let problem {
                    let alert = UIAlertController(title: L.text("pair_failed_title"), message: problem.message, preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: L.text("ok"), style: .default))
                    self.present(alert, animated: true)
                } else {
                    self.toast(L.format("pair_done", pairing.pc), seconds: 3.5)
                    self.stream.stop()
                    self.stream.start()
                    self.pushState()
                    self.reloadPanel()
                }
            }
        }
    }

    /// Android's Toast: a short note at the bottom of the screen.
    private func toast(_ text: String, seconds: TimeInterval) {
        toastView?.removeFromSuperview()
        let label = UILabel()
        label.text = text
        label.textColor = .white
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.numberOfLines = 0
        label.textAlignment = .center
        let box = UIView()
        box.backgroundColor = UIColor(white: 0.18, alpha: 0.95)
        box.layer.cornerRadius = 18
        box.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        view.addSubview(box)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 18),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -18),
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -10),
            box.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            box.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            box.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.8),
        ])
        toastView = box
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak box] in
            UIView.animate(withDuration: 0.3, animations: { box?.alpha = 0 }) { _ in box?.removeFromSuperview() }
        }
    }

    // ------------------------------------------------------------------------------------------- bridge

    /// window.Android for the panel's main frame. Android's bridge answers synchronously; WebKit's cannot, so the values
    /// the panel reads (battery, transport, …) are kept in the page and refreshed by pushState(), and the calls that act
    /// go to the app as messages. Sandboxed frames get neither the object nor the key.
    private func installBridge() {
        let ucc = web.configuration.userContentController
        ucc.removeAllUserScripts()
        let source = PanelViewController.bridgeSource
            .replacingOccurrences(of: "__KEY__", with: bridgeKey)
            .replacingOccurrences(of: "__STATE__", with: stateJson())
        ucc.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        ucc.addUserScript(WKUserScript(source: PanelViewController.styleSource, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    }

    private func stateJson() -> String {
        let state: [String: Any] = [
            "battery": Battery.json(),
            "transport": link.route.rawValue,
            "is24Hour": PanelViewController.is24Hour(),
            "sensors": Sensors.available(),
            "pcs": link.pcsJson(),
            "version": (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "",
            "canListen": dictation.available(),
            "location": location.json(),
            // the phone's own languages: WebKit reports only those the app bundle lists
            "languages": Locale.preferredLanguages,
        ]
        return Json.string(state) ?? "{}"
    }

    /// Sends fresh values to the page and to the script the next page load starts with.
    private func pushState() {
        installBridge()
        evaluate("window.__phoneboxState && window.__phoneboxState(\(stateJson()))")
    }

    @objc private func stateChanged() {
        DispatchQueue.main.async { self.pushState() }
    }

    private func evaluate(_ js: String) {
        web?.evaluateJavaScript(js, completionHandler: nil)
    }

    /// A message from window.Android: only from the panel's own main frame, and only with the key.
    fileprivate func receive(_ message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.protocol == PanelSchemeHandler.scheme,
              let body = message.body as? [String: Any],
              body["key"] as? String == bridgeKey,
              let method = body["method"] as? String else { return }
        let args = body["args"] as? [Any] ?? []
        func string(_ i: Int) -> String { args.count > i ? (args[i] as? String ?? "") : "" }
        func number(_ i: Int) -> Double { args.count > i ? ((args[i] as? NSNumber)?.doubleValue ?? 0) : 0 }
        func bool(_ i: Int) -> Bool { args.count > i ? ((args[i] as? NSNumber)?.boolValue ?? false) : false }

        switch method {
        case "haptic":
            haptics.tap()
        case "buzz":
            haptics.buzz(string(0))
        case "setBrightness":
            setBrightness(number(0))
        case "setVolumeKeys":
            volumeKeys.setEnabled(bool(0))
        case "setPinned":
            setPinned(bool(0))
        case "setOrientation":
            setOrientation(string(0))
        case "wantLocation":
            location.want()
        case "sensorNeeds":
            sensors.setNeeds(light: bool(0), proximity: bool(1))
        case "selectPc":
            if link.select(string(0)) {
                stream.stop()
                stream.start()
                pushState()
                reloadPanel()
            }
        case "forgetPc":
            link.forget(string(0))
            pushState()
        case "listen":
            let id = Int(number(0))
            guard id > 0 else { return }
            let lang = String(string(1).prefix(20).filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
            dictation.start(id: id, lang: lang, offline: bool(2))
        case "stopListening":
            let id = Int(number(0))
            if id > 0 { dictation.stop(id) }
        case "cancelListening":
            let id = Int(number(0))
            if id > 0 { dictation.cancel(id) }
        default:
            break
        }
    }

    /// Kiosk behaviour: Back does not leave the app, it returns to the first page (window.onAndroidBack).
    @objc private func backSwipe(_ g: UIScreenEdgePanGestureRecognizer) {
        if g.state == .ended || g.state == .recognized, g.translation(in: view).x > 40 {
            evaluate("window.onAndroidBack && window.onAndroidBack()")
        }
    }

    /// Screen brightness 0..1; a negative value returns control to the phone's own setting.
    private func setBrightness(_ value: Double) {
        if value < 0 {
            wantedBrightness = nil
            if let s = systemBrightness {
                UIScreen.main.brightness = s
                systemBrightness = nil
            }
            return
        }
        let v = CGFloat(min(max(value, 0.01), 1))
        wantedBrightness = v
        guard active else { return }
        if systemBrightness == nil { systemBrightness = UIScreen.main.brightness }
        UIScreen.main.brightness = v
    }

    /// Screen pinning: iOS has Guided Access instead. An app can start it only on a supervised iPhone (otherwise the
    /// request is refused and nothing happens); everywhere else the user starts it with a triple-click of the side button.
    private func setPinned(_ on: Bool) {
        guard on != UIAccessibility.isGuidedAccessEnabled else { return }
        UIAccessibility.requestGuidedAccessSession(enabled: on) { _ in }
    }

    /// "landscape" (default), "portrait" or "auto" (follow the phone).
    private func setOrientation(_ mode: String) {
        let want: UIInterfaceOrientationMask
        switch mode {
        case "portrait": want = UIDevice.current.userInterfaceIdiom == .pad ? [.portrait, .portraitUpsideDown] : .portrait
        case "auto": want = UIDevice.current.userInterfaceIdiom == .pad ? .all : .allButUpsideDown
        default: want = .landscape
        }
        guard want != orientationMask else { return }
        orientationMask = want
        if #available(iOS 16.0, *) {
            setNeedsUpdateOfSupportedInterfaceOrientations()
            view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: want)) { _ in }
        } else {
            let current = view.window?.windowScene?.interfaceOrientation ?? .unknown
            let target: UIInterfaceOrientation
            if want == .landscape && !current.isLandscape { target = .landscapeRight }
            else if want == .portrait && !current.isPortrait { target = .portrait }
            else { target = .unknown }
            if target != .unknown { UIDevice.current.setValue(target.rawValue, forKey: "orientation") }
            UIViewController.attemptRotationToDeviceOrientation()
        }
    }

    /// Whether the phone is set to 24-hour time (Settings › General › Date & Time).
    private static func is24Hour() -> Bool {
        let format = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? ""
        return !format.contains("a")
    }

    // ------------------------------------------------------------------------------------------- navigation

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        // The panel stays in this web view; widgets with their own frames (Web, Custom HTML) load what they show.
        if url.scheme == PanelSchemeHandler.scheme || action.targetFrame?.isMainFrame == false || url.scheme == "about" || url.scheme == "data" || url.scheme == "blob" {
            decisionHandler(.allow)
            return
        }
        // A link that would replace the panel opens in Safari instead (Android's WebView did not follow such links either).
        if action.navigationType == .linkActivated, ["http", "https"].contains(url.scheme ?? "") {
            UIApplication.shared.open(url)
        }
        decisionHandler(.cancel)
    }

    /// target="_blank" / window.open: nothing (as on Android, where the WebView has no new windows).
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }

    /// The web process can be ended by iOS (memory); start the panel again instead of showing a blank screen.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        reloadPanel()
    }

    // ------------------------------------------------------------------------------------------- scripts

    private static let bridgeSource = """
    (function () {
      if (window.Android) return;
      var key = '__KEY__';
      var state = __STATE__;
      window.__phoneboxKey = key;
      // "auto" language and date formats follow the iPhone's languages (Settings › General › Language & Region)
      var langs = state.languages;
      if (langs && langs.length) {
        try {
          Object.defineProperty(Navigator.prototype, 'languages', { get: function () { return langs.slice(); }, configurable: true });
          Object.defineProperty(Navigator.prototype, 'language', { get: function () { return langs[0]; }, configurable: true });
        } catch (_) {}
      }
      window.__phoneboxState = function (s) { for (var k in s) state[k] = s[k]; };
      var post = function (method, args) {
        try { window.webkit.messageHandlers.phonebox.postMessage({ key: key, method: method, args: args }); } catch (_) {}
      };
      var nextId = Math.floor(Math.random() * 1e6) + 1;
      var own = function (k) { return k === key; };
      window.Android = {
        battery: function (k) { return own(k) ? state.battery : '{}'; },
        transport: function (k) { return own(k) ? state.transport : ''; },
        is24Hour: function (k) { return own(k) ? state.is24Hour : true; },
        sensors: function (k) { return own(k) ? state.sensors : '{}'; },
        location: function (k) { return own(k) ? state.location : ''; },
        wantLocation: function (k) { if (own(k)) post('wantLocation', []); },
        sensorNeeds: function (k, light, near) { if (own(k)) post('sensorNeeds', [!!light, !!near]); },
        pcs: function (k) { return own(k) ? state.pcs : '[]'; },
        version: function (k) { return own(k) ? state.version : ''; },
        canListen: function (k) { return own(k) && state.canListen; },
        haptic: function (k) { if (own(k)) post('haptic', []); },
        buzz: function (k, pattern) { if (own(k)) post('buzz', [String(pattern)]); },
        setBrightness: function (k, v) { if (own(k)) post('setBrightness', [Number(v)]); },
        setVolumeKeys: function (k, on) { if (own(k)) post('setVolumeKeys', [!!on]); },
        setPinned: function (k, on) { if (own(k)) post('setPinned', [!!on]); },
        setOrientation: function (k, mode) { if (own(k)) post('setOrientation', [String(mode)]); },
        selectPc: function (k, id) { if (own(k)) post('selectPc', [String(id)]); },
        forgetPc: function (k, id) { if (own(k)) post('forgetPc', [String(id)]); },
        listen: function (k, lang, offline) {
          if (!own(k)) return 0;
          var id = nextId++;
          post('listen', [id, String(lang), !!offline]);
          return id;
        },
        stopListening: function (k, id) { if (own(k)) post('stopListening', [Number(id)]); },
        cancelListening: function (k, id) { if (own(k)) post('cancelListening', [Number(id)]); }
      };
    })();
    """

    /// No callout menu or magnifier on long presses (the panel uses long presses itself).
    private static let styleSource = """
    (function () {
      var s = document.createElement('style');
      s.textContent = 'html, body { -webkit-touch-callout: none; -webkit-text-size-adjust: 100%; }';
      (document.head || document.documentElement).appendChild(s);
    })();
    """
}

/// WKUserContentController keeps its handlers strongly; this breaks the cycle with the view controller.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: PanelViewController?

    init(_ target: PanelViewController) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.receive(message)
    }
}
