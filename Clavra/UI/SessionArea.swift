import SwiftTerm
import SwiftUI

/// Open tabs as soft pills, the front session's terminal, and a quiet status line.
struct SessionArea: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            TabStrip(model: model)
            if let session = model.current {
                SessionPane(session: session, model: model)
                    .id(session.id)
            }
        }
        .background(Theme.window)
    }
}

private struct TabStrip: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(model.sessions) { session in
                        Tab(session: session, isFront: session.id == model.selection,
                            select: { model.selection = session.id }, close: { model.close(session.id) })
                    }
                }
            }
            .scrollIndicators(.never)
            Button { model.goHome() } label: {
                Image(systemName: "plus").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New connection (⌘T)")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

private struct Tab: View {
    var session: Session
    var isFront: Bool
    var select: () -> Void
    var close: () -> Void
    @State private var hovering = false

    private var dot: SwiftUI.Color? {
        switch session.state {
        case .connected: session.server.place == .production ? Theme.color(for: .production) : nil
        case .failed, .closed: Theme.tertiary
        default: Theme.brass
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
            Text(session.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1).frame(maxWidth: 180)
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Theme.tertiary)
                    .frame(width: 16, height: 16).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isFront || hovering ? 1 : 0)
        }
        .foregroundStyle(isFront ? Theme.ink : Theme.secondary)
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 28)
        .background(Capsule().fill(isFront ? Theme.card : hovering ? Theme.card.opacity(0.5) : .clear))
        .contentShape(Capsule())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isFront)
    }
}

private struct SessionPane: View {
    var session: Session
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if session.server.place == .production {
                HStack(spacing: 8) {
                    Circle().fill(Theme.color(for: .production)).frame(width: 6, height: 6)
                    Text("Production").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.color(for: .production))
                    Text("Take care: this server is live.").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    Spacer()
                }
                .padding(.horizontal, 18)
                .frame(height: 30)
                .background(Theme.color(for: .production).opacity(0.07))
            }

            HStack(spacing: 0) {
                ZStack {
                    Theme.terminal
                    TerminalPane(session: session)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .opacity(session.state == .connected || session.state == .closed ? 1 : 0.25)
                    overlay
                    if let held = session.held {
                        HeldCommandPrompt(server: session.server, held: held) { session.release(run: $0) }
                    }
                    if model.showingSnippets, session.isLive {
                        SnippetPalette(store: model.snippets) { snippet in
                            model.showingSnippets = false
                            if let snippet { session.type(snippet.command, run: snippet.runs) } else { session.refocus() }
                        }
                    }
                }
                .animation(.easeOut(duration: 0.2), value: session.state)
                .animation(.easeOut(duration: 0.15), value: session.held)

                if let panel = model.sidePanel, session.isLive {
                    Rectangle().fill(Theme.line).frame(width: 1)
                    Group {
                        switch panel {
                        case .files: FilesPanel(session: session)
                        case .ports: PortsPanel(session: session, model: model)
                        }
                    }
                    .frame(width: 320)
                    .background(Theme.window)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.18), value: model.sidePanel)

            StatusLine(session: session, model: model)
        }
    }

    @ViewBuilder private var overlay: some View {
        switch session.state {
        case .connecting:
            Notice {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Connecting to \(session.server.target)…").font(.system(size: 13)).foregroundStyle(Theme.ink)
                }
            }
        case .askingHostKey(let question):
            HostKeyPrompt(server: session.server, question: question) { session.answerHostKey($0) }
        case .failed(let message):
            Notice {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Couldn't connect").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text(message).font(.system(size: 13)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("Try Again") { session.connect() }.buttonStyle(BrassButtonStyle())
                        Button("Edit Host") { model.editing = session.server }.buttonStyle(QuietButtonStyle())
                    }
                    .padding(.top, 2)
                }
                .frame(width: 340, alignment: .leading)
            }
        case .closed:
            VStack {
                Spacer()
                Notice {
                    HStack(spacing: 12) {
                        Text("Session ended").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                        Button("Reconnect") { session.connect() }.buttonStyle(BrassButtonStyle())
                    }
                }
                .padding(.bottom, 18)
            }
        case .connected:
            EmptyView()
        }
    }
}

/// A soft floating card over the terminal.
struct Notice<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line))
            .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }
}

private struct HostKeyPrompt: View {
    var server: Server
    var question: Session.HostKeyQuestion
    var answer: (Bool) -> Void

    var body: some View {
        Notice {
            VStack(alignment: .leading, spacing: 12) {
                if question.isJump {
                    Text("Through \(question.host) first").font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
                }
                if question.changed {
                    Text("This server's key changed").font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.color(for: .production))
                    Text("\(question.host) shows a different key from the one you trusted before. It can happen after a reinstall, but it can also mean someone is in the middle. Only continue if you know why it changed.")
                        .font(.system(size: 13)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("First time connecting to \(question.host)").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text("Check this fingerprint with the server's owner, or with `ssh-keygen -lf` on the server. Clavra remembers it once you trust it.")
                        .font(.system(size: 13)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(question.type).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                    Text(question.fingerprint).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.ink)
                        .textSelection(.enabled)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.field))
                HStack(spacing: 8) {
                    if question.changed {
                        Button("Don't Connect") { answer(false) }.buttonStyle(BrassButtonStyle()).keyboardShortcut(.defaultAction)
                        Button("Trust New Key") { answer(true) }.buttonStyle(QuietButtonStyle(tint: Theme.color(for: .production)))
                    } else {
                        Button("Trust and Connect") { answer(true) }.buttonStyle(BrassButtonStyle()).keyboardShortcut(.defaultAction)
                        Button("Cancel") { answer(false) }.buttonStyle(QuietButtonStyle())
                    }
                }
                .padding(.top, 2)
            }
            .frame(width: 400, alignment: .leading)
        }
    }
}

private struct StatusLine: View {
    var session: Session
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            Text(session.jumpServer.map { "\(session.server.target) via \($0.title)" } ?? session.server.target)
            switch session.state {
            case .connected: Text("connected")
            case .closed: Text("ended")
            case .failed: Text("not connected")
            default: Text("connecting")
            }
            if session.isLive, let stats = session.stats { Vitals(stats: stats) }
            Spacer()
            if session.isLive {
                let open = session.forwards.items.count
                PanelButton(title: open > 0 ? "Ports \(open)" : "Ports", icon: "arrow.left.arrow.right", isOn: model.sidePanel == .ports) {
                    model.sidePanel = model.sidePanel == .ports ? nil : .ports
                }
                .help("Forward ports (⇧⌘P)")
                PanelButton(title: "Files", icon: "folder", isOn: model.sidePanel == .files) {
                    model.sidePanel = model.sidePanel == .files ? nil : .files
                }
                .help("Browse files over SFTP (⇧⌘F)")
                PanelButton(title: "Snippets", icon: "text.insert", isOn: model.showingSnippets) {
                    model.showingSnippets.toggle()
                }
                .help("Type a saved command (⌘;)")
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Theme.tertiary)
        .padding(.leading, 18)
        .padding(.trailing, 10)
        .frame(height: 30)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

/// Load, memory, disk and uptime, quiet unless something is running hot.
private struct Vitals: View {
    var stats: ServerStats

    var body: some View {
        HStack(spacing: 12) {
            if let load = stats.load { reading("load", String(format: "%.2f", load), hot: stats.isLoadHigh) }
            if let memory = stats.memory { reading("mem", "\(memory)%", hot: stats.isMemoryHigh) }
            if let disk = stats.disk { reading("disk", "\(disk)%", hot: stats.isDiskHigh) }
            if let up = stats.uptimeText { Text(up) }
        }
        .padding(.leading, 4)
    }

    private func reading(_ label: String, _ value: String, hot: Bool) -> some View {
        HStack(spacing: 4) {
            Text(label)
            Text(value).monospacedDigit().foregroundStyle(hot ? Theme.color(for: .production) : Theme.secondary)
        }
    }
}

private struct PanelButton: View {
    var title: String
    var icon: String
    var isOn: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10.5, weight: .medium))
                Text(title)
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(isOn ? Theme.ink : Theme.secondary)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(isOn ? Theme.card : hovering ? Theme.card.opacity(0.5) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Return was pressed on a risky command on a guarded host; nothing has gone to the server yet.
private struct HeldCommandPrompt: View {
    var server: Server
    var held: Session.HeldCommand
    var answer: (Bool) -> Void

    var body: some View {
        let coral = Theme.color(for: .production)
        Notice {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Circle().fill(coral).frame(width: 7, height: 7)
                    Text("Run this on \(server.title)?").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                }
                Text(held.command)
                    .font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Theme.ink)
                    .lineLimit(4).textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.field))
                Text("\(held.reason). Nothing has been sent yet.")
                    .font(.system(size: 13)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Don't Run") { answer(false) }.buttonStyle(BrassButtonStyle()).keyboardShortcut(.cancelAction)
                    Button("Run It") { answer(true) }.buttonStyle(QuietButtonStyle(tint: coral))
                }
                .padding(.top, 2)
            }
            .frame(width: 420, alignment: .leading)
        }
    }
}

/// The session's SwiftTerm view, kept alive across tab switches.
struct TerminalPane: NSViewRepresentable {
    var session: Session

    func makeNSView(context: Context) -> TerminalView { session.terminal }

    func updateNSView(_ view: TerminalView, context: Context) {
        guard session.state == .connected else { return }
        DispatchQueue.main.async {
            if view.window?.firstResponder !== view { view.window?.makeFirstResponder(view) }
        }
    }
}
