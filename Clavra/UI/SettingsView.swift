import SwiftUI

/// ⌘, : the few things that are yours to choose.
struct SettingsView: View {
    var model: AppModel
    @State private var sync = Library.syncsWithICloud
    @State private var check = HealthMonitor.isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            setting(
                "Keep hosts and snippets in iCloud Drive",
                isOn: $sync,
                note: Library.iCloudAvailable
                    ? "They sit in a Clavra folder in iCloud Drive, so your other Macs see them. Passwords and passphrases stay in this Mac's Keychain, and keys stay in ~/.ssh."
                    : "Turn on iCloud Drive in System Settings to use this."
            )
            .disabled(!Library.iCloudAvailable)
            .onChange(of: sync) { model.setICloudSync(sync) }

            setting(
                "Check whether hosts are up",
                isOn: $check,
                note: "Every five minutes Clavra opens and closes a connection to each host's SSH port to show it's reachable and how fast. Nothing is sent and nobody logs in."
            )
            .onChange(of: check) {
                HealthMonitor.isEnabled = check
                model.health.restart()
            }
        }
        .padding(24)
        .frame(width: 480)
        .background(Theme.window)
    }

    private func setting(_ title: String, isOn: Binding<Bool>, note: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(title, isOn: isOn).toggleStyle(.switch).font(.system(size: 13, weight: .medium))
            Text(note).font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
