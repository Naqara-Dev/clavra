import SwiftUI

@main
struct ClavraApp: App {
    @State private var model = AppModel()
    @AppStorage("MenuBarExtra") private var menuBar = true

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView(model: model)
                .frame(minWidth: 860, minHeight: 540)
                .onOpenURL { url in model.openURL(url) }
                // An ssh:// link opens a tab in the window that's already there, not a new window.
                .handlesExternalEvents(preferring: ["ssh"], allowing: ["*"])
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Host…") { model.newHost() }.keyboardShortcut("n")
                Button("Connect…") { model.goHome() }.keyboardShortcut("k")
                Button("New Tab") { model.goHome() }.keyboardShortcut("t")
                Divider()
                Button(model.currentTab?.isSplit == true ? "Close Pane" : "Close Tab") { model.closeFront() }
                    .keyboardShortcut("w")
            }
            CommandGroup(after: .textEditing) {
                Button("Find…") { model.showingFind = true }.keyboardShortcut("f").disabled(model.current == nil)
                Button("Find Next") { _ = model.current?.terminal.findNext(model.lastFind) }.keyboardShortcut("g").disabled(model.current == nil)
                Button("Clear Scrollback") { model.current?.clearScrollback() }
                    .keyboardShortcut("k", modifiers: [.command, .option]).disabled(model.current == nil)
            }
            CommandGroup(after: .toolbar) {
                Button("Make Text Bigger") { model.setFontSize(model.fontSize + 1) }.keyboardShortcut("=")
                Button("Make Text Smaller") { model.setFontSize(model.fontSize - 1) }.keyboardShortcut("-")
                Button("Actual Size") { model.setFontSize(TerminalStyle.defaultFontSize) }.keyboardShortcut("0")
                Divider()
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save Output…") { model.saveOutput() }.keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(model.current == nil)
            }
            CommandMenu("Session") {
                Button("Snippets…") { model.showingSnippets.toggle() }
                    .keyboardShortcut(";").disabled(model.current?.isLive != true)
                Button("Files") { model.sidePanel = model.sidePanel == .files ? nil : .files }
                    .keyboardShortcut("f", modifiers: [.command, .shift]).disabled(model.current?.isLive != true)
                Button("Ports") { model.sidePanel = model.sidePanel == .ports ? nil : .ports }
                    .keyboardShortcut("p", modifiers: [.command, .shift]).disabled(model.current?.isLive != true)
                Divider()
                Button("Reconnect") { model.current?.connect() }
                    .keyboardShortcut("r", modifiers: [.command, .shift]).disabled(model.current == nil || model.current?.isLive == true)
                Button("Duplicate Tab") { if let s = model.current { model.open(s.server, through: s.jumpServer) } }
                    .keyboardShortcut("t", modifiers: [.command, .option]).disabled(model.current == nil)
                Divider()
                Button("Split Beside") { model.split(.sideBySide) }
                    .keyboardShortcut("d").disabled(model.current == nil)
                Button("Split Below") { model.split(.stacked) }
                    .keyboardShortcut("d", modifiers: [.command, .shift]).disabled(model.current == nil)
                Button("Next Pane") { model.focusPane(1) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option]).disabled(model.currentTab?.isSplit != true)
                Button("Previous Pane") { model.focusPane(-1) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option]).disabled(model.currentTab?.isSplit != true)
                Button("Pane Below") { model.focusPane(1) }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option]).disabled(model.currentTab?.isSplit != true)
                Button("Pane Above") { model.focusPane(-1) }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option]).disabled(model.currentTab?.isSplit != true)
                Divider()
                Toggle("Type into Every Pane", isOn: $model.broadcasting)
                    .keyboardShortcut("i", modifiers: [.command, .option])
                Divider()
                Button("Next Tab") { model.cycle(1) }.keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Previous Tab") { model.cycle(-1) }.keyboardShortcut("[", modifiers: [.command, .shift])
            }
            CommandGroup(after: .sidebar) {
                Button("Keys") { model.show(.keys) }.keyboardShortcut("1", modifiers: [.command, .option])
                Button("Snippets") { model.show(.snippets) }.keyboardShortcut("2", modifiers: [.command, .option])
            }
        }

        Settings {
            SettingsView(model: model)
        }

        MenuBarExtra("Clavra", systemImage: "key", isInserted: $menuBar) {
            MenuBarHosts(model: model)
        }
    }
}

struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(model: model)
            Rectangle().fill(Theme.line).frame(width: 1)
            Group {
                if model.current != nil {
                    SessionArea(model: model)
                } else {
                    switch model.page {
                    case .home: HomeView(model: model)
                    case .keys: KeysView(model: model)
                    case .snippets: SnippetsView(model: model)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.window)
        .ignoresSafeArea()
        .sheet(item: $model.editing) { server in
            HostEditor(server: server, isNew: !model.isSaved(server), others: model.store.hosts,
                       save: { saved, connect in
                           model.save(saved)
                           if connect { model.open(saved) }
                       },
                       delete: model.isSaved(server) ? { model.store.delete(server) } : nil)
        }
        .onAppear {
            debugLaunch()
            if model.sessions.isEmpty { model.restoreTabs() }
        }
    }

    /// `-ClavraOpen user@host:port [-ClavraKey path] [-ClavraPlace production] [-ClavraAutoTrust YES]`
    /// opens a session on launch; `-ClavraNewHost YES` opens the host editor; `-ClavraPage keys`
    /// shows a page; `-ClavraPanel files|ports` and `-ClavraSnippets YES` open those beside the tab.
    private func debugLaunch() {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "ClavraNewHost") { model.newHost() }
        if let page = UserDefaults.standard.string(forKey: "ClavraPage") {
            model.show(page == "keys" ? .keys : page == "snippets" ? .snippets : .home)
        }
        guard let target = UserDefaults.standard.string(forKey: "ClavraOpen"), var server = Server(quick: target) else { return }
        server.keyPath = UserDefaults.standard.string(forKey: "ClavraKey")
        if let place = UserDefaults.standard.string(forKey: "ClavraPlace").flatMap(Server.Place.init(rawValue:)) { server.place = place }
        // `-ClavraForward 18080:8080` (or `socks:1080`, or `remote:9000:3000` for server 9000 → Mac 3000)
        // adds tunnels, comma-separated; `-ClavraJump user@host:port` hops through another host.
        if let spec = UserDefaults.standard.string(forKey: "ClavraForward") {
            server.forwards = spec.split(separator: ",").compactMap { item in
                let parts = item.split(separator: ":")
                let numbers = parts.compactMap { Int($0) }
                switch parts.first {
                case "socks": return numbers.first.map { Server.Forward(kind: .socks, localPort: $0, port: 0) }
                case "remote": return numbers.count == 2 ? Server.Forward(kind: .remote, localPort: numbers[1], port: numbers[0]) : nil
                default: return numbers.count == 2 ? Server.Forward(localPort: numbers[0], port: numbers[1]) : nil
                }
            }
        }
        server.startup = UserDefaults.standard.string(forKey: "ClavraStartup") ?? ""
        var jump = UserDefaults.standard.string(forKey: "ClavraJump").flatMap(Server.init(quick:))
        jump?.keyPath = server.keyPath
        model.open(server, through: jump)
        if let panel = UserDefaults.standard.string(forKey: "ClavraPanel") {
            model.sidePanel = panel == "files" ? .files : panel == "ports" ? .ports : nil
        }
        if UserDefaults.standard.bool(forKey: "ClavraSnippets") { model.showingSnippets = true }
        // `-ClavraSplit beside,below` splits the new tab, one step per word.
        for step in (UserDefaults.standard.string(forKey: "ClavraSplit") ?? "").split(separator: ",") {
            model.split(step == "below" ? .stacked : .sideBySide)
        }
        #endif
    }
}

/// The menu bar's list: every saved host by place, and the way back to the window.
private struct MenuBarHosts: View {
    var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ForEach(model.store.grouped(matching: ""), id: \.0) { place, servers in
            Section(place.label) {
                ForEach(servers) { server in
                    Button(server.title) {
                        model.open(server)
                        bringForward()
                    }
                }
            }
        }
        if model.store.hosts.isEmpty { Text("No saved hosts yet") }
        Divider()
        Button("Open Clavra") { bringForward() }
        Button("Quit Clavra") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private func bringForward() {
        NSApp.activate()
        if NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }) == nil { openWindow(id: "main") }
    }
}
