import SallaPush
import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = ExampleViewController()
        window.makeKeyAndVisible()
        self.window = window
    }
}

/// The example's only screen: where to follow the integration, this device's SallaPush id, the last notification
/// tapped, and a button that asks for notification permission.
private final class ExampleViewController: UIViewController {
    private let statusLabel = UILabel()
    private let deviceLabel = UILabel()
    private var subscriptionObserver: SallaPushObservation?
    private var clickListener: SallaPushObservation?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let titleLabel = UILabel()
        titleLabel.text = "SallaPush \(SallaPush.sdkVersion)"
        titleLabel.font = .preferredFont(forTextStyle: .title2)

        statusLabel.text = "Filter the Xcode console on \"SallaPush\" to follow registration, login and events."
        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center

        deviceLabel.text = "Not registered yet."
        deviceLabel.font = .preferredFont(forTextStyle: .footnote)
        deviceLabel.numberOfLines = 0
        deviceLabel.textAlignment = .center

        let permissionButton = UIButton(type: .system)
        permissionButton.setTitle("Allow notifications", for: .normal)
        permissionButton.addTarget(self, action: #selector(requestPermission), for: .primaryActionTriggered)

        let stack = UIStackView(arrangedSubviews: [titleLabel, statusLabel, deviceLabel, permissionButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        // Called with the state once SallaPush has loaded it and the device is registered, then at every change.
        subscriptionObserver = SallaPush.User.pushSubscription.addObserver { [weak self] state in
            self?.show(deviceId: state.current.id, optedIn: state.current.optedIn)
        }
        // A tap that launched the app is kept until this listener is added, then delivered to it.
        clickListener = SallaPush.Notifications.addClickListener { [weak self] event in
            let title = event.notification.title ?? event.notification.body ?? "A notification"
            self?.statusLabel.text = "Opened: \(title)"
        }
    }

    private func show(deviceId: String?, optedIn: Bool) {
        guard let deviceId else {
            deviceLabel.text = "Not registered yet."
            return
        }
        deviceLabel.text = "Device id \(deviceId)\n"
            + (optedIn ? "Opted in: notifications are delivered." : "Not opted in: allow notifications to receive them.")
    }

    @objc private func requestPermission() {
        SallaPush.Notifications.requestPermission(fallbackToSettings: true) { [weak self] granted in
            self?.statusLabel.text = granted ? "Notifications are allowed." : "Notifications are off. Allow them in Settings."
        }
    }
}
