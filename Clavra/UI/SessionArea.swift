import SwiftTerm
import SwiftUI

/// Open tabs as soft pills, the front tab's panes, and a quiet status line for the focused one.
struct SessionArea: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            TabStrip(model: model)
            if let tab = model.currentTab, let session = model.current {
                TabContent(tab: tab, focused: session, model: model)
                    .id(tab.id)
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
                    ForEach(model.tabs) { tab in
                        TabPill(tab: tab, model: model, isFront: tab.id == model.selection)
                            .contextMenu {
                                if let session = model.session(tab.focused) {
                                    Button("Duplicate Tab") { model.open(session.server, through: session.jumpServer) }
                                    Button("Reconnect") { session.connect() }
                                }
                                Divider()
                                Button("Close Other Tabs") { model.closeOthers(than: tab.id) }
                                Button("Close Tab") { model.closeTab(tab.id) }
                            }
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
            if model.broadcasting {
                Button { model.broadcasting = false } label: {
                    HStack(spacing: 6) {
                        Circle().fill(Theme.brass).frame(width: 6, height: 6)
                        Text("Typing into every pane in this tab").font(.system(size: 11.5, weight: .medium))
                    }
                    .foregroundStyle(Theme.brass)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(Capsule().fill(Theme.brass.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .help("Stop broadcasting (⌥⌘I)")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
        .background(WindowDragArea())
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

private struct TabPill: View {
    var tab: TabGroup
    var model: AppModel
    var isFront: Bool
    @State private var hovering = false

    private var panes: [Session] { tab.paneIDs.compactMap(model.session) }
    private var focused: Session? { model.session(tab.focused) }

    private var dot: SwiftUI.Color? {
        guard let focused else { return nil }
        if !isFront, panes.contains(where: \.wantsAttention) { return Theme.brass }
        switch focused.state {
        case .connected: return panes.contains { $0.server.place == .production } ? Theme.color(for: .production) : nil
        case .failed, .closed: return Theme.tertiary
        default: return Theme.brass
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
            Text(focused?.title ?? "").font(.system(size: 12.5, weight: .medium)).lineLimit(1).frame(maxWidth: 180)
            if panes.count > 1 {
                Text(verbatim: "\(panes.count)").font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(Theme.tertiary)
                    .padding(.horizontal, 5)
                    .background(Capsule().fill(Theme.line))
                    .help("\(panes.count) panes")
            }
            Button { model.closeTab(tab.id) } label: {
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
        .onTapGesture { model.selection = tab.id }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isFront)
    }
}

/// The tab's panes, the side panel for the focused one, and its status line.
private struct TabContent: View {
    var tab: TabGroup
    var focused: Session
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                PaneTree(node: tab.root, tab: tab, model: model)

                if let panel = model.sidePanel, focused.isLive {
                    Rectangle().fill(Theme.line).frame(width: 1)
                    Group {
                        switch panel {
                        case .files: FilesPanel(session: focused) { path in
                            focused.logs.follow(.file(path))
                            model.sidePanel = .logs
                        }
                        case .ports: PortsPanel(session: focused, model: model)
                        case .runbook: RunbookPanel(session: focused, model: model)
                        case .logs: LogsPanel(session: focused)
                        }
                    }
                    .id(focused.id)
                    .frame(width: panel == .logs ? 460 : 320)
                    .background(Theme.window)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.18), value: model.sidePanel)

            StatusLine(session: focused, model: model)
        }
    }
}

/// Splits nest, so the tree draws itself; dividers can be dragged.
private struct PaneTree: View {
    var node: PaneNode
    var tab: TabGroup
    var model: AppModel

    var body: some View {
        switch node {
        case .leaf(let id):
            if let session = model.session(id) {
                PaneLeaf(session: session, isFocused: tab.focused == id, isSplit: tab.isSplit, model: model)
                    .id(id)
            }
        case .split(let axis, let children):
            SplitStack(axis: axis, children: children, tab: tab, model: model)
        }
    }
}

/// Panes side by side or stacked, sharing the space evenly until a divider is dragged.
/// Double-clicking a divider evens them out again. (AppKit's split views size panes by what's in
/// them, so new panes came out lopsided.)
private struct SplitStack: View {
    var axis: PaneNode.Axis
    var children: [PaneNode]
    var tab: TabGroup
    var model: AppModel
    /// Each pane's share; empty or the wrong length means even.
    @State private var shares: [CGFloat] = []
    @State private var dragStart: [CGFloat]?

    private var minimum: CGFloat { axis == .sideBySide ? 160 : 90 }

    private var current: [CGFloat] {
        shares.count == children.count ? shares : Array(repeating: 1 / CGFloat(children.count), count: children.count)
    }

    var body: some View {
        GeometryReader { geometry in
            let total = axis == .sideBySide ? geometry.size.width : geometry.size.height
            let room = max(total - CGFloat(children.count - 1), 1)
            let parts = current
            let layout = axis == .sideBySide ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                ForEach(Array(children.enumerated()), id: \.element.ids) { index, child in
                    let length = (room * parts[index]).rounded()
                    AnyView(PaneTree(node: child, tab: tab, model: model))
                        .frame(width: axis == .sideBySide ? length : nil, height: axis == .stacked ? length : nil)
                    if index < children.count - 1 {
                        SplitDivider(axis: axis)
                            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                .onChanged { drag in resize(index, by: axis == .sideBySide ? drag.translation.width : drag.translation.height, room: room) }
                                .onEnded { _ in dragStart = nil })
                            .onTapGesture(count: 2) { shares = [] }
                    }
                }
            }
        }
        .onChange(of: children.count) { shares = [] }
    }

    /// Moves the divider after pane `index`: that pane and the next trade space, neither going
    /// below the smallest a pane can usefully be.
    private func resize(_ index: Int, by offset: CGFloat, room: CGFloat) {
        let start = dragStart ?? current
        if dragStart == nil { dragStart = start }
        let pair = start[index] + start[index + 1]
        let least = min(minimum / room, pair / 2)
        var first = start[index] + offset / room
        first = min(max(first, least), pair - least)
        var next = start
        next[index] = first
        next[index + 1] = pair - first
        shares = next
    }
}

/// A hairline between panes with a wider grip around it.
private struct SplitDivider: View {
    var axis: PaneNode.Axis
    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(hovering ? Theme.brass.opacity(0.6) : Color.black)
            .frame(width: axis == .sideBySide ? 1 : nil, height: axis == .stacked ? 1 : nil)
            .overlay {
                Color.clear
                    .frame(width: axis == .sideBySide ? 9 : nil, height: axis == .stacked ? 9 : nil)
                    .contentShape(Rectangle())
                    .onHover { hovering = $0 }
                    .pointerStyle(axis == .sideBySide ? .columnResize : .rowResize)
            }
            .zIndex(1)
            .help("Drag to resize; double-click to even them out")
    }
}

/// One terminal, with whatever it's asking or showing on top. In a split, the panes without the
/// keyboard step back a little.
private struct PaneLeaf: View {
    var session: Session
    var isFocused: Bool
    var isSplit: Bool
    @Bindable var model: AppModel
    /// Where a pane dragged over this one would land.
    @State private var dropEdge: PaneNode.Edge?
    @State private var size: CGSize = .zero

    var body: some View {
        VStack(spacing: 0) {
            if session.server.place == .production {
                HStack(spacing: 8) {
                    Circle().fill(Theme.color(for: .production)).frame(width: 6, height: 6)
                    Text("Production").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.color(for: .production))
                    if !isSplit {
                        Text("Take care: this server is live.").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    } else {
                        Text(session.server.title).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
                    }
                    Spacer()
                }
                .padding(.horizontal, isSplit ? 12 : 18)
                .frame(height: isSplit ? 24 : 30)
                .background(Theme.color(for: .production).opacity(0.07))
            }

            ZStack {
                Theme.terminal
                TerminalPane(session: session, isFocused: isFocused)
                    .padding(.horizontal, isSplit ? 10 : 14)
                    .padding(.vertical, isSplit ? 8 : 10)
                    .opacity(session.dimsTerminal ? 0.25 : 1)
                if isSplit && !isFocused {
                    Theme.terminal.opacity(0.45).allowsHitTesting(false)
                }
                if let edge = dropEdge {
                    DropHighlight(edge: edge)
                }
                if isSplit {
                    PaneCloseButton(id: session.id, title: session.title, focused: isFocused) { model.close(session.id) }
                }
                overlay
                if let held = session.held {
                    HeldCommandPrompt(server: session.server, held: held, impact: session.impact,
                                      phone: session.needsPhoneApproval ? model.remote.devices.contains(where: \.allowed) : nil,
                                      canBackUp: session.backupPlan != nil, backingUp: session.backingUpFor == held.command,
                                      backUp: { Task { await session.backUpThenRun() } },
                                      openPhoneAccess: { model.show(.remote) }) { session.release(run: $0) }
                }
                if let notice = session.notice {
                    VStack {
                        Spacer()
                        Text(notice).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.ink)
                            .padding(.horizontal, 14).frame(height: 32)
                            .background(Capsule().fill(Theme.card))
                            .overlay(Capsule().strokeBorder(Theme.line))
                            .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
                            .padding(.bottom, 16)
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
                if isFocused, let prompt = session.sudoPrompt {
                    SudoCard(session: session, prompt: prompt)
                }
                if isFocused, model.showingFind {
                    FindBar(session: session, text: $model.lastFind) { model.showingFind = false; session.refocus() }
                }
                if isFocused, model.showingSnippets, session.isLive {
                    SnippetPalette(store: model.snippets) { snippet in
                        model.showingSnippets = false
                        if let snippet { session.type(snippet.command, run: snippet.runs) } else { session.refocus() }
                    }
                }
            }
            .background(GeometryReader { proxy in Color.clear.onAppear { size = proxy.size }.onChange(of: proxy.size) { size = proxy.size } })
            .onDrop(of: [.utf8PlainText], delegate: PaneDrop(target: session.id, size: size, edge: $dropEdge) { id, edge in
                model.movePane(id, to: session.id, edge: edge)
            })
            .animation(.easeOut(duration: 0.12), value: dropEdge)
            .animation(.easeOut(duration: 0.2), value: session.state)
            .animation(.easeOut(duration: 0.15), value: session.held)
            .animation(.easeOut(duration: 0.15), value: session.impact)
            .animation(.easeOut(duration: 0.15), value: session.sudoPrompt)
            .animation(.easeOut(duration: 0.2), value: session.notice)
            .animation(.easeOut(duration: 0.15), value: isFocused)
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
        case .reconnecting(let attempt):
            VStack {
                Spacer()
                Notice {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Connection lost. Trying again (\(attempt) of 4)…").font(.system(size: 13)).foregroundStyle(Theme.ink)
                        Button("Stop") { session.close() }.buttonStyle(QuietButtonStyle())
                    }
                }
                .padding(.bottom, 18)
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

/// A split pane's corner: a grip to drag it onto another pane's edge (as in iTerm), and an × that
/// closes it (⌘W does the same for the focused one).
private struct PaneCloseButton: View {
    var id: Session.ID
    var title: String
    var focused: Bool
    var close: () -> Void
    @State private var hovering = false
    @State private var gripHover = false

    var body: some View {
        VStack {
            HStack(spacing: 4) {
                Spacer()
                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(gripHover ? Theme.ink : Theme.tertiary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(gripHover ? Theme.cardHover : Theme.card.opacity(0.85)))
                    .overlay(Circle().strokeBorder(Theme.line))
                    .contentShape(Circle())
                    .onHover { gripHover = $0 }
                    .pointerStyle(.grabIdle)
                    .onDrag {
                        NSItemProvider(object: "clavra-pane:\(id.uuidString)" as NSString)
                    } preview: {
                        Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.ink)
                            .padding(.horizontal, 12).frame(height: 28)
                            .background(Capsule().fill(Theme.card))
                    }
                    .opacity(focused || gripHover ? 1 : 0.55)
                    .help("Drag onto another pane to move it there")
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(hovering ? Theme.ink : Theme.tertiary)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(hovering ? Theme.cardHover : Theme.card.opacity(0.85)))
                        .overlay(Circle().strokeBorder(Theme.line))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .opacity(focused || hovering ? 1 : 0.55)
                .help("Close this pane (⌘W)")
            }
            Spacer()
        }
        .padding(.top, 6)
        .padding(.trailing, 22)
    }
}

/// Half of a pane lit up: where a dragged pane will go.
private struct DropHighlight: View {
    var edge: PaneNode.Edge

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width, h = proxy.size.height
            let rect: CGRect = switch edge {
            case .left: CGRect(x: 0, y: 0, width: w / 2, height: h)
            case .right: CGRect(x: w / 2, y: 0, width: w / 2, height: h)
            case .top: CGRect(x: 0, y: 0, width: w, height: h / 2)
            case .bottom: CGRect(x: 0, y: h / 2, width: w, height: h / 2)
            }
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Theme.brass.opacity(0.16))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.brass.opacity(0.7), lineWidth: 1.5))
                .frame(width: rect.width - 8, height: rect.height - 8)
                .position(x: rect.midX, y: rect.midY)
        }
        .allowsHitTesting(false)
    }
}

/// Takes a pane dropped on this one: the nearest edge to the pointer says which side it goes on.
private struct PaneDrop: DropDelegate {
    var target: Session.ID
    var size: CGSize
    @Binding var edge: PaneNode.Edge?
    var move: @MainActor @Sendable (Session.ID, PaneNode.Edge) -> Void

    private func nearest(_ point: CGPoint) -> PaneNode.Edge {
        guard size.width > 0, size.height > 0 else { return .right }
        let x = point.x / size.width, y = point.y / size.height
        let distances: [(PaneNode.Edge, CGFloat)] = [(.left, x), (.right, 1 - x), (.top, y), (.bottom, 1 - y)]
        return distances.min { $0.1 < $1.1 }!.0
    }

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.utf8PlainText]) }
    func dropEntered(info: DropInfo) { edge = nearest(info.location) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        edge = nearest(info.location)
        return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) { edge = nil }

    func performDrop(info: DropInfo) -> Bool {
        let side = nearest(info.location)
        edge = nil
        guard let provider = info.itemProviders(for: [.utf8PlainText]).first else { return false }
        let target = target, move = move
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? String, text.hasPrefix("clavra-pane:"),
                  let id = UUID(uuidString: String(text.dropFirst("clavra-pane:".count))), id != target else { return }
            Task { @MainActor in move(id, side) }
        }
        return true
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
            case .reconnecting: Text("reconnecting")
            default: Text("connecting")
            }
            if session.isLive, let stats = session.stats { Vitals(stats: stats) }
            if let kept = session.keptAlive {
                HStack(spacing: 5) {
                    Image(systemName: kept ? "infinity" : "exclamationmark.triangle").font(.system(size: 10, weight: .semibold))
                    Text(kept ? "kept alive" : "no tmux")
                }
                .foregroundStyle(kept ? Theme.tertiary : Theme.brass)
                .help(kept ? "Runs in tmux session \(session.tmuxName) on the server: a dropped connection or quitting Clavra doesn't end it. Closing the tab does."
                           : "Keep sessions alive is on, but this server has no tmux, so this is a plain shell. Install tmux to keep it alive.")
            }
            if !session.backups.isEmpty {
                BackupsMenu(session: session)
            }
            if session.isRecording {
                HStack(spacing: 5) {
                    Circle().fill(Theme.color(for: .production)).frame(width: 6, height: 6)
                    Text("rec")
                }
                .help("This tab is being recorded (Recordings, ⌥⌘4)")
            }
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
                PanelButton(title: "Logs", icon: "text.alignleft", isOn: model.sidePanel == .logs) {
                    model.sidePanel = model.sidePanel == .logs ? nil : .logs
                }
                .help("Follow a log beside the terminal (⇧⌘L)")
                PanelButton(title: "Runbook", icon: "checklist", isOn: model.sidePanel == .runbook) {
                    model.sidePanel = model.sidePanel == .runbook ? nil : .runbook
                }
                .help("This host's runbook (⇧⌘B)")
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

/// Archives made before risky commands in this tab: put one back, or delete it.
private struct BackupsMenu: View {
    var session: Session
    @State private var restoring: Session.Backup?

    var body: some View {
        Menu {
            ForEach(session.backups) { backup in
                Section("\(backup.command) · \(backup.made.formatted(date: .omitted, time: .shortened))") {
                    Button("Restore…") { restoring = backup }
                    Button("Delete Backup", role: .destructive) { session.forget(backup) }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.uturn.backward").font(.system(size: 10, weight: .semibold))
                Text("Backups \(session.backups.count)")
            }
            .foregroundStyle(Theme.brass)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Put back what a command removed or changed")
        .confirmationDialog(restoring.map { "Restore what ‘\($0.command)’ touched?" } ?? "",
                            isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } }), presenting: restoring) { backup in
            Button("Restore") { Task { await session.restore(backup) } }
        } message: { backup in
            Text("The files go back where they were, as they were at \(backup.made.formatted(date: .omitted, time: .shortened)), replacing what's there now. The backup is in \(backup.file).")
        }
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

/// ⌘F over the terminal: Return finds the next match, ⇧Return the one before.
private struct FindBar: View {
    var session: Session
    @Binding var text: String
    var close: () -> Void
    @State private var missing = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack {
            HStack {
                Spacer()
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.tertiary)
                    TextField("Find in scrollback", text: $text)
                        .textFieldStyle(.plain).font(.system(size: 13)).frame(width: 200)
                        .focused($focused)
                        .onSubmit { search(backwards: NSEvent.modifierFlags.contains(.shift)) }
                        .onKeyPress(.escape) { close(); return .handled }
                    if missing { Text("No match").font(.system(size: 11.5)).foregroundStyle(Theme.tertiary) }
                    button("chevron.up") { search(backwards: true) }
                    button("chevron.down") { search(backwards: false) }
                    button("xmark", action: close)
                }
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line))
                .shadow(color: .black.opacity(0.2), radius: 14, y: 6)
            }
            .padding(.horizontal, 22)
            .padding(.top, 14)
            Spacer()
        }
        .onAppear { focused = true }
        .onChange(of: text) { missing = false }
    }

    private func search(backwards: Bool) {
        missing = !session.find(text, backwards: backwards)
    }

    private func button(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.secondary)
                .frame(width: 20, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Return was pressed on a risky command on a guarded host; nothing has gone to the server yet.
/// Below the command: what it would touch, read on the server with a look-alike that only reads.
private struct HeldCommandPrompt: View {
    var server: Server
    var held: Session.HeldCommand
    var impact: Session.Impact?
    /// Nil when the Mac can answer. Otherwise only a phone can say run: true once one is connected.
    var phone: Bool?
    /// The files it touches can be archived first.
    var canBackUp = false
    var backingUp = false
    var backUp: () -> Void = {}
    var openPhoneAccess: () -> Void
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
                if let impact { ImpactBox(impact: impact) }
                if let phone {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "iphone").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.brass).padding(.top, 1)
                        Text(phone ? "This host needs a yes from your phone. Open the Clavra page there to approve it."
                                   : "This host needs a yes from your phone, and no phone is connected. Turn on Phone Access and connect one.")
                            .font(.system(size: 12.5)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 8) {
                    Button("Don't Run") { answer(false) }.buttonStyle(BrassButtonStyle()).keyboardShortcut(.cancelAction)
                    if backingUp {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("Backing up, then it runs…").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                        }
                        .padding(.leading, 4)
                    } else if phone == nil {
                        if canBackUp {
                            Button("Back Up, Then Run", action: backUp).buttonStyle(QuietButtonStyle())
                                .help("Archives what it touches into ~/.clavra-backups on the server first, so Backups can put it back")
                        }
                        Button("Run It") { answer(true) }.buttonStyle(QuietButtonStyle(tint: coral))
                    } else if phone == false {
                        Button("Phone Access…", action: openPhoneAccess).buttonStyle(QuietButtonStyle())
                    } else {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("Waiting for your phone").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                        }
                        .padding(.leading, 4)
                    }
                }
                .padding(.top, 2)
            }
            .frame(width: 440, alignment: .leading)
        }
    }
}

/// sudo wants a password: fill it from the Keychain after Touch ID, or type it once here and keep it.
private struct SudoCard: View {
    var session: Session
    var prompt: Session.SudoPrompt
    @State private var password = ""
    @State private var remember = true
    @State private var typing = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack {
            Spacer()
            Notice {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "touchid").font(.system(size: 15)).foregroundStyle(Theme.brass)
                        Text(prompt.retry ? "That sudo password didn't work" : "sudo is asking for your password")
                            .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.ink)
                    }
                    if typing || prompt.retry || (!prompt.hasSaved && !prompt.hasSignIn) {
                        HStack(spacing: 8) {
                            SecureField("Password for sudo on \(session.server.title)", text: $password)
                                .textFieldStyle(.plain).font(.system(size: 13))
                                .padding(.horizontal, 10).frame(height: 30)
                                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.field))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.line))
                                .focused($focused)
                                .onSubmit(fillTyped)
                            Button("Fill", action: fillTyped).buttonStyle(BrassButtonStyle()).disabled(password.isEmpty)
                        }
                        Toggle("Keep it in the Keychain; next time Touch ID fills it in", isOn: $remember)
                            .toggleStyle(.checkbox).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    }
                    HStack(spacing: 8) {
                        if prompt.hasSaved, !prompt.retry, !typing {
                            Button("Fill with Touch ID") { Task { await session.fillSudo(from: .saved) } }
                                .buttonStyle(BrassButtonStyle()).keyboardShortcut(.defaultAction)
                        } else if prompt.hasSignIn, !typing, !prompt.retry {
                            Button("Use Sign-in Password") { Task { await session.fillSudo(from: .signIn) } }
                                .buttonStyle(BrassButtonStyle()).keyboardShortcut(.defaultAction)
                            Button("Another…") { typing = true; focused = true }.buttonStyle(QuietButtonStyle())
                        }
                        Button("Type It Myself") { session.dismissSudo() }.buttonStyle(QuietButtonStyle())
                    }
                }
                .frame(width: 380, alignment: .leading)
            }
            .padding(.bottom, 18)
        }
        .onAppear { if !prompt.hasSaved && !prompt.hasSignIn { focused = true } }
    }

    private func fillTyped() {
        guard !password.isEmpty else { return }
        let typed = password
        password = ""
        Task { await session.fillSudo(from: .typed(typed, remember: remember)) }
    }
}

/// What the held command would touch: a line that says it, then a few names.
private struct ImpactBox: View {
    var impact: Session.Impact

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("On the server right now").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            switch impact {
            case .checking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text("Looking at what it would touch…").font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
                }
            case .found(let lines):
                if let first = lines.first {
                    Text(first).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(lines.dropFirst().enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            case .unknown(let text):
                Text(text).font(.system(size: 12.5)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.color(for: .production).opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.color(for: .production).opacity(0.18)))
    }
}

/// The session's SwiftTerm view, kept alive across tab switches.
struct TerminalPane: NSViewRepresentable {
    var session: Session
    var isFocused = true

    func makeNSView(context: Context) -> TerminalHost { TerminalHost(session.terminal) }

    func updateNSView(_ host: TerminalHost, context: Context) {
        host.adopt(session.terminal)
        guard session.state == .connected, isFocused else { return }
        let view = session.terminal
        DispatchQueue.main.async {
            // Leave the find bar or the snippet field alone while someone is typing in it.
            if let editor = view.window?.firstResponder as? NSTextView, editor.isFieldEditor { return }
            if view.window?.firstResponder !== view { view.window?.makeFirstResponder(view) }
        }
    }
}

/// Holds a session's terminal, which outlives any one place it's shown in. When a pane is laid out
/// again (a split, coming back from Home) SwiftUI briefly gives it next to no room; passed on, that
/// would shrink the terminal to a column or two and cut every line on screen to fit. Sizes that
/// small are ignored, so the terminal only ever takes a size it can really be shown at.
final class TerminalHost: NSView {
    private static let smallest = NSSize(width: 60, height: 30)

    init(_ terminal: TerminalView) {
        super.init(frame: .zero)
        clipsToBounds = true
        adopt(terminal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func adopt(_ terminal: TerminalView) {
        guard terminal.superview !== self else { return }
        subviews.forEach { $0.removeFromSuperview() }
        terminal.translatesAutoresizingMaskIntoConstraints = true
        terminal.autoresizingMask = []
        addSubview(terminal)
        fit()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        fit()
    }

    override func layout() {
        super.layout()
        fit()
    }

    private func fit() {
        guard let terminal = subviews.first,
              bounds.width >= Self.smallest.width, bounds.height >= Self.smallest.height,
              terminal.frame != bounds else { return }
        terminal.frame = bounds
    }
}
