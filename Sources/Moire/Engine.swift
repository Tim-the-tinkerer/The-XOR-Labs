import Accelerate
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

// Row 0 is the top edge. Bytes are B, G, R, A. Alpha is ignored on the way
// in and forced to opaque on the way out, so a transparent pixel cannot punch
// a hole in the XOR. Uncovered pixels are black, and black XOR A is A.

enum MoireLimits {
    static let previewLongEdge = 960
    static let saveLongEdge = 3840
    static let maxFrameRate = 60.0
}

/// Off leaves the movie silent. From A copies the first soundtrack.
/// XOR mixes both on A's clock: signed 16-bit samples, missing sound is
/// silence, so where B has ended the rest is A. Matching samples cancel.
enum SoundMode: String, CaseIterable, Identifiable {
    case off
    case fromA
    case xor

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .fromA: return "From A"
        case .xor: return "XOR"
        }
    }

    var caption: String {
        switch self {
        case .off:
            return "Preview and save stay silent."
        case .fromA:
            return "Plays A's sound with the preview and writes it into the movie."
        case .xor:
            return "XORs both soundtracks. Matching samples go silent. After B's sound ends, the rest is A."
        }
    }
}

/// Clockwise. 90° sends the top edge to the right. 180° turns the frame over.
enum QuarterTurn: String, CaseIterable, Identifiable {
    case none
    case clockwise
    case half

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .clockwise: return "90°"
        case .half: return "180°"
        }
    }
}

/// How B is changed before it is placed on A. Identity leaves the old XOR alone.
/// Scale is a factor on the placed size. Offset is a fraction of A's frame,
/// positive x to the right and positive y downward. Delay samples B earlier.
struct PictureMix: Equatable {
    var turn: QuarterTurn = .none
    var flipHorizontal = false
    var flipVertical = false
    var scale: Double = 1
    var offsetX: Double = 0
    var offsetY: Double = 0
    var delay: Double = 0

    static let identity = PictureMix()

    static func clampedScale(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return min(2, max(0.25, value))
    }

    static func clampedOffset(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(0.5, max(-0.5, value))
    }

    static func clampedDelay(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(30, max(0, value))
    }

    var normalized: PictureMix {
        var copy = self
        copy.scale = Self.clampedScale(scale)
        copy.offsetX = Self.clampedOffset(offsetX)
        copy.offsetY = Self.clampedOffset(offsetY)
        copy.delay = Self.clampedDelay(delay)
        return copy
    }

    var offsetIsCentered: Bool {
        abs(offsetX) <= 0.0001 && abs(offsetY) <= 0.0001
    }

    var reshapes: Bool {
        turn != .none || flipHorizontal || flipVertical
            || abs(scale - 1) > 0.0001
            || !offsetIsCentered
    }

    var summary: String {
        var parts: [String] = []
        switch turn {
        case .none: break
        case .clockwise: parts.append("turned 90° clockwise")
        case .half: parts.append("turned 180°")
        }
        if flipHorizontal { parts.append("flipped horizontally") }
        if flipVertical { parts.append("flipped vertically") }
        if abs(scale - 1) > 0.01 {
            parts.append("scaled to \(Int((scale * 100).rounded()))%")
        }
        if abs(offsetX) > 0.005 || abs(offsetY) > 0.005 {
            parts.append("offset \(Self.percent(offsetX)), \(Self.percent(offsetY))")
        }
        if delay > 0.02 {
            parts.append("delayed \(MoireFormat.clock(delay))")
        }
        if parts.isEmpty {
            return "B is used straight. Turn, flip, scale, offset, and delay are at rest."
        }
        return "B is \(parts.joined(separator: ", "))."
    }

    private static func percent(_ value: Double) -> String {
        let mark = Int((value * 100).rounded())
        return mark > 0 ? "+\(mark)%" : "\(mark)%"
    }
}

/// Pulls B in step with A, but holds black until A's clock has covered the delay.
/// The reader itself starts at `readerStart`, which is earlier when playback begins mid-clip.
struct BSampler {
    private var open: Bool
    private let releaseAt: Double

    init(from: Double, delay: Double) {
        let delay = PictureMix.clampedDelay(delay)
        releaseAt = delay
        open = from + 0.0005 >= delay
    }

    static func readerStart(from: Double, delay: Double) -> Double {
        max(0, from - PictureMix.clampedDelay(delay))
    }

    mutating func pull(at time: Double, _ read: () -> FrameBuffer?) -> BPull {
        if !open {
            if time + 0.0005 < releaseAt { return .hold }
            open = true
        }
        if let frame = read() { return .frame(frame) }
        return .ended
    }
}

enum BPull {
    case hold
    case frame(FrameBuffer)
    case ended
}

enum PlaceMode: String, CaseIterable, Identifiable {
    case fit
    case fill
    case stretch
    case lock

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fit: return "Fit"
        case .fill: return "Fill"
        case .stretch: return "Stretch"
        case .lock: return "Lock"
        }
    }

    var caption: String {
        switch self {
        case .fit:
            return "B keeps its shape and sits inside A. Bars stay A's picture."
        case .fill:
            return "B covers A's frame. The extra is cropped."
        case .stretch:
            return "B is stretched to A's frame."
        case .lock:
            return "B keeps its pixel size and sits in the center. Gaps stay A's picture."
        }
    }
}

struct PlacedRect: Equatable {
    var originX: Int
    var originY: Int
    var width: Int
    var height: Int
}

enum Placement {
    /// Where `source` lands on `canvas`. A negative origin means the source
    /// hangs off the frame and is cropped. Fit never hangs off.
    static func rect(source: (Int, Int), canvas: (Int, Int), mode: PlaceMode) -> PlacedRect {
        let sw = source.0
        let sh = source.1
        let cw = canvas.0
        let ch = canvas.1
        guard sw > 0, sh > 0, cw > 0, ch > 0 else {
            return PlacedRect(originX: 0, originY: 0, width: 0, height: 0)
        }
        switch mode {
        case .stretch:
            return PlacedRect(originX: 0, originY: 0, width: cw, height: ch)
        case .lock:
            return PlacedRect(
                originX: (cw - sw) / 2,
                originY: (ch - sh) / 2,
                width: sw,
                height: sh
            )
        case .fit, .fill:
            let scale: Double
            if mode == .fit {
                scale = min(Double(cw) / Double(sw), Double(ch) / Double(sh))
            } else {
                scale = max(Double(cw) / Double(sw), Double(ch) / Double(sh))
            }
            var w = max(1, Int((Double(sw) * scale).rounded()))
            var h = max(1, Int((Double(sh) * scale).rounded()))
            if mode == .fit {
                w = min(w, cw)
                h = min(h, ch)
            }
            return PlacedRect(
                originX: (cw - w) / 2,
                originY: (ch - h) / 2,
                width: w,
                height: h
            )
        }
    }

    /// Grows or shrinks a placed rect about its center, then slides it.
    /// Identity scale and offset return the rect unchanged.
    static func nudge(_ rect: PlacedRect, mix: PictureMix, canvas: (Int, Int)) -> PlacedRect {
        let scale = PictureMix.clampedScale(mix.scale)
        let ox = PictureMix.clampedOffset(mix.offsetX)
        let oy = PictureMix.clampedOffset(mix.offsetY)
        if abs(scale - 1) < 0.0001, abs(ox) < 0.0001, abs(oy) < 0.0001 {
            return rect
        }
        let cx = Double(rect.originX) + Double(rect.width) / 2
        let cy = Double(rect.originY) + Double(rect.height) / 2
        let w = max(1, Int((Double(rect.width) * scale).rounded()))
        let h = max(1, Int((Double(rect.height) * scale).rounded()))
        let x = Int((cx - Double(w) / 2 + ox * Double(canvas.0)).rounded())
        let y = Int((cy - Double(h) / 2 + oy * Double(canvas.1)).rounded())
        return PlacedRect(originX: x, originY: y, width: w, height: h)
    }
}

enum FrameSize {
    /// Shrink so the long edge is at most `longEdge`, then make both sides even.
    /// Does not enlarge. A 1 px side becomes 2 so an encoder will accept it.
    static func capped(width: Int, height: Int, longEdge: Int) -> (Int, Int) {
        guard width > 0, height > 0 else { return (2, 2) }
        let longest = max(width, height)
        let edge = max(2, longEdge)
        let scale = min(1.0, Double(edge) / Double(longest))
        var w = Int((Double(width) * scale).rounded())
        var h = Int((Double(height) * scale).rounded())
        if w % 2 != 0 { w -= 1 }
        if h % 2 != 0 { h -= 1 }
        return (max(2, w), max(2, h))
    }
}

/// How long the XOR runs, on A's clock. Matching stops at the shorter clip.
enum MovieSpan {
    static func seconds(a: Double, b: Double, match: Bool) -> Double {
        let first = a.isFinite ? max(0, a) : 0
        let second = b.isFinite ? max(0, b) : 0
        guard match else { return first }
        return min(first, second)
    }

    /// Unmatched sound keeps A's own time range. Matched sound is that many seconds.
    static func time(a: ClipFacts, b: ClipFacts, match: Bool) -> CMTime {
        guard match else { return a.rangeDuration }
        return CMTime(seconds: seconds(a: a.durationSeconds, b: b.durationSeconds, match: true), preferredTimescale: 600)
    }
}

enum VideoGeometry {
    static func orientedPixelSize(natural: CGSize, transform: CGAffineTransform) -> CGSize {
        let rect = CGRect(origin: .zero, size: natural).applying(transform)
        return CGSize(width: abs(rect.width), height: abs(rect.height))
    }

    /// Preferred transform, shifted so the oriented picture starts at the origin,
    /// then scaled to `render`. A 90° phone video often lands on a negative origin;
    /// without the shift the frame is drawn off the canvas and comes back black.
    static func uprightTransform(natural: CGSize, preferred: CGAffineTransform, render: CGSize) -> CGAffineTransform {
        let rect = CGRect(origin: .zero, size: natural).applying(preferred)
        var upright = preferred
        upright.tx -= rect.origin.x
        upright.ty -= rect.origin.y
        let orientedW = abs(rect.width)
        let orientedH = abs(rect.height)
        guard orientedW > 0.5, orientedH > 0.5, render.width > 0.5, render.height > 0.5 else {
            return .identity
        }
        let scale = CGAffineTransform(
            scaleX: render.width / orientedW,
            y: render.height / orientedH
        )
        return upright.concatenating(scale)
    }

    /// One frame. Prefers the track's own minimum duration, and clamps the rate
    /// to 1...60. 23.976 stays 1001/24000 when that is what the track reports.
    static func frameDuration(minimum: CMTime, nominal: Float) -> CMTime {
        if minimum.isValid, minimum.seconds > 0.001, minimum.seconds <= 1 {
            let fps = 1 / minimum.seconds
            if fps >= 1, fps <= MoireLimits.maxFrameRate {
                return minimum
            }
        }
        let raw: Double
        if nominal > 1 {
            raw = Double(nominal)
        } else {
            raw = 30
        }
        let fps = min(MoireLimits.maxFrameRate, max(1, raw))
        return CMTime(value: 1, timescale: CMTimeScale(fps.rounded()))
    }
}

struct FrameBuffer {
    var width: Int
    var height: Int
    var bytes: [UInt8]

    init(width: Int, height: Int) {
        self.width = max(0, width)
        self.height = max(0, height)
        var bytes = [UInt8](repeating: 0, count: self.width * self.height * 4)
        var index = 3
        while index < bytes.count {
            bytes[index] = 255
            index += 4
        }
        self.bytes = bytes
    }

    init(width: Int, height: Int, bytes: [UInt8]) {
        precondition(bytes.count == width * height * 4, "BGRA byte count must be width*height*4")
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    var isEmpty: Bool { width <= 0 || height <= 0 }

    func offset(x: Int, y: Int) -> Int { (y * width + x) * 4 }

    func contains(x: Int, y: Int) -> Bool {
        x >= 0 && y >= 0 && x < width && y < height
    }

    /// B, G, R, A. Out of range is opaque black.
    func bgra(x: Int, y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        guard contains(x: x, y: y) else { return (0, 0, 0, 255) }
        let i = offset(x: x, y: y)
        return (bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3])
    }

    mutating func set(x: Int, y: Int, b: UInt8, g: UInt8, r: UInt8) {
        guard contains(x: x, y: y) else { return }
        let i = offset(x: x, y: y)
        bytes[i] = b
        bytes[i + 1] = g
        bytes[i + 2] = r
        bytes[i + 3] = 255
    }

    mutating func fill(x: Int, y: Int, w: Int, h: Int, b: UInt8, g: UInt8, r: UInt8) {
        let x0 = max(0, x)
        let y0 = max(0, y)
        let x1 = min(width, x + w)
        let y1 = min(height, y + h)
        guard x0 < x1, y0 < y1 else { return }
        for row in y0..<y1 {
            for col in x0..<x1 {
                set(x: col, y: row, b: b, g: g, r: r)
            }
        }
    }

    mutating func forceOpaque() {
        var index = 3
        while index < bytes.count {
            bytes[index] = 255
            index += 4
        }
    }

    func fitted(to size: (Int, Int)) -> FrameBuffer {
        if width == size.0 && height == size.1 { return self }
        return scaled(width: size.0, height: size.1)
    }

    /// Turn first, then mirror. No turn and no flip returns this frame.
    func oriented(by mix: PictureMix) -> FrameBuffer {
        if mix.turn == .none, !mix.flipHorizontal, !mix.flipVertical { return self }
        var frame = turned(mix.turn)
        if mix.flipHorizontal { frame = frame.mirrored(horizontal: true) }
        if mix.flipVertical { frame = frame.mirrored(horizontal: false) }
        return frame
    }

    func turned(_ turn: QuarterTurn) -> FrameBuffer {
        switch turn {
        case .none:
            return self
        case .half:
            return mirrored(horizontal: true).mirrored(horizontal: false)
        case .clockwise:
            return turnedClockwise()
        }
    }

    /// `horizontal` exchanges left and right. Otherwise top and bottom.
    func mirrored(horizontal: Bool) -> FrameBuffer {
        if width == 0 || height == 0 { return self }
        var out = [UInt8](repeating: 255, count: bytes.count)
        bytes.withUnsafeBytes { srcRaw in
            out.withUnsafeMutableBytes { dstRaw in
                guard let src = srcRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let dst = dstRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                if horizontal {
                    for y in 0..<height {
                        for x in 0..<width {
                            let s = (y * width + x) * 4
                            let d = (y * width + (width - 1 - x)) * 4
                            dst[d] = src[s]
                            dst[d + 1] = src[s + 1]
                            dst[d + 2] = src[s + 2]
                            dst[d + 3] = 255
                        }
                    }
                } else {
                    let row = width * 4
                    for y in 0..<height {
                        memcpy(dst + (height - 1 - y) * row, src + y * row, row)
                    }
                }
            }
        }
        return FrameBuffer(width: width, height: height, bytes: out)
    }

    /// Top edge moves to the right. The new width is the old height.
    func turnedClockwise() -> FrameBuffer {
        if width == 0 || height == 0 { return FrameBuffer(width: height, height: width) }
        let dw = height
        let dh = width
        var out = [UInt8](repeating: 255, count: dw * dh * 4)
        bytes.withUnsafeBytes { srcRaw in
            out.withUnsafeMutableBytes { dstRaw in
                guard let src = srcRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let dst = dstRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                for y in 0..<height {
                    for x in 0..<width {
                        let s = (y * width + x) * 4
                        let dx = height - 1 - y
                        let dy = x
                        let d = (dy * dw + dx) * 4
                        dst[d] = src[s]
                        dst[d + 1] = src[s + 1]
                        dst[d + 2] = src[s + 2]
                        dst[d + 3] = 255
                    }
                }
            }
        }
        return FrameBuffer(width: dw, height: dh, bytes: out)
    }

    func scaled(width: Int, height: Int) -> FrameBuffer {
        let width = max(0, width)
        let height = max(0, height)
        if width == 0 || height == 0 { return FrameBuffer(width: 0, height: 0) }
        if width == self.width && height == self.height { return self }
        if isEmpty { return FrameBuffer(width: width, height: height) }
        var dst = [UInt8](repeating: 255, count: width * height * 4)
        let flags = vImage_Flags(kvImageHighQualityResampling | kvImageEdgeExtend)
        let err: vImage_Error = bytes.withUnsafeBytes { srcRaw in
            dst.withUnsafeMutableBytes { dstRaw in
                guard let srcBase = srcRaw.baseAddress, let dstBase = dstRaw.baseAddress else {
                    return kvImageNullPointerArgument
                }
                var src = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: srcBase),
                    height: vImagePixelCount(self.height),
                    width: vImagePixelCount(self.width),
                    rowBytes: self.width * 4
                )
                var out = vImage_Buffer(
                    data: dstBase,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: width * 4
                )
                let query = flags | vImage_Flags(kvImageGetTempBufferSize)
                let tempSize = vImageScale_ARGB8888(&src, &out, nil, query)
                if tempSize < 0 { return tempSize }
                let temp = tempSize > 0
                    ? UnsafeMutableRawPointer.allocate(byteCount: tempSize, alignment: 64)
                    : nil
                defer { temp?.deallocate() }
                return vImageScale_ARGB8888(&src, &out, temp, flags)
            }
        }
        if err != kvImageNoError {
            return scaledNearest(width: width, height: height)
        }
        var frame = FrameBuffer(width: width, height: height, bytes: dst)
        frame.forceOpaque()
        return frame
    }

    private func scaledNearest(width: Int, height: Int) -> FrameBuffer {
        var out = FrameBuffer(width: width, height: height)
        for y in 0..<height {
            let sy = min(self.height - 1, y * self.height / height)
            for x in 0..<width {
                let sx = min(self.width - 1, x * self.width / width)
                let p = bgra(x: sx, y: sy)
                out.set(x: x, y: y, b: p.0, g: p.1, r: p.2)
            }
        }
        return out
    }

    /// Copies `source` onto this buffer. A negative origin crops.
    mutating func blit(_ source: FrameBuffer, atX: Int, atY: Int) {
        let x0 = max(0, atX)
        let y0 = max(0, atY)
        let x1 = min(width, atX + source.width)
        let y1 = min(height, atY + source.height)
        guard x0 < x1, y0 < y1 else { return }
        let copyWidth = (x1 - x0) * 4
        let destWidth = width
        let sourceWidth = source.width
        bytes.withUnsafeMutableBytes { dstRaw in
            source.bytes.withUnsafeBytes { srcRaw in
                guard let dstBase = dstRaw.baseAddress, let srcBase = srcRaw.baseAddress else { return }
                let dst = dstBase.assumingMemoryBound(to: UInt8.self)
                let src = srcBase.assumingMemoryBound(to: UInt8.self)
                for y in y0..<y1 {
                    let sy = y - atY
                    let sx = x0 - atX
                    let destIndex = (y * destWidth + x0) * 4
                    let sourceIndex = (sy * sourceWidth + sx) * 4
                    memcpy(dst + destIndex, src + sourceIndex, copyWidth)
                }
            }
        }
    }

    static func from(pixelBuffer: CVPixelBuffer) -> FrameBuffer? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
            return nil
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            guard let dstBase = raw.baseAddress else { return }
            let dst = dstBase.assumingMemoryBound(to: UInt8.self)
            let src = base.assumingMemoryBound(to: UInt8.self)
            let tight = width * 4
            for y in 0..<height {
                memcpy(dst + y * tight, src + y * rowBytes, tight)
            }
        }
        var frame = FrameBuffer(width: width, height: height, bytes: bytes)
        frame.forceOpaque()
        return frame
    }

    /// Draws `image` so row 0 of the buffer is the top edge.
    static func from(cgImage: CGImage) -> FrameBuffer {
        let width = cgImage.width
        let height = cgImage.height
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return }
            // No Y flip. A CGImage's first row is its top, and this bitmap's
            // first row is the top as well. Flipping here turns the preview over.
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var frame = FrameBuffer(width: width, height: height, bytes: bytes)
        frame.forceOpaque()
        return frame
    }

    func cgImage() -> CGImage? {
        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.union(
                CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
            ),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}

enum FrameXOR {
    static func xor(_ a: FrameBuffer, _ b: FrameBuffer) -> FrameBuffer {
        precondition(a.width == b.width && a.height == b.height, "XOR frames must match")
        var out = a.bytes
        let count = out.count
        out.withUnsafeMutableBytes { dstRaw in
            b.bytes.withUnsafeBytes { srcRaw in
                guard let dst = dstRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let src = srcRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                var index = 0
                while index + 4 <= count {
                    dst[index] ^= src[index]
                    dst[index + 1] ^= src[index + 1]
                    dst[index + 2] ^= src[index + 2]
                    dst[index + 3] = 255
                    index += 4
                }
            }
        }
        return FrameBuffer(width: a.width, height: a.height, bytes: out)
    }

    static func place(
        _ source: FrameBuffer,
        ontoWidth: Int,
        ontoHeight: Int,
        mode: PlaceMode,
        mix: PictureMix = .identity
    ) -> FrameBuffer {
        var canvas = FrameBuffer(width: ontoWidth, height: ontoHeight)
        let source = source.oriented(by: mix)
        let rect = Placement.nudge(
            Placement.rect(
                source: (source.width, source.height),
                canvas: (ontoWidth, ontoHeight),
                mode: mode
            ),
            mix: mix,
            canvas: (ontoWidth, ontoHeight)
        )
        guard rect.width > 0, rect.height > 0 else { return canvas }
        let scaled: FrameBuffer
        if rect.width == source.width && rect.height == source.height {
            scaled = source
        } else {
            scaled = source.scaled(width: rect.width, height: rect.height)
        }
        canvas.blit(scaled, atX: rect.originX, atY: rect.originY)
        canvas.forceOpaque()
        return canvas
    }
}

func placedB(
    open: inout Bool,
    sampler: inout BSampler,
    at time: Double,
    read: () -> FrameBuffer?,
    canvas: (Int, Int),
    mode: PlaceMode,
    mix: PictureMix
) -> FrameBuffer {
    let blank = FrameBuffer(width: canvas.0, height: canvas.1)
    guard open else { return blank }
    switch sampler.pull(at: time, read) {
    case .hold:
        return blank
    case .ended:
        open = false
        return blank
    case .frame(let raw):
        return FrameXOR.place(raw, ontoWidth: canvas.0, ontoHeight: canvas.1, mode: mode, mix: mix)
    }
}

enum DropURL {
    /// Finder hands a file URL over as a plist, a string, or a URL.
    /// `URL(string:)` misses the plist form, so a drop looks like it did nothing.
    static func resolve(_ item: Any?) -> URL? {
        if let url = item as? URL { return url }
        if let data = item as? Data {
            if let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL {
                return url
            }
            if let text = String(data: data, encoding: .utf8) {
                return resolve(text)
            }
        }
        if let text = item as? String {
            return resolve(text)
        }
        return nil
    }

    private static func resolve(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("file:"), let url = URL(string: trimmed), url.isFileURL {
            return url
        }
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed)
        }
        if let url = URL(string: trimmed), url.isFileURL { return url }
        return nil
    }
}

enum OutputGuard {
    static func collides(_ output: URL, sources: [URL]) -> Bool {
        let dest = output.standardizedFileURL.resolvingSymlinksInPath().path
        return sources.contains {
            $0.standardizedFileURL.resolvingSymlinksInPath().path == dest
        }
    }
}

enum MoireFormat {
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00.0" }
        let whole = Int(seconds)
        let tenth = min(9, Int((seconds - Double(whole)) * 10))
        return String(format: "%d:%02d.%d", whole / 60, whole % 60, tenth)
    }

    static func fps(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "30" }
        if abs(value - value.rounded()) < 0.05 { return String(Int(value.rounded())) }
        return String(format: "%.2f", value)
    }
}

enum MovieNames {
    static func stamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    static func suggested(date: Date = Date()) -> String {
        "moire-\(stamp(date)).mov"
    }
}
