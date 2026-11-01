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
                if model.current == nil {
                    HomeView(model: model)
                } else {
                    SessionArea(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.window)
        .ignoresSafeArea()
        .sheet(item: $model.editing) { server in
            HostEditor(server: server, isNew: !model.isSaved(server),
                       save: { saved, connect in
                           model.save(saved)
                           if connect { model.open(saved) }
                       },
                       delete: model.isSaved(server) ? { model.store.delete(server) } : nil)
        }
        .onAppear(perform: debugLaunch)
    }

    /// `-ClavraOpen user@host:port [-ClavraKey path] [-ClavraPlace production] [-ClavraAutoTrust YES]`
    /// opens a session on launch; `-ClavraNewHost YES` opens the host editor.
    private func debugLaunch() {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "ClavraNewHost") { model.newHost() }
        guard let target = UserDefaults.standard.string(forKey: "ClavraOpen"), var server = Server(quick: target) else { return }
        server.keyPath = UserDefaults.standard.string(forKey: "ClavraKey")
        if let place = UserDefaults.standard.string(forKey: "ClavraPlace").flatMap(Server.Place.init(rawValue:)) { server.place = place }
        model.open(server)
        #endif
    }
}
