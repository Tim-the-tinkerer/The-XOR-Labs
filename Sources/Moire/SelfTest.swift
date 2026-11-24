import CoreGraphics
import CoreMedia
import Foundation

enum SelfTest {
    static func run() -> String? {
        let checks: [() -> String?] = [
            xorBytes,
            xorInverse,
            placeRects,
            placePixels,
            pictureMix,
            span,
            geometry,
            evenSize,
            frameRate,
            names,
            guardPaths,
            audioSamples,
            longXorSound,
            containers,
            movieRoundTrip,
        ]
        for check in checks {
            if let error = check() { return error }
        }
        return nil
    }

    private static func xorBytes() -> String? {
        var a = FrameBuffer(width: 1, height: 1)
        var b = FrameBuffer(width: 1, height: 1)
        a.set(x: 0, y: 0, b: 0, g: 0, r: 255)
        b.set(x: 0, y: 0, b: 255, g: 0, r: 0)
        let xor = FrameXOR.xor(a, b)
        let pixel = xor.bgra(x: 0, y: 0)
        if pixel != (255, 0, 255, 255) {
            return "red XOR blue is \(pixel), expected magenta"
        }
        var same = FrameBuffer(width: 1, height: 1)
        same.set(x: 0, y: 0, b: 10, g: 20, r: 30)
        let black = FrameXOR.xor(same, same)
        if black.bgra(x: 0, y: 0) != (0, 0, 0, 255) {
            return "a frame XOR itself should be black, got \(black.bgra(x: 0, y: 0))"
        }
        let kept = FrameXOR.xor(a, FrameBuffer(width: 1, height: 1))
        if kept.bgra(x: 0, y: 0) != (0, 0, 255, 255) {
            return "A XOR black should keep A, got \(kept.bgra(x: 0, y: 0))"
        }
        return nil
    }

    private static func xorInverse() -> String? {
        var a = FrameBuffer(width: 2, height: 2)
        var b = FrameBuffer(width: 2, height: 2)
        a.set(x: 0, y: 0, b: 1, g: 2, r: 3)
        a.set(x: 1, y: 1, b: 200, g: 10, r: 40)
        b.set(x: 0, y: 0, b: 255, g: 128, r: 7)
        b.set(x: 1, y: 1, b: 9, g: 8, r: 7)
        let forth = FrameXOR.xor(a, b)
        let back = FrameXOR.xor(forth, b)
        if back.bgra(x: 0, y: 0) != a.bgra(x: 0, y: 0) || back.bgra(x: 1, y: 1) != a.bgra(x: 1, y: 1) {
            return "XOR is not its own inverse"
        }
        let swapped = FrameXOR.xor(b, a)
        if swapped.bgra(x: 0, y: 0) != forth.bgra(x: 0, y: 0) {
            return "XOR should be commutative"
        }
        return nil
    }

    private static func placeRects() -> String? {
        let fit = Placement.rect(source: (100, 50), canvas: (200, 200), mode: .fit)
        if fit != PlacedRect(originX: 0, originY: 50, width: 200, height: 100) {
            return "fit 100×50 into 200×200 is \(fit)"
        }
        let fill = Placement.rect(source: (100, 50), canvas: (200, 200), mode: .fill)
        if fill != PlacedRect(originX: -100, originY: 0, width: 400, height: 200) {
            return "fill 100×50 into 200×200 is \(fill)"
        }
        let stretch = Placement.rect(source: (100, 50), canvas: (200, 200), mode: .stretch)
        if stretch != PlacedRect(originX: 0, originY: 0, width: 200, height: 200) {
            return "stretch is \(stretch)"
        }
        let lock = Placement.rect(source: (100, 50), canvas: (200, 200), mode: .lock)
        if lock != PlacedRect(originX: 50, originY: 75, width: 100, height: 50) {
            return "lock is \(lock)"
        }
        let fitSmall = Placement.rect(source: (200, 200), canvas: (100, 50), mode: .fit)
        if fitSmall != PlacedRect(originX: 25, originY: 0, width: 50, height: 50) {
            return "fit 200×200 into 100×50 is \(fitSmall)"
        }
        let fillSmall = Placement.rect(source: (200, 200), canvas: (100, 50), mode: .fill)
        if fillSmall != PlacedRect(originX: 0, originY: -25, width: 100, height: 100) {
            return "fill 200×200 into 100×50 is \(fillSmall)"
        }
        return nil
    }

    private static func placePixels() -> String? {
        var source = FrameBuffer(width: 100, height: 50)
        source.fill(x: 0, y: 0, w: 100, h: 50, b: 0, g: 0, r: 255)
        let fit = FrameXOR.place(source, ontoWidth: 200, ontoHeight: 200, mode: .fit)
        if fit.bgra(x: 0, y: 0).2 != 0 { return "fit letterbox should stay black" }
        if fit.bgra(x: 100, y: 100).2 < 250 { return "fit bar should stay red" }
        if fit.bgra(x: 100, y: 160).2 != 0 { return "below the fit bar should stay black" }

        var tile = FrameBuffer(width: 10, height: 10)
        tile.fill(x: 0, y: 0, w: 10, h: 10, b: 0, g: 0, r: 255)
        let lock = FrameXOR.place(tile, ontoWidth: 30, ontoHeight: 20, mode: .lock)
        if lock.bgra(x: 0, y: 0).2 != 0 { return "lock gap should be black" }
        if lock.bgra(x: 10, y: 5).2 < 250 { return "lock origin should be red" }
        if lock.bgra(x: 19, y: 14).2 < 250 { return "lock far corner should be red" }
        if lock.bgra(x: 20, y: 5).2 != 0 { return "just outside the lock tile should be black" }
        return nil
    }

    private static func pictureMix() -> String? {
        var wide = FrameBuffer(width: 2, height: 3)
        wide.set(x: 0, y: 0, b: 0, g: 0, r: 255)
        wide.set(x: 1, y: 0, b: 0, g: 255, r: 0)
        wide.set(x: 0, y: 1, b: 255, g: 0, r: 0)
        wide.set(x: 1, y: 1, b: 255, g: 255, r: 255)
        wide.set(x: 0, y: 2, b: 255, g: 255, r: 0)
        wide.set(x: 1, y: 2, b: 255, g: 0, r: 255)
        let turned = wide.turned(.clockwise)
        if turned.width != 3 || turned.height != 2 { return "90° size is \(turned.width)×\(turned.height)" }
        if turned.bgra(x: 0, y: 0) != (255, 255, 0, 255) { return "90° top-left should be the old bottom-left" }
        if turned.bgra(x: 2, y: 0) != (0, 0, 255, 255) { return "90° top-right should be the old top-left" }
        if turned.bgra(x: 2, y: 1) != (0, 255, 0, 255) { return "90° bottom-right should be the old top-right" }
        let half = wide.turned(.half)
        if half.bgra(x: 1, y: 2) != (0, 0, 255, 255) { return "180° should put the old top-left at the bottom-right" }
        if half.bgra(x: 0, y: 0) != (255, 0, 255, 255) { return "180° should put the old bottom-right at the top-left" }
        let flipH = wide.mirrored(horizontal: true)
        if flipH.bgra(x: 0, y: 0) != (0, 255, 0, 255) { return "horizontal flip should swap the top edge" }
        let flipV = wide.mirrored(horizontal: false)
        if flipV.bgra(x: 0, y: 0) != (255, 255, 0, 255) { return "vertical flip should bring the bottom row to the top" }

        var tile = FrameBuffer(width: 10, height: 10)
        tile.fill(x: 0, y: 0, w: 10, h: 10, b: 0, g: 0, r: 255)
        var shrunk = PictureMix.identity
        shrunk.scale = 0.5
        let small = FrameXOR.place(tile, ontoWidth: 30, ontoHeight: 20, mode: .lock, mix: shrunk)
        if small.bgra(x: 10, y: 5).2 != 0 { return "a half-scale copy should leave the old corner black" }
        if small.bgra(x: 15, y: 10).2 < 250 { return "a half-scale copy should stay centered" }
        var slid = PictureMix.identity
        slid.offsetX = 0.2
        let moved = FrameXOR.place(tile, ontoWidth: 30, ontoHeight: 20, mode: .lock, mix: slid)
        if moved.bgra(x: 10, y: 5).2 != 0 { return "offset copy should leave the old origin black" }
        if moved.bgra(x: 16, y: 5).2 < 250 { return "offset copy should land 20% to the right" }

        var early = BSampler(from: 0, delay: 0.5)
        if case .hold = early.pull(at: 0, { FrameBuffer(width: 1, height: 1) }) {
        } else { return "the first delayed frame should stay A's picture" }
        if case .frame = early.pull(at: 0.5, { FrameBuffer(width: 1, height: 1) }) {
        } else { return "delay should release B at its mark" }
        if abs(BSampler.readerStart(from: 10, delay: 1) - 9) > 0.001 {
            return "a mid-clip delay should start B one second earlier"
        }

        return delayedMovie()
    }

    private static func span() -> String? {
        if MovieSpan.seconds(a: 10, b: 4, match: false) != 10 {
            return "an unmatched movie should keep A's length"
        }
        if MovieSpan.seconds(a: 10, b: 4, match: true) != 4 {
            return "matching should use the shorter clip when B is shorter"
        }
        if MovieSpan.seconds(a: 3, b: 9, match: true) != 3 {
            return "matching should use the shorter clip when A is shorter"
        }
        if MovieSpan.seconds(a: 5, b: 5, match: true) != 5 {
            return "matching equal clips should leave the length alone"
        }
        return nil
    }

    private static func delayedMovie() -> String? {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoireDelay-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            var red = FrameBuffer(width: 16, height: 16)
            red.fill(x: 0, y: 0, w: 16, h: 16, b: 0, g: 0, r: 255)
            var blue = FrameBuffer(width: 16, height: 16)
            blue.fill(x: 0, y: 0, w: 16, h: 16, b: 255, g: 0, r: 0)
            let frames = 8
            let aURL = root.appendingPathComponent("delay-a.mov")
            let bURL = root.appendingPathComponent("delay-b.mov")
            let out = root.appendingPathComponent("delay-xor.mov")
            let codec: PixelCodec
            do {
                try MovieWriter.write(frames: Array(repeating: red, count: frames), fps: 8, to: aURL, codec: .proRes4444)
                try MovieWriter.write(frames: Array(repeating: blue, count: frames), fps: 8, to: bURL, codec: .proRes4444)
                codec = .proRes4444
            } catch {
                try MovieWriter.write(frames: Array(repeating: red, count: frames), fps: 8, to: aURL, codec: .h264)
                try MovieWriter.write(frames: Array(repeating: blue, count: frames), fps: 8, to: bURL, codec: .h264)
                codec = .h264
            }
            var mix = PictureMix.identity
            mix.delay = 0.5
            _ = try MovieExport.run(
                ExportRequest(clipA: aURL, clipB: bURL, output: out, mode: .stretch, mix: mix, longEdge: 32, audio: .off, codec: codec),
                progress: { _ in },
                cancelled: { false }
            )
            let read = try FrameReadback.all(url: out)
            if read.count < frames { return "delayed XOR wrote \(read.count) frames" }
            let slack = codec == .proRes4444 ? 18 : 40
            if let error = near(read[0].bgra(x: 8, y: 8), b: 0, g: 0, r: 255, slack: slack, "delayed first frame") {
                return error
            }
            if let error = near(read[read.count - 1].bgra(x: 8, y: 8), b: 255, g: 0, r: 255, slack: slack, "delayed last frame") {
                return error
            }
            return nil
        } catch {
            return "delayed XOR failed: \(error.localizedDescription)"
        }
    }

    private static func geometry() -> String? {
        let natural = CGSize(width: 100, height: 50)
        let scaled = VideoGeometry.uprightTransform(
            natural: natural,
            preferred: .identity,
            render: CGSize(width: 50, height: 25)
        )
        let far = CGPoint(x: 100, y: 50).applying(scaled)
        if abs(far.x - 50) > 0.01 || abs(far.y - 25) > 0.01 {
            return "identity scale landed at \(far)"
        }
        let origin = CGPoint.zero.applying(scaled)
        if abs(origin.x) > 0.01 || abs(origin.y) > 0.01 {
            return "identity origin landed at \(origin)"
        }

        let wide = CGSize(width: 1920, height: 1080)
        let turned = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0)
        let oriented = VideoGeometry.orientedPixelSize(natural: wide, transform: turned)
        if abs(oriented.width - 1080) > 0.5 || abs(oriented.height - 1920) > 0.5 {
            return "90° oriented size is \(oriented)"
        }
        let upright = VideoGeometry.uprightTransform(
            natural: wide,
            preferred: turned,
            render: CGSize(width: oriented.width, height: oriented.height)
        )
        let corners = [
            CGPoint.zero,
            CGPoint(x: wide.width, y: 0),
            CGPoint(x: 0, y: wide.height),
            CGPoint(x: wide.width, y: wide.height),
        ]
        for corner in corners {
            let point = corner.applying(upright)
            if point.x < -0.6 || point.y < -0.6 || point.x > oriented.width + 0.6 || point.y > oriented.height + 0.6 {
                return "rotated corner \(corner) landed outside at \(point)"
            }
        }
        return nil
    }

    private static func evenSize() -> String? {
        let hd = FrameSize.capped(width: 1920, height: 1080, longEdge: 960)
        if hd != (960, 540) { return "1920×1080 at 960 is \(hd)" }
        let odd = FrameSize.capped(width: 101, height: 50, longEdge: 10_000)
        if odd != (100, 50) { return "odd width became \(odd)" }
        let square = FrameSize.capped(width: 100, height: 100, longEdge: 30)
        if square != (30, 30) { return "100×100 at 30 is \(square)" }
        return nil
    }

    private static func frameRate() -> String? {
        let film = CMTime(value: 1001, timescale: 24000)
        let kept = VideoGeometry.frameDuration(minimum: film, nominal: 24)
        if kept != film { return "23.976 should be kept, got \(kept.seconds)" }
        let fast = CMTime(value: 1, timescale: 120)
        let clamped = VideoGeometry.frameDuration(minimum: fast, nominal: 120)
        if abs(clamped.seconds - (1.0 / 60.0)) > 0.0001 {
            return "120 fps should clamp to 60, got \(clamped.seconds)"
        }
        return nil
    }

    private static func names() -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = DateComponents(year: 2026, month: 11, day: 16, hour: 9, minute: 5, second: 7)
        guard let date = calendar.date(from: parts) else { return "could not build a stamp date" }
        let name = MovieNames.suggested(date: date)
        if name != "moire-20261116-090507.mov" { return "suggested name is \(name)" }
        let dropped = URL(fileURLWithPath: "/tmp/moire clip.mov")
        guard let parsed = DropURL.resolve(dropped.dataRepresentation), parsed.path == dropped.path else {
            return "a dropped file URL did not survive the pasteboard"
        }
        guard DropURL.resolve("file:///tmp/moire%20clip.mov")?.path == dropped.path else {
            return "a file URL string did not parse"
        }
        return nil
    }

    private static func guardPaths() -> String? {
        let a = URL(fileURLWithPath: "/tmp/moire-a.mov")
        let b = URL(fileURLWithPath: "/tmp/moire-b.mov")
        let out = URL(fileURLWithPath: "/tmp/moire-out.mov")
        if !OutputGuard.collides(a, sources: [a, b]) { return "should refuse to overwrite A" }
        if OutputGuard.collides(out, sources: [a, b]) { return "a new path should be allowed" }
        return nil
    }

    private static func containers() -> String? {
        guard ForeignMovie.ffmpeg() != nil else { return nil }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MoireContainerTest", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let webm = root.appendingPathComponent("tiny.webm")
            let mkv = root.appendingPathComponent("tiny.mkv")
            try encodeContainer(webm, video: ["-c:v", "libvpx-vp9", "-b:v", "200k", "-deadline", "realtime", "-cpu-used", "8"])
            try encodeContainer(mkv, video: ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-preset", "veryfast"])
            if let error = try openedContainer(webm, label: "webm") { return error }
            if let error = try openedContainer(mkv, label: "mkv") { return error }
            return nil
        } catch {
            let message = error.localizedDescription
            if message.contains("Unknown encoder") { return nil }
            return "container import failed: \(message)"
        }
    }

    private static func encodeContainer(_ url: URL, video: [String]) throws {
        guard let ffmpeg = ForeignMovie.ffmpeg() else { return }
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = [
            "-nostdin", "-y", "-hide_banner", "-loglevel", "error",
            "-f", "lavfi", "-i", "testsrc=size=160x90:rate=12:duration=0.5",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=0.5",
            "-shortest",
        ] + video + ["-c:a", "libopus", url.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw MovieError.unreadable(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func openedContainer(_ url: URL, label: String) throws -> String? {
        let opened = try MovieIntake.open(url)
        defer { if let temporary = opened.temporary { try? FileManager.default.removeItem(at: temporary) } }
        let facts = opened.facts
        if facts.orientedWidth != 160 || facts.orientedHeight != 90 {
            return "\(label) opened as \(facts.orientedWidth)×\(facts.orientedHeight), expected 160×90"
        }
        if !facts.hasAudio { return "\(label) lost its sound" }
        if facts.displayName != url.lastPathComponent { return "\(label) forgot its name" }
        let frame = try StillGrabber(url: facts.url, exact: true).frame(at: 0, longEdge: 160)
        if frame.width < 2 || frame.height < 2 { return "\(label) produced an empty frame" }
        return nil
    }

    private static func audioSamples() -> String? {
        if AudioXOR.combine([1000, 2000, 3000, -1], [1000, 0]) != [0, 2000, 3000, -1] {
            return "audio XOR tail should stay A"
        }
        if AudioXOR.combine([1000], [2000]) != [1080] {
            return "1000 XOR 2000 should be 1080"
        }
        if AudioXOR.combine([7, 8, 9], [7, 8, 9]) != [0, 0, 0] {
            return "identical samples should cancel"
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MoireAudioTest", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let rate = 8000.0
            let aSamples = (0..<1600).map { index -> Int16 in
                Int16((index * 17 + 1000) % 5000) - 2500
            }
            let bSamples = (0..<800).map { index -> Int16 in
                Int16((index * 29) % 4000) - 1000
            }
            var frame = FrameBuffer(width: 16, height: 16)
            frame.fill(x: 0, y: 0, w: 16, h: 16, b: 20, g: 0, r: 40)
            let frames = Array(repeating: frame, count: 4)
            let aURL = root.appendingPathComponent("tone-a.mov")
            let bURL = root.appendingPathComponent("tone-b.mov")
            let silentURL = root.appendingPathComponent("tone-silent.mov")
            let codec: PixelCodec
            do {
                try writeTone(frames, aSamples, rate, aURL, .proRes4444)
                try writeTone(frames, bSamples, rate, bURL, .proRes4444)
                try writeTone(frames, nil, rate, silentURL, .proRes4444)
                codec = .proRes4444
            } catch {
                try writeTone(frames, aSamples, rate, aURL, .h264)
                try writeTone(frames, bSamples, rate, bURL, .h264)
                try writeTone(frames, nil, rate, silentURL, .h264)
                codec = .h264
            }
            let storedA = try AudioXOR.read(url: aURL, sampleRate: rate, channels: 1)
            let storedB = try AudioXOR.read(url: bURL, sampleRate: rate, channels: 1)
            if let error = matchAudio(storedA, aSamples, "stored A") { return error }
            if let error = matchAudio(storedB, bSamples, "stored B") { return error }

            let facts = try MovieProbe.facts(url: aURL)
            let span = Int((facts.durationSeconds * rate).rounded())
            var clockA = storedA
            if clockA.count < span {
                clockA.append(contentsOf: Array(repeating: 0, count: span - clockA.count))
            } else if clockA.count > span {
                clockA = Array(clockA.prefix(span))
            }
            let mixed = AudioXOR.combine(clockA, storedB)

            let xorURL = root.appendingPathComponent("xor-audio.mov")
            let xor = try MovieExport.run(
                ExportRequest(clipA: aURL, clipB: bURL, output: xorURL, mode: .stretch, longEdge: 32, audio: .xor, codec: codec),
                progress: { _ in },
                cancelled: { false }
            )
            if !xor.audio { return "XOR export wrote no sound" }
            let heard = try AudioXOR.read(url: xorURL, sampleRate: rate, channels: 1)
            if let error = matchAudio(heard, mixed, "XOR sound") { return error }
            if mixed.count > 800, mixed[800] == 0, clockA[800] != 0 {
                return "XOR tail cancelled a sample that should have stayed A's"
            }

            let fromURL = root.appendingPathComponent("from-a.mov")
            let fromA = try MovieExport.run(
                ExportRequest(clipA: aURL, clipB: bURL, output: fromURL, mode: .stretch, longEdge: 32, audio: .fromA, codec: codec),
                progress: { _ in },
                cancelled: { false }
            )
            if !fromA.audio { return "Sound from A wrote no sound" }
            let kept = try AudioXOR.read(url: fromURL, sampleRate: rate, channels: 1)
            if let error = matchAudio(kept, clockA, "sound from A") { return error }

            let onlyURL = root.appendingPathComponent("only-a.mov")
            let only = try MovieExport.run(
                ExportRequest(clipA: aURL, clipB: silentURL, output: onlyURL, mode: .stretch, longEdge: 32, audio: .xor, codec: codec),
                progress: { _ in },
                cancelled: { false }
            )
            if !only.audio { return "XOR with a silent clip wrote no sound" }
            let onlyHeard = try AudioXOR.read(url: onlyURL, sampleRate: rate, channels: 1)
            if let error = matchAudio(onlyHeard, clockA, "XOR with silence") { return error }

            let sameURL = root.appendingPathComponent("same-audio.mov")
            _ = try MovieExport.run(
                ExportRequest(clipA: aURL, clipB: aURL, output: sameURL, mode: .stretch, longEdge: 32, audio: .xor, codec: codec),
                progress: { _ in },
                cancelled: { false }
            )
            let cancelled = try AudioXOR.read(url: sameURL, sampleRate: rate, channels: 1)
            if let error = matchAudio(cancelled, Array(repeating: 0, count: clockA.count), "identical sound") { return error }

            let quietURL = root.appendingPathComponent("quiet.mov")
            let quiet = try MovieExport.run(
                ExportRequest(clipA: silentURL, clipB: silentURL, output: quietURL, mode: .stretch, longEdge: 32, audio: .xor, codec: codec),
                progress: { _ in },
                cancelled: { false }
            )
            if quiet.audio { return "silent clips should not grow a soundtrack" }
            return nil
        } catch {
            return "audio XOR failed: \(error.localizedDescription)"
        }
    }

    /// A few seconds of picture plus XORed sound. Shorter exports fit in the writer's
    /// interleave window and hide a mux that stalls once one track gets ahead.
    private static func longXorSound() -> String? {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoireLongSound-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            var frame = FrameBuffer(width: 16, height: 16)
            frame.fill(x: 0, y: 0, w: 16, h: 16, b: 20, g: 0, r: 40)
            let frames = Array(repeating: frame, count: 120)
            let rate = 8000.0
            let count = 48_000
            let aSamples = (0..<count).map { Int16(($0 * 13 + 1000) % 5000) - 2500 }
            let bSamples = (0..<count).map { Int16(($0 * 29) % 4000) - 1000 }
            let aURL = try movieWithSound(frames, aSamples, rate, root.appendingPathComponent("long-a.mov"))
            let bURL = try movieWithSound(frames, bSamples, rate, root.appendingPathComponent("long-b.mov"))
            let out = root.appendingPathComponent("long-xor.mov")
            let result = try MovieExport.run(
                ExportRequest(clipA: aURL, clipB: bURL, output: out, mode: .stretch, longEdge: 32, audio: .xor, codec: .h264),
                progress: { _ in },
                cancelled: { false }
            )
            if !result.audio { return "long XOR export wrote no sound" }
            if result.frames < 100 { return "long XOR export wrote \(result.frames) frames" }
            let heard = try AudioXOR.read(url: out, sampleRate: rate, channels: 1)
            let mixed = AudioXOR.combine(aSamples, bSamples)
            if heard.count <= 40_000 { return "long XOR sound has \(heard.count) samples" }
            if heard[0] != mixed[0] || heard[40_000] != mixed[40_000] {
                return "long XOR sound diverged at the tail"
            }
            return nil
        } catch {
            return "long XOR sound failed: \(error.localizedDescription)"
        }
    }

    private static func movieWithSound(_ frames: [FrameBuffer], _ samples: [Int16], _ rate: Double, _ url: URL) throws -> URL {
        let picture = url.deletingLastPathComponent().appendingPathComponent("picture-\(UUID().uuidString).mov")
        let caf = url.deletingLastPathComponent().appendingPathComponent("sound-\(UUID().uuidString).caf")
        try MovieWriter.write(frames: frames, fps: 20, to: picture, codec: .h264)
        try AudioXOR.store(PCMClip(samples: samples, sampleRate: rate, channels: 1), to: caf)
        try SoundMux.attachPCM(audioFrom: caf, toVideo: picture, destination: url)
        return url
    }

    private static func writeTone(
        _ frames: [FrameBuffer],
        _ samples: [Int16]?,
        _ rate: Double,
        _ url: URL,
        _ codec: PixelCodec
    ) throws {
        let audio = samples.map { PCMClip(samples: $0, sampleRate: rate, channels: 1) }
        try MovieWriter.write(frames: frames, fps: 20, to: url, codec: codec, audio: audio)
    }

    private static func matchAudio(_ got: [Int16], _ want: [Int16], _ label: String) -> String? {
        if got.count < want.count {
            return "\(label) has \(got.count) samples, expected \(want.count)"
        }
        if got.count > want.count + 8 {
            return "\(label) has \(got.count) samples, expected \(want.count)"
        }
        for index in 0..<want.count where got[index] != want[index] {
            return "\(label) sample \(index) is \(got[index]), expected \(want[index])"
        }
        for index in want.count..<got.count where got[index] != 0 {
            return "\(label) extra sample \(index) is \(got[index]), expected silence"
        }
        return nil
    }

    private static func movieRoundTrip() -> String? {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoireSelfTest-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            return try roundTrip(in: root)
        } catch {
            try? FileManager.default.removeItem(at: root)
            return error.localizedDescription
        }
    }

    private static func roundTrip(in root: URL) throws -> String? {
        let codec = PixelCodec.proRes4444
        let halfURL = root.appendingPathComponent("half.mov")
        var half = FrameBuffer(width: 64, height: 48)
        half.fill(x: 0, y: 0, w: 64, h: 24, b: 0, g: 0, r: 255)
        half.fill(x: 0, y: 24, w: 64, h: 24, b: 255, g: 0, r: 0)
        try MovieWriter.write(frames: Array(repeating: half, count: 4), fps: 8, to: halfURL, codec: codec)

        let read = try FrameReadback.all(url: halfURL)
        if read.isEmpty { return "reader returned no frames" }
        if let error = near(read[0].bgra(x: 8, y: 4), b: 0, g: 0, r: 255, slack: 12, "top of readback") {
            return error
        }
        if let error = near(read[0].bgra(x: 8, y: 40), b: 255, g: 0, r: 0, slack: 12, "bottom of readback") {
            return error
        }

        let still = try StillGrabber(url: halfURL, exact: true).frame(at: 0, longEdge: 128)
        // The image generator's color transform shifts a pure primary by a few dozen levels.
        // Orientation is the check: the top stays red and the bottom stays blue.
        if let error = near(still.bgra(x: still.width / 2, y: 8), b: 0, g: 0, r: 255, slack: 48, "top of still") {
            return error
        }
        if let error = near(still.bgra(x: still.width / 2, y: max(0, still.height - 8)), b: 255, g: 0, r: 0, slack: 48, "bottom of still") {
            return error
        }

        let redURL = root.appendingPathComponent("red.mov")
        let blueURL = root.appendingPathComponent("blue.mov")
        let shortURL = root.appendingPathComponent("short.mov")
        var red = FrameBuffer(width: 64, height: 48)
        red.fill(x: 0, y: 0, w: 64, h: 48, b: 0, g: 0, r: 255)
        var blue = FrameBuffer(width: 64, height: 48)
        blue.fill(x: 0, y: 0, w: 64, h: 48, b: 255, g: 0, r: 0)
        try MovieWriter.write(frames: Array(repeating: red, count: 4), fps: 8, to: redURL, codec: codec)
        try MovieWriter.write(frames: Array(repeating: blue, count: 4), fps: 8, to: blueURL, codec: codec)
        try MovieWriter.write(frames: Array(repeating: blue, count: 2), fps: 8, to: shortURL, codec: codec)

        let mixedURL = root.appendingPathComponent("mixed.mov")
        let existing = Data("existing export".utf8)
        try existing.write(to: mixedURL)
        let request = ExportRequest(
            clipA: redURL, clipB: blueURL, output: mixedURL, mode: .stretch,
            longEdge: 128, audio: .off, codec: codec
        )
        var cancel = false
        do {
            _ = try MovieExport.run(request, progress: { _ in cancel = true }, cancelled: { cancel })
            return "cancelled export completed"
        } catch MovieError.cancelled {
            if try Data(contentsOf: mixedURL) != existing {
                return "cancelled export changed the existing file"
            }
        }
        let mixed = try MovieExport.run(request, progress: { _ in }, cancelled: { false })
        if mixed.frames < 3 { return "XOR export wrote \(mixed.frames) frames" }
        let mixedFrames = try FrameReadback.all(url: mixedURL)
        if mixedFrames.isEmpty { return "XOR export could not be read" }
        if let error = near(mixedFrames[0].bgra(x: 16, y: 16), b: 255, g: 0, r: 255, slack: 18, "red XOR blue") {
            return error
        }

        let sameURL = root.appendingPathComponent("same.mov")
        _ = try MovieExport.run(
            ExportRequest(clipA: redURL, clipB: redURL, output: sameURL, mode: .fit, longEdge: 128, audio: .off, codec: codec),
            progress: { _ in },
            cancelled: { false }
        )
        let sameFrames = try FrameReadback.all(url: sameURL)
        if sameFrames.isEmpty { return "identical XOR could not be read" }
        if let error = near(sameFrames[0].bgra(x: 16, y: 16), b: 0, g: 0, r: 0, slack: 12, "identical XOR") {
            return error
        }

        let tailURL = root.appendingPathComponent("tail.mov")
        _ = try MovieExport.run(
            ExportRequest(clipA: redURL, clipB: shortURL, output: tailURL, mode: .stretch, longEdge: 128, audio: .off, codec: codec),
            progress: { _ in },
            cancelled: { false }
        )
        let tail = try FrameReadback.all(url: tailURL)
        if tail.count < 3 { return "short B export returned \(tail.count) frames" }
        if let error = near(tail[0].bgra(x: 16, y: 16), b: 255, g: 0, r: 255, slack: 18, "tail first frame") {
            return error
        }
        if let error = near(tail[tail.count - 1].bgra(x: 16, y: 16), b: 0, g: 0, r: 255, slack: 18, "tail last frame") {
            return error
        }

        let matchedURL = root.appendingPathComponent("matched.mov")
        let matched = try MovieExport.run(
            ExportRequest(
                clipA: redURL,
                clipB: shortURL,
                output: matchedURL,
                mode: .stretch,
                matchLengths: true,
                longEdge: 128,
                audio: .off,
                codec: codec
            ),
            progress: { _ in },
            cancelled: { false }
        )
        if matched.frames != 2 {
            return "matched length wrote \(matched.frames) frames, expected 2"
        }
        let matchedFrames = try FrameReadback.all(url: matchedURL)
        if matchedFrames.isEmpty { return "matched movie could not be read" }
        if let error = near(matchedFrames[0].bgra(x: 16, y: 16), b: 255, g: 0, r: 255, slack: 18, "matched first frame") {
            return error
        }
        if let error = near(matchedFrames[matchedFrames.count - 1].bgra(x: 16, y: 16), b: 255, g: 0, r: 255, slack: 18, "matched last frame") {
            return error
        }

        let shortLead = try MovieExport.run(
            ExportRequest(
                clipA: shortURL,
                clipB: redURL,
                output: root.appendingPathComponent("short-lead.mov"),
                mode: .stretch,
                matchLengths: true,
                longEdge: 128,
                audio: .off,
                codec: codec
            ),
            progress: { _ in },
            cancelled: { false }
        )
        if shortLead.frames != 2 {
            return "matched length extended the shorter clip to \(shortLead.frames) frames"
        }

        let turnedURL = root.appendingPathComponent("turned.mov")
        var sided = FrameBuffer(width: 64, height: 48)
        sided.fill(x: 0, y: 0, w: 32, h: 48, b: 0, g: 0, r: 255)
        sided.fill(x: 32, y: 0, w: 32, h: 48, b: 255, g: 0, r: 0)
        let quarter = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0)
        try MovieWriter.write(frames: [sided], fps: 8, to: turnedURL, codec: codec, transform: quarter)
        let turned = try FrameReadback.all(url: turnedURL)
        if turned.isEmpty { return "rotated video returned no frames" }
        let upright = turned[0]
        if upright.height <= upright.width {
            return "rotated 64×48 should read taller than wide, got \(upright.width)×\(upright.height)"
        }
        if !hasPrimary(upright, channel: .red) || !hasPrimary(upright, channel: .blue) {
            let mid = upright.bgra(x: upright.width / 2, y: upright.height / 2)
            return "rotated video lost a color. \(upright.width)×\(upright.height) center BGRA \(mid.0),\(mid.1),\(mid.2),\(mid.3)"
        }
        return nil
    }

    private enum Primary { case red, blue }

    private static func hasPrimary(_ frame: FrameBuffer, channel: Primary) -> Bool {
        let step = max(1, frame.width * frame.height / 80)
        var index = 0
        while index < frame.width * frame.height {
            let x = index % frame.width
            let y = index / frame.width
            let pixel = frame.bgra(x: x, y: y)
            switch channel {
            case .red:
                if pixel.2 > 180, pixel.0 < 80 { return true }
            case .blue:
                if pixel.0 > 180, pixel.2 < 80 { return true }
            }
            index += step
        }
        return false
    }

    private static func near(
        _ pixel: (UInt8, UInt8, UInt8, UInt8),
        b: Int,
        g: Int,
        r: Int,
        slack: Int,
        _ label: String
    ) -> String? {
        let db = abs(Int(pixel.0) - b)
        let dg = abs(Int(pixel.1) - g)
        let dr = abs(Int(pixel.2) - r)
        if db <= slack, dg <= slack, dr <= slack, pixel.3 == 255 { return nil }
        return "\(label) is BGRA \(pixel.0),\(pixel.1),\(pixel.2),\(pixel.3), expected near \(b),\(g),\(r)"
    }
}
