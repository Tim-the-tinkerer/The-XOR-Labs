import Foundation
import Security

/// How the repeating key is interpreted.
public enum KeyKind: String, CaseIterable, Identifiable, Sendable {
    /// UTF-8 bytes of the passphrase, repeating.
    case text
    /// Hex bytes (`4B 45 59`, `4B4559`, `0x4B4559`), repeating.
    case hex
    /// Raw bytes of a key file, repeating.
    case file

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .text: return "Text"
        case .hex:  return "Hex"
        case .file: return "Key file"
        }
    }

    public var detail: String {
        switch self {
        case .text:
            return "Repeating UTF-8 bytes of the passphrase."
        case .hex:
            return "Repeating keystream from hex (spaces and 0x allowed)."
        case .file:
            return "Repeating keystream from a binary key file."
        }
    }

    /// XOF1 method byte.
    public var formatByte: UInt8 {
        switch self {
        case .text: return 1
        case .hex:  return 2
        case .file: return 3
        }
    }

    public static func from(formatByte: UInt8) -> KeyKind? {
        switch formatByte {
        case 1: return .text
        case 2: return .hex
        case 3: return .file
        default: return nil
        }
    }
}

/// How the repeating key is written into a `.xor` archive.
public enum KeyStorage: String, CaseIterable, Identifiable, Sendable {
    /// Key string stored in the header in the clear (convenient, not secret).
    case store
    /// Key omitted. Decrypt requires the same key.
    case omit
    /// Header stores the key XOR-wrapped with a wrap passphrase.
    case wrap

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .store: return "Store key"
        case .omit:  return "Don't store"
        case .wrap:  return "Encrypt key"
        }
    }

    public var detail: String {
        switch self {
        case .store:
            return "Writes the key into the .xor header. Anyone with the file can decrypt."
        case .omit:
            return "The file does not contain the key. You type it or choose the same key file to decrypt."
        case .wrap:
            return "Stores the key XOR-wrapped with a passphrase. You type that passphrase to decrypt."
        }
    }
}

/// Repeating XOR key. Text mode uses UTF-8; hex mode parses hex bytes; file mode uses raw file bytes.
public struct XORKey: Sendable, Equatable {
    public let raw: String
    public let kind: KeyKind
    public let byteValues: [UInt8]

    public init(_ raw: String, kind: KeyKind = .text) {
        self.raw = raw
        self.kind = kind
        switch kind {
        case .text:
            self.byteValues = Array(raw.utf8)
        case .hex:
            self.byteValues = Array(XOREngine.parseHex(raw) ?? Data())
        case .file:
            self.byteValues = []
        }
    }

    public init(fileBytes: [UInt8], name: String) {
        self.raw = name
        self.kind = .file
        self.byteValues = fileBytes
    }

    public init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        self.init(fileBytes: Array(data), name: url.lastPathComponent)
    }

    public var isEmpty: Bool { byteValues.isEmpty }

    /// Bytes written into the `.xor` header for Store / Encrypt-key.
    public var headerFieldData: Data {
        switch kind {
        case .text, .hex:
            return Data(raw.utf8)
        case .file:
            return Data(byteValues)
        }
    }

    public var summary: String {
        guard !byteValues.isEmpty else { return "empty" }
        let preview = byteValues.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")
        let more = byteValues.count > 8 ? "…" : ""
        let unit = byteValues.count == 1 ? "byte" : "bytes"
        if kind == .file, !raw.isEmpty {
            return "\(raw) · \(byteValues.count) \(unit) · \(preview)\(more)"
        }
        return "\(byteValues.count) \(unit) · \(preview)\(more)"
    }
}

/// One plaintext byte aligned with its key byte and ciphertext (workshop).
public struct ByteAlign: Sendable, Equatable, Identifiable {
    public let id: Int
    public let plain: UInt8
    public let key: UInt8
    public let cipher: UInt8

    public var plainGlyph: String { XOREngine.glyph(plain) }
    public var keyGlyph: String { XOREngine.glyph(key) }
    public var cipherGlyph: String { XOREngine.glyph(cipher) }

    public var help: String {
        let p = String(format: "%02X", plain)
        let k = String(format: "%02X", key)
        let c = String(format: "%02X", cipher)
        return "\(p) ⊕ \(k) = \(c)"
    }
}

/// Repeating-key XOR. Encrypt and decrypt are the same operation.
public enum XOREngine: Sendable {
    // MARK: - Transform

    public static func encrypt(_ data: Data, key: XORKey) -> Data {
        var cursor = 0
        return transform(data, key: key, cursor: &cursor)
    }

    /// XOR is involutive: decrypt is encrypt.
    public static func decrypt(_ data: Data, key: XORKey) -> Data {
        encrypt(data, key: key)
    }

    public static func transform(_ data: Data, key: XORKey, cursor: inout Int) -> Data {
        let keys = key.byteValues
        guard !keys.isEmpty else { return data }
        let n = keys.count
        var pos = cursor

        var out = Data(count: data.count)
        out.withUnsafeMutableBytes { destRaw in
            data.withUnsafeBytes { srcRaw in
                let s = srcRaw.bindMemory(to: UInt8.self)
                let d = destRaw.bindMemory(to: UInt8.self)
                let count = s.count
                for i in 0..<count {
                    d[i] = s[i] ^ keys[pos % n]
                    pos += 1
                }
            }
        }
        cursor = pos
        return out
    }

    // MARK: - Hex / ASCII / bits

    public static func hexString(_ data: Data, separator: String = " ") -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: separator)
    }

    public static func hexString(_ bytes: [UInt8], separator: String = " ") -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: separator)
    }

    /// Parse hex with optional spaces, colons, dashes, and a leading `0x`.
    public static func parseHex(_ text: String) -> Data? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("0x") || s.hasPrefix("0X") {
            s.removeFirst(2)
        }
        var hex = ""
        hex.reserveCapacity(s.count)
        for ch in s.unicodeScalars {
            switch ch.value {
            case 48...57, 65...70, 97...102: // 0-9 A-F a-f
                hex.append(Character(ch))
            case 32, 9, 10, 13, 58, 45: // space tab lf cr : -
                continue
            default:
                return nil
            }
        }
        guard !hex.isEmpty, hex.count % 2 == 0 else { return nil }
        var out = Data()
        out.reserveCapacity(hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            out.append(b)
            i = j
        }
        return out
    }

    /// Printable ASCII, or a middle-dot for everything else.
    public static func glyph(_ byte: UInt8) -> String {
        if byte == 32 { return "·" }
        if (32...126).contains(byte) {
            return String(UnicodeScalar(byte))
        }
        return "·"
    }

    public static func asciiPreview(_ data: Data) -> String {
        String(data.map { b -> Character in
            if (32...126).contains(b) { return Character(UnicodeScalar(b)) }
            return "·"
        })
    }

    public static func bitString(_ byte: UInt8) -> String {
        String((0..<8).map { ((byte >> (7 - $0)) & 1) == 1 ? "1" : "0" }.joined())
    }

    public static func bits(of byte: UInt8) -> [Bool] {
        (0..<8).map { ((byte >> (7 - $0)) & 1) == 1 }
    }

    public static func randomBytes(_ count: Int) -> [UInt8] {
        guard count > 0 else { return [] }
        var bytes = [UInt8](repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBytes { buf in
            SecRandomCopyBytes(kSecRandomDefault, count, buf.baseAddress!)
        }
        if status != errSecSuccess {
            for i in 0..<count { bytes[i] = UInt8.random(in: 0...255) }
        }
        return bytes
    }

    public static func randomHexKey(byteCount: Int) -> String {
        hexString(randomBytes(max(1, byteCount)))
    }

    // MARK: - Workshop alignment

    public static func alignment(of data: Data, key: XORKey, limit: Int = 160) -> [ByteAlign] {
        guard !key.isEmpty else { return [] }
        let n = key.byteValues.count
        let slice = data.prefix(limit)
        var result: [ByteAlign] = []
        result.reserveCapacity(slice.count)
        for (i, b) in slice.enumerated() {
            let k = key.byteValues[i % n]
            result.append(ByteAlign(id: i, plain: b, key: k, cipher: b ^ k))
        }
        return result
    }

    public static func alignment(of text: String, key: XORKey, limit: Int = 160) -> [ByteAlign] {
        alignment(of: Data(text.utf8), key: key, limit: limit)
    }

    // MARK: - File names (XOR then hex, so the result is path-safe)

    public static func transformFileName(_ name: String, key: XORKey, decrypt: Bool = false) -> String {
        guard !key.isEmpty else { return name }
        if decrypt {
            guard let data = parseHex(name), !data.isEmpty else { return name }
            let plain = encrypt(data, key: key)
            var restored = String(data: plain, encoding: .utf8)
                ?? String(data: plain, encoding: .isoLatin1)
                ?? name
            restored = restored
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "\0", with: "_")
            if restored == "." || restored == ".." || restored.isEmpty {
                restored = name
            }
            return restored
        }

        let xored = encrypt(Data(name.utf8), key: key)
        var hex = hexString(xored, separator: "")
        if hex.isEmpty { hex = "item" }
        if hex == "." || hex == ".." {
            hex = "item"
        }
        return hex
    }

    public static func encryptedFileNamePreview(_ name: String, key: XORKey) -> String {
        let hex = transformFileName(name, key: key, decrypt: false)
        if hex.count <= 24 { return hex }
        return String(hex.prefix(20)) + "…"
    }

    // MARK: - Paths

    public static func uniqueURL(in directory: URL, preferredName: String) -> URL {
        var url = directory.appendingPathComponent(preferredName)
        if !FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        let ns = preferredName as NSString
        let ext = ns.pathExtension
        let stem = ext.isEmpty ? preferredName : ns.deletingPathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            url = directory.appendingPathComponent(candidate)
            if !FileManager.default.fileExists(atPath: url.path) {
                return url
            }
            n += 1
        }
    }
}
