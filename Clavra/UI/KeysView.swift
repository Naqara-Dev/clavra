import SwiftUI

/// Every private key in ~/.ssh: what it is, which hosts use it, and anything worth fixing.
struct KeysView: View {
    @Bindable var model: AppModel
    @State private var keys: [SSHKeyInfo] = []
    @State private var making = false
    @State private var note: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Keys").font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.ink)
                        Text("Who you sign in as, and the private keys in ~/.ssh. Nothing here leaves your Mac.")
                            .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    Button("New Key") { making = true }.buttonStyle(BrassButtonStyle())
                }
                .padding(.bottom, 22)

                if let note {
                    Text(note).font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.card))
                        .padding(.bottom, 14)
                }

                IdentitiesSection(model: model).padding(.bottom, 28)

                Text("Keys in ~/.ssh").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink).padding(.bottom, 10)

                if keys.isEmpty {
                    Text("No private keys in ~/.ssh yet. Make one to sign in without passwords.")
                        .font(.system(size: 13)).foregroundStyle(Theme.tertiary)
                }
                VStack(spacing: 10) {
                    ForEach(keys) { key in
                        KeyCard(key: key, hosts: hosts(using: key), live: model.sessions.filter(\.isLive),
                                fix: { fix(key) }, install: { install(key, on: $0) })
                    }
                }
            }
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 32)
            .padding(.top, 60)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.never)
        .background(Theme.window)
        .onAppear(perform: reload)
        .sheet(isPresented: $making) {
            NewKeySheet { path in
                reload()
                note = "Made \(path). Install it on a server from its card below, then switch the host to it."
            }
        }
    }

    private func reload() { keys = SSHKeys.scan() }

    private func hosts(using key: SSHKeyInfo) -> [Server] {
        model.store.hosts.map(model.resolved).filter { host in
            guard host.auth == .key else { return false }
            if let path = host.keyPath { return Credentials.expand(path) == Credentials.expand(key.path) }
            let fallback = Credentials.defaultKeys.first { FileManager.default.fileExists(atPath: Credentials.expand($0)) }
            return fallback.map(Credentials.expand) == Credentials.expand(key.path)
        }
    }

    private func fix(_ key: SSHKeyInfo) {
        do {
            try SSHKeys.fixPermissions(key)
            note = "\(key.path) is now readable only by you."
        } catch {
            note = "Couldn't change \(key.path): \(error.localizedDescription)"
        }
        reload()
    }

    private func install(_ key: SSHKeyInfo, on session: Session) {
        guard let publicKey = key.publicKey else { return }
        note = "Adding \(key.path) to \(session.server.title)…"
        Task {
            do {
                try await SSHKeys.install(publicKey, on: session)
                note = "\(session.server.title) now accepts \(key.path). You can switch the host to this key."
            } catch {
                note = "Couldn't add it to \(session.server.title): \(Session.describe(error))"
            }
        }
    }
}

private struct KeyCard: View {
    var key: SSHKeyInfo
    var hosts: [Server]
    var live: [Session]
    var fix: () -> Void
    var install: (Session) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "key").font(.system(size: 13)).foregroundStyle(Theme.brass)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.brass.opacity(0.12)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(key.path).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
                    Text([key.kind, key.encrypted ? "passphrase" : nil, key.comment].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
                }
                Spacer()
                Menu {
                    if let publicKey = key.publicKey {
                        Button("Copy Public Key") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(publicKey, forType: .string)
                        }
                    }
                    if !live.isEmpty, key.publicKey != nil {
                        Menu("Install on Server") {
                            ForEach(live) { session in Button(session.server.title) { install(session) } }
                        }
                    }
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: Credentials.expand(key.path))])
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12)).foregroundStyle(Theme.secondary).frame(width: 26, height: 26)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            }

            if let fingerprint = key.fingerprint {
                Text(fingerprint).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.tertiary).textSelection(.enabled)
            }

            Text(hosts.isEmpty ? "Not used by a saved host." : "Used by " + hosts.map(\.title).joined(separator: ", "))
                .font(.system(size: 12)).foregroundStyle(Theme.secondary)

            let issues = key.issues
            if issues.isEmpty {
                Label("Looks good", systemImage: "checkmark").font(.system(size: 12)).foregroundStyle(Theme.color(for: .personal))
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(issues, id: \.self) { issue in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Circle().fill(issue.isSerious ? Theme.color(for: .production) : Theme.brass).frame(width: 5, height: 5)
                                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                            Text(issue.text).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                            if case .openPermissions = issue {
                                Button("Fix") { fix() }.buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.brass)
                            }
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.line))
    }
}

private struct NewKeySheet: View {
    var made: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = "id_ed25519"
    @State private var comment = "\(NSUserName())@\(Host.current().localizedName ?? "mac")"
    @State private var passphrase = ""
    @State private var again = ""
    @State private var working = false
    @State private var error: String?

    private var ready: Bool { !name.isEmpty && passphrase == again && !working }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Key").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink)
            Text("An Ed25519 key, made by the Mac's own ssh-keygen.").font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
            SoftField("id_ed25519", text: $name, mono: true, prefix: "File")
            SoftField("Shown on servers", text: $comment, prefix: "Comment")
            SoftField("Recommended", text: $passphrase, secure: true, prefix: "Passphrase")
            SoftField("Type it again", text: $again, secure: true, prefix: "Again")
            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(Theme.color(for: .production))
            } else if passphrase != again {
                Text("The passphrases don't match.").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(QuietButtonStyle()).keyboardShortcut(.cancelAction)
                Button(working ? "Making…" : "Make Key") { create() }
                    .buttonStyle(BrassButtonStyle()).keyboardShortcut(.defaultAction).disabled(!ready).opacity(ready ? 1 : 0.5)
            }
        }
        .padding(24)
        .frame(width: 440)
        .background(Theme.window)
    }

    private func create() {
        working = true
        error = nil
        Task {
            do {
                let path = try await SSHKeys.generate(name: name, comment: comment, passphrase: passphrase)
                made(path)
                dismiss()
            } catch {
                self.error = error.localizedDescription
                working = false
            }
        }
    }
}
