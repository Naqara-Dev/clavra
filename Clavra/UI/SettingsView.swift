import SwiftUI
import UniformTypeIdentifiers

/// ⌘, : the few things that are yours to choose.
struct SettingsView: View {
    var model: AppModel
    /// Which tab is open; the sidebar's update note opens About.
    @AppStorage("SettingsTab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings(model: model).tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            TerminalSettings(model: model).tabItem { Label("Terminal", systemImage: "terminal") }.tag("terminal")
            TrustedHosts().tabItem { Label("Trusted Hosts", systemImage: "checkmark.shield") }.tag("hosts")
            AboutSettings().tabItem { Label("About", systemImage: "info.circle") }.tag("about")
        }
        .frame(width: 520)
    }
}

private struct GeneralSettings: View {
    var model: AppModel
    @State private var sync = Library.syncsWithICloud
    @State private var check = HealthMonitor.isEnabled
    @State private var restore = AppModel.restoresTabs
    @State private var notify = FinishedNotice.isEnabled
    @State private var alertDown = HealthMonitor.alertsWhenDown
    @AppStorage("MenuBarExtra") private var menuBar = true
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            setting("Keep hosts and snippets in iCloud Drive", isOn: $sync,
                    note: Library.iCloudAvailable
                        ? "They sit in a Clavra folder in iCloud Drive, so your other Macs see them. Passwords and passphrases stay in this Mac's Keychain, and keys stay in ~/.ssh."
                        : "Turn on iCloud Drive in System Settings to use this.")
                .disabled(!Library.iCloudAvailable)
                .onChange(of: sync) { model.setICloudSync(sync) }

            setting("Check whether hosts are up", isOn: $check,
                    note: "Every five minutes Clavra opens and closes a connection to each host's SSH port to show it's reachable and how fast. Nothing is sent and nobody logs in.")
                .onChange(of: check) {
                    HealthMonitor.isEnabled = check
                    model.health.restart()
                }

            setting("Tell me when a production host goes down", isOn: $alertDown,
                    note: "Hosts that ask before risky commands are checked every minute. Two misses in a row and you get a notification, and another when it answers again. Nothing is said while this Mac itself is offline.")
                .onChange(of: alertDown) { HealthMonitor.alertsWhenDown = alertDown }
                .disabled(!check)

            setting("Tell me when a long command finishes", isOn: $notify,
                    note: "A command that ran 20 seconds or more, in a tab you weren't looking at, ends with a notification. Clicking it brings the tab forward.")
                .onChange(of: notify) { FinishedNotice.isEnabled = notify }

            setting("Open last session's tabs on launch", isOn: $restore,
                    note: "Saved hosts that had a tab when Clavra quit connect again.")
                .onChange(of: restore) { AppModel.restoresTabs = restore }

            setting("Show Clavra in the menu bar", isOn: $menuBar,
                    note: "Every saved host, one click away, even with the window closed.")


            VStack(alignment: .leading, spacing: 8) {
                Text("Backup").font(.system(size: 13, weight: .medium))
                HStack(spacing: 8) {
                    Button("Export Hosts and Snippets…", action: export)
                    Button("Import…", action: importFile)
                }
                Text(note ?? "One JSON file. Passwords, passphrases and keys are never in it.")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
        }
        .padding(24)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Clavra Hosts.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.exportBackup(to: url)
            note = "Saved \(model.store.hosts.count) hosts and \(model.snippets.snippets.count) snippets."
        } catch {
            note = "Couldn't save: \(error.localizedDescription)"
        }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let added = try model.importBackup(from: url)
            note = "Added \(added.hosts) hosts and \(added.snippets) snippets. Ones you already had were left alone."
        } catch {
            note = "That file isn't a Clavra backup."
        }
    }
}

private struct TerminalSettings: View {
    var model: AppModel
    @State private var suggest = CommandHistory.isEnabled
    @State private var forgotten = false
    @State private var recording = Recordings.policy
    @State private var redact = Redaction.isOn

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Font size").font(.system(size: 13, weight: .medium))
                Spacer()
                Text(verbatim: "\(Int(model.fontSize)) pt").monospacedDigit().foregroundStyle(Theme.secondary)
            }
            Slider(value: Binding(get: { Double(model.fontSize) }, set: { model.setFontSize(CGFloat($0.rounded())) }), in: 9...28)
            Text("⌘+ and ⌘- change it from any tab; ⌘0 goes back to 13.")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            Text("The quick brown fox, ls -la ~/srv")
                .font(.system(size: model.fontSize, design: .monospaced))
                .foregroundStyle(SwiftUI.Color(nsColor: NSColor(hex: 0xE6E3DC)))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.terminal))

            setting("Suggest commands as you type", isOn: $suggest,
                    note: "Grey text after the cursor shows a command you ran before on that host; → takes it. Commands you run are kept on this Mac, never synced, and ones that look like they hold a password are skipped. The server's own shell history is read when you connect and kept in memory only.")
                .onChange(of: suggest) { CommandHistory.isEnabled = suggest }
                .padding(.top, 6)
            Button(forgotten ? "Forgotten" : "Forget Command History") {
                CommandHistory.forgetEverything()
                forgotten = true
            }
            .disabled(forgotten)

            VStack(alignment: .leading, spacing: 5) {
                Text("Record sessions").font(.system(size: 13, weight: .medium))
                Dropdown(icon: "record.circle", title: recording.label, height: 32) {
                    Recordings.Policy.allCases.map { option in
                        .item(option.label, isOn: recording == option, id: "policy:\(option.rawValue)") {
                            recording = option
                            Recordings.policy = option
                        }
                    }
                }
                .frame(width: 320)
                Toggle("Hide passwords, tokens and keys in recordings", isOn: $redact).toggleStyle(.checkbox)
                    .font(.system(size: 12.5))
                    .onChange(of: redact) { Redaction.isOn = redact }
                Text("A playable copy of each tab, with every command marked on the timeline, in Recordings (⌥⌘4). Kept on this Mac only, readable only by you, removed after \(Recordings.keepDays) days. Files are asciinema .cast files.")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 6)
        }
        .padding(24)
    }
}

private struct TrustedHosts: View {
    @State private var list = KnownHosts.trusted()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Server keys you've trusted in Clavra. Forget one and the next connection asks again. Entries in ~/.ssh/known_hosts are read too, but never changed.")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            List {
                if list.isEmpty {
                    Text("Nothing yet.").foregroundStyle(Theme.tertiary)
                }
                ForEach(list) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).font(.system(size: 12.5, weight: .medium))
                            Text("\(item.type)  \(item.fingerprint)").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.tertiary)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Button("Forget") {
                            KnownHosts.forget(item)
                            list = KnownHosts.trusted()
                        }
                    }
                }
            }
            .frame(height: 260)
        }
        .padding(24)
        .onAppear { list = KnownHosts.trusted() }
    }
}

/// The version, updates, and where Clavra comes from.
private struct AboutSettings: View {
    @State private var automatic = Updates.shared.checksAutomatically
    private var updates: Updates { Updates.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Clavra").font(.system(size: 20, weight: .semibold))
                    Text("Version \(Updates.version)").font(.system(size: 12.5)).foregroundStyle(Theme.secondary).textSelection(.enabled)
                    Text("An SSH client by Naqara Dev.").font(.system(size: 12.5)).foregroundStyle(Theme.tertiary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Button(updates.available.map { "Update to \($0)…" } ?? "Check for Updates…") { updates.checkNow() }
                    if let version = updates.available {
                        Text("Version \(version) is ready").font(.system(size: 12)).foregroundStyle(Theme.brass)
                    } else if updates.confirmedLatest {
                        Text("You have the latest version").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    } else if let checked = updates.lastChecked {
                        Text("Last checked \(checked.formatted(.relative(presentation: .named)))").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    }
                }
                setting("Check for updates every day", isOn: $automatic,
                        note: "Clavra asks before installing anything. Each update is checked against Naqara Dev's signing key, so a tampered download is refused.")
                    .onChange(of: automatic) { updates.checksAutomatically = automatic }
            }

            HStack(spacing: 16) {
                Link("clavra.naqara.dev", destination: URL(string: "https://clavra.naqara.dev")!)
                Link("Source on GitHub", destination: URL(string: "https://github.com/Naqara-Dev/clavra")!)
                Link("Report an issue", destination: URL(string: "https://github.com/Naqara-Dev/clavra/issues")!)
            }
            .font(.system(size: 12.5))
        }
        .padding(24)
    }
}

private func setting(_ title: String, isOn: Binding<Bool>, note: String) -> some View {
    VStack(alignment: .leading, spacing: 5) {
        Toggle(title, isOn: isOn).toggleStyle(.switch).font(.system(size: 13, weight: .medium))
        Text(note).font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
