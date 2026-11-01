import SwiftUI

@main
struct ClavraApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .frame(minWidth: 860, minHeight: 540)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Host…") { model.newHost() }.keyboardShortcut("n")
                Button("Connect…") { model.goHome() }.keyboardShortcut("k")
                Button("New Tab") { model.goHome() }.keyboardShortcut("t")
                Divider()
                Button("Close Tab") {
                    if let id = model.selection { model.close(id) } else { NSApp.keyWindow?.performClose(nil) }
                }
                .keyboardShortcut("w")
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
        .onAppear(perform: debugLaunch)
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
        // `-ClavraForward 18080:8080` adds a tunnel; `-ClavraJump user@host:port` hops through another host.
        if let spec = UserDefaults.standard.string(forKey: "ClavraForward") {
            let parts = spec.split(separator: ":").compactMap { Int($0) }
            if parts.count == 2 { server.forwards = [Server.Forward(localPort: parts[0], port: parts[1])] }
        }
        var jump = UserDefaults.standard.string(forKey: "ClavraJump").flatMap(Server.init(quick:))
        jump?.keyPath = server.keyPath
        model.open(server, through: jump)
        if let panel = UserDefaults.standard.string(forKey: "ClavraPanel") {
            model.sidePanel = panel == "files" ? .files : panel == "ports" ? .ports : nil
        }
        if UserDefaults.standard.bool(forKey: "ClavraSnippets") { model.showingSnippets = true }
        #endif
    }
}
