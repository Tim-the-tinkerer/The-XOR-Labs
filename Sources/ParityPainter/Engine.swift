import Accelerate
import Foundation

// Row 0 is the top edge. ImageCodec keeps that order on the way in and out,
// so two loads of the same file line up without a flip.

/// Packed RGBA. Stride is 4, so a buffer can be handed to vImage and CGImage.
struct Pixel: Equatable {
    var r: UInt8
    var g: UInt8
    var b: UInt8
    var a: UInt8

    static let black = Pixel(r: 0, g: 0, b: 0, a: 255)
    static let white = Pixel(r: 255, g: 255, b: 255, a: 255)

    static func rgb(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Pixel {
        Pixel(r: r, g: g, b: b, a: 255)
    }
}

struct PixelBuffer: Equatable {
    let width: Int
    let height: Int
    var pixels: [Pixel]

    var pixelCount: Int { width * height }
    var isEmpty: Bool { width <= 0 || height <= 0 || pixels.count != width * height }

    init(width: Int, height: Int, fill: Pixel = .black) {
        self.width = max(0, width)
        self.height = max(0, height)
        self.pixels = Array(repeating: fill, count: self.width * self.height)
    }

    init(width: Int, height: Int, pixels: [Pixel]) {
        precondition(pixels.count == width * height, "pixel count must match width*height")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    func inBounds(x: Int, y: Int) -> Bool {
        x >= 0 && y >= 0 && x < width && y < height
    }

    func pixel(x: Int, y: Int) -> Pixel {
        guard inBounds(x: x, y: y) else { return .black }
        return pixels[y * width + x]
    }

    mutating func set(_ x: Int, _ y: Int, _ pixel: Pixel) {
        guard inBounds(x: x, y: y) else { return }
        pixels[y * width + x] = pixel
    }

    func sample(_ x: Int, _ y: Int) -> Pixel {
        guard width > 0, height > 0 else { return .black }
        let cx = min(width - 1, max(0, x))
        let cy = min(height - 1, max(0, y))
        return pixels[cy * width + cx]
    }

    /// Nearest sample on a coarser grid. Stride 2 keeps pixels (0,0), (2,0), …
    func decimated(stride: Int) -> PixelBuffer {
        guard stride > 1, width > 0, height > 0 else { return self }
        let newW = max(1, width / stride)
        let newH = max(1, height / stride)
        var out = [Pixel](repeating: .black, count: newW * newH)
        let srcW = width
        pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                guard let srcBase = src.baseAddress, let dstBase = dst.baseAddress else { return }
                for y in 0..<newH {
                    let srcRow = srcBase + (y * stride) * srcW
                    let dstRow = dstBase + y * newW
                    for x in 0..<newW {
                        dstRow[x] = srcRow[x * stride]
                    }
                }
            }
        }
        return PixelBuffer(width: newW, height: newH, pixels: out)
    }

    /// Fit. High-quality, and a constant field stays exact.
    func scaledBilinear(width: Int, height: Int) -> PixelBuffer {
        scaled(width: width, height: height, highQuality: true)
    }

    /// Wells and the live preview. Nearest-decimate toward the target, then one bilinear pass.
    /// A full-frame high-quality scale is reserved for the real Fit used by the count and by Save.
    func scaledDisplay(width: Int, height: Int) -> PixelBuffer {
        let width = max(0, width)
        let height = max(0, height)
        if width == 0 || height == 0 || isEmpty {
            return PixelBuffer(width: width, height: height)
        }
        if width == self.width && height == self.height { return self }
        let stride = displayStride(toWidth: width, toHeight: height)
        let base = stride > 1 ? decimated(stride: stride) : self
        if base.width == width && base.height == height { return base }
        return base.scaled(width: width, height: height, highQuality: false)
    }

    private func displayStride(toWidth: Int, toHeight: Int) -> Int {
        guard toWidth > 0, toHeight > 0 else { return 1 }
        let sx = width > toWidth * 2 ? width / (toWidth * 2) : 1
        let sy = height > toHeight * 2 ? height / (toHeight * 2) : 1
        return max(1, min(sx, sy))
    }

    private func scaled(width: Int, height: Int, highQuality: Bool) -> PixelBuffer {
        let width = max(0, width)
        let height = max(0, height)
        if width == 0 || height == 0 {
            return PixelBuffer(width: 0, height: 0)
        }
        if width == self.width && height == self.height { return self }
        if isEmpty { return PixelBuffer(width: width, height: height) }
        if MemoryLayout<Pixel>.stride == 4,
           let scaled = scaledVImage(width: width, height: height, highQuality: highQuality) {
            return scaled
        }
        return scaledScalar(width: width, height: height)
    }

    private func scaledVImage(width: Int, height: Int, highQuality: Bool) -> PixelBuffer? {
        var dstPixels = [Pixel](repeating: .black, count: width * height)
        let srcWidth = self.width
        let srcHeight = self.height
        var flags = vImage_Flags(kvImageEdgeExtend)
        if highQuality { flags |= vImage_Flags(kvImageHighQualityResampling) }
        let err: vImage_Error = pixels.withUnsafeBytes { srcRaw in
            dstPixels.withUnsafeMutableBytes { dstRaw in
                guard let srcBase = srcRaw.baseAddress, let dstBase = dstRaw.baseAddress else {
                    return kvImageNullPointerArgument
                }
                var src = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: srcBase),
                    height: vImagePixelCount(srcHeight),
                    width: vImagePixelCount(srcWidth),
                    rowBytes: srcWidth * 4
                )
                var dst = vImage_Buffer(
                    data: dstBase,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: width * 4
                )
                let query = flags | vImage_Flags(kvImageGetTempBufferSize)
                let tempSize = vImageScale_ARGB8888(&src, &dst, nil, query)
                if tempSize < 0 { return tempSize }
                let temp = tempSize > 0
                    ? UnsafeMutableRawPointer.allocate(byteCount: tempSize, alignment: 64)
                    : nil
                defer { temp?.deallocate() }
                return vImageScale_ARGB8888(&src, &dst, temp, flags)
            }
        }
        guard err == kvImageNoError else { return nil }
        // Fit ignores source alpha and always paints an opaque pixel.
        // RGBA in memory: on this little-endian Mac the alpha byte is the top of the word.
        dstPixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            let count = width * height
            var index = 0
            let mask = SIMD4<UInt32>(repeating: 0xFF00_0000)
            while index + 4 <= count {
                let ptr = base.advanced(by: index * 4)
                var words = ptr.loadUnaligned(as: SIMD4<UInt32>.self)
                words |= mask
                ptr.storeBytes(of: words, as: SIMD4<UInt32>.self)
                index += 4
            }
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            while index < count {
                bytes[index * 4 + 3] = 255
                index += 1
            }
        }
        return PixelBuffer(width: width, height: height, pixels: dstPixels)
    }

    private func scaledScalar(width: Int, height: Int) -> PixelBuffer {
        var out = [Pixel](repeating: .black, count: width * height)
        let xScale = Double(self.width) / Double(width)
        let yScale = Double(self.height) / Double(height)
        for y in 0..<height {
            let fy = (Double(y) + 0.5) * yScale - 0.5
            let y0 = Int(fy.rounded(.down))
            let y1 = y0 + 1
            let ty = fy - Double(y0)
            let row = y * width
            for x in 0..<width {
                let fx = (Double(x) + 0.5) * xScale - 0.5
                let x0 = Int(fx.rounded(.down))
                let x1 = x0 + 1
                let tx = fx - Double(x0)
                let c00 = sample(x0, y0)
                let c10 = sample(x1, y0)
                let c01 = sample(x0, y1)
                let c11 = sample(x1, y1)
                out[row + x] = Pixel(
                    r: bilerp(c00.r, c10.r, c01.r, c11.r, tx, ty),
                    g: bilerp(c00.g, c10.g, c01.g, c11.g, tx, ty),
                    b: bilerp(c00.b, c10.b, c01.b, c11.b, tx, ty),
                    a: 255
                )
            }
        }
        return PixelBuffer(width: width, height: height, pixels: out)
    }

    private func bilerp(
        _ c00: UInt8, _ c10: UInt8, _ c01: UInt8, _ c11: UInt8,
        _ tx: Double, _ ty: Double
    ) -> UInt8 {
        let top = Double(c00) + (Double(c10) - Double(c00)) * tx
        let bottom = Double(c01) + (Double(c11) - Double(c01)) * tx
        let value = top + (bottom - top) * ty
        return UInt8(min(255, max(0, Int(value.rounded()))))
    }
}

enum PaintMode: String, CaseIterable, Identifiable {
    case mask
    case xor
    case plane
    case trace

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mask: return "Mask"
        case .xor: return "XOR"
        case .plane: return "Plane"
        case .trace: return "Trace"
        }
    }

    var caption: String {
        switch self {
        case .mask: return "Black where the pixels match. White where they differ."
        case .xor: return "The color of the XOR. Black is a match."
        case .plane: return "One bit of that XOR. Bit 0 is the finest grain."
        case .trace: return "Image A, with the differences traced in white."
        }
    }

    static func parse(_ raw: String) -> PaintMode? {
        switch raw.lowercased() {
        case "mask", "difference", "diff", "bw", "binary": return .mask
        case "xor", "colour", "color": return .xor
        case "plane", "bit", "bitplane": return .plane
        case "trace", "ghost", "over", "overlay": return .trace
        default: return nil
        }
    }
}

enum PaintChannel: String, CaseIterable, Identifiable {
    case rgb
    case red
    case green
    case blue
    case luma

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rgb: return "All"
        case .red: return "Red"
        case .green: return "Green"
        case .blue: return "Blue"
        case .luma: return "Luma"
        }
    }

    static func parse(_ raw: String) -> PaintChannel? {
        switch raw.lowercased() {
        case "rgb", "all": return .rgb
        case "r", "red": return .red
        case "g", "green": return .green
        case "b", "blue": return .blue
        case "luma", "y", "grey", "gray": return .luma
        default: return nil
        }
    }
}

enum AlignMode: String, CaseIterable, Identifiable {
    case fit
    case lock

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fit: return "Fit"
        case .lock: return "Lock"
        }
    }

    var caption: String {
        switch self {
        case .fit: return "Scale B onto A's pixels."
        case .lock: return "No resampling. Nudge slides B by whole pixels."
        }
    }

    static func parse(_ raw: String) -> AlignMode? {
        switch raw.lowercased() {
        case "fit", "scale", "match": return .fit
        case "lock", "pixel", "crop", "exact": return .lock
        default: return nil
        }
    }
}

struct PaintOptions: Equatable {
    var mode: PaintMode = .mask
    var channel: PaintChannel = .rgb
    var align: AlignMode = .fit
    var slack: Int = 0
    var plane: Int = 0
    var offsetX: Int = 0
    var offsetY: Int = 0
    var invert: Bool = false
    var lift: Int = 1

    static let lifts = [1, 2, 4, 8, 16, 32]

    func sanitized() -> PaintOptions {
        var copy = self
        copy.slack = min(255, max(0, slack))
        copy.plane = min(7, max(0, plane))
        if !Self.lifts.contains(lift) {
            copy.lift = Self.lifts.min(by: { abs($0 - lift) < abs($1 - lift) }) ?? 1
        }
        return copy
    }
}

struct PaintResult: Equatable {
    var image: PixelBuffer
    var differed: Int
}

struct PreparedPreview {
    var a: PixelBuffer
    var b: PixelBuffer
    var options: PaintOptions
    var reduced: Bool
    var stride: Int
}

enum Painter {
    /// White mix used when Trace paints a differing pixel back onto A.
    static let traceMix = 78

    @inline(__always)
    static func luma(_ pixel: Pixel) -> UInt8 {
        let y = (13933 * Int(pixel.r) + 46871 * Int(pixel.g) + 4732 * Int(pixel.b)) >> 16
        return UInt8(min(255, max(0, y)))
    }

    @inline(__always)
    static func traced(_ base: UInt8) -> UInt8 {
        let span = 255 - Int(base)
        return UInt8(Int(base) + span * traceMix / 100)
    }

    static func compare(_ a: PixelBuffer, _ b: PixelBuffer, options: PaintOptions) -> PaintResult {
        let options = options.sanitized()
        let width = a.width
        let height = a.height
        guard width > 0, height > 0, a.pixels.count == width * height else {
            return PaintResult(image: PixelBuffer(width: 0, height: 0), differed: 0)
        }
        let sourceB = fitted(b, toWidth: width, height: height, align: options.align)
        let count = width * height
        var differed = 0
        let pixels = [Pixel](unsafeUninitializedCapacity: count) { buffer, initialized in
            guard let out = buffer.baseAddress else {
                initialized = 0
                return
            }
            differed = render(a: a, b: sourceB, out: out, options: options)
            initialized = count
        }
        return PaintResult(
            image: PixelBuffer(width: width, height: height, pixels: pixels),
            differed: differed
        )
    }

    /// Pixels where the slack gate opens. Mode, lift, plane, and invert do not change it.
    static func differCount(_ a: PixelBuffer, _ b: PixelBuffer, options: PaintOptions) -> Int {
        counted(a, b, options: options, stop: nil) ?? 0
    }

    /// Nil when `stop` asks the walk to quit. The count is thrown away.
    static func differCount(
        _ a: PixelBuffer,
        _ b: PixelBuffer,
        options: PaintOptions,
        stop: @escaping () -> Bool
    ) -> Int? {
        counted(a, b, options: options, stop: stop)
    }

    private static func counted(
        _ a: PixelBuffer,
        _ b: PixelBuffer,
        options: PaintOptions,
        stop: (() -> Bool)?
    ) -> Int? {
        if let stop, stop() { return nil }
        let options = options.sanitized()
        let width = a.width
        let height = a.height
        guard width > 0, height > 0, a.pixels.count == width * height else { return 0 }
        let sourceB = fitted(b, toWidth: width, height: height, align: options.align)
        return tally(
            a: a, b: sourceB,
            channel: options.channel, slack: options.slack,
            ox: options.offsetX, oy: options.offsetY,
            stop: stop
        )
    }

    /// Live view. The full-frame differ count is computed separately.
    static func preparePreview(
        a: PixelBuffer,
        b: PixelBuffer,
        options: PaintOptions,
        maxSide: Int
    ) -> PreparedPreview {
        let long = max(a.width, a.height)
        guard maxSide > 0, long > maxSide, a.width > 0, a.height > 0 else {
            return PreparedPreview(a: a, b: b, options: options, reduced: false, stride: 1)
        }
        let stride = max(1, (long + maxSide - 1) / maxSide)
        guard stride > 1 else {
            return PreparedPreview(a: a, b: b, options: options, reduced: false, stride: 1)
        }
        var shifted = options
        shifted.offsetX = options.offsetX / stride
        shifted.offsetY = options.offsetY / stride
        let smallerA = a.decimated(stride: stride)
        switch options.align {
        case .fit:
            return PreparedPreview(a: smallerA, b: b, options: shifted, reduced: true, stride: stride)
        case .lock:
            return PreparedPreview(a: smallerA, b: b.decimated(stride: stride), options: shifted, reduced: true, stride: stride)
        }
    }

    private static func fitted(_ b: PixelBuffer, toWidth width: Int, height: Int, align: AlignMode) -> PixelBuffer {
        switch align {
        case .fit:
            return b.scaledBilinear(width: width, height: height)
        case .lock:
            return b
        }
    }

    private static func render(
        a: PixelBuffer,
        b: PixelBuffer,
        out: UnsafeMutablePointer<Pixel>,
        options: PaintOptions
    ) -> Int {
        let width = a.width
        let height = a.height
        let bw = b.width
        let bh = b.height
        return a.pixels.withUnsafeBufferPointer { aPtr in
            b.pixels.withUnsafeBufferPointer { bPtr in
                guard let aBase = aPtr.baseAddress else { return 0 }
                let aligned = options.offsetX == 0 && options.offsetY == 0
                    && bw == width && bh == height && bPtr.count == width * height
                if aligned, let bBase = bPtr.baseAddress {
                    return renderAligned(
                        a: aBase, b: bBase, out: out,
                        count: width * height, options: options
                    )
                }
                return renderOffset(
                    a: aBase, b: bPtr.baseAddress, out: out,
                    width: width, height: height,
                    bw: bw, bh: bh, bCount: bPtr.count,
                    options: options
                )
            }
        }
    }

    private static func renderAligned(
        a: UnsafePointer<Pixel>,
        b: UnsafePointer<Pixel>,
        out: UnsafeMutablePointer<Pixel>,
        count: Int,
        options: PaintOptions
    ) -> Int {
        if options.channel == .rgb {
            return renderAlignedRGB(a: a, b: b, out: out, count: count, options: options)
        }
        var differed = 0
        for index in 0..<count {
            let painted = paintPixel(a[index], b[index], options)
            out[index] = painted.pixel
            if painted.differs { differed += 1 }
        }
        return differed
    }

    /// Default view: all three channels, no nudge. The mode switch stays outside the pixel walk.
    private static func renderAlignedRGB(
        a: UnsafePointer<Pixel>,
        b: UnsafePointer<Pixel>,
        out: UnsafeMutablePointer<Pixel>,
        count: Int,
        options: PaintOptions
    ) -> Int {
        let slack = options.slack
        let invert = options.invert
        var differed = 0
        switch options.mode {
        case .mask:
            for index in 0..<count {
                let left = a[index]
                let right = b[index]
                let differs = channelGap(left.r, right.r, slack)
                    || channelGap(left.g, right.g, slack)
                    || channelGap(left.b, right.b, slack)
                var value: UInt8 = differs ? 255 : 0
                if invert { value = 255 - value }
                out[index] = Pixel(r: value, g: value, b: value, a: 255)
                if differs { differed += 1 }
            }
        case .xor:
            let lift = options.lift
            for index in 0..<count {
                let left = a[index]
                let right = b[index]
                let red = xorByte(left.r, right.r, slack: slack, lift: lift)
                let green = xorByte(left.g, right.g, slack: slack, lift: lift)
                let blue = xorByte(left.b, right.b, slack: slack, lift: lift)
                var pixel = Pixel(r: red.0, g: green.0, b: blue.0, a: 255)
                if invert { pixel = inverted(pixel) }
                out[index] = pixel
                if red.1 || green.1 || blue.1 { differed += 1 }
            }
        case .plane:
            let mask = UInt8(1 << options.plane)
            for index in 0..<count {
                let left = a[index]
                let right = b[index]
                let red = planeByte(left.r, right.r, slack: slack, mask: mask)
                let green = planeByte(left.g, right.g, slack: slack, mask: mask)
                let blue = planeByte(left.b, right.b, slack: slack, mask: mask)
                var pixel = Pixel(r: red.0, g: green.0, b: blue.0, a: 255)
                if invert { pixel = inverted(pixel) }
                out[index] = pixel
                if red.1 || green.1 || blue.1 { differed += 1 }
            }
        case .trace:
            for index in 0..<count {
                let left = a[index]
                let right = b[index]
                let differs = channelGap(left.r, right.r, slack)
                    || channelGap(left.g, right.g, slack)
                    || channelGap(left.b, right.b, slack)
                var pixel = differs
                    ? Pixel(r: traced(left.r), g: traced(left.g), b: traced(left.b), a: 255)
                    : Pixel(r: left.r, g: left.g, b: left.b, a: 255)
                if invert { pixel = inverted(pixel) }
                out[index] = pixel
                if differs { differed += 1 }
            }
        }
        return differed
    }

    private static func renderOffset(
        a: UnsafePointer<Pixel>,
        b: UnsafePointer<Pixel>?,
        out: UnsafeMutablePointer<Pixel>,
        width: Int,
        height: Int,
        bw: Int,
        bh: Int,
        bCount: Int,
        options: PaintOptions
    ) -> Int {
        let ox = options.offsetX
        let oy = options.offsetY
        let black = Pixel.black
        let bReady = b != nil && bw > 0 && bh > 0 && bCount == bw * bh
        var differed = 0
        for y in 0..<height {
            let row = y * width
            let by = y - oy
            let rowInB = bReady && by >= 0 && by < bh
            for x in 0..<width {
                let bx = x - ox
                let other: Pixel
                if rowInB, bx >= 0, bx < bw, let b {
                    other = b[by * bw + bx]
                } else {
                    other = black
                }
                let painted = paintPixel(a[row + x], other, options)
                out[row + x] = painted.pixel
                if painted.differs { differed += 1 }
            }
        }
        return differed
    }

    private static func tally(
        a: PixelBuffer,
        b: PixelBuffer,
        channel: PaintChannel,
        slack: Int,
        ox: Int,
        oy: Int,
        stop: (() -> Bool)?
    ) -> Int? {
        let width = a.width
        let height = a.height
        let bw = b.width
        let bh = b.height
        return a.pixels.withUnsafeBufferPointer { aPtr in
            b.pixels.withUnsafeBufferPointer { bPtr in
                guard let aBase = aPtr.baseAddress else { return 0 }
                let aligned = ox == 0 && oy == 0 && bw == width && bh == height && bPtr.count == width * height
                if aligned, let bBase = bPtr.baseAddress {
                    return tallyAligned(
                        a: aBase, b: bBase, count: width * height,
                        channel: channel, slack: slack, stop: stop
                    )
                }
                return tallyOffset(
                    a: aBase, b: bPtr.baseAddress,
                    width: width, height: height,
                    bw: bw, bh: bh, bCount: bPtr.count,
                    ox: ox, oy: oy, channel: channel, slack: slack,
                    stop: stop
                )
            }
        }
    }

    private static func tallyAligned(
        a: UnsafePointer<Pixel>,
        b: UnsafePointer<Pixel>,
        count: Int,
        channel: PaintChannel,
        slack: Int,
        stop: (() -> Bool)?
    ) -> Int? {
        var differed = 0
        let chunk = 65_536
        var start = 0
        while start < count {
            let end = min(count, start + chunk)
            switch channel {
            case .rgb:
                for index in start..<end {
                    let left = a[index]
                    let right = b[index]
                    if channelGap(left.r, right.r, slack)
                        || channelGap(left.g, right.g, slack)
                        || channelGap(left.b, right.b, slack) {
                        differed += 1
                    }
                }
            case .red:
                for index in start..<end where channelGap(a[index].r, b[index].r, slack) { differed += 1 }
            case .green:
                for index in start..<end where channelGap(a[index].g, b[index].g, slack) { differed += 1 }
            case .blue:
                for index in start..<end where channelGap(a[index].b, b[index].b, slack) { differed += 1 }
            case .luma:
                for index in start..<end where channelGap(luma(a[index]), luma(b[index]), slack) { differed += 1 }
            }
            start = end
            if let stop, stop() { return nil }
        }
        return differed
    }

    private static func tallyOffset(
        a: UnsafePointer<Pixel>,
        b: UnsafePointer<Pixel>?,
        width: Int,
        height: Int,
        bw: Int,
        bh: Int,
        bCount: Int,
        ox: Int,
        oy: Int,
        channel: PaintChannel,
        slack: Int,
        stop: (() -> Bool)?
    ) -> Int? {
        let black = Pixel.black
        let bReady = b != nil && bw > 0 && bh > 0 && bCount == bw * bh
        var differed = 0
        for y in 0..<height {
            let row = y * width
            let by = y - oy
            let rowInB = bReady && by >= 0 && by < bh
            for x in 0..<width {
                let bx = x - ox
                let other: Pixel
                if rowInB, bx >= 0, bx < bw, let b {
                    other = b[by * bw + bx]
                } else {
                    other = black
                }
                if differs(a[row + x], other, channel: channel, slack: slack) {
                    differed += 1
                }
            }
            if y & 31 == 31, let stop, stop() { return nil }
        }
        return differed
    }

    @inline(__always)
    private static func paintPixel(_ a: Pixel, _ b: Pixel, _ options: PaintOptions) -> (pixel: Pixel, differs: Bool) {
        let slack = options.slack
        let open = differs(a, b, channel: options.channel, slack: slack)
        var pixel: Pixel
        switch options.mode {
        case .mask:
            let value: UInt8 = open ? 255 : 0
            pixel = Pixel(r: value, g: value, b: value, a: 255)
        case .xor:
            pixel = xorPixel(a, b, channel: options.channel, slack: slack, lift: options.lift)
        case .plane:
            let mask = UInt8(1 << options.plane)
            pixel = planePixel(a, b, channel: options.channel, slack: slack, mask: mask)
        case .trace:
            if open {
                pixel = Pixel(r: traced(a.r), g: traced(a.g), b: traced(a.b), a: 255)
            } else {
                pixel = Pixel(r: a.r, g: a.g, b: a.b, a: 255)
            }
        }
        if options.invert { pixel = inverted(pixel) }
        return (pixel, open)
    }

    @inline(__always)
    private static func differs(_ a: Pixel, _ b: Pixel, channel: PaintChannel, slack: Int) -> Bool {
        switch channel {
        case .rgb:
            return channelGap(a.r, b.r, slack) || channelGap(a.g, b.g, slack) || channelGap(a.b, b.b, slack)
        case .red:
            return channelGap(a.r, b.r, slack)
        case .green:
            return channelGap(a.g, b.g, slack)
        case .blue:
            return channelGap(a.b, b.b, slack)
        case .luma:
            return channelGap(luma(a), luma(b), slack)
        }
    }

    @inline(__always)
    private static func channelGap(_ a: UInt8, _ b: UInt8, _ slack: Int) -> Bool {
        if slack == 0 { return a != b }
        return abs(Int(a) - Int(b)) > slack
    }

    /// Slack is an absolute gap, not an XOR magnitude.
    /// 127 and 128 differ by 1 and XOR to 255: slack 1 stores 0, slack 0 stores 255.
    @inline(__always)
    private static func xorByte(_ a: UInt8, _ b: UInt8, slack: Int, lift: Int) -> (UInt8, Bool) {
        if abs(Int(a) - Int(b)) <= slack { return (0, false) }
        return (UInt8(min(255, Int(a ^ b) * lift)), true)
    }

    @inline(__always)
    private static func planeByte(_ a: UInt8, _ b: UInt8, slack: Int, mask: UInt8) -> (UInt8, Bool) {
        if abs(Int(a) - Int(b)) <= slack { return (0, false) }
        let lit: UInt8 = (a ^ b) & mask == 0 ? 0 : 255
        return (lit, true)
    }

    @inline(__always)
    private static func inverted(_ pixel: Pixel) -> Pixel {
        Pixel(r: 255 - pixel.r, g: 255 - pixel.g, b: 255 - pixel.b, a: 255)
    }

    private static func xorPixel(
        _ a: Pixel, _ b: Pixel,
        channel: PaintChannel, slack: Int, lift: Int
    ) -> Pixel {
        switch channel {
        case .rgb:
            return Pixel(
                r: xorByte(a.r, b.r, slack: slack, lift: lift).0,
                g: xorByte(a.g, b.g, slack: slack, lift: lift).0,
                b: xorByte(a.b, b.b, slack: slack, lift: lift).0,
                a: 255
            )
        case .red:
            return Pixel(r: xorByte(a.r, b.r, slack: slack, lift: lift).0, g: 0, b: 0, a: 255)
        case .green:
            return Pixel(r: 0, g: xorByte(a.g, b.g, slack: slack, lift: lift).0, b: 0, a: 255)
        case .blue:
            return Pixel(r: 0, g: 0, b: xorByte(a.b, b.b, slack: slack, lift: lift).0, a: 255)
        case .luma:
            let value = xorByte(luma(a), luma(b), slack: slack, lift: lift).0
            return Pixel(r: value, g: value, b: value, a: 255)
        }
    }

    private static func planePixel(
        _ a: Pixel, _ b: Pixel,
        channel: PaintChannel, slack: Int, mask: UInt8
    ) -> Pixel {
        switch channel {
        case .rgb:
            return Pixel(
                r: planeByte(a.r, b.r, slack: slack, mask: mask).0,
                g: planeByte(a.g, b.g, slack: slack, mask: mask).0,
                b: planeByte(a.b, b.b, slack: slack, mask: mask).0,
                a: 255
            )
        case .red:
            let lit = planeByte(a.r, b.r, slack: slack, mask: mask).0
            return Pixel(r: lit, g: lit, b: lit, a: 255)
        case .green:
            let lit = planeByte(a.g, b.g, slack: slack, mask: mask).0
            return Pixel(r: lit, g: lit, b: lit, a: 255)
        case .blue:
            let lit = planeByte(a.b, b.b, slack: slack, mask: mask).0
            return Pixel(r: lit, g: lit, b: lit, a: 255)
        case .luma:
            let lit = planeByte(luma(a), luma(b), slack: slack, mask: mask).0
            return Pixel(r: lit, g: lit, b: lit, a: 255)
        }
    }
}

enum OutputGuard {
    static func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.resolvingSymlinksInPath().path
            == rhs.standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func collides(_ output: URL, sources: [URL]) -> Bool {
        sources.contains { sameFile(output, $0) }
    }
}

enum DecimalText {
    static func grouped(_ value: Int) -> String {
        let digits = String(value)
        var out = ""
        for (index, character) in digits.reversed().enumerated() {
            if index > 0 && index % 3 == 0 { out.append(",") }
            out.append(character)
        }
        return String(out.reversed())
    }

    static func summary(differed: Int, pixels: Int, width: Int, height: Int) -> String {
        let size = "\(width)×\(height)"
        guard pixels > 0 else { return size }
        if differed == 0 { return "Exact match · \(size)" }
        let pct = Double(differed) * 100 / Double(pixels)
        return String(
            format: "%.2f%% differ · %@ of %@ · %@",
            pct,
            grouped(differed),
            grouped(pixels),
            size
        )
    }
}

enum PaintParse: Equatable {
    case success(PaintInvocation)
    case failure(String)
}

struct PaintInvocation: Equatable {
    var options = PaintOptions()
    var output: String?
    var jpeg = false
    var sample = false
    var inputs: [String] = []

    static func parse(_ args: [String]) -> PaintParse {
        var invocation = PaintInvocation()
        let valued: Set<String> = [
            "--mode", "--channel", "--align", "--slack", "--plane",
            "--dx", "--dy", "--lift", "-o", "--out",
        ]
        var index = 1
        while index < args.count {
            let arg = args[index]
            if valued.contains(arg) {
                guard index + 1 < args.count else {
                    return .failure("Missing value for \(arg).")
                }
                let value = args[index + 1]
                switch arg {
                case "--mode":
                    guard let mode = PaintMode.parse(value) else {
                        return .failure("Unknown --mode \(value). Use mask, xor, plane, or trace.")
                    }
                    invocation.options.mode = mode
                case "--channel":
                    guard let channel = PaintChannel.parse(value) else {
                        return .failure("Unknown --channel \(value). Use all, red, green, blue, or luma.")
                    }
                    invocation.options.channel = channel
                case "--align":
                    guard let align = AlignMode.parse(value) else {
                        return .failure("Unknown --align \(value). Use fit or lock.")
                    }
                    invocation.options.align = align
                case "--slack":
                    guard let slack = Int(value), (0...255).contains(slack) else {
                        return .failure("--slack must be 0...255.")
                    }
                    invocation.options.slack = slack
                case "--plane":
                    guard let plane = Int(value), (0...7).contains(plane) else {
                        return .failure("--plane must be 0...7.")
                    }
                    invocation.options.plane = plane
                case "--dx":
                    guard let dx = Int(value) else { return .failure("--dx must be an integer.") }
                    invocation.options.offsetX = dx
                case "--dy":
                    guard let dy = Int(value) else { return .failure("--dy must be an integer.") }
                    invocation.options.offsetY = dy
                case "--lift":
                    guard let lift = Int(value), PaintOptions.lifts.contains(lift) else {
                        return .failure("--lift must be 1, 2, 4, 8, 16, or 32.")
                    }
                    invocation.options.lift = lift
                case "-o", "--out":
                    invocation.output = value
                default:
                    break
                }
                index += 2
                continue
            }
            switch arg {
            case "--invert":
                invocation.options.invert = true
            case "--jpeg":
                invocation.jpeg = true
            case "--sample":
                invocation.sample = true
            default:
                if arg.hasPrefix("-") {
                    return .failure("Unknown option \(arg).")
                }
                invocation.inputs.append(arg)
            }
            index += 1
        }

        if invocation.sample {
            if !invocation.inputs.isEmpty {
                return .failure("--sample does not take input images.")
            }
        } else if invocation.inputs.count != 2 {
            return .failure("Give two images: ParityPainter A.png B.png")
        }
        return .success(invocation)
    }

    /// `parity-mask-20261003-154207.png`. Plane includes the bit on screen.
    static func fileName(mode: PaintMode, plane: Int, stamp: String, jpeg: Bool) -> String {
        let ext = jpeg ? "jpg" : "png"
        return "parity-\(viewToken(mode: mode, plane: plane))-\(stamp).\(ext)"
    }

    static func viewToken(mode: PaintMode, plane: Int) -> String {
        switch mode {
        case .plane:
            return "plane-\(min(7, max(0, plane)))"
        case .mask, .xor, .trace:
            return mode.rawValue
        }
    }

    static func stamp(from date: Date = Date()) -> String {
        stampFormatter.string(from: date)
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

enum SampleScene {
    static let width = 480
    static let height = 300
    static let horizon = 188
    static let ground = Pixel.rgb(58, 50, 40)
    static let buildingColor = Pixel.rgb(38, 36, 34)
    static let windowColor = Pixel.rgb(226, 206, 160)
    static let doorColor = Pixel.rgb(186, 64, 48)
    static let scratchColor = Pixel.rgb(245, 244, 240)
    static let sunA = Pixel.rgb(244, 204, 112)
    static let sunB = Pixel.rgb(230, 108, 58)

    static let doorPixel = (x: 90, y: 230)
    static let windowPixel = (x: 66, y: 150)
    static let groundPixel = (x: 8, y: 290)

    static func pair() -> (PixelBuffer, PixelBuffer) {
        let a = render(
            sun: (360, 72),
            radius: 34,
            color: sunA,
            door: false,
            scratch: false
        )
        let b = render(
            sun: (286, 58),
            radius: 26,
            color: sunB,
            door: true,
            scratch: true
        )
        return (a, b)
    }

    static func sky(_ y: Int) -> Pixel {
        let span = max(1, horizon - 1)
        let t = min(span, max(0, y))
        func mix(_ deep: Int, _ warm: Int) -> UInt8 {
            UInt8(min(255, max(0, deep + (warm - deep) * t / span)))
        }
        return Pixel.rgb(mix(28, 214), mix(40, 170), mix(72, 120))
    }

    private static func render(
        sun: (Int, Int),
        radius: Int,
        color: Pixel,
        door: Bool,
        scratch: Bool
    ) -> PixelBuffer {
        var buffer = PixelBuffer(width: width, height: height, fill: ground)
        for y in 0..<horizon {
            let color = sky(y)
            for x in 0..<width {
                buffer.set(x, y, color)
            }
        }
        fillCircle(&buffer, cx: sun.0, cy: sun.1, radius: radius, color)
        fill(&buffer, 46, 150, 118, 272, buildingColor)
        fill(&buffer, 58, 76, 138, 168, windowColor)
        fill(&buffer, 112, 130, 138, 168, windowColor)
        if door {
            fill(&buffer, 78, 110, 200, 264, doorColor)
        }
        if scratch {
            fill(&buffer, 430, 432, 28, 150, scratchColor)
        }
        return buffer
    }

    private static func fill(
        _ buffer: inout PixelBuffer,
        _ x0: Int, _ x1: Int, _ y0: Int, _ y1: Int,
        _ pixel: Pixel
    ) {
        for y in y0..<y1 {
            for x in x0..<x1 {
                buffer.set(x, y, pixel)
            }
        }
    }

    private static func fillCircle(
        _ buffer: inout PixelBuffer,
        cx: Int, cy: Int, radius: Int, _ pixel: Pixel
    ) {
        let r2 = radius * radius
        for y in (cy - radius)...(cy + radius) {
            let dy = y - cy
            for x in (cx - radius)...(cx + radius) {
                let dx = x - cx
                if dx * dx + dy * dy <= r2 {
                    buffer.set(x, y, pixel)
                }
            }
        }
    }
}
