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
        var permissions: UInt32?
        var id: String { name }

        /// `rwxr-xr-x`
        var mode: String? {
            guard let permissions else { return nil }
            let bits = Array("rwxrwxrwx")
            return String((0..<9).map { permissions & (1 << (8 - $0)) != 0 ? bits[$0] : "-" })
        }
    }

    struct Transfer: Identifiable, Equatable {
        enum Direction { case up, down, editing }
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
        guard SafeNames.isSafe(component.filename) else { return nil }
        let mode = component.attributes.permissions ?? 0
        let type = mode & 0o170000
        let long = component.longname
        return Entry(name: component.filename,
                     isFolder: type == 0o040000 || (type == 0 && long.hasPrefix("d")),
                     isLink: type == 0o120000 || long.hasPrefix("l"),
                     size: component.attributes.size,
                     modified: component.attributes.accessModificationTime?.modificationTime,
                     permissions: component.attributes.permissions.map { $0 & 0o7777 })
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

    func makeFile(_ name: String) async {
        await change { sftp in
            try await sftp.withFile(filePath: self.join(name), flags: [.write, .create, .forceCreate]) { _ in }
        }
    }

    /// `0o644` and the like.
    func setPermissions(_ entry: Entry, to mode: UInt32) async {
        await change { sftp in
            var attributes = SFTPFileAttributes()
            attributes.permissions = mode
            try await sftp.setAttributes(at: self.join(entry.name), to: attributes)
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

    /// A file, or a whole folder with everything inside it.
    func download(_ entry: Entry) {
        let source = join(entry.name)
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        guard SafeNames.isSafe(entry.name), let target = SafeNames.contained(Self.unused(downloads.appending(path: entry.name)), in: downloads) else { return }
        let transfer = Transfer(name: entry.name, direction: .down, total: entry.isFolder ? nil : entry.size)
        transfers.insert(transfer, at: 0)
        Task { [weak self] in
            guard let self else { return }
            do {
                let sftp = try await session.sftp()
                let report: @Sendable (UInt64) async -> Void = { [weak self] done in await self?.progress(transfer.id, done) }
                if entry.isFolder {
                    try await Self.downloadFolder(source, to: target, with: sftp, counter: Counter(), progress: report)
                } else {
                    try await Self.download(source, to: target, with: sftp, progress: report)
                }
                finish(transfer.id, nil)
                NSWorkspace.shared.activateFileViewerSelecting([target])
            } catch {
                try? FileManager.default.removeItem(at: target)
                finish(transfer.id, Self.describe(error))
            }
        }
    }

    /// Names already in this folder, which an upload of `urls` would replace.
    func conflicts(_ urls: [URL]) -> [String] {
        urls.map(\.lastPathComponent).filter { name in entries.contains { $0.name == name } }
    }

    /// Files and folders; folders go up with everything inside.
    func upload(_ urls: [URL]) {
        for url in urls {
            let destination = join(url.lastPathComponent)
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let size = isFolder ? Self.folderSize(url) : (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value
            let transfer = Transfer(name: url.lastPathComponent, direction: .up, total: size)
            transfers.insert(transfer, at: 0)
            Task { [weak self] in
                guard let self else { return }
                do {
                    let sftp = try await session.sftp()
                    let report: @Sendable (UInt64) async -> Void = { [weak self] done in await self?.progress(transfer.id, done) }
                    if isFolder {
                        try await Self.uploadFolder(url, to: destination, with: sftp, counter: Counter(), progress: report)
                    } else {
                        try await Self.upload(url, to: destination, with: sftp, progress: report)
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

    // MARK: Editing

    @ObservationIgnored private var editors: [String: Task<Void, Never>] = [:]
    /// This tab's own copies, so closing it never touches another tab's open files.
    @ObservationIgnored private lazy var editingFolder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appending(path: "Clavra/Editing/\(UUID().uuidString)", directoryHint: .isDirectory)

    /// Opens the file in the Mac's app for its type. Every save there goes back to the server for as
    /// long as the tab is open; a save made while the connection is down goes up once it's back.
    func edit(_ entry: Entry) {
        guard !entry.isFolder, SafeNames.isSafe(entry.name) else { return }
        let source = join(entry.name)
        editors[source]?.cancel()
        let folder = editingFolder.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let local = folder.appending(path: entry.name)
        var transfer = Transfer(name: entry.name, direction: .editing, total: entry.size)
        transfer.done = 0
        transfers.insert(transfer, at: 0)
        editors[source] = Task { [weak self] in
            guard let self else { return }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let sftp = try await session.sftp()
                try await Self.download(source, to: local, with: sftp) { _ in }
                #if DEBUG
                if UserDefaults.standard.bool(forKey: "ClavraEditNoOpen") {
                    print("CLAVRA_EDIT \(local.path)")
                    fflush(stdout)
                } else {
                    NSWorkspace.shared.open(local)
                }
                #else
                NSWorkspace.shared.open(local)
                #endif
                var stamp = Self.modified(local)
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(1))
                    let now = Self.modified(local)
                    guard now != stamp else { continue }
                    do {
                        let sftp = try await session.sftp()
                        try await Self.upload(local, to: source, with: sftp) { _ in }
                        stamp = now
                        saved(transfer.id)
                        await load()
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        // Not sent; the stamp stays put so the next tick tries again.
                        pending(transfer.id, Self.describe(error))
                        try await Task.sleep(for: .seconds(3))
                    }
                }
            } catch is CancellationError {
            } catch {
                finish(transfer.id, Self.describe(error))
            }
        }
    }

    /// Stops sending saves back, and cleans up this tab's local copies.
    func stopEditing() {
        for task in editors.values { task.cancel() }
        editors = [:]
        transfers.removeAll { $0.direction == .editing }
        try? FileManager.default.removeItem(at: editingFolder)
    }

    var isEditing: Bool { !editors.isEmpty }

    private func saved(_ id: Transfer.ID) {
        if let index = transfers.firstIndex(where: { $0.id == id }) {
            transfers[index].done += 1
            transfers[index].failed = nil
        }
    }

    private func pending(_ id: Transfer.ID, _ why: String) {
        if let index = transfers.firstIndex(where: { $0.id == id }) { transfers[index].failed = "Not uploaded yet: \(why) Trying again." }
    }

    private nonisolated static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
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

    /// Writes to a temporary name beside the destination and renames it into place, so a dropped
    /// connection never leaves a half-written file where the old one was. The old file's permissions
    /// carry over.
    private nonisolated static func upload(_ source: URL, to destination: String, with sftp: SFTPClient,
                                           progress: @escaping @Sendable (UInt64) async -> Void) async throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let folder = (destination as NSString).deletingLastPathComponent
        let name = (destination as NSString).lastPathComponent
        let temporary = (folder.isEmpty ? "" : folder + "/") + ".\(name).clavra-\(UUID().uuidString.prefix(8))"
        let existing = try? await sftp.getAttributes(at: destination)
        do {
            try await sftp.withFile(filePath: temporary, flags: [.write, .create, .truncate]) { file in
                var offset: UInt64 = 0
                while let data = try input.read(upToCount: Int(chunk)), !data.isEmpty {
                    try await file.write(ByteBuffer(bytes: data), at: offset)
                    offset += UInt64(data.count)
                    await progress(offset)
                }
            }
            if let mode = existing?.permissions {
                var attributes = SFTPFileAttributes()
                attributes.permissions = mode & 0o7777
                try? await sftp.setAttributes(at: temporary, to: attributes)
            }
            do {
                try await sftp.rename(at: temporary, to: destination)
            } catch where existing != nil {
                // SFTP v3 won't rename over a file; take the old one away first.
                try await sftp.remove(at: destination)
                try await sftp.rename(at: temporary, to: destination)
            }
        } catch {
            try? await sftp.remove(at: temporary)
            throw error
        }
    }

    /// Running total of bytes moved across a folder's files.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var total: UInt64 = 0

        func add(_ bytes: UInt64) -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            total += bytes
            return total
        }

        func file() -> File { File(counter: self) }

        /// One file's share: turns "this file is at n bytes" into the folder's running total.
        final class File: @unchecked Sendable {
            private let counter: Counter
            private var last: UInt64 = 0

            init(counter: Counter) { self.counter = counter }

            func reached(_ done: UInt64) -> UInt64 {
                defer { last = done }
                return counter.add(done - last)
            }
        }
    }

    private nonisolated static func downloadFolder(_ source: String, to target: URL, with sftp: SFTPClient, counter: Counter,
                                                   progress: @escaping @Sendable (UInt64) async -> Void) async throws {
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let names = try await sftp.listDirectory(atPath: source).flatMap(\.components)
        for component in names where SafeNames.isSafe(component.filename) {
            let type = (component.attributes.permissions ?? 0) & 0o170000
            let path = source + "/" + component.filename
            // A file with this name may already be there from a half-finished download; never write
            // anywhere but inside the new folder.
            guard let local = SafeNames.contained(unused(target.appending(path: component.filename)), in: target) else { continue }
            if type == 0o040000 {
                try await downloadFolder(path, to: local, with: sftp, counter: counter, progress: progress)
            } else if type == 0o100000 || type == 0 {
                let file = counter.file()
                try await download(path, to: local, with: sftp) { done in await progress(file.reached(done)) }
            }
            // Links, sockets and devices are skipped: following links can loop forever.
        }
    }

    private nonisolated static func uploadFolder(_ source: URL, to destination: String, with sftp: SFTPClient, counter: Counter,
                                                 progress: @escaping @Sendable (UInt64) async -> Void) async throws {
        do { try await sftp.createDirectory(atPath: destination) } catch {
            // Already there is fine; anything else shows up on the first file.
        }
        let items = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        for item in items {
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { continue }
            let path = destination + "/" + item.lastPathComponent
            if values?.isDirectory == true {
                try await uploadFolder(item, to: path, with: sftp, counter: counter, progress: progress)
            } else {
                let file = counter.file()
                try await upload(item, to: path, with: sftp) { done in await progress(file.reached(done)) }
            }
        }
    }

    private nonisolated static func folderSize(_ url: URL) -> UInt64 {
        let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        var total: UInt64 = 0
        while let item = walker?.nextObject() as? URL {
            total += UInt64((try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
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
