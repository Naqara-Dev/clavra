import AppKit
import SwiftTerm
import SwiftUI
import UniformTypeIdentifiers

/// Recorded sessions: pick one, then play it back, scrub through it, or jump straight to a command.
struct RecordingsView: View {
    @Bindable var model: AppModel
    @State private var recordings: [Recordings.Info] = []
    @State private var loading = true
    @State private var selection: Recordings.Info?
    @State private var query = ""
    @State private var policy = Recordings.policy
    @State private var redact = Redaction.isOn
    @State private var editingWords = false
    private var exports = VideoExports.shared

    private var shown: [Recordings.Info] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return recordings }
        return recordings.filter { info in
            info.title.lowercased().contains(q) || info.commands.contains { $0.text.lowercased().contains(q) }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            list.frame(width: 300)
            Rectangle().fill(Theme.line).frame(width: 1)
            Group {
                if let selection {
                    PlayerView(info: selection, highlight: query) { delete(selection) }
                        .id(selection.url)
                } else if recordings.isEmpty, !loading {
                    emptyGuide.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "play.rectangle").font(.system(size: 28)).foregroundStyle(Theme.tertiary)
                        Text("Pick a recording to play it back")
                            .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(Theme.window)
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: Recordings.didChange)) { _ in
            Task { await load() }
        }
        .sheet(isPresented: $editingWords) { RedactionWords() }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Recordings").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.ink)
                Dropdown(icon: "record.circle", title: policy.label, height: 32) {
                    Recordings.Policy.allCases.map { option in
                        .item(option.label, isOn: policy == option, id: "policy:\(option.rawValue)") {
                            policy = option
                            Recordings.policy = option
                        }
                    }
                }
                HStack(spacing: 8) {
                    Toggle("Hide secrets", isOn: $redact).toggleStyle(.switch).controlSize(.mini)
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        .onChange(of: redact) { Redaction.isOn = redact }
                    Spacer()
                    Button("Words…") { editingWords = true }.buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.brass)
                        .help("Words to always hide, and ones never to hide")
                }
                Text(policy == .off
                     ? "Press Record at the bottom of a tab (⌥⌘R) to start, and Stop when you're done. Recordings stay on this Mac and go after \(Recordings.keepDays) days; export the ones to keep as a video."
                     : "New tabs on those hosts record from when they connect; Stop at the bottom of the tab ends it. Recordings stay on this Mac and go after \(Recordings.keepDays) days.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.tertiary)
                    TextField("Host or command", text: $query).textFieldStyle(.plain).font(.system(size: 13))
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.card))
                ForEach(exports.jobs) { job in ExportRow(job: job) }
            }
            .padding(.horizontal, 16)
            .padding(.top, 44)
            .padding(.bottom, 10)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if loading { ProgressView().controlSize(.small).padding(20) }
                    ForEach(shown) { info in
                        RecordingRow(info: info, isSelected: selection?.url == info.url, query: query)
                            .onTapGesture { selection = info }
                            .clavraContextMenu {
                                [.item("Export Video (MP4)…", icon: "film") { Exporting.video(of: info, skipPauses: true) },
                                 .item("Export Recording (.cast)…", icon: "doc") { Exporting.cast(of: info) },
                                 .divider("export"),
                                 .item("Show in Finder", icon: "folder") { NSWorkspace.shared.activateFileViewerSelecting([info.url]) },
                                 .divider("delete"),
                                 .item("Delete", icon: "trash", tint: Theme.color(for: .production)) { delete(info) }]
                            }
                    }
                    if !loading, shown.isEmpty, !recordings.isEmpty {
                        Text("No recording has that host or command.").font(.system(size: 12)).foregroundStyle(Theme.tertiary).padding(12)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
        }
        .background(Theme.sidebar.opacity(0.5))
    }

    /// How recording works, and which of your hosts the current choice covers.
    private var emptyGuide: some View {
        let covered = model.store.hosts.filter { !$0.isGitRemote && Recordings.records($0) }
        let whom: String = switch policy {
        case .off: "Nothing records on its own. Press Record at the bottom of a tab (or ⌥⌘R) when you want to keep what happens next."
        case .all: "Every host records from when its tab connects."
        case .production:
            covered.isEmpty
                ? "None of your hosts asks before risky commands yet, so none records on its own. Press Record at the bottom of a tab (⌥⌘R) to record it anyway."
                : "Recording on their own: \(covered.prefix(4).map(\.title).joined(separator: ", "))\(covered.count > 4 ? " and \(covered.count - 4) more" : ""). Any other tab records when you press Record."
        }
        return VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "record.circle").font(.system(size: 26)).foregroundStyle(Theme.tertiary)
            Text("Nothing recorded yet").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
            Text(whom).font(.system(size: 12.5)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                step("1", "Press Record at the bottom of a tab. A red dot and a clock show while it records.")
                step("2", "Work as usual. Every command you run is marked on the timeline.")
                step("3", "Press Stop. The recording shows up here, with passwords and tokens hidden when Hide secrets is on.")
                step("4", "Play it back, drag to scrub, or click a command to jump to it. Export saves it as an MP4 video wherever you choose.")
            }
        }
        .frame(maxWidth: 420, alignment: .leading)
        .padding(24)
    }

    private func step(_ number: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text(number).font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.brass)
                .frame(width: 18, height: 18).background(Circle().fill(Theme.brass.opacity(0.14)))
            Text(text).font(.system(size: 12.5)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func load() async {
        let found = await Task.detached(priority: .userInitiated) { Recordings.list() }.value
        recordings = found
        loading = false
        if let picked = selection, !found.contains(where: { $0.url == picked.url }) { selection = nil }
        if selection == nil { selection = found.first }
    }

    private func delete(_ info: Recordings.Info) {
        try? FileManager.default.removeItem(at: info.url)
        recordings.removeAll { $0.url == info.url }
        if selection?.url == info.url { selection = recordings.first }
    }
}

/// Your own words to hide in recordings, and ones never to hide.
private struct RedactionWords: View {
    @State private var hide = Redaction.extraWords.joined(separator: "\n")
    @State private var allow = Redaction.allowed.joined(separator: "\n")
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Hiding secrets in recordings").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
            Text("Passwords and tokens after = or :, --password, Authorization headers, passwords in URLs, mysql -p, GitHub, AWS, Slack, OpenAI and GitLab tokens, JWTs and private keys are hidden on their own. Each hidden character becomes •.")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            box("Also hide, one per line", text: $hide, hint: "my-db-password\ninternal-host-name")
            box("Never hide, one per line", text: $allow, hint: "public-demo-key")
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(QuietButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Save") {
                    Redaction.extraWords = hide.components(separatedBy: .newlines)
                    Redaction.allowed = allow.components(separatedBy: .newlines)
                    dismiss()
                }
                .buttonStyle(BrassButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 440)
        .background(Theme.window)
    }

    private func box(_ title: String, text: Binding<String>, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
            TextEditor(text: text)
                .font(.system(size: 12.5, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 86)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.field))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line))
                .overlay(alignment: .topLeading) {
                    if text.wrappedValue.isEmpty {
                        Text(hint).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Theme.tertiary)
                            .padding(.horizontal, 13).padding(.vertical, 8).allowsHitTesting(false)
                    }
                }
        }
    }
}

private struct RecordingRow: View {
    var info: Recordings.Info
    var isSelected: Bool
    var query: String
    @State private var hovering = false

    private var matching: String? {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return nil }
        return info.commands.first { $0.text.lowercased().contains(q) }?.text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(info.host.isEmpty ? info.title : info.host).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                Spacer()
                Text(PlayerView.clock(info.duration)).font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.tertiary)
            }
            Text(info.started.formatted(date: .abbreviated, time: .shortened) + " · \(info.commands.count) command\(info.commands.count == 1 ? "" : "s")")
                .font(.system(size: 11.5)).foregroundStyle(Theme.tertiary).lineLimit(1)
            if let matching {
                Text(matching).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.brass).lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(isSelected ? Theme.card : hovering ? Theme.card.opacity(0.55) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// One recording on screen: the terminal as it was, a scrubber, and the commands down the side.
private struct PlayerView: View {
    var info: Recordings.Info
    var highlight: String
    var delete: () -> Void
    @State private var player: ReplayPlayer?
    @State private var failed = false
    @State private var find = ""
    @State private var notFound = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.line).frame(height: 1)
            HStack(spacing: 0) {
                ZStack {
                    Theme.terminal
                    if let player {
                        ReplayTerminal(player: player).padding(12)
                    } else if failed {
                        Text("This recording couldn't be read.").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                Rectangle().fill(Theme.line).frame(width: 1)
                commands.frame(width: 250)
            }
            Rectangle().fill(Theme.line).frame(height: 1)
            if let player { Controls(player: player) }
        }
        .task {
            let url = info.url
            guard let tape = await Task.detached(priority: .userInitiated, operation: { Recordings.tape(at: url) }).value else {
                failed = true
                return
            }
            let player = ReplayPlayer(tape: tape)
            self.player = player
            // A search that found this recording by a command starts right there.
            let q = highlight.trimmingCharacters(in: .whitespaces).lowercased()
            if !q.isEmpty, let hit = info.commands.first(where: { $0.text.lowercased().contains(q) }) {
                player.seek(to: hit.time)
            } else {
                player.seek(to: tape.duration)
            }
        }
        .onDisappear { player?.pause() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(info.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                Text(info.started.formatted(date: .complete, time: .standard) + " · " + ByteCountFormatter.string(fromByteCount: Int64(info.size), countStyle: .file))
                    .font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
            }
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 10.5)).foregroundStyle(Theme.tertiary)
                TextField("Find in output", text: $find).textFieldStyle(.plain).font(.system(size: 12.5)).frame(width: 150)
                    .onSubmit {
                        notFound = player?.find(find) == false
                    }
                    .onChange(of: find) { notFound = false }
                if notFound { Text("Not after here").font(.system(size: 11)).foregroundStyle(Theme.tertiary) }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.card))
            MenuButton(minWidth: 200, alignRight: true) {
                [.item("Video (MP4)…", icon: "film") { Exporting.video(of: info, skipPauses: player?.skipsPauses ?? true) },
                 .item("Recording (.cast)…", icon: "doc") { Exporting.cast(of: info) }]
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 11, weight: .medium))
                    Text("Export").font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 10).frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.card))
                .contentShape(Rectangle())
            }
            .fixedSize()
            .help("Save as a video, or as the .cast file asciinema plays")
            Button { NSWorkspace.shared.activateFileViewerSelecting([info.url]) } label: { Image(systemName: "folder") }
                .buttonStyle(.plain).foregroundStyle(Theme.secondary).help("Show the .cast file in Finder (asciinema can play it too)")
            Button(action: delete) { Image(systemName: "trash") }
                .buttonStyle(.plain).foregroundStyle(Theme.secondary).help("Delete this recording")
        }
        .padding(.horizontal, 18)
        .padding(.top, 40)
        .padding(.bottom, 12)
    }

    private var commands: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Commands").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.tertiary)
                .padding(.horizontal, 14).padding(.vertical, 10)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if info.commands.isEmpty {
                        Text("No commands were marked.").font(.system(size: 12)).foregroundStyle(Theme.tertiary).padding(14)
                    }
                    ForEach(Array(info.commands.enumerated()), id: \.offset) { _, marker in
                        CommandRow(marker: marker, isPast: (player?.position ?? 0) >= marker.time,
                                   matches: !highlight.isEmpty && marker.text.lowercased().contains(highlight.lowercased())) {
                            player?.seek(to: marker.time)
                        }
                    }
                }
                .padding(.horizontal, 6)
            }
            .scrollIndicators(.never)
        }
        .background(Theme.window)
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct CommandRow: View {
    var marker: Recordings.Marker
    var isPast: Bool
    var matches: Bool
    var jump: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: jump) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(PlayerView.clock(marker.time)).font(.system(size: 10.5)).monospacedDigit().foregroundStyle(Theme.tertiary)
                    .frame(width: 40, alignment: .trailing)
                Text(marker.text).font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(matches ? Theme.brass : isPast ? Theme.ink : Theme.secondary).lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Theme.card : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Jump to \(PlayerView.clock(marker.time))")
    }
}

private struct Controls: View {
    var player: ReplayPlayer

    var body: some View {
        HStack(spacing: 14) {
            Button { player.playing ? player.pause() : player.play() } label: {
                Image(systemName: player.playing ? "pause.fill" : "play.fill").font(.system(size: 13)).foregroundStyle(Theme.ink)
                    .frame(width: 30, height: 30).background(Circle().fill(Theme.card))
            }
            .buttonStyle(.plain)
            Text("\(PlayerView.clock(player.position)) / \(PlayerView.clock(player.duration))")
                .font(.system(size: 11.5)).monospacedDigit().foregroundStyle(Theme.secondary)
            Slider(value: Binding(get: { player.position }, set: { player.seek(to: $0) }), in: 0...max(player.duration, 0.1))
                .controlSize(.small)
            MenuButton(minWidth: 120, alignRight: true) {
                [1.0, 2.0, 4.0, 8.0].map { speed in
                    .item("\(Int(speed))× speed", isOn: player.speed == speed, id: "speed:\(speed)") { player.speed = speed }
                }
            } label: {
                HStack(spacing: 4) {
                    Text("\(Int(player.speed))×").font(.system(size: 12, weight: .medium)).monospacedDigit()
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(Theme.secondary)
                .padding(.horizontal, 9).frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.card))
                .contentShape(Rectangle())
            }
            .fixedSize()
            .help("Playback speed")
            Toggle("Skip pauses", isOn: Binding(get: { player.skipsPauses }, set: { player.skipsPauses = $0 }))
                .toggleStyle(.checkbox).font(.system(size: 12)).foregroundStyle(Theme.secondary)
        }
        .padding(.horizontal, 18)
        .frame(height: 50)
    }
}

/// Plays a tape into a terminal of its own: feeds what was printed, at the speed it was printed.
/// Going back starts again from the top and catches up, which is quick even for long recordings.
@MainActor @Observable
final class ReplayPlayer {
    let tape: Recordings.Tape
    @ObservationIgnored let terminal: TerminalView
    private(set) var position: TimeInterval = 0
    private(set) var playing = false
    var speed = 1.0
    /// Waits longer than a second are cut to one.
    var skipsPauses = true
    private(set) var cols: Int
    private(set) var rows: Int
    @ObservationIgnored private var next = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Asks the view to fit the terminal again after a size change.
    @ObservationIgnored var onResize: (() -> Void)?

    var duration: TimeInterval { tape.duration }

    init(tape: Recordings.Tape) {
        self.tape = tape
        cols = tape.cols
        rows = tape.rows
        terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        TerminalStyle.apply(to: terminal)
        terminal.allowMouseReporting = false
        terminal.resize(cols: cols, rows: rows)
    }

    func seek(to time: TimeInterval) {
        let target = min(max(time, 0), duration)
        if target < position || next == 0 { restart() }
        while next < tape.events.count, tape.events[next].time <= target {
            apply(tape.events[next].event)
            next += 1
        }
        position = target
    }

    func play() {
        if position >= duration { seek(to: 0) }
        playing = true
        task?.cancel()
        task = Task { [weak self] in
            while let self, self.playing, self.next < self.tape.events.count {
                let at = self.tape.events[self.next].time
                var wait = (at - self.position) / self.speed
                if self.skipsPauses { wait = min(wait, 1) }
                if wait > 0.004 { try? await Task.sleep(for: .seconds(wait)) }
                guard !Task.isCancelled, self.playing else { return }
                // Everything due in the next few milliseconds goes in one go.
                self.seek(to: at + 0.01 * self.speed)
            }
            self?.playing = false
        }
    }

    func pause() {
        playing = false
        task?.cancel()
    }

    /// Jumps to the next time `text` was printed after here. False when it wasn't.
    func find(_ text: String) -> Bool {
        let q = text.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return false }
        for index in next..<tape.events.count {
            if case .output(let printed) = tape.events[index].event, printed.localizedCaseInsensitiveContains(q) {
                pause()
                seek(to: tape.events[index].time)
                _ = terminal.findNext(q)
                return true
            }
        }
        return false
    }

    private func restart() {
        terminal.getTerminal().resetToInitialState()
        cols = tape.cols
        rows = tape.rows
        terminal.resize(cols: cols, rows: rows)
        onResize?()
        next = 0
        position = 0
    }

    private func apply(_ event: Recordings.Tape.Event) {
        switch event {
        case .output(let text):
            terminal.feed(text: text)
        case .resize(let c, let r):
            cols = c
            rows = r
            terminal.resize(cols: c, rows: r)
            onResize?()
        }
    }
}

/// The replay terminal, sized to the recording's columns: the font shrinks to fit rather than
/// letting lines wrap differently from how they were printed.
private struct ReplayTerminal: NSViewRepresentable {
    var player: ReplayPlayer

    func makeNSView(context: Context) -> ReplayHost {
        let host = ReplayHost(player: player)
        player.onResize = { [weak host] in host?.needsLayout = true }
        return host
    }

    func updateNSView(_ host: ReplayHost, context: Context) {}
}

final class ReplayHost: NSView {
    private let player: ReplayPlayer

    @MainActor init(player: ReplayPlayer) {
        self.player = player
        super.init(frame: .zero)
        clipsToBounds = true
        player.terminal.autoresizingMask = []
        addSubview(player.terminal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The font is worked out from the room there is, so it's worked out again whenever that changes.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let terminal = player.terminal
        guard bounds.width > 60, bounds.height > 30 else { return }
        let cols = CGFloat(max(player.cols, 1)), rows = CGFloat(max(player.rows, 1))
        // The system monospaced font is about 0.6 em wide and 1.2 em tall per cell.
        let size = min(TerminalStyle.fontSize, (bounds.width - 16) / (cols * 0.61), bounds.height / (rows * 1.22))
        let font = NSFont.monospacedSystemFont(ofSize: max(size.rounded(.down), 5), weight: .regular)
        if terminal.font != font { terminal.font = font }
        if terminal.getTerminal().cols != player.cols || terminal.getTerminal().rows != player.rows {
            terminal.resize(cols: player.cols, rows: player.rows)
        }
        var frame = terminal.getOptimalFrameSize()
        frame.origin = CGPoint(x: max((bounds.width - frame.width) / 2, 0), y: max(bounds.height - frame.height, 0))
        if terminal.frame != frame { terminal.frame = frame }
    }
}

/// Where exports go: a save panel that starts in the folder used last, or Downloads.
@MainActor
enum Exporting {
    private static var folder: URL {
        get {
            UserDefaults.standard.url(forKey: "ExportFolder")
                ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        }
        set { UserDefaults.standard.set(newValue, forKey: "ExportFolder") }
    }

    static func name(for info: Recordings.Info, extension ext: String) -> String {
        let host = (info.host.isEmpty ? info.title : info.host)
            .components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
        let stamp = info.started.formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false).timeSeparator(.omitted))
        return "\(host) \(stamp.replacingOccurrences(of: "T", with: " ")).\(ext)"
    }

    private static func ask(_ name: String, type: UTType, title: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = title
        panel.nameFieldStringValue = name
        panel.directoryURL = folder
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        folder = url.deletingLastPathComponent()
        return url
    }

    static func video(of info: Recordings.Info, skipPauses: Bool) {
        guard let url = ask(name(for: info, extension: "mp4"), type: .mpeg4Movie, title: "Export Video") else { return }
        VideoExports.shared.start(recording: info.url, to: url, skipPauses: skipPauses)
    }

    /// The .cast file, with its secrets hidden when Hide secrets is on.
    static func cast(of info: Recordings.Info) {
        guard let url = ask(name(for: info, extension: "cast"), type: UTType(filenameExtension: "cast") ?? .data, title: "Export Recording") else { return }
        let source = info.url
        Task.detached(priority: .userInitiated) {
            try? FileManager.default.removeItem(at: url)
            guard (try? FileManager.default.copyItem(at: source, to: url)) != nil else { return }
            if Redaction.isOn { Redaction.apply(to: url) }
        }
    }
}

/// A video being made, or just made: how far it is, and where it went.
private struct ExportRow: View {
    var job: VideoExports.Job

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "film").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.name).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                switch job.state {
                case .running(let fraction):
                    ProgressView(value: fraction).progressViewStyle(.linear).controlSize(.mini).tint(Theme.brass)
                case .done:
                    Text("Saved in \(job.url.deletingLastPathComponent().lastPathComponent)").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                case .failed(let reason):
                    Text(reason).font(.system(size: 11)).foregroundStyle(Theme.color(for: .production)).lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            switch job.state {
            case .running:
                small("xmark", help: "Stop exporting") { VideoExports.shared.cancel(job.id) }
            case .done:
                small("magnifyingglass", help: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([job.url]) }
                small("play.fill", help: "Open the video") { NSWorkspace.shared.open(job.url) }
                small("xmark", help: "Hide") { VideoExports.shared.dismiss(job.id) }
            case .failed:
                small("xmark", help: "Hide") { VideoExports.shared.dismiss(job.id) }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.card))
    }

    private func small(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.secondary)
                .frame(width: 20, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
