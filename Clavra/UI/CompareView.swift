import SwiftUI

/// Two saved hosts side by side: what's on one and not the other, and what differs.
struct CompareView: View {
    @Bindable var model: AppModel
    @AppStorage("CompareLeft") private var leftID = ""
    @AppStorage("CompareRight") private var rightID = ""
    @AppStorage("CompareSubject") private var subject = ServerDiff.Subject.packages
    @State private var input = ""
    @State private var rows: [ServerDiff.Row] = []
    @State private var ran: (left: String, right: String)?
    @State private var running = false
    @State private var problem: String?
    @State private var showsSame = false
    @State private var confirming = false

    private var hosts: [Server] { model.store.hosts.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending } }
    private var left: Server? { model.store.host(UUID(uuidString: leftID) ?? UUID()) }
    private var right: Server? { model.store.host(UUID(uuidString: rightID) ?? UUID()) }
    private var command: String? { ServerDiff.command(for: subject, input: input) }
    private var ready: Bool { left != nil && right != nil && left?.id != right?.id && command != nil && !running }
    private var shown: [ServerDiff.Row] { showsSame ? rows : rows.filter { $0.kind != .same } }

    var body: some View {
        VStack(spacing: 0) {
            form
            Rectangle().fill(Theme.line).frame(height: 1)
            results
        }
        .background(Theme.window)
        .confirmationDialog("Run this on \(left?.title ?? "") and \(right?.title ?? "")?", isPresented: $confirming) {
            Button("Run on Both", action: compare)
        } message: {
            Text(input + "\n\nIt runs as typed. Only go ahead if it just reads.")
        }
        .onAppear {
            if left == nil { leftID = hosts.first?.id.uuidString ?? "" }
            if right == nil { rightID = hosts.dropFirst().first?.id.uuidString ?? "" }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Compare servers").font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.ink)
                Text("See what drifted between two hosts: packages, services, ports, a config file or a whole folder. Each side signs in on its own, reads, and hangs up.")
                    .font(.system(size: 13)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                hostPicker($leftID)
                Button {
                    let was = leftID
                    leftID = rightID
                    rightID = was
                    rows = rows.map { row in
                        var flipped = row
                        flipped.left = row.right
                        flipped.right = row.left
                        flipped.kind = row.kind == .onlyLeft ? .onlyRight : row.kind == .onlyRight ? .onlyLeft : row.kind
                        return flipped
                    }
                    ran = ran.map { ($0.right, $0.left) }
                } label: {
                    Image(systemName: "arrow.left.arrow.right").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
                        .frame(width: 28, height: 28).background(Circle().fill(Theme.card))
                }
                .buttonStyle(.plain).help("Swap sides")
                hostPicker($rightID)
            }
            HStack(spacing: 10) {
                Segments(options: ServerDiff.Subject.allCases, selection: $subject) { $0.label }
                    .frame(width: 520)
                if let placeholder = subject.placeholder {
                    SoftField(placeholder, text: $input, mono: true)
                        .onSubmit { if ready { subject == .command ? (confirming = true) : compare() } }
                }
                Spacer(minLength: 0)
                Button(running ? "Comparing…" : "Compare") { subject == .command ? (confirming = true) : compare() }
                    .buttonStyle(BrassButtonStyle()).disabled(!ready).opacity(ready ? 1 : 0.5)
                    .keyboardShortcut(.defaultAction)
            }
            if subject == .command, !input.isEmpty, command == nil {
                Text("That command changes things, so it isn't run here.")
                    .font(.system(size: 12)).foregroundStyle(Theme.color(for: .production))
            } else if subject == .command {
                Text("Runs exactly as typed on both hosts, so use it for commands that only read.")
                    .font(.system(size: 12)).foregroundStyle(Theme.tertiary)
            }
            if left != nil, left?.id == right?.id {
                Text("Pick two different hosts.").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 52)
        .padding(.bottom, 18)
    }

    private func hostPicker(_ id: Binding<String>) -> some View {
        Picker("", selection: id) {
            ForEach(hosts) { host in Text("\(host.title)  ·  \(host.place.label)").tag(host.id.uuidString) }
        }
        .labelsHidden()
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var results: some View {
        if running {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Signing in to both and reading…").font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let problem {
            Text(problem).font(.system(size: 13)).foregroundStyle(Theme.color(for: .production))
                .frame(maxWidth: 520).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let ran {
            VStack(spacing: 0) {
                summary(ran)
                Rectangle().fill(Theme.line).frame(height: 1)
                if shown.isEmpty {
                    Text(rows.isEmpty ? "Neither side printed anything." : "No differences. They match.")
                        .font(.system(size: 13)).foregroundStyle(Theme.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(shown) { row in DiffRow(row: row, keyed: subject.isKeyed) }
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "square.split.2x1").font(.system(size: 26)).foregroundStyle(Theme.tertiary)
                Text(hosts.count < 2 ? "Save at least two hosts to compare them." : "Pick two hosts and what to compare.")
                    .font(.system(size: 13)).foregroundStyle(Theme.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func summary(_ ran: (left: String, right: String)) -> some View {
        let onlyLeft = rows.filter { $0.kind == .onlyLeft }.count, onlyRight = rows.filter { $0.kind == .onlyRight }.count
        let changed = rows.filter { $0.kind == .changed }.count, same = rows.filter { $0.kind == .same }.count
        return HStack(spacing: 14) {
            Text(ran.left).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.ink).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 12) {
                chip("\(onlyLeft) only left", Theme.color(for: .production), show: onlyLeft > 0)
                chip("\(changed) differ", Theme.brass, show: changed > 0)
                chip("\(onlyRight) only right", Theme.color(for: .staging), show: onlyRight > 0)
                Toggle("\(same) the same", isOn: $showsSame).toggleStyle(.checkbox).font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            .fixedSize()
            Text(ran.right).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.ink).frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 28)
        .frame(height: 40)
    }

    @ViewBuilder private func chip(_ text: String, _ tint: Color, show: Bool) -> some View {
        if show {
            HStack(spacing: 5) {
                Circle().fill(tint).frame(width: 6, height: 6)
                Text(text).font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
        }
    }

    private func compare() {
        guard ready, let left, let right, let command else { return }
        running = true
        problem = nil
        let subject = subject
        let a = model.resolved(left), b = model.resolved(right)
        let jumpA = model.jumpHost(for: left), jumpB = model.jumpHost(for: right)
        Task {
            async let one = Result { try await RemoteRun.run(command, on: a, through: jumpA) }
            async let two = Result { try await RemoteRun.run(command, on: b, through: jumpB) }
            let (x, y) = await (one, two)
            running = false
            switch (x, y) {
            case let (.success(l), .success(r)):
                rows = ServerDiff.rows(l, r, subject: subject)
                ran = (left.title, right.title)
            case let (.failure(error), _):
                problem = "\(left.title): \(Session.describe(error))"
            case let (_, .failure(error)):
                problem = "\(right.title): \(Session.describe(error))"
            }
        }
    }
}

extension Result where Failure == Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}

private struct DiffRow: View {
    var row: ServerDiff.Row
    var keyed: Bool

    private var tint: Color {
        switch row.kind {
        case .same: .clear
        case .onlyLeft: Theme.color(for: .production)
        case .onlyRight: Theme.color(for: .staging)
        case .changed: Theme.brass
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            side(row.kind == .onlyRight ? nil : row.left, leading: true)
            Rectangle().fill(Theme.line).frame(width: 1)
            side(row.kind == .onlyLeft ? nil : row.right, leading: false)
        }
        .background(tint.opacity(row.kind == .same ? 0 : 0.06))
        .overlay(alignment: .leading) { Rectangle().fill(tint).frame(width: 2) }
    }

    private func side(_ value: String?, leading: Bool) -> some View {
        HStack(spacing: 10) {
            if let value {
                if keyed {
                    Text(row.key).foregroundStyle(row.kind == .same ? Theme.secondary : Theme.ink).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    Text(value).foregroundStyle(row.kind == .changed ? Theme.brass : Theme.tertiary).lineLimit(1)
                } else {
                    Text(value.isEmpty ? " " : value).foregroundStyle(row.kind == .same ? Theme.secondary : Theme.ink)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                }
            } else {
                Spacer()
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
    }
}
