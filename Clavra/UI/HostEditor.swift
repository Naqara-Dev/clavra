import SwiftUI

/// Add or change a host. Secrets go straight to the Keychain when you save.
struct HostEditor: View {
    @State var server: Server
    var isNew: Bool
    /// Other saved hosts, for the jump host menu.
    var others: [Server] = []
    var model: AppModel
    var save: (Server, _ connect: Bool) -> Void
    var delete: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    @State private var password = ""
    @State private var passphrase = ""
    @State private var keys = Credentials.keysInSSHFolder()
    @State private var tab = Tab.basics
    @State private var newLocal = ""
    @State private var newRemote = ""
    @State private var newKind = Server.Forward.Kind.local
    @State private var tagsText = ""
    @State private var testing = false
    @State private var outcome: ConnectionTest.Outcome?

    private enum Tab: CaseIterable { case basics, more }

    private var identity: Identity? { model.identities.identity(server.identity) }

    private var canSave: Bool {
        !server.address.trimmingCharacters(in: .whitespaces).isEmpty
            && (identity != nil || !server.user.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(isNew ? "New Host" : "Edit Host").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink)
                Spacer()
                Segments(options: Tab.allCases, selection: $tab) { $0 == .basics ? "Basics" : "More" }
                    .frame(width: 170)
            }

            if tab == .basics { basics } else { more }

            if let outcome { TestResult(outcome: outcome) { trust($0) } }

            HStack(spacing: 8) {
                if let delete {
                    Button("Delete") { delete(); dismiss() }
                        .buttonStyle(QuietButtonStyle(tint: Theme.color(for: .production)))
                }
                Button(testing ? "Testing…" : "Test Connection") { test() }
                    .buttonStyle(QuietButtonStyle()).disabled(!canSave || testing)
                    .help("Reach the server, check its key and sign in, without opening a tab")
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
            tagsText = server.tags.joined(separator: ", ")
        }
        .onChange(of: tagsText) {
            server.tags = tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
    }

    @ViewBuilder private var basics: some View {
        section("Server") {
            HStack(spacing: 8) {
                SoftField("Address or IP", text: $server.address)
                SoftField("Port", text: portText).frame(width: 74)
            }
            SoftField("Optional, shown in the sidebar", text: $server.name, prefix: "Name")
            SoftField("nginx, client-a", text: $tagsText, prefix: "Tags")
        }

        section("Sign in as") {
            Menu {
                Button("This host only") { server.identity = nil }
                if !model.identities.identities.isEmpty { Divider() }
                ForEach(model.identities.identities) { item in
                    Button("\(item.title)  ·  \(item.summary)") { server.identity = item.id }
                }
                Divider()
                Button("Save These Details as an Identity…", action: makeIdentity)
                    .disabled(server.user.trimmingCharacters(in: .whitespaces).isEmpty)
            } label: {
                pickerLabel(icon: "person.crop.circle", text: identity.map { "\($0.title) · \($0.summary)" } ?? "This host only")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)

            if let identity {
                Text("Uses \(identity.title)'s user, key and password. Change them once in Keys › Identities and every host that uses it follows.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
            } else {
                SoftField("root, deploy…", text: $server.user, prefix: "User")
                Segments(options: Server.Auth.allCases, selection: $server.auth) { $0 == .key ? "Key" : "Password" }
                if server.auth == .key {
                    Menu {
                        Button("Default (id_ed25519, then id_rsa)") { server.keyPath = nil }
                        if !keys.isEmpty { Divider() }
                        ForEach(keys, id: \.self) { key in Button(key) { server.keyPath = key } }
                        Divider()
                        Button("Choose File…", action: chooseKey)
                    } label: {
                        pickerLabel(icon: "key", text: server.keyPath ?? "Default key")
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

        section("Tunnels when connected") {
            ForEach($server.forwards) { $forward in
                HStack(spacing: 8) {
                    Text(verbatim: forward.summary).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Theme.ink)
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
                Picker("", selection: $newKind) {
                    Text("To server").tag(Server.Forward.Kind.local)
                    Text("To Mac").tag(Server.Forward.Kind.remote)
                    Text("SOCKS").tag(Server.Forward.Kind.socks)
                }
                .labelsHidden().fixedSize()
                ForwardFields(kind: newKind, local: $newLocal, remote: $newRemote)
                Button("Add", action: addForward).buttonStyle(QuietButtonStyle())
                    .disabled(Server.Forward.parse(kind: newKind, local: newLocal, remote: newRemote) == nil)
            }
        }

        section("When the shell is up, type") {
            SoftField("cd /srv/app && tmux attach -t main", text: $server.startup, mono: true)
        }

        section("Risky commands") {
            Toggle("Ask before running them", isOn: Binding(get: { server.guardsCommands }, set: { server.guardOverride = $0 }))
                .toggleStyle(.switch).font(.system(size: 13))
            Text("rm -rf, DROP TABLE, shutdown, docker rm and the like wait for a yes. On by default for production.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
        }

        section("Notes") {
            TextEditor(text: $server.notes)
                .font(.system(size: 12.5))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 64)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.field))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line))
        }
    }

    private func addForward() {
        guard let forward = Server.Forward.parse(kind: newKind, local: newLocal, remote: newRemote) else { return }
        server.forwards.append(forward)
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

    /// Turns what's typed into a reusable identity and points this host at it.
    private func makeIdentity() {
        let user = server.user.trimmingCharacters(in: .whitespaces)
        let made = Identity(name: "\(user)@\(server.title)", user: user, auth: server.auth, keyPath: server.keyPath)
        model.identities.save(made)
        if server.auth == .password { Keychain.setPassword(password, for: made.id) } else { Keychain.setPassphrase(passphrase, for: made.id) }
        server.identity = made.id
    }

    private func test() {
        testing = true
        outcome = nil
        let target = model.resolved(server)
        let jump = model.jumpHost(for: server)
        let typedPassword = identity == nil ? password : nil
        let typedPassphrase = identity == nil ? passphrase : nil
        Task {
            outcome = await ConnectionTest.run(target, through: jump, password: typedPassword, passphrase: typedPassphrase)
            testing = false
        }
    }

    private func trust(_ outcome: ConnectionTest.Outcome) {
        guard case .newKey(_, let key, let host, let port) = outcome else { return }
        KnownHosts.trust(host: host, port: port, key: key)
        test()
    }

    private func commit(connect: Bool) {
        server.address = server.address.trimmingCharacters(in: .whitespaces)
        server.user = server.user.trimmingCharacters(in: .whitespaces)
        if let identity {
            // The identity holds the secret; this host keeps none of its own.
            server.user = identity.user
            Keychain.forget(server.id)
            save(server, connect)
            dismiss()
            return
        }
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

/// What Test Connection found, in a soft card above the buttons.
private struct TestResult: View {
    var outcome: ConnectionTest.Outcome
    var trust: (ConnectionTest.Outcome) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint).padding(.top, 1)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.ink)
                Text(detail).font(.system(size: 12, design: isKey ? .monospaced : .default)).foregroundStyle(Theme.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if case .newKey = outcome {
                    Button("Trust This Key and Test Again") { trust(outcome) }.buttonStyle(QuietButtonStyle())
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.opacity(0.25)))
    }

    private var isKey: Bool {
        switch outcome {
        case .newKey, .changedKey: true
        default: false
        }
    }

    private var icon: String {
        switch outcome {
        case .ok: "checkmark.circle"
        case .newKey: "key"
        case .changedKey, .failed: "exclamationmark.triangle"
        }
    }

    private var tint: Color {
        switch outcome {
        case .ok: Theme.color(for: .personal)
        case .newKey: Theme.brass
        case .changedKey, .failed: Theme.color(for: .production)
        }
    }

    private var title: String {
        switch outcome {
        case .ok: "It works"
        case .newKey: "First time seeing this server's key"
        case .changedKey: "This server's key changed"
        case .failed: "Couldn't connect"
        }
    }

    private var detail: String {
        switch outcome {
        case .ok(let text): text
        case .newKey(let fingerprint, _, _, _): fingerprint
        case .changedKey(let fingerprint): "It now shows \(fingerprint). Only trust it if you know why it changed; connecting will ask."
        case .failed(let text): text
        }
    }
}
