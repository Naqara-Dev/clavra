import AppKit
import Citadel
import Foundation
import NIOCore

/// One folder on the server at a time, over the tab's SFTP channel. Downloads land in ~/Downloads.
@MainActor @Observable
final class FileBrowser {
    struct Entry: Identifiable, Hashable {
        var name: String
        var isFolder: Bool
        var isLink: Bool
        var size: UInt64?
        var modified: Date?
        var id: String { name }
    }

    struct Transfer: Identifiable, Equatable {
        enum Direction { case up, down }
        let id = UUID()
        var name: String
        var direction: Direction
        var done: UInt64 = 0
        var total: UInt64?
        var failed: String?
        var finished = false

        var fraction: Double? {
            guard let total, total > 0 else { return nil }
            return min(Double(done) / Double(total), 1)
        }
    }

    private let session: Session
    private(set) var path = ""
    private(set) var entries: [Entry] = []
    private(set) var loading = false
    private(set) var error: String?
    private(set) var transfers: [Transfer] = []
    var showsHidden = false

    init(session: Session) {
        self.session = session
    }

    var visible: [Entry] { showsHidden ? entries : entries.filter { !$0.name.hasPrefix(".") } }

    /// `/home/deploy/app` as clickable steps.
    var crumbs: [(name: String, path: String)] {
        var result = [(name: "/", path: "/")]
        var built = ""
        for part in path.split(separator: "/") {
            built += "/" + part
            result.append((String(part), built))
        }
        return result
    }

    func start() async {
        guard path.isEmpty else { return }
        do {
            let sftp = try await session.sftp()
            path = try await sftp.getRealPath(atPath: ".")
        } catch {
            self.error = Session.describe(error)
            return
        }
        await load()
    }

    func open(_ entry: Entry) async {
        guard entry.isFolder || entry.isLink else { return }
        await go(to: join(entry.name))
    }

    func up() async {
        guard path != "/" else { return }
        let parent = (path as NSString).deletingLastPathComponent
        await go(to: parent.isEmpty ? "/" : parent)
    }

    func go(to newPath: String) async {
        let previous = path
        path = newPath
        await load()
        if error != nil, !previous.isEmpty, newPath != previous {
            // A link to a file, or a folder we can't read: stay where we were.
            path = previous
            let message = error
            await load()
            error = message
        }
    }

    func load() async {
        loading = true
        defer { loading = false }
        do {
            let sftp = try await session.sftp()
            let names = try await sftp.listDirectory(atPath: path)
            entries = names.flatMap(\.components).compactMap(Self.entry).sorted {
                $0.isFolder != $1.isFolder ? $0.isFolder : $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            error = nil
        } catch {
            self.error = Self.describe(error)
        }
    }

    private static func entry(_ component: SFTPPathComponent) -> Entry? {
        guard component.filename != ".", component.filename != ".." else { return nil }
        let mode = component.attributes.permissions ?? 0
        let type = mode & 0o170000
        let long = component.longname
        return Entry(name: component.filename,
                     isFolder: type == 0o040000 || (type == 0 && long.hasPrefix("d")),
                     isLink: type == 0o120000 || long.hasPrefix("l"),
                     size: component.attributes.size,
                     modified: component.attributes.accessModificationTime?.modificationTime)
    }

    func join(_ name: String) -> String {
        path == "/" ? "/" + name : path + "/" + name
    }

    // MARK: Changes

    func makeFolder(_ name: String) async {
        await change { try await $0.createDirectory(atPath: self.join(name)) }
    }

    func rename(_ entry: Entry, to name: String) async {
        guard !name.isEmpty, name != entry.name else { return }
        await change { try await $0.rename(at: self.join(entry.name), to: self.join(name)) }
    }

    /// Files go straight away; a folder only when it's empty, so nothing is lost by a slip.
    func delete(_ entry: Entry) async {
        await change { sftp in
            if entry.isFolder { try await sftp.rmdir(at: self.join(entry.name)) } else { try await sftp.remove(at: self.join(entry.name)) }
        }
    }

    private func change(_ body: @escaping (SFTPClient) async throws -> Void) async {
        do {
            try await body(try await session.sftp())
            await load()
        } catch {
            self.error = Self.describe(error)
        }
    }

    // MARK: Transfers

    func download(_ entry: Entry) {
        guard !entry.isFolder else { return }
        let source = join(entry.name)
        let target = Self.unused(FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appending(path: entry.name))
        let transfer = Transfer(name: entry.name, direction: .down, total: entry.size)
        transfers.insert(transfer, at: 0)
        Task { [weak self] in
            guard let self else { return }
            do {
                let sftp = try await session.sftp()
                try await Self.download(source, to: target, with: sftp) { [weak self] done in
                    await self?.progress(transfer.id, done)
                }
                finish(transfer.id, nil)
                NSWorkspace.shared.activateFileViewerSelecting([target])
            } catch {
                try? FileManager.default.removeItem(at: target)
                finish(transfer.id, Self.describe(error))
            }
        }
    }

    func upload(_ urls: [URL]) {
        for url in urls where !url.hasDirectoryPath {
            let destination = join(url.lastPathComponent)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value
            let transfer = Transfer(name: url.lastPathComponent, direction: .up, total: size)
            transfers.insert(transfer, at: 0)
            Task { [weak self] in
                guard let self else { return }
                do {
                    let sftp = try await session.sftp()
                    try await Self.upload(url, to: destination, with: sftp) { [weak self] done in
                        await self?.progress(transfer.id, done)
                    }
                    finish(transfer.id, nil)
                    await load()
                } catch {
                    finish(transfer.id, Self.describe(error))
                }
            }
        }
    }

    func clearFinished() {
        transfers.removeAll { $0.finished }
    }

    private func progress(_ id: Transfer.ID, _ done: UInt64) {
        if let index = transfers.firstIndex(where: { $0.id == id }) { transfers[index].done = done }
    }

    private func finish(_ id: Transfer.ID, _ failure: String?) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[index].finished = true
        transfers[index].failed = failure
    }

    private nonisolated static let chunk: UInt32 = 256 * 1024

    private nonisolated static func download(_ source: String, to target: URL, with sftp: SFTPClient,
                                             progress: @escaping @Sendable (UInt64) async -> Void) async throws {
        FileManager.default.createFile(atPath: target.path, contents: nil)
        let output = try FileHandle(forWritingTo: target)
        defer { try? output.close() }
        try await sftp.withFile(filePath: source, flags: .read) { file in
            var offset: UInt64 = 0
            while true {
                let buffer = try await file.read(from: offset, length: chunk)
                guard buffer.readableBytes > 0 else { break }
                try output.write(contentsOf: buffer.readableBytesView)
                offset += UInt64(buffer.readableBytes)
                await progress(offset)
            }
        }
    }

    private nonisolated static func upload(_ source: URL, to destination: String, with sftp: SFTPClient,
                                           progress: @escaping @Sendable (UInt64) async -> Void) async throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        try await sftp.withFile(filePath: destination, flags: [.write, .create, .truncate]) { file in
            var offset: UInt64 = 0
            while let data = try input.read(upToCount: Int(chunk)), !data.isEmpty {
                try await file.write(ByteBuffer(bytes: data), at: offset)
                offset += UInt64(data.count)
                await progress(offset)
            }
        }
    }

    /// `report.pdf`, then `report 2.pdf`, like Finder.
    private nonisolated static func unused(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var number = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            let candidate = url.deletingLastPathComponent().appending(path: name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            number += 1
        }
    }

    private static func describe(_ error: Error) -> String {
        let raw = String(describing: error)
        if raw.contains("permissionDenied") || raw.contains("Permission denied") { return "You don't have permission for that." }
        if raw.contains("noSuchFile") || raw.contains("No such file") { return "That isn't there any more." }
        if raw.contains("failure") && raw.contains("rmdir") { return "Only empty folders can be deleted here." }
        return Session.describe(error)
    }
}
