import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct DecodedImage {
    var buffer: PixelBuffer
    var capped: Bool
}

enum ImageCodec {
    static let maxSide = 8192

    /// Big-endian + alpha last = RGBA bytes in memory on every Mac.
    private static let rgbaPremultiplied: UInt32 =
        CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
    private static let rgbaStraight: UInt32 =
        CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.last.rawValue

    enum CodecError: LocalizedError {
        case unreadable
        case empty
        case encodeFailed

        var errorDescription: String? {
            switch self {
            case .unreadable: return "Could not read that image."
            case .empty: return "Image is empty."
            case .encodeFailed: return "Could not encode the image."
            }
        }
    }

    static func load(url: URL) throws -> DecodedImage {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else {
            throw CodecError.unreadable
        }
        return try image(from: source)
    }

    static func load(data: Data) throws -> DecodedImage {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else {
            throw CodecError.unreadable
        }
        return try image(from: source)
    }

    static func load(nsImage: NSImage) throws -> DecodedImage {
        var rect = NSRect(origin: .zero, size: nsImage.size)
        guard let cg = nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            throw CodecError.unreadable
        }
        let buffer = try fromCGImage(cg)
        return cap(buffer)
    }

    static func pngData(_ buffer: PixelBuffer) throws -> Data {
        try encode(buffer, type: UTType.png, quality: nil)
    }

    static func jpegData(_ buffer: PixelBuffer, quality: Double = 0.92) throws -> Data {
        try encode(buffer, type: UTType.jpeg, quality: quality)
    }

    static func write(_ buffer: PixelBuffer, to url: URL, jpeg: Bool) throws {
        let data = jpeg ? try jpegData(buffer) : try pngData(buffer)
        try data.write(to: url, options: .atomic)
    }

    static func cgImage(_ buffer: PixelBuffer) -> CGImage? {
        guard !buffer.isEmpty, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let byteCount = buffer.pixelCount * 4
        let data: CFData?
        if MemoryLayout<Pixel>.stride == 4, MemoryLayout<Pixel>.offset(of: \Pixel.a) == 3 {
            data = buffer.pixels.withUnsafeBytes { raw in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
                return CFDataCreate(nil, base, byteCount)
            }
        } else {
            var bytes = [UInt8]()
            bytes.reserveCapacity(byteCount)
            for pixel in buffer.pixels {
                bytes.append(pixel.r)
                bytes.append(pixel.g)
                bytes.append(pixel.b)
                bytes.append(pixel.a)
            }
            data = CFDataCreate(nil, bytes, bytes.count)
        }
        guard let data, let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(
            width: buffer.width,
            height: buffer.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: buffer.width * 4,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: rgbaStraight),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    static func nsImage(_ buffer: PixelBuffer) -> NSImage? {
        guard let cg = cgImage(buffer) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: buffer.width, height: buffer.height))
    }

    static func thumbnail(_ buffer: PixelBuffer, maxSide: Int = 720) -> NSImage? {
        let long = max(buffer.width, buffer.height)
        guard long > maxSide, maxSide > 0 else { return nsImage(buffer) }
        let scale = Double(maxSide) / Double(long)
        let width = max(1, Int((Double(buffer.width) * scale).rounded()))
        let height = max(1, Int((Double(buffer.height) * scale).rounded()))
        return nsImage(buffer.scaledDisplay(width: width, height: height))
    }

    static func fromCGImage(_ image: CGImage) throws -> PixelBuffer {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { throw CodecError.empty }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw CodecError.unreadable }

        var raw = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = raw.withUnsafeMutableBytes { ptr -> Bool in
            guard let ctx = CGContext(
                data: ptr.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: rgbaPremultiplied
            ) else {
                return false
            }
            ctx.interpolationQuality = .none
            ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw CodecError.unreadable }

        let count = width * height
        if MemoryLayout<Pixel>.stride == 4, rgbaIsOpaque(raw) {
            let pixels = [Pixel](unsafeUninitializedCapacity: count) { buffer, initialized in
                guard let dest = buffer.baseAddress else {
                    initialized = 0
                    return
                }
                dest.withMemoryRebound(to: UInt8.self, capacity: raw.count) { rebound in
                    raw.withUnsafeBufferPointer { src in
                        guard let base = src.baseAddress else { return }
                        rebound.update(from: base, count: raw.count)
                    }
                }
                initialized = count
            }
            return PixelBuffer(width: width, height: height, pixels: pixels)
        }
        let pixels = [Pixel](unsafeUninitializedCapacity: count) { buffer, initialized in
            guard let dest = buffer.baseAddress else {
                initialized = 0
                return
            }
            for index in 0..<count {
                let offset = index * 4
                dest[index] = unpremultiply(
                    r: raw[offset],
                    g: raw[offset + 1],
                    b: raw[offset + 2],
                    a: raw[offset + 3]
                )
            }
            initialized = count
        }
        return PixelBuffer(width: width, height: height, pixels: pixels)
    }

    private static func image(from source: CGImageSource) throws -> DecodedImage {
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let orientation = props?[kCGImagePropertyOrientation] as? Int ?? 1
        let longSide = max(width, height)
        let capped = longSide > maxSide
        let needsThumb = orientation != 1 || capped

        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        let image: CGImage?
        if needsThumb {
            let thumb: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxSide,
                kCGImageSourceShouldCache: false,
            ]
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumb as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
        }
        guard let image else { throw CodecError.unreadable }
        return DecodedImage(buffer: try fromCGImage(image), capped: capped)
    }

    private static func cap(_ buffer: PixelBuffer) -> DecodedImage {
        let long = max(buffer.width, buffer.height)
        guard long > maxSide else { return DecodedImage(buffer: buffer, capped: false) }
        let scale = Double(maxSide) / Double(long)
        let width = max(1, Int((Double(buffer.width) * scale).rounded()))
        let height = max(1, Int((Double(buffer.height) * scale).rounded()))
        return DecodedImage(
            buffer: buffer.scaledBilinear(width: width, height: height),
            capped: true
        )
    }

    private static func encode(_ buffer: PixelBuffer, type: UTType, quality: Double?) throws -> Data {
        guard let cg = cgImage(buffer) else { throw CodecError.encodeFailed }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            type.identifier as CFString,
            1,
            nil
        ) else {
            throw CodecError.encodeFailed
        }
        var props: [CFString: Any] = [:]
        if let quality {
            props[kCGImageDestinationLossyCompressionQuality] = max(0.05, min(1, quality))
        }
        CGImageDestinationAddImage(destination, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CodecError.encodeFailed }
        return data as Data
    }

    private static func rgbaIsOpaque(_ raw: [UInt8]) -> Bool {
        var index = 3
        while index < raw.count {
            if raw[index] != 255 { return false }
            index += 4
        }
        return true
    }

    private static func unpremultiply(r: UInt8, g: UInt8, b: UInt8, a: UInt8) -> Pixel {
        if a == 0 { return Pixel(r: 0, g: 0, b: 0, a: 0) }
        if a == 255 { return Pixel(r: r, g: g, b: b, a: a) }
        let ia = Int(a)
        return Pixel(
            r: UInt8(min(255, Int(r) * 255 / ia)),
            g: UInt8(min(255, Int(g) * 255 / ia)),
            b: UInt8(min(255, Int(b) * 255 / ia)),
            a: a
        )
    }
}
