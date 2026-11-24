import AudioToolbox
import AVFoundation
import CoreMedia
import CoreVideo
import Darwin
import Foundation

enum MovieError: LocalizedError {
    case unreadable(String)
    case noVideo(String)
    case empty
    case writer(String)
    case cancelled
    case overwrite

    var errorDescription: String? {
        switch self {
        case .unreadable(let message): return message
        case .noVideo(let name): return "\(name) has no video track."
        case .empty: return "The video has no duration."
        case .writer(let message): return message
        case .cancelled: return "Save cancelled."
        case .overwrite: return "Refusing to overwrite a source video."
        }
    }
}

enum PixelCodec {
    case h264
    case proRes4444

    var avType: AVVideoCodecType {
        switch self {
        case .h264: return .h264
        case .proRes4444: return .proRes4444
        }
    }
}

struct ClipFacts {
    var url: URL
    var displayName: String
    var orientedWidth: Int
    var orientedHeight: Int
    var rangeStart: CMTime
    var rangeDuration: CMTime
    var frameDuration: CMTime
    var hasAudio: Bool

    var durationSeconds: Double { rangeDuration.seconds }

    var framesPerSecond: Double {
        let seconds = frameDuration.seconds
        guard seconds > 0 else { return 30 }
        return 1 / seconds
    }
}

enum Sync {
    private final class Box<T> {
        var result: Result<T, Error>?
    }

    static func value<T>(_ work: @escaping () async throws -> T) throws -> T {
        let box = Box<T>()
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                box.result = .success(try await work())
            } catch {
                box.result = .failure(error)
            }
            sem.signal()
        }
        // Pump the current run loop. AVFoundation finishes loads on it, and a
        // plain wait from that same thread never returns.
        while sem.wait(timeout: .now()) == .timedOut {
            RunLoop.current.run(mode: .common, before: Date(timeIntervalSinceNow: 0.02))
        }
        guard let result = box.result else {
            throw MovieError.unreadable("The video could not be read.")
        }
        return try result.get()
    }
}

enum MovieProbe {
    static func asset(url: URL) -> AVURLAsset {
        AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    }

    static func facts(url: URL) throws -> ClipFacts {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
        ]), values.isUbiquitousItem == true,
           values.ubiquitousItemDownloadingStatus != .current {
            throw MovieError.unreadable("\(url.lastPathComponent) is still in iCloud. Download it, then open it again.")
        }
        let asset = asset(url: url)
        let tracks = try Sync.value { try await asset.loadTracks(withMediaType: .video) }
        guard let track = tracks.first else {
            throw MovieError.unreadable("\(url.lastPathComponent) has no video Moire can read.")
        }
        let audio = try Sync.value { try await asset.loadTracks(withMediaType: .audio) }
        let natural = try Sync.value { try await track.load(.naturalSize) }
        let transform = try Sync.value { try await track.load(.preferredTransform) }
        let nominal = try Sync.value { try await track.load(.nominalFrameRate) }
        let minimum = try Sync.value { try await track.load(.minFrameDuration) }
        let range = try Sync.value { try await track.load(.timeRange) }
        var oriented = VideoGeometry.orientedPixelSize(natural: natural, transform: transform)
        if oriented.width < 2 || oriented.height < 2 {
            let descriptions = (try? Sync.value { try await track.load(.formatDescriptions) }) ?? []
            if let description = descriptions.first {
                let dimensions = CMVideoFormatDescriptionGetDimensions(description)
                oriented = CGSize(width: CGFloat(abs(dimensions.width)), height: CGFloat(abs(dimensions.height)))
            }
        }
        let width = Int(abs(oriented.width).rounded())
        let height = Int(abs(oriented.height).rounded())
        guard width >= 2, height >= 2 else { throw MovieError.noVideo(url.lastPathComponent) }
        var duration = range.duration
        if !duration.isValid || duration.seconds <= 0 {
            duration = try Sync.value { try await asset.load(.duration) }
        }
        guard duration.isValid, duration.seconds > 0 else { throw MovieError.empty }
        return ClipFacts(
            url: url,
            displayName: url.lastPathComponent,
            orientedWidth: width,
            orientedHeight: height,
            rangeStart: range.start,
            rangeDuration: duration,
            frameDuration: VideoGeometry.frameDuration(minimum: minimum, nominal: nominal),
            hasAudio: !audio.isEmpty
        )
    }
}

struct OpenedClip {
    var facts: ClipFacts
    /// A temporary movie Moire made so AVFoundation can read the original. The caller deletes it.
    var temporary: URL?
}

enum MovieIntake {
    static func open(
        _ url: URL,
        cancelled: @escaping () -> Bool = { false },
        progress: @escaping (Double) -> Void = { _ in },
        onProcess: ((Process) -> Void)? = nil
    ) throws -> OpenedClip {
        if cancelled() { throw MovieError.cancelled }
        if let facts = try? MovieProbe.facts(url: url) {
            return OpenedClip(facts: facts, temporary: nil)
        }
        guard ForeignMovie.isContainer(url) else {
            return OpenedClip(facts: try MovieProbe.facts(url: url), temporary: nil)
        }
        let temp = try ForeignMovie.convert(url, cancelled: cancelled, progress: progress, onProcess: onProcess)
        do {
            var facts = try MovieProbe.facts(url: temp)
            facts.displayName = url.lastPathComponent
            return OpenedClip(facts: facts, temporary: temp)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }
}

enum ForeignMovie {
    private static let extensions: Set<String> = ["mkv", "mk3d", "webm"]
    private static let copyVideo: Set<String> = ["h264", "hevc", "prores"]

    static func isContainer(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    static func ffmpeg() -> URL? {
        for path in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg"]
            where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    static func convert(
        _ url: URL,
        cancelled: @escaping () -> Bool,
        progress: @escaping (Double) -> Void,
        onProcess: ((Process) -> Void)? = nil
    ) throws -> URL {
        if cancelled() { throw MovieError.cancelled }
        guard let ffmpeg = ffmpeg() else {
            throw MovieError.unreadable("Moire can't read \(url.pathExtension.uppercased()) by itself. Install ffmpeg, or export the video as an MP4.")
        }
        let ffprobe = ffmpeg.deletingLastPathComponent().appendingPathComponent("ffprobe")
        guard FileManager.default.isExecutableFile(atPath: ffprobe.path) else {
            throw MovieError.unreadable("Moire can't read \(url.pathExtension.uppercased()) by itself. Install ffmpeg, or export the video as an MP4.")
        }
        let source = try inspect(url, ffprobe: ffprobe)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MoireImport", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent("\(UUID().uuidString).mov")
        var arguments = [
            "-nostdin", "-y", "-hide_banner", "-loglevel", "error", "-progress", "pipe:1",
            "-i", url.path, "-map", "0:v:0",
        ]
        if source.hasAudio { arguments += ["-map", "0:a:0"] }
        if copyVideo.contains(source.videoCodec) {
            arguments += ["-c:v", "copy"]
        } else {
            arguments += [
                "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2",
                "-c:v", "libx264", "-preset", "veryfast", "-crf", "16", "-pix_fmt", "yuv420p",
            ]
        }
        if source.hasAudio { arguments += ["-c:a", "aac", "-b:a", "192k"] }
        arguments.append(output.path)
        progress(0.01)
        do {
            try run(
                ffmpeg,
                arguments,
                duration: source.duration,
                cancelled: cancelled,
                progress: progress,
                onProcess: onProcess
            )
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        progress(1)
        return output
    }

    private struct Source {
        var videoCodec: String
        var hasAudio: Bool
        var duration: Double
    }

    private static func inspect(_ url: URL, ffprobe: URL) throws -> Source {
        let video = try capture(ffprobe, [
            "-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream=codec_name", "-of", "csv=p=0", url.path,
        ])
        let codec = video.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        guard !codec.isEmpty else { throw MovieError.noVideo(url.lastPathComponent) }
        let audio = (try? capture(ffprobe, [
            "-v", "error", "-select_streams", "a:0",
            "-show_entries", "stream=codec_name", "-of", "csv=p=0", url.path,
        ])) ?? ""
        let durationText = try capture(ffprobe, [
            "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", url.path,
        ])
        let cleaned = codec.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: ",")))
        return Source(
            videoCodec: cleaned,
            hasAudio: !audio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            duration: Double(durationText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        )
    }

    private static func capture(_ tool: URL, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let message = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            throw MovieError.unreadable(trimmed.isEmpty ? "Could not read \(arguments.last ?? "the video")." : trimmed)
        }
        return text
    }

    private static func run(
        _ ffmpeg: URL,
        _ arguments: [String],
        duration: Double,
        cancelled: @escaping () -> Bool,
        progress: @escaping (Double) -> Void,
        onProcess: ((Process) -> Void)?
    ) throws {
        if cancelled() { throw MovieError.cancelled }
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let notes = LockedText()
        let leftover = LockedText()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            guard let text = String(data: data, encoding: .utf8) else { return }
            let chunk = leftover.append(text)
            guard let split = Self.lines(chunk) else { return }
            leftover.set(split.rest)
            for line in split.lines {
                if cancelled() {
                    if process.isRunning { process.terminate() }
                    return
                }
                guard duration > 0 else { continue }
                if let seconds = Self.seconds(fromProgress: line) {
                    progress(min(0.99, max(0.01, seconds / duration)))
                }
            }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            if let text = String(data: data, encoding: .utf8) { _ = notes.append(text) }
        }
        onProcess?(process)
        try process.run()
        process.waitUntilExit()
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        if cancelled() || process.terminationReason == .uncaughtSignal {
            throw MovieError.cancelled
        }
        guard process.terminationStatus == 0 else {
            let message = notes.value.trimmingCharacters(in: .whitespacesAndNewlines)
            throw MovieError.unreadable(message.isEmpty ? "Could not convert the video." : message)
        }
    }

    private static func lines(_ text: String) -> (lines: [String], rest: String)? {
        guard text.contains("\n") else { return nil }
        var parts = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let rest = text.hasSuffix("\n") ? "" : (parts.popLast() ?? "")
        return (parts, rest)
    }

    /// ffmpeg writes `out_time_ms` in microseconds.
    private static func seconds(fromProgress line: String) -> Double? {
        let fields = ["out_time_us=", "out_time_ms="]
        for field in fields where line.hasPrefix(field) {
            let raw = line.dropFirst(field.count)
            guard let value = Double(raw) else { return nil }
            return value / 1_000_000
        }
        return nil
    }
}

private final class LockedText {
    private let lock = NSLock()
    private var text = ""

    func append(_ chunk: String) -> String {
        lock.lock()
        text += chunk
        let copy = text
        lock.unlock()
        return copy
    }

    func set(_ value: String) {
        lock.lock()
        text = value
        lock.unlock()
    }

    var value: String {
        lock.lock()
        defer { lock.unlock() }
        return text
    }
}

final class StillGrabber {
    private let generator: AVAssetImageGenerator

    init(url: URL, exact: Bool) {
        let generator = AVAssetImageGenerator(asset: MovieProbe.asset(url: url))
        generator.appliesPreferredTrackTransform = true
        let slack: CMTime = exact ? .zero : CMTime(seconds: 0.12, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = slack
        generator.requestedTimeToleranceAfter = slack
        self.generator = generator
    }

    func frame(at seconds: Double, longEdge: Int) throws -> FrameBuffer {
        let edge = max(2, longEdge)
        generator.maximumSize = CGSize(width: edge, height: edge)
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        let image: CGImage
        do {
            image = try generator.copyCGImage(at: time, actualTime: nil)
        } catch {
            throw MovieError.unreadable(error.localizedDescription)
        }
        return FrameBuffer.from(cgImage: image)
    }
}

final class OrientedReader {
    private let reader: AVAssetReader?
    private let output: AVAssetReaderVideoCompositionOutput?

    /// `start` is seconds from the beginning of the clip. Frames are upright,
    /// rendered at `renderWidth` × `renderHeight`, one per `frameDuration`.
    /// Pass A's frame duration for both clips so the pair shares a clock.
    /// A start past the end yields a reader whose `next()` is immediately nil.
    init(
        facts: ClipFacts,
        renderWidth: Int,
        renderHeight: Int,
        frameDuration: CMTime,
        start: CMTime
    ) throws {
        let clipEnd = CMTimeAdd(facts.rangeStart, facts.rangeDuration)
        let begin = CMTimeAdd(facts.rangeStart, CMTimeMaximum(start, .zero))
        let remaining = CMTimeSubtract(clipEnd, begin)
        guard remaining.isValid, remaining.seconds > 0.0005 else {
            self.reader = nil
            self.output = nil
            return
        }

        let asset = MovieProbe.asset(url: facts.url)
        let tracks = try Sync.value { try await asset.loadTracks(withMediaType: .video) }
        guard let track = tracks.first else { throw MovieError.noVideo(facts.displayName) }
        let natural = try Sync.value { try await track.load(.naturalSize) }
        let preferred = try Sync.value { try await track.load(.preferredTransform) }

        let render = CGSize(width: max(2, renderWidth), height: max(2, renderHeight))
        let composition = AVMutableVideoComposition()
        composition.renderSize = render
        composition.frameDuration = frameDuration
        composition.renderScale = 1

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: begin, duration: remaining)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        let transform = VideoGeometry.uprightTransform(natural: natural, preferred: preferred, render: render)
        layer.setTransform(transform, at: begin)
        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]

        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: settings)
        output.videoComposition = composition
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw MovieError.unreadable("Could not read frames from \(facts.displayName).")
        }
        reader.add(output)
        reader.timeRange = instruction.timeRange
        guard reader.startReading() else {
            throw MovieError.unreadable(reader.error?.localizedDescription ?? "Could not start reading \(facts.displayName).")
        }
        self.reader = reader
        self.output = output
    }

    func next() -> FrameBuffer? {
        guard let reader, let output, reader.status == .reading,
              let sample = output.copyNextSampleBuffer(),
              let buffer = CMSampleBufferGetImageBuffer(sample),
              let frame = FrameBuffer.from(pixelBuffer: buffer) else { return nil }
        return frame
    }

    func cancel() {
        reader?.cancelReading()
    }
}

struct PCMClip {
    var samples: [Int16]
    var sampleRate: Double
    var channels: Int
}

final class MovieWriter {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audioInput: AVAssetWriterInput?
    let width: Int
    let height: Int

    init(
        url: URL,
        width: Int,
        height: Int,
        codec: PixelCodec,
        transform: CGAffineTransform = .identity,
        audio: PCMClip? = nil
    ) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var settings: [String: Any] = [
            AVVideoCodecKey: codec.avType,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        if codec == .h264 {
            let bitrate = min(100_000_000, max(12_000_000, width * height * 8))
            settings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: 30,
            ]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        input.transform = transform
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: attributes
        )
        guard writer.canAdd(input) else { throw MovieError.writer("Could not add a video track.") }
        writer.add(input)
        var audioInput: AVAssetWriterInput?
        if let audio, !audio.samples.isEmpty {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: audio.sampleRate,
                AVNumberOfChannelsKey: audio.channels,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            let sound = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            sound.expectsMediaDataInRealTime = false
            guard writer.canAdd(sound) else { throw MovieError.writer("Could not add a sound track.") }
            writer.add(sound)
            audioInput = sound
        }
        guard writer.startWriting() else {
            throw MovieError.writer(writer.error?.localizedDescription ?? "Could not start writing.")
        }
        writer.startSession(atSourceTime: .zero)
        self.writer = writer
        self.input = input
        self.adaptor = adaptor
        self.audioInput = audioInput
        self.width = width
        self.height = height
    }

    func append(_ frame: FrameBuffer, at time: CMTime) throws {
        let frame = frame.fitted(to: (width, height))
        try waitUntilReady(input)
        var pixel: CVPixelBuffer?
        let status: CVReturn
        if let pool = adaptor.pixelBufferPool {
            status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel)
        } else {
            status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pixel)
        }
        guard status == kCVReturnSuccess, let pixel else {
            throw MovieError.writer("Could not allocate a frame.")
        }
        CVPixelBufferLockBaseAddress(pixel, [])
        defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixel) else {
            throw MovieError.writer("Could not lock a frame.")
        }
        let rowBytes = CVPixelBufferGetBytesPerRow(pixel)
        frame.bytes.withUnsafeBytes { raw in
            guard let srcBase = raw.baseAddress else { return }
            let src = srcBase.assumingMemoryBound(to: UInt8.self)
            let dst = base.assumingMemoryBound(to: UInt8.self)
            let tight = width * 4
            if rowBytes == tight {
                memcpy(dst, src, tight * height)
            } else {
                for y in 0..<height {
                    memcpy(dst + y * rowBytes, src + y * tight, tight)
                }
            }
        }
        if !adaptor.append(pixel, withPresentationTime: time) {
            throw MovieError.writer(writer.error?.localizedDescription ?? "Could not append a frame.")
        }
    }

    func append(_ pcm: PCMClip) throws {
        guard let audioInput else { return }
        let buffer = try PCMSamples.buffer(from: pcm)
        try waitUntilReady(audioInput)
        if !audioInput.append(buffer) {
            throw MovieError.writer(writer.error?.localizedDescription ?? "Could not append sound.")
        }
    }

    /// A failed writer reports not-ready forever. Surface that error instead of waiting out the stall timeout.
    private func waitUntilReady(_ input: AVAssetWriterInput) throws {
        var spins = 0
        while !input.isReadyForMoreMediaData {
            if writer.status == .failed {
                throw MovieError.writer(writer.error?.localizedDescription ?? "The encoder failed.")
            }
            spins += 1
            if spins > 5000 { throw MovieError.writer("The encoder stalled.") }
            Thread.sleep(forTimeInterval: 0.002)
        }
    }

    func finish(end: CMTime) throws {
        writer.endSession(atSourceTime: end)
        input.markAsFinished()
        audioInput?.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        while sem.wait(timeout: .now()) == .timedOut {
            RunLoop.current.run(mode: .common, before: Date(timeIntervalSinceNow: 0.02))
        }
        if writer.status != .completed {
            throw MovieError.writer(writer.error?.localizedDescription ?? "Could not finish the movie.")
        }
    }

    static func write(
        frames: [FrameBuffer],
        fps: Int32,
        to url: URL,
        codec: PixelCodec,
        transform: CGAffineTransform = .identity,
        audio: PCMClip? = nil
    ) throws {
        guard let first = frames.first, first.width > 0, first.height > 0 else { throw MovieError.empty }
        let writer = try MovieWriter(
            url: url,
            width: first.width,
            height: first.height,
            codec: codec,
            transform: transform,
            audio: audio
        )
        for (index, frame) in frames.enumerated() {
            let time = CMTime(value: CMTimeValue(index), timescale: fps)
            try writer.append(frame, at: time)
        }
        if let audio {
            try writer.append(audio)
        }
        try writer.finish(end: CMTime(value: CMTimeValue(frames.count), timescale: fps))
    }
}

struct ExportRequest {
    var clipA: URL
    var clipB: URL
    var output: URL
    var mode: PlaceMode
    var mix: PictureMix = .identity
    /// Stop at the shorter clip. Off keeps A's full length, and the tail after B is A.
    var matchLengths: Bool = false
    var longEdge: Int
    var audio: SoundMode
    var codec: PixelCodec = .h264
}

struct ExportResult {
    var width: Int
    var height: Int
    var frames: Int
    var audio: Bool
    var framesPerSecond: Double
}

enum MovieExport {
    static func run(
        _ request: ExportRequest,
        progress: @escaping (Double) -> Void,
        cancelled: @escaping () -> Bool
    ) throws -> ExportResult {
        if OutputGuard.collides(request.output, sources: [request.clipA, request.clipB]) {
            throw MovieError.overwrite
        }
        let openedA = try MovieIntake.open(request.clipA, cancelled: cancelled)
        defer { if let temporary = openedA.temporary { try? FileManager.default.removeItem(at: temporary) } }
        let openedB = try MovieIntake.open(request.clipB, cancelled: cancelled)
        defer { if let temporary = openedB.temporary { try? FileManager.default.removeItem(at: temporary) } }
        let factsA = openedA.facts
        let factsB = openedB.facts
        let canvas = FrameSize.capped(
            width: factsA.orientedWidth,
            height: factsA.orientedHeight,
            longEdge: request.longEdge
        )
        let bSize = FrameSize.capped(
            width: factsB.orientedWidth,
            height: factsB.orientedHeight,
            longEdge: request.longEdge
        )
        let soundMode: SoundMode = {
            switch request.audio {
            case .off:
                return .off
            case .fromA:
                return factsA.hasAudio ? .fromA : .off
            case .xor:
                return (factsA.hasAudio || factsB.hasAudio) ? .xor : .off
            }
        }()
        let files = FileManager.default
        let staging = request.output.deletingLastPathComponent()
            .appendingPathComponent(".moire-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: staging) }

        let picture = staging.appendingPathComponent("picture.mov")
        let withSound = staging.appendingPathComponent("with-sound.mov")
        let wantsAudio = soundMode != .off
        let frames = try writePicture(
            factsA: factsA,
            factsB: factsB,
            canvas: canvas,
            bSize: bSize,
            mode: request.mode,
            mix: request.mix,
            matchLengths: request.matchLengths,
            codec: request.codec,
            to: picture,
            progress: { value in progress(wantsAudio ? value * 0.9 : value) },
            cancelled: cancelled
        )

        var audio = false
        if soundMode == .fromA {
            do {
                try SoundMux.attach(audioFrom: factsA.url, toVideo: picture, destination: withSound)
                audio = true
            } catch {
                // Keep the completed picture if Clip A's audio cannot be attached.
            }
        } else if soundMode == .xor {
            let caf = staging.appendingPathComponent("xor.caf")
            let wrote = try AudioXOR.render(
                clipA: factsA.url,
                clipB: factsB.url,
                startA: factsA.rangeStart,
                startB: factsB.rangeStart,
                duration: MovieSpan.time(a: factsA, b: factsB, match: request.matchLengths),
                to: caf,
                cancelled: cancelled,
                progress: { fraction in progress(0.9 + 0.1 * fraction) }
            )
            if wrote {
                try SoundMux.attachPCM(audioFrom: caf, toVideo: picture, destination: withSound)
                audio = true
            }
        }

        if cancelled() { throw MovieError.cancelled }
        let movie = audio ? withSound : picture
        // A same-volume rename replaces an existing file only after export succeeds.
        guard Darwin.rename(movie.path, request.output.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: request.output.path])
        }
        return ExportResult(
            width: canvas.0,
            height: canvas.1,
            frames: frames,
            audio: audio,
            framesPerSecond: factsA.framesPerSecond
        )
    }

    private static func writePicture(
        factsA: ClipFacts,
        factsB: ClipFacts,
        canvas: (Int, Int),
        bSize: (Int, Int),
        mode: PlaceMode,
        mix: PictureMix,
        matchLengths: Bool,
        codec: PixelCodec,
        to url: URL,
        progress: @escaping (Double) -> Void,
        cancelled: @escaping () -> Bool
    ) throws -> Int {
        if cancelled() { throw MovieError.cancelled }
        let readerA = try OrientedReader(
            facts: factsA,
            renderWidth: canvas.0,
            renderHeight: canvas.1,
            frameDuration: factsA.frameDuration,
            start: .zero
        )
        let readerB = try OrientedReader(
            facts: factsB,
            renderWidth: bSize.0,
            renderHeight: bSize.1,
            frameDuration: factsA.frameDuration,
            start: CMTime(seconds: BSampler.readerStart(from: 0, delay: mix.delay), preferredTimescale: 600)
        )
        defer {
            readerA.cancel()
            readerB.cancel()
        }
        let writer = try MovieWriter(url: url, width: canvas.0, height: canvas.1, codec: codec)
        let step = factsA.frameDuration
        let limit = MovieSpan.seconds(
            a: factsA.durationSeconds,
            b: factsB.durationSeconds,
            match: matchLengths
        )
        let estimated = max(1, Int((limit / max(step.seconds, 0.001)).rounded()))
        var index = 0
        var bOpen = true
        var sampler = BSampler(from: 0, delay: mix.delay)
        while true {
            if cancelled() { throw MovieError.cancelled }
            let shown = CMTimeMultiply(step, multiplier: Int32(index)).seconds
            if matchLengths, shown >= limit - 0.0005 { break }
            guard let rawA = readerA.next() else { break }
            let frameA = rawA.fitted(to: canvas)
            let frameB = placedB(
                open: &bOpen,
                sampler: &sampler,
                at: shown,
                read: { readerB.next() },
                canvas: canvas,
                mode: mode,
                mix: mix
            )
            let xor = FrameXOR.xor(frameA, frameB)
            let time = CMTimeMultiply(step, multiplier: Int32(index))
            try writer.append(xor, at: time)
            index += 1
            progress(min(1, Double(index) / Double(estimated)))
        }
        guard index > 0 else { throw MovieError.empty }
        try writer.finish(end: CMTimeMultiply(step, multiplier: Int32(index)))
        progress(1)
        return index
    }
}

enum SoundMux {
    static func attach(audioFrom source: URL, toVideo video: URL, destination: URL) throws {
        let videoAsset = MovieProbe.asset(url: video)
        let audioAsset = MovieProbe.asset(url: source)
        guard let videoTrack = try Sync.value({ try await videoAsset.loadTracks(withMediaType: .video).first }) else {
            throw MovieError.writer("The XOR movie has no picture.")
        }
        guard let audioTrack = try Sync.value({ try await audioAsset.loadTracks(withMediaType: .audio).first }) else {
            throw MovieError.writer("Clip A has no sound.")
        }
        let videoDuration = try Sync.value { try await videoAsset.load(.duration) }
        let audioDuration = try Sync.value { try await audioAsset.load(.duration) }
        let mix = AVMutableComposition()
        guard let picture = mix.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let sound = mix.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw MovieError.writer("Could not attach sound.") }
        try picture.insertTimeRange(CMTimeRange(start: .zero, duration: videoDuration), of: videoTrack, at: .zero)
        let use = CMTimeMinimum(videoDuration, audioDuration)
        try sound.insertTimeRange(CMTimeRange(start: .zero, duration: use), of: audioTrack, at: .zero)

        guard let session = AVAssetExportSession(asset: mix, presetName: AVAssetExportPresetPassthrough) else {
            throw MovieError.writer("Could not attach sound.")
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        session.outputURL = destination
        session.outputFileType = .mov
        let sem = DispatchSemaphore(value: 0)
        session.exportAsynchronously { sem.signal() }
        while sem.wait(timeout: .now()) == .timedOut {
            RunLoop.current.run(mode: .common, before: Date(timeIntervalSinceNow: 0.05))
        }
        guard session.status == .completed else {
            throw MovieError.writer(session.error?.localizedDescription ?? "Could not attach sound.")
        }
    }

    /// Copies the picture bitstream and a PCM soundtrack into one movie.
    /// Passthrough keeps the XOR frames exact. Both inputs are pulled as they
    /// become ready. Filling one track first makes the writer wait on the other,
    /// and a movie longer than a few seconds never finishes.
    static func attachPCM(audioFrom caf: URL, toVideo video: URL, destination: URL) throws {
        let videoAsset = MovieProbe.asset(url: video)
        let audioAsset = MovieProbe.asset(url: caf)
        guard let videoTrack = try Sync.value({ try await videoAsset.loadTracks(withMediaType: .video).first }) else {
            throw MovieError.writer("The XOR movie has no picture.")
        }
        guard let audioTrack = try Sync.value({ try await audioAsset.loadTracks(withMediaType: .audio).first }) else {
            throw MovieError.writer("The mixed sound could not be read.")
        }
        let videoHint = try Sync.value { try await videoTrack.load(.formatDescriptions).first }
        let audioHint = try Sync.value { try await audioTrack.load(.formatDescriptions).first }
        let duration = try Sync.value { try await videoAsset.load(.duration) }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        let mux = try PCMMovieMux(
            destination: destination,
            video: (videoAsset, videoTrack, videoHint),
            audio: (audioAsset, audioTrack, audioHint)
        )
        try mux.write(duration: duration)
    }
}

/// Once initialized, the AVFoundation objects and mutable state are used only
/// on the serial mux queue. The caller waits for completion before returning.
private final class PCMMovieMux: @unchecked Sendable {
    typealias Source = (AVAsset, AVAssetTrack, CMFormatDescription?)
    private static let writeError = "Could not attach the mixed sound."

    private final class Track {
        let reader: AVAssetReader
        let output: AVAssetReaderTrackOutput
        let input: AVAssetWriterInput
        var finished = false

        init(source: Source, mediaType: AVMediaType, writer: AVAssetWriter) throws {
            let (asset, track, hint) = source
            reader = try AVAssetReader(asset: asset)
            output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            input = AVAssetWriterInput(mediaType: mediaType, outputSettings: nil, sourceFormatHint: hint)
            output.alwaysCopiesSampleData = true
            input.expectsMediaDataInRealTime = false
            guard reader.canAdd(output), writer.canAdd(input) else {
                throw MovieError.writer(PCMMovieMux.writeError)
            }
            reader.add(output)
            writer.add(input)
        }
    }

    private let writer: AVAssetWriter
    private let picture: Track
    private let sound: Track
    private let queue = DispatchQueue(label: "com.tim.moire.mux")
    private let completed = DispatchSemaphore(value: 0)
    private var failure: MovieError?

    init(destination: URL, video: Source, audio: Source) throws {
        writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        picture = try Track(source: video, mediaType: .video, writer: writer)
        sound = try Track(source: audio, mediaType: .audio, writer: writer)
    }

    func write(duration: CMTime) throws {
        try queue.sync {
            guard writer.startWriting(), picture.reader.startReading(), sound.reader.startReading() else {
                let message = writer.error?.localizedDescription
                    ?? picture.reader.error?.localizedDescription
                    ?? sound.reader.error?.localizedDescription
                    ?? Self.writeError
                cancel()
                throw MovieError.writer(message)
            }
            writer.startSession(atSourceTime: .zero)
            picture.input.requestMediaDataWhenReady(on: queue) { [weak self] in
                guard let self else { return }
                self.pump(self.picture, duration: duration)
            }
            sound.input.requestMediaDataWhenReady(on: queue) { [weak self] in
                guard let self else { return }
                self.pump(self.sound, duration: duration)
            }
        }
        while completed.wait(timeout: .now() + .milliseconds(20)) == .timedOut {
            RunLoop.current.run(mode: .default, before: Date())
        }
        try queue.sync {
            if let failure { throw failure }
        }
    }

    private func pump(_ track: Track, duration: CMTime) {
        guard failure == nil, !track.finished else { return }
        while track.input.isReadyForMoreMediaData {
            if let sample = track.output.copyNextSampleBuffer() {
                guard track.input.append(sample) else {
                    fail(writer.error)
                    return
                }
            } else if track.reader.status == .failed || track.reader.status == .cancelled {
                fail(track.reader.error)
                return
            } else {
                track.finished = true
                track.input.markAsFinished()
                if picture.finished && sound.finished {
                    writer.endSession(atSourceTime: duration)
                    writer.finishWriting { [self] in
                        queue.async { [self] in
                            if writer.status != .completed {
                                failure = .writer(writer.error?.localizedDescription ?? Self.writeError)
                            }
                            completed.signal()
                        }
                    }
                }
                return
            }
        }
    }

    private func fail(_ error: Error?) {
        failure = .writer(error?.localizedDescription ?? Self.writeError)
        cancel()
        completed.signal()
    }

    private func cancel() {
        if picture.reader.status == .reading { picture.reader.cancelReading() }
        if sound.reader.status == .reading { sound.reader.cancelReading() }
        if writer.status == .writing { writer.cancelWriting() }
    }
}

enum PCMSamples {
    static func buffer(from clip: PCMClip) throws -> CMSampleBuffer {
        let channels = max(1, clip.channels)
        guard clip.sampleRate >= 1, clip.sampleRate <= 192_000 else {
            throw MovieError.writer("That sample rate cannot be written.")
        }
        guard clip.samples.count % channels == 0 else {
            throw MovieError.writer("The sound does not fill a whole frame.")
        }
        let frames = clip.samples.count / channels
        var asbd = AudioStreamBasicDescription(
            mSampleRate: clip.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: UInt32(channels * 2),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(channels * 2),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        let described = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format
        )
        guard described == noErr, let format else {
            throw MovieError.writer("Could not describe the sound.")
        }
        let byteCount = clip.samples.count * MemoryLayout<Int16>.size
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &block
        )
        guard status == kCMBlockBufferNoErr, let block else {
            throw MovieError.writer("Could not store the sound.")
        }
        status = clip.samples.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return kCMBlockBufferBadCustomBlockSourceErr }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        guard status == kCMBlockBufferNoErr else {
            throw MovieError.writer("Could not store the sound.")
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(clip.sampleRate.rounded())),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        let made = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: frames,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sample
        )
        guard made == noErr, let sample else {
            throw MovieError.writer("Could not store the sound.")
        }
        return sample
    }
}

enum AudioXOR {
    struct Layout {
        var sampleRate: Double
        var channels: Int
    }

    /// Length follows `a`. Missing `b` samples are silence, so the tail stays `a`.
    /// Samples past `a` are dropped. The movie clock is A.
    static func combine(_ a: [Int16], _ b: [Int16]) -> [Int16] {
        if b.isEmpty { return a }
        var out = a
        let shared = min(a.count, b.count)
        for index in 0..<shared {
            out[index] = a[index] ^ b[index]
        }
        return out
    }

    static func layout(of url: URL) throws -> Layout? {
        let asset = MovieProbe.asset(url: url)
        let tracks = try Sync.value { try await asset.loadTracks(withMediaType: .audio) }
        guard let track = tracks.first else { return nil }
        let descriptions = try Sync.value { try await track.load(.formatDescriptions) }
        guard let description = descriptions.first,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
        else { return nil }
        let rate = asbd.mSampleRate
        let channels = Int(asbd.mChannelsPerFrame)
        guard rate > 0, channels >= 1 else { return nil }
        return Layout(sampleRate: min(rate, 192_000), channels: min(channels, 8))
    }

    /// Writes interleaved 16-bit PCM to a CAF. Used to build a soundtrack the muxer can copy.
    static func store(_ clip: PCMClip, to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let channels = max(1, clip.channels)
        guard clip.sampleRate >= 1, clip.samples.count % channels == 0 else {
            throw MovieError.writer("Could not store the sound.")
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: clip.sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
        guard file.processingFormat.commonFormat == .pcmFormatInt16, file.processingFormat.isInterleaved else {
            throw MovieError.writer("Could not store 16-bit sound.")
        }
        try write(clip.samples, frames: clip.samples.count / channels, format: file.processingFormat, file: file)
    }

    /// Writes a 16-bit CAF of A XOR B across `duration`, starting each clip at its own media time.
    /// Returns false when neither clip has a soundtrack.
    static func render(
        clipA: URL,
        clipB: URL,
        startA: CMTime,
        startB: CMTime,
        duration: CMTime,
        to url: URL,
        cancelled: @escaping () -> Bool = { false },
        progress: @escaping (Double) -> Void = { _ in }
    ) throws -> Bool {
        if cancelled() { throw MovieError.cancelled }
        let layoutA = try layout(of: clipA)
        let layoutB = try layout(of: clipB)
        guard let layout = layoutA ?? layoutB else { return false }
        let seconds = duration.seconds
        guard seconds.isFinite, seconds > 0 else { throw MovieError.empty }
        let totalFrames = Int((seconds * layout.sampleRate).rounded())
        guard totalFrames > 0 else { return false }

        let pullA = try PCMPuller(url: clipA, layout: layout, start: startA, duration: duration)
        let pullB = try PCMPuller(url: clipB, layout: layout, start: startB, duration: duration)
        defer {
            pullA?.cancel()
            pullB?.cancel()
        }
        let streamA = Stream(puller: pullA, layout: layout, origin: startA)
        let streamB = Stream(puller: pullB, layout: layout, origin: startB)

        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: layout.sampleRate,
            AVNumberOfChannelsKey: layout.channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
        guard file.processingFormat.commonFormat == .pcmFormatInt16, file.processingFormat.isInterleaved else {
            throw MovieError.writer("Could not store 16-bit sound.")
        }
        let format = file.processingFormat
        let chunkFrames = 8192
        var written = 0
        while written < totalFrames {
            if cancelled() { throw MovieError.cancelled }
            let count = min(chunkFrames, totalFrames - written)
            var mixed = [Int16](repeating: 0, count: count * layout.channels)
            streamA.xor(into: &mixed, chunkStart: written)
            streamB.xor(into: &mixed, chunkStart: written)
            try write(mixed, frames: count, format: format, file: file)
            written += count
            progress(min(1, Double(written) / Double(totalFrames)))
        }
        progress(1)
        return true
    }

    static func read(url: URL, sampleRate: Double, channels: Int) throws -> [Int16] {
        let layout = Layout(sampleRate: sampleRate, channels: channels)
        guard let puller = try PCMPuller(
            url: url,
            layout: layout,
            start: .zero,
            duration: CMTime(seconds: 60 * 60, preferredTimescale: 600)
        ) else { return [] }
        defer { puller.cancel() }
        var all: [Int16] = []
        while let packet = puller.nextPacket() {
            all.append(contentsOf: packet.samples)
            if all.count > 20_000_000 { break }
        }
        return all
    }

    private static func write(_ samples: [Int16], frames: Int, format: AVAudioFormat, file: AVAudioFile) throws {
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { throw MovieError.writer("Could not store the sound.") }
        buffer.frameLength = AVAudioFrameCount(frames)
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard let destination = list.first?.mData else {
            throw MovieError.writer("Could not store the sound.")
        }
        samples.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            destination.copyMemory(from: base, byteCount: raw.count)
        }
        try file.write(from: buffer)
    }

    private final class Stream {
        let puller: PCMPuller?
        let channels: Int
        let rate: Double
        let origin: CMTime
        private var packetStart = 0
        private var packet: [Int16] = []
        private var exhausted: Bool

        init(puller: PCMPuller?, layout: Layout, origin: CMTime) {
            self.puller = puller
            channels = layout.channels
            rate = layout.sampleRate
            self.origin = origin
            exhausted = puller == nil
        }

        func xor(into buffer: inout [Int16], chunkStart: Int) {
            let chunkFrames = buffer.count / channels
            let chunkEnd = chunkStart + chunkFrames
            while true {
                prepare()
                if exhausted || packet.isEmpty { return }
                let packetFrames = packet.count / channels
                let packetEnd = packetStart + packetFrames
                if packetEnd <= chunkStart {
                    packet = []
                    continue
                }
                if packetStart >= chunkEnd { return }
                let from = max(packetStart, chunkStart)
                let to = min(packetEnd, chunkEnd)
                let packetOffset = (from - packetStart) * channels
                let bufferOffset = (from - chunkStart) * channels
                let count = (to - from) * channels
                for index in 0..<count {
                    buffer[bufferOffset + index] ^= packet[packetOffset + index]
                }
                if packetEnd <= chunkEnd {
                    packet = []
                } else {
                    packet.removeFirst(packetOffset + count)
                    packetStart = to
                    return
                }
            }
        }

        private func prepare() {
            if exhausted || !packet.isEmpty { return }
            guard let puller, let next = puller.nextPacket() else {
                exhausted = true
                return
            }
            let delta = CMTimeSubtract(next.presentation, origin)
            let seconds = delta.isValid ? delta.seconds : 0
            let frame = seconds.isFinite ? Int((seconds * rate).rounded()) : 0
            packetStart = max(0, frame)
            let usable = next.samples.count - next.samples.count % channels
            packet = usable == next.samples.count ? next.samples : Array(next.samples.prefix(usable))
        }
    }
}

private final class PCMPuller {
    struct Packet {
        var presentation: CMTime
        var samples: [Int16]
    }

    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private var finished = false

    init?(url: URL, layout: AudioXOR.Layout, start: CMTime, duration: CMTime) throws {
        let asset = MovieProbe.asset(url: url)
        let tracks = try Sync.value { try await asset.loadTracks(withMediaType: .audio) }
        guard let track = tracks.first else { return nil }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: layout.sampleRate,
            AVNumberOfChannelsKey: layout.channels,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = true
        let reader = try AVAssetReader(asset: asset)
        let begin = start.isValid ? start : .zero
        let span = duration.isValid && duration.seconds > 0 ? duration : CMTime(seconds: 60 * 60, preferredTimescale: 600)
        reader.timeRange = CMTimeRange(start: begin, duration: span)
        guard reader.canAdd(output) else { throw MovieError.writer("Could not read the sound.") }
        reader.add(output)
        guard reader.startReading() else {
            throw MovieError.writer(reader.error?.localizedDescription ?? "Could not read the sound.")
        }
        self.reader = reader
        self.output = output
    }

    func nextPacket() -> Packet? {
        if finished { return nil }
        guard reader.status == .reading, let sample = output.copyNextSampleBuffer() else {
            finished = true
            return nil
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let samples = Self.samples(from: sample)
        if samples.isEmpty { return nextPacket() }
        return Packet(presentation: pts.isValid ? pts : .zero, samples: samples)
    }

    func cancel() {
        reader.cancelReading()
    }

    private static func samples(from sample: CMSampleBuffer) -> [Int16] {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return [] }
        let length = CMBlockBufferGetDataLength(block)
        guard length >= 2 else { return [] }
        let count = length - length % 2
        var bytes = [UInt8](repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return kCMBlockBufferBadCustomBlockSourceErr }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count, destination: base)
        }
        guard status == kCMBlockBufferNoErr else { return [] }
        var samples = [Int16](repeating: 0, count: count / 2)
        samples.withUnsafeMutableBytes { destination in
            bytes.withUnsafeBytes { source in
                destination.copyMemory(from: source)
            }
        }
        return samples
    }
}

enum SampleScene {
    static func writePair(to directory: URL, codec: PixelCodec = .proRes4444) throws -> (URL, URL) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let aURL = directory.appendingPathComponent("moire-a.mov")
        let bURL = directory.appendingPathComponent("moire-b.mov")
        let count = 24
        let width = 160
        let height = 90
        var framesA: [FrameBuffer] = []
        var framesB: [FrameBuffer] = []
        for index in 0..<count {
            var a = FrameBuffer(width: width, height: height)
            var b = FrameBuffer(width: width, height: height)
            let travel = max(1, count - 1)
            let ax = (width - 36) * index / travel
            let by = (height - 36) * index / travel
            a.fill(x: ax, y: 27, w: 36, h: 36, b: 0, g: 0, r: 255)
            b.fill(x: 62, y: by, w: 36, h: 36, b: 255, g: 0, r: 0)
            framesA.append(a)
            framesB.append(b)
        }
        try MovieWriter.write(frames: framesA, fps: 12, to: aURL, codec: codec)
        try MovieWriter.write(frames: framesB, fps: 12, to: bURL, codec: codec)
        return (aURL, bURL)
    }
}

enum FrameReadback {
    static func all(url: URL) throws -> [FrameBuffer] {
        let facts = try MovieProbe.facts(url: url)
        let reader = try OrientedReader(
            facts: facts,
            renderWidth: facts.orientedWidth,
            renderHeight: facts.orientedHeight,
            frameDuration: facts.frameDuration,
            start: .zero
        )
        defer { reader.cancel() }
        var frames: [FrameBuffer] = []
        while let frame = reader.next() {
            frames.append(frame)
            if frames.count > 600 { break }
        }
        return frames
    }
}
