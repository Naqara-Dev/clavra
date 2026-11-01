import SwiftUI

/// Turn phone access on, show the QR code, and see who's connected.
struct RemoteView: View {
    @Bindable var model: AppModel
    @State private var via = RemoteAccess.throughRelay

    private static let relayNote = "The QR code holds a fresh key that never crosses the network. Everything between phone and Mac is encrypted with it, so clavra.naqara.dev only ever passes along data it can't read. Every new phone has to be allowed here, and access turns itself off after 30 minutes without use."
    private static let directNote = "The QR code holds this Mac's address and a fresh key that never crosses the network. Everything between phone and Mac is encrypted with it, every new phone has to be allowed here, and access turns itself off after 30 minutes without use. The page itself loads over plain HTTP, so only use this on networks you trust: home or office, not a café."

    private var remote: RemoteAccess { model.remote }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Phone Access").font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.ink)
                        Text("Use your tabs from a phone. Nothing to install: scan, allow, type.")
                            .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    if remote.isOn {
                        Button("Turn Off") { remote.stop() }.buttonStyle(QuietButtonStyle(tint: Theme.color(for: .production)))
                    } else {
                        Button("Turn On") { remote.start() }.buttonStyle(BrassButtonStyle())
                    }
                }
                .padding(.bottom, 22)

                if let problem = remote.problem {
                    Text(problem).font(.system(size: 13)).foregroundStyle(Theme.color(for: .production)).padding(.bottom, 14)
                }

                if remote.isOn {
                    HStack(alignment: .top, spacing: 22) {
                        VStack(spacing: 10) {
                            if let qr = remote.qr {
                                Image(nsImage: qr)
                                    .interpolation(.none)
                                    .resizable()
                                    .frame(width: 200, height: 200)
                                    .padding(14)
                                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white))
                            } else {
                                ProgressView().frame(width: 228, height: 228)
                            }
                            Text("Scan with the phone's camera").font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
                            if RemoteAccess.throughRelay {
                                HStack(spacing: 6) {
                                    Circle().fill(remote.relayConnected ? Theme.color(for: .personal) : Theme.brass).frame(width: 6, height: 6)
                                    Text(remote.relayConnected ? "Ready on clavra.naqara.dev" : "Reaching clavra.naqara.dev…")
                                        .font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: 16) {
                            card("Connected") {
                                if remote.devices.isEmpty {
                                    Text("No phone yet.").font(.system(size: 12.5)).foregroundStyle(Theme.tertiary)
                                }
                                ForEach(remote.devices) { device in
                                    HStack {
                                        Image(systemName: "iphone").foregroundStyle(Theme.secondary)
                                        Text(device.name).font(.system(size: 13)).foregroundStyle(Theme.ink)
                                        if !device.allowed { Text("waiting").font(.system(size: 11)).foregroundStyle(Theme.brass) }
                                        Spacer()
                                        Button("Remove") { remote.disconnect(device.id) }.buttonStyle(.plain)
                                            .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                                    }
                                }
                            }

                            card("Production tabs") {
                                Toggle("Let phones type in production tabs", isOn: Binding(get: { remote.typingInProduction },
                                                                                       set: { remote.typingInProduction = $0 }))
                                    .toggleStyle(.switch).font(.system(size: 13))
                                Text("Off: phones can watch production tabs but not type. Risky commands still wait for a yes on this Mac either way.")
                                    .font(.system(size: 11.5)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("How it's kept safe").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
                        Text(RemoteAccess.throughRelay ? Self.relayNote : Self.directNote)
                            .font(.system(size: 12)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 24)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        step("1", "Turn it on. A QR code appears.")
                        step("2", "Scan it with the phone's camera; the page opens in the browser.")
                        step("3", "Allow the phone here. Pick a tab on the phone and type.")
                    }
                    card("Connect") {
                        Segments(options: [true, false], selection: Binding(get: { RemoteAccess.throughRelay }, set: { RemoteAccess.throughRelay = $0; via = $0 })) {
                            $0 ? "From anywhere" : "Same Wi-Fi only"
                        }
                        .frame(width: 300)
                        Text(via ? "Phone and Mac meet through clavra.naqara.dev over HTTPS. The relay passes along encrypted data it can't read." : "The phone talks to this Mac directly. Nothing leaves your network, but the page loads over plain HTTP, so use it only on networks you trust.")
                            .font(.system(size: 11.5)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 22)
                }
            }
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 32)
            .padding(.top, 60)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.never)
        .background(Theme.window)
    }

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.line))
    }

    private func step(_ number: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Text(number).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.brass)
                .frame(width: 22, height: 22).background(Circle().fill(Theme.brass.opacity(0.12)))
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.secondary)
        }
    }
}

/// A phone that scanned the code wants in.
struct RemoteRequest: View {
    var device: RemoteAccess.Device
    var remote: RemoteAccess

    var body: some View {
        Notice {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "iphone").font(.system(size: 16)).foregroundStyle(Theme.brass)
                    Text("Let \(device.name) use Clavra?").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                }
                Text("It scanned this Mac's code just now. It will see your open tabs and can type in them\(remote.typingInProduction ? "" : ", except production tabs, which it can only watch").")
                    .font(.system(size: 13)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Allow") { remote.allow(device.id) }.buttonStyle(BrassButtonStyle())
                    Button("Don't Allow") { remote.disconnect(device.id) }.buttonStyle(QuietButtonStyle()).keyboardShortcut(.cancelAction)
                }
                .padding(.top, 2)
            }
            .frame(width: 380, alignment: .leading)
        }
    }
}
