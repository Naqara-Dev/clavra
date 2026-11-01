import AppKit
import SwiftUI

/// Saved ways of signing in, on the Keys page. Change the user, key or password here once and every
/// host that signs in as it follows.
struct IdentitiesSection: View {
    var model: AppModel
    @State private var editing: Identity?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Identities").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text("A user with a key or a password that many hosts share. Pick one under Sign in as when editing a host.")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("New Identity") { editing = Identity(name: "", user: NSUserName()) }.buttonStyle(QuietButtonStyle())
            }

            if !model.identities.identities.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(model.identities.identities.enumerated()), id: \.element.id) { index, identity in
                        if index > 0 { Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 52) }
                        IdentityRow(identity: identity, hosts: model.hosts(signingInAs: identity),
                                    edit: { editing = identity }, delete: { model.deleteIdentity(identity) })
                    }
                }
                .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.line))
            }
        }
        .sheet(item: $editing) { identity in
            IdentityEditor(identity: identity, isNew: model.identities.identity(identity.id) == nil) { saved, secret in
                model.identities.save(saved)
                if saved.auth == .password {
                    Keychain.setPassword(secret.isEmpty ? nil : secret, for: saved.id)
                    Keychain.setPassphrase(nil, for: saved.id)
                } else {
                    Keychain.setPassphrase(secret.isEmpty ? nil : secret, for: saved.id)
                    Keychain.setPassword(nil, for: saved.id)
                }
            }
        }
    }
}

private struct IdentityRow: View {
    var identity: Identity
    var hosts: [Server]
    var edit: () -> Void
    var delete: () -> Void
    @State private var hovering = false
    @State private var confirming = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: identity.auth == .password ? "person.badge.key" : "person.crop.circle")
                .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.line))
            VStack(alignment: .leading, spacing: 2) {
                Text(identity.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
                Text(identity.summary).font(.system(size: 11.5)).foregroundStyle(Theme.tertiary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(hosts.isEmpty ? "No hosts yet" : hosts.count == 1 ? "1 host" : "\(hosts.count) hosts")
                .font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
                .help(hosts.map(\.title).joined(separator: ", "))
            Button("Edit", action: edit).buttonStyle(QuietButtonStyle())
            Menu {
                Button("Delete…", role: .destructive) { confirming = true }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: edit)
        .confirmationDialog("Delete \(identity.title)?", isPresented: $confirming) {
            Button("Delete", role: .destructive, action: delete)
        } message: {
            Text(hosts.isEmpty
                 ? "Its saved password or passphrase is removed from the Keychain."
                 : "The \(hosts.count == 1 ? "host" : "\(hosts.count) hosts") using it keep signing in the same way, each with its own copy.")
        }
    }
}

private struct IdentityEditor: View {
    @State var identity: Identity
    var isNew: Bool
    var save: (Identity, _ secret: String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var secret = ""
    @State private var keys = Credentials.keysInSSHFolder()

    private var canSave: Bool { !identity.user.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "New Identity" : "Edit \(identity.title)")
                .font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink)

            VStack(alignment: .leading, spacing: 8) {
                SoftField("Work deploy, Team root…", text: $identity.name, prefix: "Name")
                SoftField("root, deploy…", text: $identity.user, prefix: "User")
                Segments(options: Server.Auth.allCases, selection: $identity.auth) { $0 == .key ? "Key" : "Password" }
                if identity.auth == .key {
                    Menu {
                        Button("Default (id_ed25519, then id_rsa)") { identity.keyPath = nil }
                        if !keys.isEmpty { Divider() }
                        ForEach(keys, id: \.self) { key in Button(key) { identity.keyPath = key } }
                        Divider()
                        Button("Choose File…", action: chooseKey)
                    } label: {
                        HStack {
                            Image(systemName: "key").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                            Text(identity.keyPath ?? "Default key").font(.system(size: 13)).foregroundStyle(Theme.ink)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.field))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.line))
                        .contentShape(Rectangle())
                    }
                    .menuStyle(.button).buttonStyle(.plain)
                    SoftField("Only if the key has one", text: $secret, secure: true, prefix: "Passphrase")
                } else {
                    SoftField("Saved to the Keychain", text: $secret, secure: true, prefix: "Password")
                }
                Text("Kept in your Mac's Keychain. Every host that signs in as this identity uses it.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(QuietButtonStyle()).keyboardShortcut(.cancelAction)
                Button(isNew ? "Add Identity" : "Save") {
                    identity.name = identity.name.trimmingCharacters(in: .whitespaces)
                    identity.user = identity.user.trimmingCharacters(in: .whitespaces)
                    save(identity, secret)
                    dismiss()
                }
                .buttonStyle(BrassButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(22)
        .frame(width: 440)
        .background(Theme.window)
        .onAppear {
            secret = (identity.auth == .password ? Keychain.password(for: identity.id) : Keychain.passphrase(for: identity.id)) ?? ""
        }
        .onChange(of: identity.auth) {
            secret = (identity.auth == .password ? Keychain.password(for: identity.id) : Keychain.passphrase(for: identity.id)) ?? ""
        }
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh")
        panel.showsHiddenFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        identity.keyPath = url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }
}
