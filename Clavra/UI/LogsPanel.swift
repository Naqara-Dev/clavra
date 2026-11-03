import SwiftUI

/// A log followed live: pick a file, a journal unit or a container; filter, pause, and see errors
/// stand out as they arrive.
struct LogsPanel: View {
    var session: Session
    @State private var kind = Kind.file
    @State private var name = ""
    @AppStorage("LogsLastFile") private var lastFile = "/var/log/syslog"

    enum Kind: String, CaseIterable {
        case file, journal, docker
        var label: String {
            switch self {
            case .file: "File"
            case .journal: "Journal"
            case .docker: "Docker"
            }
        }
        var placeholder: String {
            switch self {
            case .file: "/var/log/nginx/error.log"
            case .journal: "Unit, e.g. nginx (or empty for all)"
            case .docker: "Container name"
            }
        }
    }

    private var lens: LogLens { session.logs }

    private var source: LogLens.Source? {
        let text = name.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .file: return text.isEmpty ? nil : .file(text)
        case .journal: return .journal(unit: text)
        case .docker: return text.isEmpty ? nil : .docker(text)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.line).frame(height: 1)
            list
        }
        .onAppear {
            if let current = lens.source {
                switch current {
                case .file(let path): kind = .file; name = path
                case .journal(let unit): kind = .journal; name = unit
                case .docker(let container): kind = .docker; name = container
                }
            } else if name.isEmpty {
                name = lastFile
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text("Logs").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                if lens.running {
                    Circle().fill(Theme.color(for: .personal)).frame(width: 6, height: 6).padding(.leading, 4)
                    Text(lens.source?.label ?? "").font(.system(size: 11.5)).foregroundStyle(Theme.tertiary).lineLimit(1)
                }
                Spacer()
                if lens.errors > 0 { badge("\(lens.errors)", Theme.color(for: .production), help: "Error lines since it started") }
                if lens.warnings > 0 { badge("\(lens.warnings)", Theme.brass, help: "Warning lines since it started") }
                if lens.source != nil {
                    icon(lens.paused ? "play.fill" : "pause.fill", help: lens.paused ? "Resume" : "Pause") { lens.paused.toggle() }
                    icon("trash", help: "Clear") { lens.clear() }
                    if lens.running { icon("stop.fill", help: "Stop following") { lens.stop() } }
                }
            }
            Segments(options: Kind.allCases, selection: $kind) { $0.label }
            HStack(spacing: 6) {
                SoftField(kind.placeholder, text: $name, mono: true).onSubmit(start)
                Button(lens.running ? "Switch" : "Follow", action: start)
                    .buttonStyle(QuietButtonStyle()).disabled(source == nil || !session.isLive)
            }
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease").font(.system(size: 10.5)).foregroundStyle(Theme.tertiary)
                    TextField("Filter", text: Bindable(lens).filter).textFieldStyle(.plain).font(.system(size: 12))
                }
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.field))
                Picker("", selection: Bindable(lens).minimum) {
                    Text("All").tag(LogLens.Level.debug)
                    Text("Info+").tag(LogLens.Level.info)
                    Text("Warnings+").tag(LogLens.Level.warning)
                    Text("Errors").tag(LogLens.Level.error)
                }
                .labelsHidden().pickerStyle(.menu).controlSize(.small).fixedSize()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var list: some View {
        if let problem = lens.problem {
            Text(problem).font(.system(size: 12)).foregroundStyle(Theme.color(for: .production))
                .padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if lens.source == nil {
            Text("Follow a log file, the systemd journal or a container's output here, without tying up the shell. Errors and warnings stand out as they arrive.")
                .font(.system(size: 12)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                .padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            let shown = lens.visible
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if lens.running && lens.lines.isEmpty {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini)
                                Text("Waiting for lines…").font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
                            }
                            .padding(10)
                        }
                        ForEach(shown) { line in LogRow(line: line, highlight: lens.filter).id(line.id) }
                    }
                    .padding(.vertical, 4)
                    .textSelection(.enabled)
                }
                .background(Theme.terminal)
                .onChange(of: shown.last?.id) {
                    guard !lens.paused, let last = shown.last?.id else { return }
                    reader.scrollTo(last, anchor: .bottom)
                }
                .overlay(alignment: .bottom) {
                    if lens.paused, lens.waiting > 0 {
                        Button("\(lens.waiting) new line\(lens.waiting == 1 ? "" : "s"), resume") { lens.paused = false }
                            .buttonStyle(QuietButtonStyle()).padding(10)
                    }
                }
            }
        }
    }

    private func start() {
        guard let source, session.isLive else { return }
        if case .file(let path) = source { lastFile = path }
        lens.paused = false
        lens.follow(source)
    }

    private func badge(_ text: String, _ tint: Color, help: String) -> some View {
        Text(text).font(.system(size: 10.5, weight: .semibold)).monospacedDigit().foregroundStyle(tint)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(tint.opacity(0.14)))
            .help(help)
    }

    private func icon(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 10.5)).foregroundStyle(Theme.secondary)
                .frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct LogRow: View {
    var line: LogLens.Line
    var highlight: String

    private var tint: Color? {
        switch line.level {
        case .error: Theme.color(for: .production)
        case .warning: Theme.brass
        default: nil
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Rectangle().fill(tint ?? .clear).frame(width: 2)
            Text(line.text.isEmpty ? " " : line.text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(line.level == .debug ? Theme.tertiary : tint ?? SwiftUI.Color(nsColor: NSColor(hex: 0xD9D6CF)))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.trailing, 8)
        .padding(.vertical, 1.5)
        .background((tint ?? .clear).opacity(line.level == .error ? 0.07 : 0))
    }
}
