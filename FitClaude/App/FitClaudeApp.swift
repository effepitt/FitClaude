import SwiftUI
import UIKit

@main
struct FitClaudeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .preferredColorScheme(.dark)
                .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        }
    }
}

/// Decide quale scena usare: quella normale sull'iPad, quella "TV" sullo schermo esterno
/// (cavo USB-C → HDMI oppure AirPlay).
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        if connectingSceneSession.role == .windowExternalDisplayNonInteractive {
            let config = UISceneConfiguration(name: "TV", sessionRole: connectingSceneSession.role)
            config.delegateClass = ExternalSceneDelegate.self
            return config
        }
        return UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
    }
}

/// Scena mostrata sulla TV: percorso 3D a schermo intero con i dati sovrapposti.
final class ExternalSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        let root = TVView().environment(AppModel.shared).preferredColorScheme(.dark)
        window.rootViewController = UIHostingController(rootView: root)
        window.isHidden = false
        self.window = window
        AppModel.shared.externalDisplayConnected = true
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        window = nil
        AppModel.shared.externalDisplayConnected = false
    }
}
