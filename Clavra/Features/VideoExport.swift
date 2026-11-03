import AppKit
import AVFoundation
import CoreVideo
import Observation
import SwiftTerm

/// Turns a recording into an MP4: plays it into an offscreen terminal and films every change.
/// Frames are only written when the screen changes (at most 30 a second), so a quiet minute costs
/// nothing and the file stays small.
@MainActor
enum VideoExport {
    nonisolated static let framesPerSecond = 30.0
    /// Pauses longer than this are cut down to it when skipping pauses, as in the player.
    nonisolated static let longestPause = 1.0

    enum Failure: LocalizedError {
        case unreadable, writer(String)
        var errorDescription: String? {
            switch self {
            case .unreadable: "The recording couldn't be read."
            case .writer(let reason): "The video couldn't be written: \(reason)"
            }
        }
    }

    /// The time each event lands at in the video: the same as recorded, or with long pauses cut.
    nonisolated static func timeline(_ times: [TimeInterval], skipPauses: Bool) -> [TimeInterval] {
        guard skipPauses else { return times }
        var out: [TimeInterval] = []
        out.reserveCapacity(times.count)
        var last: TimeInterval = 0, shifted: TimeInterval = 0
        for time in times {
            shifted += min(max(time - last, 0), longestPause)
            last = time
            out.append(shifted)
        }
        return out
    }

    /// Even pixel sizes: H.264 needs them, and most players want them.
    nonisolated static func even(_ value: CGFloat) -> Int { max(Int(value.rounded(.up)) & ~1, 2) }

    static func export(tape: Recordings.Tape, to url: URL, skipPauses: Bool, progress: @escaping (Double) -> Void) async throws {
        let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        TerminalStyle.apply(to: terminal)
        terminal.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        terminal.appearance = NSAppearance(named: .darkAqua)

        // The canvas fits the largest size the terminal had.
        var cols = tape.cols, rows = tape.rows
        for case (_, .resize(let c, let r)) in tape.events {
            cols = max(cols, c)
            rows = max(rows, r)
        }
        terminal.resize(cols: max(cols, 1), rows: max(rows, 1))
        let cell = cellSize(terminal)
        let padding: CGFloat = 20
        let points = CGSize(width: cell.width * CGFloat(max(cols, 1)) + padding * 2, height: cell.height * CGFloat(max(rows, 1)) + padding * 2)
        // Sharp at 2×, but no wider than 1920 pixels (or taller than 1920), which every player handles.
        let scale = min(2, 1920 / points.width, 1920 / points.height)
        let width = even(points.width * scale), height = even(points.height * scale)
        terminal.resize(cols: tape.cols, rows: tape.rows)
        terminal.frame = NSRect(origin: .zero, size: CGSize(width: cell.width * CGFloat(tape.cols), height: cell.height * CGFloat(tape.rows)))

        try? FileManager.default.removeItem(at: url)
        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: url, fileType: .mp4) } catch { throw Failure.writer(error.localizedDescription) }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(width * height * 3, 1_500_000),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(input) else { throw Failure.writer("H.264 isn't available.") }
        writer.add(input)
        guard writer.startWriting() else { throw Failure.writer(writer.error?.localizedDescription ?? "it wouldn't start.") }
        writer.startSession(atSourceTime: .zero)

        let times = timeline(tape.events.map(\.time), skipPauses: skipPauses)
        let end = (times.last ?? 0) + 1
        let step = 1 / framesPerSecond
        var lastFrame = -1.0
        var index = 0
        var dirty = true
        var sinceYield = 0

        func frame(at time: TimeInterval) async throws {
            // A frame per step at most; and times only go forward.
            let at = max(time, lastFrame + step)
            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(2))
            }
            guard let pool = adaptor.pixelBufferPool else { throw Failure.writer(writer.error?.localizedDescription ?? "no frames.") }
            var made: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
            guard let buffer = made else { throw Failure.writer("out of memory.") }
            draw(terminal, into: buffer, scale: scale, padding: padding, cell: cell)
            guard adaptor.append(buffer, withPresentationTime: CMTime(seconds: at, preferredTimescale: 600)) else {
                throw Failure.writer(writer.error?.localizedDescription ?? "a frame was refused.")
            }
            lastFrame = at
            dirty = false
        }

        do {
            while index < tape.events.count {
                try Task.checkCancellation()
                // Everything due before the next frame goes in together.
                let bucket = times[index]
                while index < tape.events.count, times[index] < bucket + step {
                    switch tape.events[index].event {
                    case .output(let text): terminal.feed(text: text)
                    case .resize(let c, let r):
                        terminal.resize(cols: c, rows: r)
                        terminal.frame = NSRect(origin: .zero, size: CGSize(width: cell.width * CGFloat(c), height: cell.height * CGFloat(r)))
                    }
                    index += 1
                    dirty = true
                }
                if dirty { try await frame(at: bucket) }
                sinceYield += 1
                if sinceYield >= 60 {
                    sinceYield = 0
                    progress(Double(index) / Double(max(tape.events.count, 1)))
                    await Task.yield()
                }
            }
            // The last screen stays up for a second.
            try await frame(at: end)
        } catch {
            input.markAsFinished()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: lastFrame + step, preferredTimescale: 600))
        await writer.finishWriting()
        if writer.status != .completed {
            try? FileManager.default.removeItem(at: url)
            throw Failure.writer(writer.error?.localizedDescription ?? "it didn't finish.")
        }
        progress(1)
    }

    /// One cell, as the terminal lays them out: its height from the terminal's own frame size,
    /// its width from the font's advance.
    private static func cellSize(_ terminal: TerminalView) -> CGSize {
        let rows = CGFloat(max(terminal.getTerminal().rows, 1))
        let height = terminal.getOptimalFrameSize().height / rows
        let font = terminal.font as CTFont
        var glyph = CGGlyph(0)
        var character = UniChar(("W" as Unicode.Scalar).value)
        CTFontGetGlyphsForCharacters(font, &character, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        return CGSize(width: advance.width, height: height)
    }

    private static func draw(_ terminal: TerminalView, into buffer: CVPixelBuffer, scale: CGFloat, padding: CGFloat, cell: CGSize) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        context.setFillColor(NSColor(hex: 0x121114).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        let size = terminal.frame.size
        let canvasHeight = CGFloat(height) / scale
        // Top left, inside the padding.
        context.translateBy(x: padding, y: canvasHeight - padding - size.height)

        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        terminal.draw(NSRect(origin: .zero, size: size))
        // The caret: a block where the cursor is.
        let screen = terminal.getTerminal()
        let cursor = screen.getCursorLocation()
        if cursor.y < screen.rows, cursor.x < screen.cols {
            let rect = CGRect(x: CGFloat(cursor.x) * cell.width, y: size.height - CGFloat(cursor.y + 1) * cell.height,
                              width: cell.width, height: cell.height)
            context.setFillColor(NSColor(hex: 0xD8B46C).withAlphaComponent(0.75).cgColor)
            context.fill(rect)
        }
        NSGraphicsContext.current = previous
    }
}

/// Videos being made, so leaving the page doesn't stop them and the list can show how far they are.
@MainActor @Observable
final class VideoExports {
    static let shared = VideoExports()

    struct Job: Identifiable {
        enum State { case running(Double), done, failed(String) }
        let id = UUID()
        let name: String
        let url: URL
        var state: State
    }

    private(set) var jobs: [Job] = []
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]

    func start(recording: URL, to url: URL, skipPauses: Bool) {
        jobs.removeAll { $0.url == url }
        let job = Job(name: url.lastPathComponent, url: url, state: .running(0))
        jobs.insert(job, at: 0)
        let id = job.id
        tasks[id] = Task { [weak self] in
            do {
                // A copy with its secrets hidden: a tab still recording hasn't been through that yet.
                let copy = FileManager.default.temporaryDirectory.appending(path: "clavra-export-\(id.uuidString).cast")
                defer { try? FileManager.default.removeItem(at: copy) }
                try await Task.detached(priority: .userInitiated) {
                    try? FileManager.default.removeItem(at: copy)
                    try FileManager.default.copyItem(at: recording, to: copy)
                    if Redaction.isOn { Redaction.apply(to: copy) }
                }.value
                guard let tape = await Task.detached(priority: .userInitiated, operation: { Recordings.tape(at: copy) }).value else {
                    throw VideoExport.Failure.unreadable
                }
                try await VideoExport.export(tape: tape, to: url, skipPauses: skipPauses) { fraction in
                    self?.update(id, .running(fraction))
                }
                self?.update(id, .done)
            } catch is CancellationError {
                self?.jobs.removeAll { $0.id == id }
            } catch {
                self?.update(id, .failed(error.localizedDescription))
            }
            self?.tasks[id] = nil
        }
    }

    func cancel(_ id: UUID) {
        tasks[id]?.cancel()
    }

    func dismiss(_ id: UUID) {
        tasks[id]?.cancel()
        jobs.removeAll { $0.id == id }
    }

    private func update(_ id: UUID, _ state: Job.State) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].state = state
    }
}
