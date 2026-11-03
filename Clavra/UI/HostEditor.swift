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
    @State private var tab = UserDefaults.standard.string(forKey: "ClavraEditorTab") == "more" ? Tab.more : .basics
    @State private var newLocal = ""
    @State private var newRemote = ""
    @State private var newKind = Server.Forward.Kind.local
    @State private var tagsText = ""
    @State private var testing = false
    @State private var outcome: ConnectionTest.Outcome?
    /// Keys ~/.ssh/config names for this host, and everything Automatic would try.
    @State private var configured: [String] = []
    @State private var automatic: [String] = []

    private enum Tab: CaseIterable { case basics, more }

    private var identity: Identity? { model.identities.identity(server.identity) }

    private var canSave: Bool {
        !server.address.trimmingCharacters(in: .whitespaces).isEmpty
            && (identity != nil || !server.user.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(isNew ? "New Host" : "Edit Host").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink)
                Spacer()
                Segments(options: Tab.allCases, selection: $tab) { $0 == .basics ? "Basics" : "More" }
                    .frame(width: 170)
            }
            .padding(.bottom, 20)

            Group { if tab == .basics { basics } else { more } }

            if let outcome { TestResult(outcome: outcome) { trust($0) }.padding(.top, 16) }

            Rectangle().fill(Theme.line).frame(height: 1).padding(.horizontal, -24).padding(.top, 22)

            HStack(spacing: 8) {
                if let delete {
                    Button("Delete") { delete(); dismiss() }
                        .buttonStyle(QuietButtonStyle(tint: Theme.color(for: .production)))
                }
                Button(testing ? "Testing…" : "Test Connection") { test() }
                    .buttonStyle(QuietButtonStyle()).disabled(!canSave || testing)
                    .help("Reach the server, check its key and sign in, without opening a tab")
                Spacer(minLength: 12)
                Button("Cancel") { dismiss() }.buttonStyle(QuietButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Save") { commit(connect: false) }.buttonStyle(QuietButtonStyle()).disabled(!canSave)
                Button("Save and Connect") { commit(connect: true) }.buttonStyle(BrassButtonStyle())
                    .keyboardShortcut(.defaultAction).disabled(!canSave).opacity(canSave ? 1 : 0.5)
            }
            .padding(.top, 16)
        }
        .padding(24)
        .frame(width: 580)
        .background(Theme.window)
        .onAppear {
            password = Keychain.password(for: server.id) ?? ""
            passphrase = Keychain.passphrase(for: server.id) ?? ""
            tagsText = server.tags.joined(separator: ", ")
            findKeys()
        }
        .onChange(of: tagsText) {
            server.tags = tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        .onChange(of: server.address) { findKeys() }
        .onChange(of: server.name) { findKeys() }
    }

    @ViewBuilder private var basics: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 10) {
                FormField("Address") { SoftField("10.0.1.12 or api.example.com", text: $server.address) }
                FormField("Port") { SoftField("22", text: portText) }.frame(width: 84)
            }
            HStack(alignment: .top, spacing: 10) {
                FormField("Name") { SoftField("Shown in the sidebar", text: $server.name) }
                FormField("Tags") { SoftField("nginx, client-a", text: $tagsText) }
            }
            FormField("Label", note: server.place == .production
                      ? "Production tabs carry a coral mark and ask before risky commands." : nil) {
                LabelPicker(place: $server.place, store: model.store)
            }

            Rectangle().fill(Theme.line).frame(height: 1).padding(.vertical, 2)

            FormField("Sign in as", note: identity.map { "Uses \($0.title)'s user, key and password. Change them once in Keys and every host that uses it follows." }) {
                Dropdown(icon: "person.crop.circle", title: identity?.title ?? "This host only",
                         detail: identity?.summary, entries: identityEntries)
            }
            if identity == nil {
                HStack(alignment: .top, spacing: 10) {
                    FormField("User") { SoftField("root, deploy…", text: $server.user) }
                    FormField("With") {
                        Segments(options: Server.Auth.allCases, selection: $server.auth) { $0 == .key ? "Key" : "Password" }
                    }
                    .frame(width: 190)
                }
                if server.auth == .key {
                    HStack(alignment: .top, spacing: 10) {
                        FormField("Key") {
                            Dropdown(icon: "key", title: server.keyPath.map(Self.fileName) ?? "Automatic",
                                     detail: server.keyPath ?? automaticDetail, entries: keyEntries)
                        }
                        FormField("Passphrase") { SoftField("If the key has one", text: $passphrase, secure: true) }
                            .frame(width: 190)
                    }
                } else {
                    FormField("Password") { SoftField("Saved to the Keychain", text: $password, secure: true) }
                }
                Text("Passwords and passphrases stay in your Mac's Keychain.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
            }
        }
    }

    @ViewBuilder private var more: some View {
        VStack(alignment: .leading, spacing: 18) {
            FormField("Connect through",
                      note: "A jump host (bastion) you reach first. The address is then looked up from there, so private names and IPs work.") {
                let jump = others.first { $0.id == server.jump }
                Dropdown(icon: "arrow.triangle.turn.up.right.diamond", title: jump?.title ?? "Directly",
                         detail: jump.map { "\($0.target), then this server" }, entries: jumpEntries)
            }

            FormField("Tunnels", note: ForwardFields.note(newKind)) {
                if !server.forwards.isEmpty {
                    VStack(spacing: 0) {
                        ForEach($server.forwards) { $forward in
                            HStack(spacing: 10) {
                                Text(verbatim: forward.summary).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Theme.ink)
                                Spacer()
                                Toggle("Open on connect", isOn: $forward.automatic).toggleStyle(.checkbox)
                                    .font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                                Button { server.forwards.removeAll { $0.id == forward.id } } label: {
                                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.tertiary)
                                        .frame(width: 22, height: 22).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Remove this tunnel")
                            }
                            .padding(.horizontal, 12)
                            .frame(height: 38)
                            if forward.id != server.forwards.last?.id { Rectangle().fill(Theme.line).frame(height: 1) }
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.field))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line))
                }
                HStack(spacing: 8) {
                    Dropdown(title: Self.kindName(newKind), entries: kindEntries).frame(width: 128)
                    ForwardFields(kind: newKind, local: $newLocal, remote: $newRemote)
                    Button("Add", action: addForward).buttonStyle(QuietButtonStyle())
                        .disabled(Server.Forward.parse(kind: newKind, local: newLocal, remote: newRemote) == nil)
                }
                if let problem = ForwardFields.problem(kind: newKind, local: newLocal, remote: newRemote) {
                    Text(problem.text).font(.system(size: 11.5))
                        .foregroundStyle(problem.isWarning ? Theme.brass : Theme.color(for: .production))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            FormField("Run after connecting") {
                SoftField("cd /srv/app && tmux attach -t main", text: $server.startup, mono: true)
            }

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Keep sessions alive").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
                    Text("Each tab runs inside tmux on the server, so a dropped connection, sleep or quitting Clavra doesn't stop what's running; reconnecting picks up right where it was. Closing the tab ends it. Needs tmux on the server.")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: $server.keepsAlive).toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line))

            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Ask before risky commands").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
                        Text("rm -rf, DROP TABLE, shutdown, docker rm and the like wait for a yes, with what they'd touch on the server. On by default for Production.")
                            .font(.system(size: 11.5)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Toggle("", isOn: Binding(get: { server.guardsCommands }, set: { server.guardOverride = $0 }))
                        .toggleStyle(.switch).labelsHidden().controlSize(.small)
                }
                .padding(12)

                if server.guardsCommands {
                    Rectangle().fill(Theme.line).frame(height: 1).padding(.horizontal, 12)
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Only a phone can say yes").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
                            Text("Those commands run once a phone connected through Phone Access approves them. The Mac on its own can only say no.")
                                .font(.system(size: 11.5)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Toggle("", isOn: $server.phoneApproval).toggleStyle(.switch).labelsHidden().controlSize(.small)
                    }
                    .padding(12)
                }
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line))

            FormField("Notes") {
                TextEditor(text: $server.notes)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.never)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 8)
                    .frame(height: 64)
                    .overlay(alignment: .topLeading) {
                        if server.notes.isEmpty {
                            Text("Anything worth remembering about this server")
                                .font(.system(size: 13)).foregroundStyle(Theme.tertiary)
                                .padding(.horizontal, 12).padding(.vertical, 8).allowsHitTesting(false)
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.field))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line))
            }
        }
    }

    // MARK: Dropdown lists

    private func identityEntries() -> [DropdownEntry] {
        var list: [DropdownEntry] = [
            .item("This host only", detail: "Type a user and key below", icon: "person.crop.circle", isOn: identity == nil) { server.identity = nil },
        ]
        if !model.identities.identities.isEmpty {
            list.append(.divider("ids"))
            list.append(.heading("Identities"))
            for item in model.identities.identities {
                list.append(.item(item.title, detail: item.summary, icon: "person.2", isOn: server.identity == item.id, id: item.id.uuidString) {
                    server.identity = item.id
                })
            }
        }
        if identity == nil, !server.user.trimmingCharacters(in: .whitespaces).isEmpty {
            list.append(.divider("save"))
            list.append(.item("Save These Details as an Identity", detail: "Reuse this user and key on other hosts", icon: "plus", action: makeIdentity))
        }
        return list
    }

    private func keyEntries() -> [DropdownEntry] {
        var list: [DropdownEntry] = [
            .item("Automatic", detail: automaticDetail, icon: "magnifyingglass", isOn: server.keyPath == nil, id: "auto") { server.keyPath = nil },
        ]
        if !keys.isEmpty {
            list.append(.divider("keys"))
            list.append(.heading("In ~/.ssh"))
            for key in keys {
                let matches = configured.contains { Credentials.expand($0) == Credentials.expand(key) }
                list.append(.item(Self.fileName(key), detail: matches ? "Named for this host in ~/.ssh/config" : nil,
                                  icon: "key", isOn: server.keyPath == key, id: key) { server.keyPath = key })
            }
        }
        list.append(.divider("file"))
        list.append(.item("Choose File…", icon: "folder", action: chooseKey))
        return list
    }

    private func jumpEntries() -> [DropdownEntry] {
        var list: [DropdownEntry] = [
            .item("Directly", detail: "Straight from this Mac", icon: "arrow.right", isOn: server.jump == nil) { server.jump = nil },
        ]
        let candidates = others.filter { $0.id != server.id && $0.jump != server.id && !$0.isGitRemote }
        if !candidates.isEmpty {
            list.append(.divider("hosts"))
            list.append(.heading("Through a saved host"))
            for host in candidates {
                list.append(.item(host.title, detail: host.target, icon: "server.rack", isOn: server.jump == host.id, id: host.id.uuidString) {
                    server.jump = host.id
                })
            }
        }
        return list
    }

    private func kindEntries() -> [DropdownEntry] {
        Server.Forward.Kind.allCases.map { kind in
            .item(Self.kindName(kind), detail: Self.kindDetail(kind), isOn: newKind == kind, id: kind.rawValue) { newKind = kind }
        }
    }

    private static func kindName(_ kind: Server.Forward.Kind) -> String {
        switch kind {
        case .local: "To server"
        case .remote: "To Mac"
        case .socks: "SOCKS"
        }
    }

    private static func kindDetail(_ kind: Server.Forward.Kind) -> String {
        switch kind {
        case .local: "Like ssh -L"
        case .remote: "Like ssh -R"
        case .socks: "Like ssh -D"
        }
    }

    private static func fileName(_ path: String) -> String { (path as NSString).lastPathComponent }

    /// What Automatic will use, in a few words.
    private var automaticDetail: String {
        if let first = configured.first { return "Uses \(Self.fileName(first)), from ~/.ssh/config" }
        if let first = automatic.first {
            let name = Self.fileName(first)
            return automatic.count > 1 ? "Tries \(name), then \(automatic.count - 1) more" : "Uses \(name)"
        }
        return "No keys found in ~/.ssh"
    }

    private func findKeys() {
        configured = Credentials.configuredKeys(for: server)
        automatic = Credentials.automaticKeys(for: server)
    }

    private func addForward() {
        guard let forward = Server.Forward.parse(kind: newKind, local: newLocal, remote: newRemote) else { return }
        server.forwards.append(forward)
        newLocal = ""
        newRemote = ""
    }

    private var portText: Binding<String> {
        Binding(get: { String(server.port) }, set: { server.port = Int($0.filter(\.isNumber)) ?? 22 })
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

/// Personal, Staging, Production and the user's own labels, as chips; the last one makes a new label.
private struct LabelPicker: View {
    @Binding var place: Server.Place
    var store: HostStore
    @State private var labels = LabelStore.shared
    /// The label being made or changed, if the small form under the chips is open.
    @State private var draft: HostLabel?
    @State private var isNewDraft = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FlowLayout(spacing: 8) {
                ForEach(labels.choices) { choice in
                    LabelChip(title: choice.label, tint: Theme.color(for: choice), isOn: labels.resolve(place) == choice) {
                        place = choice
                    }
                    .clavraContextMenu {
                        guard let custom = labels.label(for: choice) else { return [] }
                        return [.item("Edit Label…", icon: "pencil") { draft = custom; isNewDraft = false },
                                .item("Delete Label", icon: "trash", tint: Theme.color(for: .production)) { remove(custom) }]
                    }
                }
                Button {
                    draft = HostLabel(name: "", tint: HostLabel.Tint.allCases.first { tint in !labels.labels.contains { $0.tint == tint } && ![.sage, .mist, .coral].contains(tint) } ?? .lilac)
                    isNewDraft = true
                } label: {
                    Label("New Label", systemImage: "plus").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.secondary)
                        .padding(.horizontal, 12).frame(height: 30)
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Make your own label, like Client A or Lab")
            }

            if let draft {
                // The form edits its own copy: a binding into `draft` would let the name field,
                // committing as it loses focus to Cancel, write the label straight back.
                LabelForm(draft: draft, isNew: isNewDraft, cancel: { self.draft = nil }, save: save)
                    .id(draft.id)
            }
        }
    }

    private func save(_ label: HostLabel) {
        if isNewDraft {
            let made = labels.add(name: label.name, tint: label.tint)
            place = made.place
        } else {
            labels.save(label)
        }
        draft = nil
    }

    private func remove(_ label: HostLabel) {
        if place == label.place { place = .personal }
        store.moveHosts(from: label.place)
        labels.delete(label)
    }
}

/// One label to pick: quiet when it isn't chosen, washed in its colour when it is.
private struct LabelChip: View {
    var title: String
    var tint: Color
    var isOn: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(isOn ? tint : hovering ? Theme.ink : Theme.secondary)
                .padding(.horizontal, 13)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(isOn ? tint.opacity(0.14) : Theme.field))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(isOn ? tint.opacity(0.4) : Theme.line))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isOn)
    }
}

/// Name a label and give it a colour.
private struct LabelForm: View {
    @State var draft: HostLabel
    var isNew: Bool
    var cancel: () -> Void
    var save: (HostLabel) -> Void

    private var canSave: Bool { !draft.name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SoftField("Client A, Lab, Database…", text: $draft.name)
            HStack(spacing: 8) {
                ForEach(HostLabel.Tint.allCases, id: \.self) { tint in
                    let color = Theme.color(for: tint)
                    Button { draft.tint = tint } label: {
                        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color.opacity(0.85))
                            .frame(width: 22, height: 22)
                            .padding(3)
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(draft.tint == tint ? color : .clear, lineWidth: 1.5))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(tint.rawValue.capitalized)
                }
                Spacer()
                Button("Cancel", action: cancel).buttonStyle(QuietButtonStyle())
                Button(isNew ? "Add Label" : "Save Label") { save(draft) }.buttonStyle(BrassButtonStyle())
                    .disabled(!canSave).opacity(canSave ? 1 : 0.5)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line))
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
