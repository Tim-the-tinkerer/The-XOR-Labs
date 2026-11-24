import Foundation

enum SelfTest {
    static func run() -> String? {
        let tests: [(String, () -> String?)] = [
            ("identical", testIdentical),
            ("one bit", testOneBit),
            ("slack versus xor", testSlackVersusXOR),
            ("plane", testPlane),
            ("channel", testChannel),
            ("luma", testLuma),
            ("invert", testInvert),
            ("trace", testTrace),
            ("lock offset", testLockOffset),
            ("uncovered", testUncovered),
            ("fit solid", testFitSolid),
            ("decimate", testDecimate),
            ("preview stride", testPreviewStride),
            ("display scale", testDisplayScale),
            ("fit agrees with lock", testFitAgreesWithLock),
            ("stop count", testStopCount),
            ("sample pair", testSamplePair),
            ("parse", testParse),
            ("overwrite", testOverwrite),
            ("grouping", testGrouping),
            ("file name", testFileName),
            ("differ count", testDifferCount),
            ("png", testPNG),
        ]
        for (name, test) in tests {
            if let error = test() {
                return "\(name): \(error)"
            }
        }
        return nil
    }

    private static func fail(_ message: String) -> String { message }

    private static func solid(_ width: Int, _ height: Int, _ pixel: Pixel) -> PixelBuffer {
        PixelBuffer(width: width, height: height, fill: pixel)
    }

    private static func grayRow(_ values: [UInt8]) -> PixelBuffer {
        let pixels = values.map { Pixel.rgb($0, $0, $0) }
        return PixelBuffer(width: values.count, height: 1, pixels: pixels)
    }

    private static func testIdentical() -> String? {
        let image = solid(3, 2, Pixel.rgb(12, 40, 90))
        let result = Painter.compare(image, image, options: PaintOptions())
        if result.differed != 0 { return fail("identical images differed") }
        if result.image.pixels.contains(where: { $0 != .black }) {
            return fail("mask of a match was not black")
        }
        return nil
    }

    private static func testOneBit() -> String? {
        let a = solid(2, 1, .black)
        var b = a
        b.set(1, 0, Pixel.rgb(1, 0, 0))
        let mask = Painter.compare(a, b, options: PaintOptions())
        if mask.differed != 1 { return fail("expected one differing pixel, got \(mask.differed)") }
        if mask.image.pixel(x: 0, y: 0) != .black { return fail("matching pixel was not black") }
        if mask.image.pixel(x: 1, y: 0) != .white { return fail("differing pixel was not white") }

        var xor = PaintOptions()
        xor.mode = .xor
        let color = Painter.compare(a, b, options: xor)
        if color.image.pixel(x: 1, y: 0) != Pixel.rgb(1, 0, 0) {
            return fail("xor of 0 and 1 should be red 1")
        }
        return nil
    }

    private static func testSlackVersusXOR() -> String? {
        let a = solid(1, 1, Pixel.rgb(127, 0, 0))
        let b = solid(1, 1, Pixel.rgb(128, 0, 0))
        var exact = PaintOptions()
        exact.mode = .xor
        exact.channel = .red
        let loud = Painter.compare(a, b, options: exact)
        if loud.image.pixel(x: 0, y: 0).r != 255 { return fail("127 xor 128 should be 255") }
        if loud.differed != 1 { return fail("slack 0 should count the pixel") }

        exact.slack = 1
        let quiet = Painter.compare(a, b, options: exact)
        if quiet.differed != 0 { return fail("slack 1 should quiet a gap of 1") }
        if quiet.image.pixel(x: 0, y: 0) != .black { return fail("quiet xor should be black") }

        var small = PaintOptions()
        small.mode = .xor
        small.channel = .red
        let ten = solid(1, 1, Pixel.rgb(10, 0, 0))
        let twelve = solid(1, 1, Pixel.rgb(12, 0, 0))
        small.slack = 1
        let kept = Painter.compare(ten, twelve, options: small)
        if kept.image.pixel(x: 0, y: 0).r != 6 { return fail("10 xor 12 should be 6") }
        small.lift = 8
        let lifted = Painter.compare(ten, twelve, options: small)
        if lifted.image.pixel(x: 0, y: 0).r != 48 { return fail("lift 8 should scale the xor to 48") }
        return nil
    }

    private static func testPlane() -> String? {
        let a = solid(1, 1, .black)
        let one = solid(1, 1, Pixel.rgb(1, 0, 0))
        var plane = PaintOptions()
        plane.mode = .plane
        plane.channel = .red
        plane.plane = 0
        let lsb = Painter.compare(a, one, options: plane)
        if lsb.image.pixel(x: 0, y: 0) != .white { return fail("bit 0 of 1 should be lit") }
        plane.plane = 1
        let next = Painter.compare(a, one, options: plane)
        if next.image.pixel(x: 0, y: 0) != .black { return fail("bit 1 of 1 should be dark") }
        if next.differed != 1 { return fail("the pixel still differs when the bit is off") }

        let high = solid(1, 1, Pixel.rgb(128, 0, 0))
        plane.plane = 7
        plane.channel = .rgb
        let msb = Painter.compare(a, high, options: plane)
        if msb.image.pixel(x: 0, y: 0) != Pixel.rgb(255, 0, 0) {
            return fail("bit 7 should light only red")
        }
        return nil
    }

    private static func testChannel() -> String? {
        let a = solid(1, 1, .black)
        let b = solid(1, 1, Pixel.rgb(0, 255, 0))
        var red = PaintOptions()
        red.channel = .red
        let ignored = Painter.compare(a, b, options: red)
        if ignored.differed != 0 { return fail("red channel should ignore a green change") }
        red.channel = .green
        let seen = Painter.compare(a, b, options: red)
        if seen.image.pixel(x: 0, y: 0) != .white { return fail("green channel should catch the change") }
        return nil
    }

    private static func testLuma() -> String? {
        if Painter.luma(Pixel.rgb(255, 0, 0)) != 54 { return fail("red luma should be 54") }
        let red = solid(1, 1, Pixel.rgb(255, 0, 0))
        let black = solid(1, 1, .black)
        var options = PaintOptions()
        options.channel = .luma
        options.slack = 54
        if Painter.compare(red, black, options: options).differed != 0 {
            return fail("slack 54 should match red against black in luma")
        }
        options.slack = 53
        if Painter.compare(red, black, options: options).differed != 1 {
            return fail("slack 53 should still see red")
        }
        options.slack = 0
        options.mode = .xor
        let painted = Painter.compare(red, black, options: options)
        if painted.image.pixel(x: 0, y: 0) != Pixel.rgb(54, 54, 54) {
            return fail("luma xor should be gray 54")
        }
        return nil
    }

    private static func testInvert() -> String? {
        let a = solid(2, 1, .black)
        var b = a
        b.set(1, 0, .white)
        var options = PaintOptions()
        options.invert = true
        let mask = Painter.compare(a, b, options: options)
        if mask.differed != 1 { return fail("invert should not change the count") }
        if mask.image.pixel(x: 0, y: 0) != .white { return fail("inverted match should be white") }
        if mask.image.pixel(x: 1, y: 0) != .black { return fail("inverted differ should be black") }
        return nil
    }

    private static func testTrace() -> String? {
        let a = solid(1, 1, Pixel.rgb(10, 20, 30))
        let b = solid(1, 1, .black)
        var options = PaintOptions()
        options.mode = .trace
        let traced = Painter.compare(a, b, options: options)
        let pixel = traced.image.pixel(x: 0, y: 0)
        if pixel != Pixel.rgb(201, 203, 205) {
            return fail("trace mix was \(pixel.r),\(pixel.g),\(pixel.b)")
        }
        let same = Painter.compare(a, a, options: options)
        if same.image.pixel(x: 0, y: 0) != Pixel.rgb(10, 20, 30) {
            return fail("trace of a match should keep A")
        }
        return nil
    }

    private static func testLockOffset() -> String? {
        let a = grayRow([0, 10, 20])
        let b = grayRow([10, 20, 30])
        var options = PaintOptions()
        options.align = .lock
        options.offsetX = 1
        let slid = Painter.compare(a, b, options: options)
        if slid.differed != 0 { return fail("a one-pixel nudge should line these rows up") }
        options.offsetX = 0
        let straight = Painter.compare(a, b, options: options)
        if straight.differed != 3 { return fail("without the nudge every pixel differs") }
        return nil
    }

    private static func testUncovered() -> String? {
        let a = grayRow([0, 40])
        let b = grayRow([9])
        var options = PaintOptions()
        options.align = .lock
        options.offsetX = 5
        let mask = Painter.compare(a, b, options: options)
        if mask.image.pixel(x: 0, y: 0) != .black {
            return fail("black against an uncovered pixel matches black")
        }
        if mask.image.pixel(x: 1, y: 0) != .white {
            return fail("a lit pixel against uncovered black should differ")
        }
        return nil
    }

    private static func testFitSolid() -> String? {
        let canvas = solid(4, 3, Pixel.rgb(200, 10, 10))
        let other = solid(9, 2, Pixel.rgb(200, 10, 10))
        let matched = Painter.compare(canvas, other, options: PaintOptions())
        if matched.differed != 0 { return fail("a solid scaled onto the same solid should match") }
        if matched.image.width != 4 || matched.image.height != 3 {
            return fail("fit should keep A's size")
        }
        let blue = solid(2, 5, Pixel.rgb(0, 0, 255))
        var xor = PaintOptions()
        xor.mode = .xor
        let painted = Painter.compare(canvas, blue, options: xor)
        let pixel = painted.image.pixel(x: 2, y: 1)
        if pixel != Pixel.rgb(200, 10, 245) {
            return fail("solid xor was \(pixel.r),\(pixel.g),\(pixel.b)")
        }
        return nil
    }

    private static func testDecimate() -> String? {
        let pixels = (0..<8).map { Pixel.rgb(UInt8($0), 0, 0) }
        let buffer = PixelBuffer(width: 4, height: 2, pixels: pixels)
        let small = buffer.decimated(stride: 2)
        if small.width != 2 || small.height != 1 { return fail("stride 2 of 4×2 should be 2×1") }
        if small.pixel(x: 0, y: 0).r != 0 || small.pixel(x: 1, y: 0).r != 2 {
            return fail("decimate should keep columns 0 and 2")
        }
        return nil
    }

    private static func testPreviewStride() -> String? {
        let a = solid(3000, 1000, .black)
        let b = solid(3000, 1000, .white)
        var options = PaintOptions()
        options.align = .lock
        options.offsetX = 5
        options.offsetY = 4
        let prepared = Painter.preparePreview(a: a, b: b, options: options, maxSide: 1500)
        if !prepared.reduced { return fail("3000px edge should reduce") }
        if prepared.a.width != 1500 || prepared.a.height != 500 {
            return fail("stride 2 should halve the frame")
        }
        if prepared.options.offsetX != 2 || prepared.options.offsetY != 2 {
            return fail("preview nudge should divide by the stride")
        }
        let same = Painter.preparePreview(a: solid(20, 10, .black), b: b, options: options, maxSide: 1500)
        if same.reduced { return fail("a small frame should stay full") }
        return nil
    }

    private static func testDisplayScale() -> String? {
        var pixels = [Pixel](repeating: Pixel(r: 9, g: 8, b: 7, a: 0), count: 4)
        pixels[3] = Pixel(r: 9, g: 8, b: 7, a: 10)
        let tiny = PixelBuffer(width: 2, height: 2, pixels: pixels)
        let scaled = tiny.scaledBilinear(width: 5, height: 3)
        if scaled.pixel(x: 4, y: 2) != Pixel.rgb(9, 8, 7) {
            let pixel = scaled.pixel(x: 4, y: 2)
            return fail("opaque fit was \(pixel.r),\(pixel.g),\(pixel.b),\(pixel.a)")
        }
        let display = solid(90, 40, Pixel.rgb(4, 5, 6)).scaledDisplay(width: 30, height: 10)
        if display.width != 30 || display.height != 10 {
            return fail("display scale size")
        }
        if display.pixels.contains(where: { $0 != Pixel.rgb(4, 5, 6) }) {
            return fail("display scale changed a solid")
        }
        return nil
    }

    private static func testFitAgreesWithLock() -> String? {
        let wide = solid(18, 10, Pixel.rgb(200, 10, 10))
        var smallPixels = [Pixel](repeating: Pixel.rgb(0, 0, 255), count: 6)
        smallPixels[0] = Pixel.rgb(10, 20, 30)
        let small = PixelBuffer(width: 3, height: 2, pixels: smallPixels)
        var fit = PaintOptions()
        fit.align = .fit
        fit.offsetX = 1
        fit.offsetY = -1
        fit.slack = 2
        fit.mode = .xor
        fit.lift = 4
        let direct = Painter.compare(wide, small, options: fit)
        let scaled = small.scaledBilinear(width: wide.width, height: wide.height)
        var locked = fit
        locked.align = .lock
        let via = Painter.compare(wide, scaled, options: locked)
        if direct.image != via.image || direct.differed != via.differed {
            return fail("a pre-fitted buffer should match Fit")
        }
        if Painter.differCount(wide, scaled, options: locked) != direct.differed {
            return fail("the cached fit changed the count")
        }
        return nil
    }

    private static func testStopCount() -> String? {
        let image = solid(8, 8, .white)
        if Painter.differCount(image, image, options: PaintOptions(), stop: { true }) != nil {
            return fail("stop should abandon the count")
        }
        var calls = 0
        let counted = Painter.differCount(image, solid(8, 8, .black), options: PaintOptions()) {
            calls += 1
            return false
        }
        if counted != image.pixelCount || calls == 0 {
            return fail("a finished count should keep every pixel")
        }
        return nil
    }

    private static func testSamplePair() -> String? {
        let pair = SampleScene.pair()
        let mask = Painter.compare(pair.0, pair.1, options: PaintOptions())
        if mask.differed == 0 || mask.differed >= pair.0.pixelCount / 2 {
            return fail("sample difference was \(mask.differed)")
        }
        let door = SampleScene.doorPixel
        if mask.image.pixel(x: door.x, y: door.y) != .white {
            return fail("the sample door should read as a difference")
        }
        let ground = SampleScene.groundPixel
        if mask.image.pixel(x: ground.x, y: ground.y) != .black {
            return fail("shared ground should be black")
        }
        let window = SampleScene.windowPixel
        if mask.image.pixel(x: window.x, y: window.y) != .black {
            return fail("shared window should be black")
        }
        if Painter.compare(pair.0, pair.0, options: PaintOptions()).differed != 0 {
            return fail("a plate against itself should match")
        }
        return nil
    }

    private static func testParse() -> String? {
        let args = [
            "ParityPainter", "a.png", "b.png",
            "--mode", "diff",
            "--channel", "red",
            "--align", "lock",
            "--slack", "8",
            "--plane", "3",
            "--dx", "-4",
            "--dy", "6",
            "--lift", "8",
            "--invert",
            "--jpeg",
            "-o", "out.jpg",
        ]
        guard case let .success(parsed) = PaintInvocation.parse(args) else {
            return fail("expected a valid command")
        }
        if parsed.options.mode != .mask { return fail("diff should be mask") }
        if parsed.options.channel != .red || parsed.options.align != .lock { return fail("channel or align") }
        if parsed.options.slack != 8 || parsed.options.plane != 3 { return fail("slack or plane") }
        if parsed.options.offsetX != -4 || parsed.options.offsetY != 6 { return fail("nudge") }
        if parsed.options.lift != 8 || !parsed.options.invert || !parsed.jpeg { return fail("lift, invert, or jpeg") }
        if parsed.output != "out.jpg" || parsed.inputs != ["a.png", "b.png"] { return fail("paths") }

        if case .success = PaintInvocation.parse(["ParityPainter", "--mode", "nope", "a.png", "b.png"]) {
            return fail("bad mode should fail")
        }
        if case .success = PaintInvocation.parse(["ParityPainter", "--slack", "-1", "a.png", "b.png"]) {
            return fail("negative slack should fail")
        }
        if case .success = PaintInvocation.parse(["ParityPainter", "--sample", "a.png"]) {
            return fail("sample should not take inputs")
        }
        guard case let .success(sample) = PaintInvocation.parse(["ParityPainter", "--sample", "--mode", "bit"]) else {
            return fail("sample command should parse")
        }
        if !sample.sample || sample.options.mode != .plane { return fail("bit should be plane") }
        if case .success = PaintInvocation.parse(["ParityPainter", "only-one.png"]) {
            return fail("one image should fail")
        }
        return nil
    }

    private static func testOverwrite() -> String? {
        let a = URL(fileURLWithPath: "/tmp/plate-a.png")
        let b = URL(fileURLWithPath: "/tmp/plate-b.png")
        if !OutputGuard.collides(URL(fileURLWithPath: "/tmp/plate-a.png"), sources: [a, b]) {
            return fail("should refuse the source path")
        }
        if OutputGuard.collides(URL(fileURLWithPath: "/tmp/parity-out.png"), sources: [a, b]) {
            return fail("a new name should be allowed")
        }
        return nil
    }

    private static func testGrouping() -> String? {
        if DecimalText.grouped(1204302) != "1,204,302" { return fail("grouping") }
        if DecimalText.grouped(0) != "0" { return fail("zero") }
        let line = DecimalText.summary(differed: 0, pixels: 12, width: 4, height: 3)
        if line != "Exact match · 4×3" { return fail("exact summary") }
        return nil
    }

    private static func testFileName() -> String? {
        let mask = PaintInvocation.fileName(mode: .mask, plane: 0, stamp: "20261003-154207", jpeg: false)
        if mask != "parity-mask-20261003-154207.png" { return fail(mask) }
        let plane = PaintInvocation.fileName(mode: .plane, plane: 3, stamp: "20261003-154207", jpeg: true)
        if plane != "parity-plane-3-20261003-154207.jpg" { return fail(plane) }
        let xor = PaintInvocation.fileName(mode: .xor, plane: 4, stamp: "20261003-154207", jpeg: false)
        if xor != "parity-xor-20261003-154207.png" { return fail(xor) }
        let trace = PaintInvocation.fileName(mode: .trace, plane: 1, stamp: "20261003-154207", jpeg: false)
        if trace != "parity-trace-20261003-154207.png" { return fail(trace) }
        let live = PaintInvocation.stamp()
        if live.range(of: #"^\d{8}-\d{6}$"#, options: .regularExpression) == nil {
            return fail("stamp \(live)")
        }
        return nil
    }

    private static func testDifferCount() -> String? {
        if MemoryLayout<Pixel>.stride != 4 || MemoryLayout<Pixel>.offset(of: \Pixel.a) != 3 {
            return fail("Pixel must stay packed RGBA")
        }
        let a = solid(3, 2, Pixel.rgb(10, 20, 30))
        var b = solid(3, 2, Pixel.rgb(10, 20, 30))
        b.set(2, 1, Pixel.rgb(12, 20, 40))
        var options = PaintOptions()
        options.slack = 1
        options.mode = .plane
        options.plane = 2
        options.lift = 8
        options.invert = true
        if let error = expectCount(a, b, options) { return error }

        let mask = Painter.differCount(a, b, options: PaintOptions())
        var view = PaintOptions()
        view.mode = .xor
        view.lift = 32
        view.plane = 7
        view.invert = true
        if Painter.differCount(a, b, options: view) != mask {
            return fail("the view changed the differ count")
        }

        options.align = .lock
        options.offsetX = 1
        options.offsetY = -1
        options.channel = .luma
        options.mode = .xor
        if let error = expectCount(a, b, options) { return error }

        let wide = solid(5, 4, Pixel.rgb(200, 10, 10))
        let small = solid(2, 2, Pixel.rgb(0, 0, 255))
        options = PaintOptions()
        options.align = .fit
        options.mode = .trace
        if let error = expectCount(wide, small, options) { return error }
        return nil
    }

    private static func expectCount(_ a: PixelBuffer, _ b: PixelBuffer, _ options: PaintOptions) -> String? {
        let painted = Painter.compare(a, b, options: options)
        let counted = Painter.differCount(a, b, options: options)
        if painted.differed != counted {
            return fail("count \(counted) did not match paint \(painted.differed)")
        }
        return nil
    }

    private static func testPNG() -> String? {
        var buffer = PixelBuffer(width: 4, height: 2, fill: .black)
        buffer.set(0, 0, Pixel.rgb(255, 0, 0))
        buffer.set(3, 1, Pixel.rgb(0, 255, 40))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("parity-painter-roundtrip.png")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try ImageCodec.write(buffer, to: url, jpeg: false)
            let loaded = try ImageCodec.load(url: url)
            if loaded.capped { return fail("tiny png should not be capped") }
            if loaded.buffer != buffer { return fail("png round-trip changed pixels") }
        } catch {
            return fail(error.localizedDescription)
        }
        return nil
    }
}
