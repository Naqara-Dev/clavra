import SwiftUI

/// What ~/.ssh/config holds, before anything is saved: every host with its user, port, key and jump
/// host, ticked if it's worth importing. Hosts already saved can't be ticked; ones that only pick a
/// key for git start unticked.
struct ImportSheet: View {
    var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [HostStore.ImportCandidate] = []
    @State private var chosen: Set<UUID> = []
    @State private var loaded = false

    private var available: [HostStore.ImportCandidate] { candidates.filter { !$0.isSaved } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Import from ~/.ssh/config").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink)
            Text(summary).font(.system(size: 12.5)).foregroundStyle(Theme.secondary).padding(.top, 4)
                .fixedSize(horizontal: false, vertical: true)

            if candidates.isEmpty {
                Text(loaded ? "~/.ssh/config has no hosts to import." : "Reading…")
                    .font(.system(size: 13)).foregroundStyle(Theme.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                HStack {
                    if !available.isEmpty {
                    Button(chosen.count == available.count ? "Select None" : "Select All") {
                        chosen = chosen.count == available.count ? [] : Set(available.map(\.id))
                    }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.brass)
                    }
                    Spacer()
                    Text(verbatim: "\(chosen.count) of \(available.count)").font(.system(size: 11.5)).monospacedDigit()
                        .foregroundStyle(Theme.tertiary)
                }
                .padding(.top, 16).padding(.bottom, 8)

                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(candidates) { candidate in
                            ImportRow(candidate: candidate, isOn: chosen.contains(candidate.id)) {
                                if chosen.contains(candidate.id) { chosen.remove(candidate.id) } else { chosen.insert(candidate.id) }
                            }
                            if candidate.id != candidates.last?.id { Rectangle().fill(Theme.line).frame(height: 1) }
                        }
                    }
                }
                .scrollIndicators(.automatic)
                .frame(maxHeight: 380)
                .fixedSize(horizontal: false, vertical: true)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.field))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            Rectangle().fill(Theme.line).frame(height: 1).padding(.horizontal, -24).padding(.top, 20)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(QuietButtonStyle()).keyboardShortcut(.cancelAction)
                Button(chosen.count == 1 ? "Import 1 Host" : "Import \(chosen.count) Hosts") {
                    model.store.add(candidates.filter { chosen.contains($0.id) })
                    dismiss()
                }
                .buttonStyle(BrassButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty).opacity(chosen.isEmpty ? 0.5 : 1)
            }
            .padding(.top, 16)
        }
        .padding(24)
        .frame(width: 560)
        .background(Theme.window)
        .onAppear {
            candidates = model.store.importCandidates()
            chosen = Set(candidates.filter { !$0.isSaved && !$0.server.isGitRemote }.map(\.id))
            loaded = true
        }
    }

    private var summary: String {
        let git = candidates.filter { !$0.isSaved && $0.server.isGitRemote }.count
        let saved = candidates.filter(\.isSaved).count
        if loaded, !candidates.isEmpty, available.isEmpty { return "Everything in ~/.ssh/config is saved already." }
        var parts = ["Check what each host will look like before it's saved."]
        if git > 0 { parts.append(git == 1 ? "One only picks a key for git, so it starts unticked." : "\(git) only pick a key for git, so they start unticked.") }
        if saved > 0 { parts.append(saved == 1 ? "One is saved already." : "\(saved) are saved already.") }
        return parts.joined(separator: " ")
    }
}

private struct ImportRow: View {
    var candidate: HostStore.ImportCandidate
    var isOn: Bool
    var toggle: () -> Void
    @State private var hovering = false

    private var server: Server { candidate.server }

    private var details: String {
        var parts: [String] = []
        if let key = candidate.keys.first {
            let more = candidate.keys.count > 1 ? " +\(candidate.keys.count - 1)" : ""
            parts.append("key \((key as NSString).lastPathComponent)\(more)")
        } else {
            parts.append("key automatic")
        }
        if let jump = candidate.jump { parts.append("through \(jump)") }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .top, spacing: 12) {
                Checkbox(isOn: isOn && !candidate.isSaved, isDisabled: candidate.isSaved).padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(server.title).font(.system(size: 13, weight: .medium))
                            .foregroundStyle(candidate.isSaved ? Theme.tertiary : Theme.ink).lineLimit(1)
                        if candidate.isSaved {
                            Text("Saved already").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                        } else if server.isGitRemote {
                            Text("Git key only").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.brass)
                        }
                    }
                    Text(verbatim: server.target).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.secondary).lineLimit(1)
                    Text(details).font(.system(size: 11.5)).foregroundStyle(Theme.tertiary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(hovering && !candidate.isSaved ? Theme.cardHover.opacity(0.6) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(candidate.isSaved)
        .onHover { hovering = $0 }
    }
}

/// A soft square tick box in Clavra's colours.
struct Checkbox: View {
    var isOn: Bool
    var isDisabled = false

    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(isOn ? Theme.brass : Theme.card)
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(isOn ? .clear : Theme.line, lineWidth: 1))
            .overlay {
                if isOn { Image(systemName: "checkmark").font(.system(size: 9.5, weight: .bold)).foregroundStyle(Theme.onBrass) }
            }
            .frame(width: 16, height: 16)
            .opacity(isDisabled ? 0.4 : 1)
            .animation(.easeOut(duration: 0.12), value: isOn)
    }
}
