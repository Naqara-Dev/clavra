import AppKit
import UserNotifications

/// "Done on web-1: make build, after 4m 12s": a long command finishing in a tab you're not
/// looking at. Clicking the notification brings that tab forward. No shell integration needed;
/// Clavra notices the prompt coming back.
@MainActor
final class FinishedNotice: NSObject, UNUserNotificationCenterDelegate {
    static let shared = FinishedNotice()
    /// Brings the tab forward when its notification is clicked.
    var reveal: ((UUID) -> Void)?
    private var asked = false

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "NotifyFinished") == nil || UserDefaults.standard.bool(forKey: "NotifyFinished") }
        set { UserDefaults.standard.set(newValue, forKey: "NotifyFinished") }
    }

    func post(host: String, command: String, took: TimeInterval, session: UUID) {
        guard Self.isEnabled else { return }
        send(title: "Done on \(host)",
             body: "\(command.count > 80 ? String(command.prefix(80)) + "…" : command), after \(Self.duration(took))",
             session: session.uuidString)
    }

    /// A host going down or coming back.
    func alert(_ change: HealthMonitor.Change) {
        switch change {
        case .down(let host):
            send(title: "\(host.title) isn't answering", body: "\(host.target) stopped answering on port \(host.port). Clavra keeps checking every minute.", session: "")
        case .back(let host, let after):
            send(title: "\(host.title) is back", body: "It answered again after \(Self.duration(after)) down.", session: "")
        }
    }

    private func send(title: String, body: String, session: String) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let id = session
        if asked { return Self.deliver(title: title, body: body, session: id) }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in
                FinishedNotice.shared.asked = true
                if granted { Self.deliver(title: title, body: body, session: id) }
            }
        }
    }

    private static func deliver(title: String, body: String, session: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["session": session]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let raw = response.notification.request.content.userInfo["session"] as? String, let id = UUID(uuidString: raw) else { return }
        await MainActor.run {
            NSApp.activate()
            reveal?(id)
        }
    }

    /// Shown even while Clavra is in front, since the tab it's about may not be.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \(s / 60 % 60)m"
    }
}
