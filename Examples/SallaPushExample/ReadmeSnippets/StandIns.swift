import Foundation
import SallaPush
import SwiftUI
import UIKit
import UserNotifications

// Stand-ins for the host app's own code that the README snippets call. They exist only so that the snippets compile
// exactly as the README shows them.

/// The app's router for notification taps.
@MainActor
final class Router {
    static let shared = Router()

    func showProduct(id: Int) {}

    func showOrder(id: String) {}

    func open(_ url: URL) {}
}

/// The app's settings screen.
@MainActor
final class SettingsScreen {
    static let shared = SettingsScreen()

    func show(permissionGranted: Bool) {}

    func show(deviceId: String?, optedIn: Bool) {}
}

/// The app's checkout flow, during which it holds foreground notifications.
@MainActor
final class Checkout {
    static let shared = Checkout()

    private(set) var isInProgress = false
    private var afterCheckout: [@MainActor () -> Void] = []

    func start() {
        isInProgress = true
    }

    /// Runs `action` when the checkout ends.
    func whenFinished(_ action: @escaping @MainActor () -> Void) {
        afterCheckout.append(action)
    }

    func finish() {
        isInProgress = false
        let actions = afterCheckout
        afterCheckout.removeAll()
        actions.forEach { $0() }
    }
}

/// The app's telemetry, where SallaPush errors are reported.
enum Telemetry {
    static func report(source: String, code: String, message: String, metadata: [String: String]) {}
}

/// The app's SwiftUI root view.
struct ContentView: View {
    var body: some View {
        Text("Shop")
    }
}
