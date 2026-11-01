import SwiftUI

/// Add or change a host. Secrets go straight to the Keychain when you save.
struct HostEditor: View {
    @State var server: Server
    var isNew: Bool
    /// Other saved hosts, for the jump host menu.
    var others: [Server] = []
    var save: (Server, _ connect: Bool) -> Void
    var delete: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    @State private var password = ""
    @State private var passphrase = ""
    @State private var keys = Credentials.keysInSSHFolder()
    @State private var tab = Tab.basics
    @State private var newLocal = ""
    @State private var newRemote = ""

    private enum Tab: CaseIterable { case basics, more }

    private var canSave: Bool {
        !server.address.trimmingCharacters(in: .whitespaces).isEmpty && !server.user.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(isNew ? "New Host" : "Edit Host").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink)
                Spacer()
                Segments(options: Tab.allCases, selection: $tab) { $0 == .basics ? "Basics" : "Jump, Ports, Guard" }
                    .frame(width: 250)
            }

            if tab == .basics { basics } else { more }

            HStack(spacing: 8) {
                if let delete {
                    Button("Delete") { delete(); dismiss() }
                        .buttonStyle(QuietButtonStyle(tint: Theme.color(for: .production)))
                }
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(QuietButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Save") { commit(connect: false) }.buttonStyle(QuietButtonStyle()).disabled(!canSave)
                Button("Save and Connect") { commit(connect: true) }.buttonStyle(BrassButtonStyle())
                    .keyboardShortcut(.defaultAction).disabled(!canSave).opacity(canSave ? 1 : 0.5)
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 500)
        .background(Theme.window)
        .onAppear {
            password = Keychain.password(for: server.id) ?? ""
            passphrase = Keychain.passphrase(for: server.id) ?? ""
        }
    }

    @ViewBuilder private var basics: some View {
        section("Server") {
            HStack(spacing: 8) {
                SoftField("Address or IP", text: $server.address)
                SoftField("Port", text: portText).frame(width: 74)
            }
            SoftField("Optional, shown in the sidebar", text: $server.name, prefix: "Name")
            SoftField("root, deploy…", text: $server.user, prefix: "User")
        }

        section("Sign in with") {
            Segments(options: Server.Auth.allCases, selection: $server.auth) { $0 == .key ? "Key" : "Password" }
            if server.auth == .key {
                Menu {
                    Button("Default (id_ed25519, then id_rsa)") { server.keyPath = nil }
                    if !keys.isEmpty { Divider() }
                    ForEach(keys, id: \.self) { key in Button(key) { server.keyPath = key } }
                    Divider()
                    Button("Choose File…", action: chooseKey)
                } label: {
                    HStack {
                        Image(systemName: "key").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                        Text(server.keyPath ?? "Default key").font(.system(size: 13)).foregroundStyle(Theme.ink)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.field))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line))
                    .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                SoftField("Only if the key has one", text: $passphrase, secure: true, prefix: "Passphrase")
            } else {
                SoftField("Saved to the Keychain", text: $password, secure: true, prefix: "Password")
            }
            Text("Kept in your Mac's Keychain. Clavra never writes it anywhere else.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
        }

        section("This server is") {
            HStack(spacing: 8) {
                ForEach(Server.Place.allCases, id: \.self) { place in
                    PlaceOption(place: place, isOn: server.place == place) { server.place = place }
                }
            }
        }
    }

    @ViewBuilder private var more: some View {
        section("Connect through") {
            Menu {
                Button("Directly") { server.jump = nil }
                let candidates = others.filter { $0.id != server.id && $0.jump != server.id }
                if !candidates.isEmpty { Divider() }
                ForEach(candidates) { host in Button(host.title) { server.jump = host.id } }
            } label: {
                pickerLabel(icon: "arrow.triangle.turn.up.right.diamond",
                            text: others.first { $0.id == server.jump }.map { "\($0.title), then this server" } ?? "Directly")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            Text("A jump host (bastion) you reach first. The address above is then looked up from there, so private names and IPs work.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
        }

        section("Forward ports when connected") {
            ForEach($server.forwards) { $forward in
                HStack(spacing: 8) {
                    Text("localhost:\(String(forward.localPort))").font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Theme.ink)
                    Image(systemName: "arrow.right").font(.system(size: 9.5)).foregroundStyle(Theme.tertiary)
                    Text(forward.host == "localhost" ? "server:\(String(forward.port))" : "\(forward.host):\(String(forward.port))")
                        .font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Theme.secondary)
                    Spacer()
                    Toggle("Automatic", isOn: $forward.automatic).toggleStyle(.checkbox).font(.system(size: 11.5))
                        .help("Open as soon as the session connects")
                    Button { server.forwards.removeAll { $0.id == forward.id } } label: {
                        Image(systemName: "minus.circle").foregroundStyle(Theme.tertiary)
                    }
                    .buttonStyle(.plain)
                }
                .frame(height: 26)
            }
            HStack(spacing: 6) {
                SoftField("Mac port", text: $newLocal, mono: true).frame(width: 100)
                Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                SoftField("port, or host:port", text: $newRemote, mono: true)
                Button("Add", action: addForward).buttonStyle(QuietButtonStyle()).disabled(parsedRemote == nil)
            }
        }

        section("Risky commands") {
            Toggle("Ask before running them", isOn: Binding(get: { server.guardsCommands }, set: { server.guardOverride = $0 }))
                .toggleStyle(.switch).font(.system(size: 13))
            Text("rm -rf, DROP TABLE, shutdown, docker rm and the like wait for a yes. On by default for production.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var parsedRemote: (host: String, port: Int)? {
        let text = newRemote.trimmingCharacters(in: .whitespaces)
        if let port = Int(text), port > 0 { return ("localhost", port) }
        guard let colon = text.lastIndex(of: ":"), let port = Int(text[text.index(after: colon)...]), port > 0 else { return nil }
        let host = String(text[..<colon])
        return host.isEmpty ? nil : (host, port)
    }

    private func addForward() {
        guard let target = parsedRemote else { return }
        let local = Int(newLocal.trimmingCharacters(in: .whitespaces)) ?? target.port
        server.forwards.append(Server.Forward(localPort: local, host: target.host, port: target.port))
        newLocal = ""
        newRemote = ""
    }

    private func pickerLabel(icon: String, text: String) -> some View {
        HStack {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(Theme.tertiary)
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.ink)
            Spacer()
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line))
        .contentShape(Rectangle())
    }

    private var portText: Binding<String> {
        Binding(get: { String(server.port) }, set: { server.port = Int($0.filter(\.isNumber)) ?? 22 })
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            content()
        }
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh")
        panel.showsHiddenFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        server.keyPath = url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }

    private func commit(connect: Bool) {
        server.address = server.address.trimmingCharacters(in: .whitespaces)
        server.user = server.user.trimmingCharacters(in: .whitespaces)
        if server.auth == .password {
            Keychain.setPassword(password, for: server.id)
            Keychain.setPassphrase(nil, for: server.id)
        } else {
            Keychain.setPassphrase(passphrase, for: server.id)
            Keychain.setPassword(nil, for: server.id)
        }
        save(server, connect)
        dismiss()
    }
}

/// A row of soft segments, the chosen one lifted onto a card.
struct Segments<Option: Hashable>: View {
    var options: [Option]
    @Binding var selection: Option
    var label: (Option) -> String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { option in
                Text(label(option))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(selection == option ? Theme.ink : Theme.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selection == option ? Theme.card : .clear))
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { selection = option } }
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line))
    }
}

private struct PlaceOption: View {
    var place: Server.Place
    var isOn: Bool
    var action: () -> Void

    var body: some View {
        let tint = Theme.color(for: place)
        Button(action: action) {
            HStack(spacing: 7) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text(place.label).font(.system(size: 12.5, weight: .medium)).foregroundStyle(isOn ? Theme.ink : Theme.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(isOn ? tint.opacity(0.13) : Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(isOn ? tint.opacity(0.5) : Theme.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: isOn)
    }
}
