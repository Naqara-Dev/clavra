import Foundation

/// This Mac's seat in a relay room on clavra.naqara.dev. Frames from the relay start with a kind
/// (0 data, 1 a phone joined, 2 a phone left) and the phone's number; what follows is the phone's
/// sealed message, which the relay can't read. Reconnects on its own while Phone Access is on.
@MainActor
final class RelayClient: NSObject, URLSessionWebSocketDelegate {
    enum Event {
        case connected
        case disconnected(String?)
        case joined(UInt32)
        case data(UInt32, Data)
        case left(UInt32)
    }

    var onEvent: ((Event) -> Void)?

    private let url: URL
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var keepAlive: Task<Void, Never>?
    private var stopped = false

    init(url: URL) {
        self.url = url
    }

    func start() {
        stopped = false
        connect()
    }

    func stop() {
        stopped = true
        keepAlive?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    func send(kind: UInt8, phone: UInt32, _ payload: Data) {
        var frame = Data([kind])
        withUnsafeBytes(of: phone.bigEndian) { frame.append(contentsOf: $0) }
        frame.append(payload)
        task?.send(.data(frame)) { _ in }
    }

    private func connect() {
        guard !stopped else { return }
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: .main)
        self.session = session
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 1 << 20
        self.task = task
        task.resume()
        receive(on: task)
        // Some networks close a WebSocket that's been quiet for a minute or two.
        keepAlive?.cancel()
        keepAlive = Task { [weak self, weak task] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(25))
                task?.sendPing { _ in }
                if self == nil { return }
            }
        }
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, task === self.task else { return }
                switch result {
                case .success(.data(let frame)):
                    self.dispatch(frame)
                    self.receive(on: task)
                case .success:
                    self.receive(on: task)
                case .failure:
                    self.dropped("Can't reach clavra.naqara.dev. Trying again…")
                }
            }
        }
    }

    private func dispatch(_ frame: Data) {
        guard frame.count >= 5 else { return }
        let bytes = [UInt8](frame)
        let phone = UInt32(bytes[1]) << 24 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 8 | UInt32(bytes[4])
        switch bytes[0] {
        case 0: onEvent?(.data(phone, Data(bytes[5...])))
        case 1: onEvent?(.joined(phone))
        case 2: onEvent?(.left(phone))
        default: break
        }
    }

    private func dropped(_ why: String) {
        task = nil
        keepAlive?.cancel()
        session?.invalidateAndCancel()
        session = nil
        onEvent?(.disconnected(stopped ? nil : why))
        guard !stopped else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.connect()
        }
    }

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        MainActor.assumeIsolated { onEvent?(.connected) }
    }

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                                didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        MainActor.assumeIsolated {
            guard webSocketTask === task else { return }
            dropped(closeCode.rawValue == 4000 ? "Phone Access was opened on another connection." : "The relay closed the room. Trying again…")
        }
    }
}
