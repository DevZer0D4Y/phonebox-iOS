import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        true
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

/// One window with the panel. Pairing links (phonebox://pair?...) arrive here, at launch or while the app runs.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var panel: PanelViewController?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let panel = PanelViewController()
        let window = UIWindow(windowScene: windowScene)
        window.backgroundColor = .black
        window.rootViewController = panel
        window.makeKeyAndVisible()
        self.window = window
        self.panel = panel
        if let url = options.urlContexts.first?.url { panel.handlePairingLink(url) }
        if let url = options.userActivities.first(where: { $0.activityType == NSUserActivityTypeBrowsingWeb })?.webpageURL {
            panel.handlePairingLink(url)
        }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        if let url = URLContexts.first?.url { panel?.handlePairingLink(url) }
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        if let url = userActivity.webpageURL { panel?.handlePairingLink(url) }
    }

    func sceneDidBecomeActive(_ scene: UIScene) { panel?.resume() }

    func sceneWillResignActive(_ scene: UIScene) { panel?.pause() }
}
