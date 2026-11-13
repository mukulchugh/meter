import Foundation
import MeterCore
import ServiceManagement
import UserNotifications

/// Local notifications. A protocol so tests never touch `UNUserNotificationCenter`, which traps in a
/// process that is not an app bundle.
public protocol Notifying: Sendable {
    func requestAuthorization() async -> Bool
    func post(_ event: AlertEvent) async
}

/// Launch at login. A protocol so tests never register a login item.
@MainActor
public protocol LoginItemControlling {
    var isEnabled: Bool { get }
    func setEnabled(_ on: Bool) throws
}

public struct SystemNotifier: Notifying {
    public init() {}

    public func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    public func post(_ event: AlertEvent) async {
        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = event.body
        let request = UNNotificationRequest(identifier: event.key, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

public struct NoopNotifier: Notifying {
    public init() {}
    public func requestAuthorization() async -> Bool { false }
    public func post(_ event: AlertEvent) async {}
}

/// `SMAppService.mainApp`. Registered only when the user flips the switch.
public struct SystemLoginItem: LoginItemControlling {
    public init() {}
    public var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    public func setEnabled(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

@MainActor
public struct NoopLoginItem: LoginItemControlling {
    public init() {}
    public var isEnabled: Bool { false }
    public func setEnabled(_ on: Bool) throws {}
}
