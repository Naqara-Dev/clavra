import SwiftUI

@main
struct ClavraApp: App {
    @State private var model = AppModel()
    @AppStorage("MenuBarExtra") private var menuBar = true

    init() {
        Updates.shared.start()
    }

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
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Updates.shared.checkNow() }
            }
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
                Toggle("Type into Every Pane in This Tab", isOn: $model.broadcasting)
                    .keyboardShortcut("i", modifiers: [.command, .option])
                Divider()
                Button("Next Tab") { model.cycle(1) }.keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Previous Tab") { model.cycle(-1) }.keyboardShortcut("[", modifiers: [.command, .shift])
            }
            CommandGroup(after: .sidebar) {
                Button("Keys") { model.show(.keys) }.keyboardShortcut("1", modifiers: [.command, .option])
                Button("Snippets") { model.show(.snippets) }.keyboardShortcut("2", modifiers: [.command, .option])
                Button("Remote Access") { model.show(.remote) }.keyboardShortcut("3", modifiers: [.command, .option])
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
                    case .remote: RemoteView(model: model)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.window)
        .ignoresSafeArea()
        .overlay {
            if let device = model.remote.waiting {
                ZStack {
                    Color.black.opacity(0.25).ignoresSafeArea()
                    RemoteRequest(device: device, remote: model.remote)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.remote.waiting)
        .sheet(item: $model.editing) { server in
            HostEditor(server: server, isNew: !model.isSaved(server), others: model.store.hosts, model: model,
                       save: { saved, connect in
                           model.save(saved)
                           if connect { model.open(saved) }
                       },
                       delete: model.isSaved(server) ? { model.store.delete(server) } : nil)
        }
        .onAppear {
            debugLaunch()
            if model.sessions.isEmpty { model.restoreTabs() }
            if UserDefaults.standard.bool(forKey: "ClavraRemote") { model.remote.start() }
        }
    }

    /// `-ClavraOpen user@host:port [-ClavraKey path] [-ClavraPlace production] [-ClavraAutoTrust YES]`
    /// opens a session on launch; `-ClavraNewHost YES` opens the host editor; `-ClavraPage keys`
    /// shows a page; `-ClavraPanel files|ports` and `-ClavraSnippets YES` open those beside the tab.
    private func debugLaunch() {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "ClavraNewHost") { model.newHost() }
        // `-ClavraSettings about` opens Settings on that tab.
        if let tab = UserDefaults.standard.string(forKey: "ClavraSettings") {
            UserDefaults.standard.set(tab, forKey: "SettingsTab")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
        }
        // `-ClavraWindow 1440x880` sizes the window, for screenshots.
        if let size = UserDefaults.standard.string(forKey: "ClavraWindow")?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
            DispatchQueue.main.async {
                guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { return }
                window.setFrame(NSRect(x: 36, y: 36, width: size[0], height: size[1]), display: true)
            }
        }
        // `-ClavraOpenSaved api-prod,web-staging` opens saved hosts by name, a tab each.
        for name in (UserDefaults.standard.string(forKey: "ClavraOpenSaved") ?? "").split(separator: ",") {
            if let server = model.store.hosts.first(where: { $0.title == name }) { model.open(server) }
        }
        if let page = UserDefaults.standard.string(forKey: "ClavraPage") {
            // After restored tabs, which would otherwise come to the front.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                model.show(["keys": .keys, "snippets": .snippets, "remote": .remote][page] ?? .home)
            }
        }
        if let target = UserDefaults.standard.string(forKey: "ClavraOpen"), let server = Server(quick: target) { debugOpen(server) }
        if let panel = UserDefaults.standard.string(forKey: "ClavraPanel") {
            model.sidePanel = panel == "files" ? .files : panel == "ports" ? .ports : nil
        }
        if UserDefaults.standard.bool(forKey: "ClavraSnippets") { model.showingSnippets = true }
        // `-ClavraFilesTest dir` drives the file browser for scripts/e2e.sh: downloads everything
        // named e2e-dl-*, uploads `-ClavraFilesUpload path`, and edits e2e-edit.txt.
        if let dir = UserDefaults.standard.string(forKey: "ClavraFilesTest") {
            Task {
                try? await Task.sleep(for: .seconds(4))
                guard let files = model.current?.files else { return }
                await files.go(to: dir)
                for entry in files.entries where entry.name.hasPrefix("e2e-dl-") { files.download(entry) }
                if let path = UserDefaults.standard.string(forKey: "ClavraFilesUpload") { files.upload([URL(fileURLWithPath: path)]) }
                if let note = files.entries.first(where: { $0.name == "e2e-edit.txt" }) { files.edit(note) }
            }
        }
        // `-ClavraSplit beside,below` splits the front tab, one step per word.
        for step in (UserDefaults.standard.string(forKey: "ClavraSplit") ?? "").split(separator: ",") {
            model.split(step == "below" ? .stacked : .sideBySide)
        }
        #endif
    }

    #if DEBUG
    private func debugOpen(_ quick: Server) {
        var server = quick
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
    }
    #endif
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
