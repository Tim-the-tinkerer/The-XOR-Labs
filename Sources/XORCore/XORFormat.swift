import Foundation

/// `.xor` archive format (XOF1).
///
/// ```
/// Magic "XOF1" | version | method | flags | keyLen
/// originalSize | payloadSize | crc32 | nameLen | name | key | payload
/// ```
///
/// Method: `1` text key (UTF-8), `2` hex key (parsed hex), `3` binary key file
/// Flags: bit 0 = directory; bit 1 = encrypted names; bit 2 = key omitted; bit 3 = key wrapped
public enum XORFormat: Sendable {
    public static let fileExtension = "xor"
    public static let magic = Data([0x58, 0x4F, 0x46, 0x31]) // XOF1
    public static let version: UInt16 = 1
    public static let headerFixedSize = 32
    public static let maxStoredKeyBytes = Int(UInt16.max)

    public static let methodText: UInt8 = 1
    public static let methodHex: UInt8 = 2
    public static let methodFile: UInt8 = 3

    public static let flagDirectory: UInt8 = 0x01
    public static let flagEncryptNames: UInt8 = 0x02
    public static let flagOmitKey: UInt8 = 0x04
    public static let flagWrapKey: UInt8 = 0x08

    public struct Info: Sendable, Equatable {
        public var keyData: Data
        public var method: UInt8
        public var flags: UInt8
        public var originalSize: UInt64
        public var payloadSize: UInt64
        public var crc32: UInt32
        public var originalName: String?

        public var key: String {
            String(data: keyData, encoding: .utf8)
                ?? String(data: keyData, encoding: .isoLatin1)
                ?? ""
        }

        public var isDirectory: Bool { (flags & flagDirectory) != 0 }
        public var encryptsNames: Bool { (flags & flagEncryptNames) != 0 }
        public var omitsKey: Bool { (flags & flagOmitKey) != 0 }
        public var wrapsKey: Bool { (flags & flagWrapKey) != 0 }
        public var needsSecret: Bool { omitsKey || wrapsKey }

        public var keyKind: KeyKind { KeyKind.from(formatByte: method) ?? .text }
        public var xorKey: XORKey {
            switch keyKind {
            case .file:
                return XORKey(fileBytes: Array(keyData), name: "key")
            case .text, .hex:
                return XORKey(key, kind: keyKind)
            }
        }

        public var restoredName: String? { restoredName(using: xorKey) }

        public func restoredName(using key: XORKey) -> String? {
            guard let name = originalName else { return nil }
            if encryptsNames {
                return XOREngine.transformFileName(name, key: key, decrypt: true)
            }
            return name
        }

        public var modeLabel: String {
            switch method {
            case methodText: return "Text key"
            case methodHex:  return "Hex key"
            case methodFile: return "Key file"
            default:         return "Unknown (\(method))"
            }
        }

        public init(
            keyData: Data,
            method: UInt8,
            flags: UInt8,
            originalSize: UInt64,
            payloadSize: UInt64,
            crc32: UInt32,
            originalName: String?
        ) {
            self.keyData = keyData
            self.method = method
            self.flags = flags
            self.originalSize = originalSize
            self.payloadSize = payloadSize
            self.crc32 = crc32
            self.originalName = originalName
        }
    }

    /// Key bytes written to the header, plus omit/wrap flags.
    public static func encodedKeyField(
        key: XORKey,
        storage: KeyStorage,
        wrapPassphrase: String
    ) throws -> (data: Data, extraFlags: UInt8) {
        switch storage {
        case .store:
            let data = key.headerFieldData
            guard data.count <= maxStoredKeyBytes else { throw XORError.keyTooLong }
            return (data, 0)
        case .omit:
            return (Data(), flagOmitKey)
        case .wrap:
            let wrap = XORKey(wrapPassphrase, kind: .text)
            guard !wrap.isEmpty else { throw XORError.wrapPassphraseRequired }
            let wrapped = XOREngine.encrypt(key.headerFieldData, key: wrap)
            guard wrapped.count <= maxStoredKeyBytes else { throw XORError.keyTooLong }
            return (wrapped, flagWrapKey)
        }
    }

    /// Recover the payload XOR key from the header plus any secret the user typed.
    public static func resolveKey(
        from info: Info,
        suppliedKey: XORKey? = nil,
        wrapPassphrase: String? = nil
    ) throws -> XORKey {
        if info.omitsKey {
            guard let supplied = suppliedKey, !supplied.isEmpty else { throw XORError.keyRequired }
            return supplied
        }
        if info.wrapsKey {
            guard let pass = wrapPassphrase, !XORKey(pass, kind: .text).isEmpty else {
                throw XORError.wrapPassphraseRequired
            }
            let wrap = XORKey(pass, kind: .text)
            let unwrapped = XOREngine.encrypt(info.keyData, key: wrap)
            let recovered: XORKey
            switch info.keyKind {
            case .file:
                recovered = XORKey(fileBytes: Array(unwrapped), name: "key")
            case .text, .hex:
                let raw = String(data: unwrapped, encoding: .utf8)
                    ?? String(data: unwrapped, encoding: .isoLatin1)
                    ?? ""
                recovered = XORKey(raw, kind: info.keyKind)
            }
            guard !recovered.isEmpty else { throw XORError.wrongSecret }
            return recovered
        }
        let stored = info.xorKey
        guard !stored.isEmpty else { throw XORError.emptyKey }
        return stored
    }

    public static func isXORFile(at url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        let head = (try? h.read(upToCount: 4)) ?? Data()
        return head == magic
    }

    public static func exactPayloadCount(payloadSize: UInt64, payloadStart: Int, dataCount: Int) -> Int? {
        guard payloadStart >= 0, payloadStart <= dataCount else { return nil }
        guard let payloadCount = Int(exactly: payloadSize) else { return nil }
        guard payloadCount >= 0, payloadCount <= dataCount - payloadStart else { return nil }
        return payloadCount
    }

    // MARK: - Atomic output

    public static func writeAtomically(to destination: URL, work: (URL) throws -> Void) throws {
        let fm = FileManager.default
        let dir = destination.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let temp = dir.appendingPathComponent(".xor-\(UUID().uuidString).tmp")
        do {
            try work(temp)
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(
                    destination,
                    withItemAt: temp,
                    backupItemName: nil,
                    options: []
                )
            } else {
                try fm.moveItem(at: temp, to: destination)
            }
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    // MARK: - Encrypt

    public static func encryptFile(
        at source: URL,
        to destination: URL,
        key: XORKey,
        encryptNames: Bool = false,
        storage: KeyStorage = .store,
        wrapPassphrase: String = ""
    ) throws {
        try validateKey(key)
        let plainName = source.lastPathComponent
        let storedName = encryptNames
            ? XOREngine.transformFileName(plainName, key: key)
            : plainName
        var flags: UInt8 = 0
        if encryptNames { flags |= flagEncryptNames }

        try writeAtomically(to: destination) { temp in
            try encryptPayloadFile(
                at: source,
                to: temp,
                key: key,
                originalName: storedName,
                flags: flags,
                storage: storage,
                wrapPassphrase: wrapPassphrase
            )
        }
    }

    public static func encryptDirectory(
        at source: URL,
        to destination: URL,
        key: XORKey,
        encryptNames: Bool = false,
        storage: KeyStorage = .store,
        wrapPassphrase: String = ""
    ) throws {
        try validateKey(key)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDir),
              isDir.boolValue else {
            throw XORError.notDirectory
        }

        let fm = FileManager.default
        let tempZip = fm.temporaryDirectory
            .appendingPathComponent("xor_dir_\(UUID().uuidString).zip")
        let tempTree = fm.temporaryDirectory
            .appendingPathComponent("xor_tree_\(UUID().uuidString)")
        defer {
            try? fm.removeItem(at: tempZip)
            try? fm.removeItem(at: tempTree)
        }

        let packRoot: URL
        let storedFolderName: String
        var flags = flagDirectory

        if encryptNames {
            flags |= flagEncryptNames
            storedFolderName = XOREngine.transformFileName(source.lastPathComponent, key: key)
            let mirroredRoot = tempTree.appendingPathComponent(storedFolderName)
            try mirrorDirectory(from: source, to: mirroredRoot, key: key, encryptNames: true)
            packRoot = mirroredRoot
        } else {
            storedFolderName = source.lastPathComponent
            packRoot = source
        }

        try zipDirectory(packRoot, to: tempZip)
        try writeAtomically(to: destination) { temp in
            try encryptPayloadFile(
                at: tempZip,
                to: temp,
                key: key,
                originalName: storedFolderName,
                flags: flags,
                storage: storage,
                wrapPassphrase: wrapPassphrase
            )
        }
    }

    private static func mirrorDirectory(
        from source: URL,
        to destination: URL,
        key: XORKey,
        encryptNames: Bool
    ) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        let children = try fm.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsPackageDescendants]
        )

        var usedNames = Set<String>()

        for child in children {
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                continue
            }
            let isSubdir = values.isDirectory == true

            var outName = encryptNames
                ? XOREngine.transformFileName(child.lastPathComponent, key: key)
                : child.lastPathComponent

            if usedNames.contains(outName) {
                var n = 2
                let base = outName
                while usedNames.contains("\(base)_\(n)") { n += 1 }
                outName = "\(base)_\(n)"
            }
            usedNames.insert(outName)

            let destChild = destination.appendingPathComponent(outName)
            if isSubdir {
                try mirrorDirectory(from: child, to: destChild, key: key, encryptNames: encryptNames)
            } else {
                try fm.copyItem(at: child, to: destChild)
            }
        }
    }

    private static func encryptPayloadFile(
        at source: URL,
        to destination: URL,
        key: XORKey,
        originalName: String,
        flags: UInt8,
        storage: KeyStorage = .store,
        wrapPassphrase: String = ""
    ) throws {
        let nameData = Data(originalName.utf8)
        let encoded = try encodedKeyField(key: key, storage: storage, wrapPassphrase: wrapPassphrase)
        let keyData = encoded.data
        let headerFlags = flags | encoded.extraFlags
        guard nameData.count <= Int(UInt16.max) else {
            throw XORError.nameTooLong
        }

        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        var header = Data()
        header.append(magic)
        header.appendUInt16LE(version)
        header.append(key.kind.formatByte)
        header.append(headerFlags)
        header.appendUInt16LE(UInt16(keyData.count))
        header.appendUInt64LE(0)
        header.appendUInt64LE(0)
        header.appendUInt32LE(0)
        header.appendUInt16LE(UInt16(nameData.count))
        header.append(nameData)
        header.append(keyData)
        try output.write(contentsOf: header)

        var originalSize: UInt64 = 0
        var payloadSize: UInt64 = 0
        var crc = CRC32()
        var cursor = 0
        let chunkSize = 1024 * 1024

        while true {
            let chunk = try input.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            originalSize += UInt64(chunk.count)
            crc.update(chunk)
            let encrypted = XOREngine.transform(chunk, key: key, cursor: &cursor)
            try output.write(contentsOf: encrypted)
            payloadSize += UInt64(encrypted.count)
        }

        try output.seek(toOffset: 10)
        var sizes = Data()
        sizes.appendUInt64LE(originalSize)
        sizes.appendUInt64LE(payloadSize)
        sizes.appendUInt32LE(crc.final)
        try output.write(contentsOf: sizes)
        try output.synchronize()
    }

    public static func encryptText(
        _ text: String,
        key: XORKey,
        originalName: String = "text.txt",
        storage: KeyStorage = .store,
        wrapPassphrase: String = ""
    ) throws -> Data {
        try validateKey(key)
        let data = Data(text.utf8)
        let payload = XOREngine.encrypt(data, key: key)
        let nameData = Data(originalName.utf8)
        let encoded = try encodedKeyField(key: key, storage: storage, wrapPassphrase: wrapPassphrase)
        let keyData = encoded.data
        guard nameData.count <= Int(UInt16.max) else {
            throw XORError.nameTooLong
        }

        var out = Data()
        out.append(magic)
        out.appendUInt16LE(version)
        out.append(key.kind.formatByte)
        out.append(encoded.extraFlags)
        out.appendUInt16LE(UInt16(keyData.count))
        out.appendUInt64LE(UInt64(data.count))
        out.appendUInt64LE(UInt64(payload.count))
        out.appendUInt32LE(CRC32.checksum(data))
        out.appendUInt16LE(UInt16(nameData.count))
        out.append(nameData)
        out.append(keyData)
        out.append(payload)
        return out
    }

    // MARK: - Decrypt

    public static func readInfo(from url: URL) throws -> Info {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let fixed = try handle.read(upToCount: headerFixedSize) ?? Data()
        guard fixed.count == headerFixedSize, fixed.prefix(4) == magic else {
            throw XORError.notXOR
        }

        var o = 4
        let ver = fixed.readUInt16LE(at: &o)
        guard ver == version else { throw XORError.badVersion(Int(ver)) }

        let method = fixed[o]; o += 1
        let flags = fixed[o]; o += 1
        let keyLen = Int(fixed.readUInt16LE(at: &o))
        let originalSize = fixed.readUInt64LE(at: &o)
        let payloadSize = fixed.readUInt64LE(at: &o)
        let crc = fixed.readUInt32LE(at: &o)
        let nameLen = Int(fixed.readUInt16LE(at: &o))

        var name: String?
        if nameLen > 0 {
            let bytes = try handle.read(upToCount: nameLen) ?? Data()
            guard bytes.count == nameLen else { throw XORError.corrupt }
            name = String(data: bytes, encoding: .utf8)
                ?? String(data: bytes, encoding: .isoLatin1)
        }

        var keyData = Data()
        if keyLen > 0 {
            let bytes = try handle.read(upToCount: keyLen) ?? Data()
            guard bytes.count == keyLen else { throw XORError.corrupt }
            keyData = bytes
        }

        return Info(
            keyData: keyData,
            method: method,
            flags: flags,
            originalSize: originalSize,
            payloadSize: payloadSize,
            crc32: crc,
            originalName: sanitizeName(name)
        )
    }

    public static func decrypt(
        at source: URL,
        to destination: URL,
        suppliedKey: XORKey? = nil,
        wrapPassphrase: String? = nil
    ) throws -> Info {
        let info = try readInfo(from: source)
        guard KeyKind.from(formatByte: info.method) != nil else {
            throw XORError.unknownMethod(Int(info.method))
        }
        let key = try resolveKey(from: info, suppliedKey: suppliedKey, wrapPassphrase: wrapPassphrase)

        if info.isDirectory {
            return try decryptDirectory(at: source, to: destination, info: info, key: key)
        }

        try writeAtomically(to: destination) { temp in
            _ = try decryptStreaming(at: source, to: temp, info: info, key: key)
        }
        return info
    }

    private static func decryptStreaming(at source: URL, to destination: URL, info: Info, key: XORKey) throws -> Info {
        guard KeyKind.from(formatByte: info.method) != nil else {
            throw XORError.unknownMethod(Int(info.method))
        }
        guard !key.isEmpty else { throw XORError.emptyKey }
        guard info.payloadSize <= UInt64(Int.max) else { throw XORError.corrupt }

        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }

        try input.seek(toOffset: 0)
        let fixed = try input.read(upToCount: headerFixedSize) ?? Data()
        guard fixed.count == headerFixedSize else { throw XORError.corrupt }
        var off = 8
        let keyLen = Int(fixed.readUInt16LE(at: &off))
        off = 30
        let nameLen = Int(fixed.readUInt16LE(at: &off))
        if nameLen > 0 {
            let skipped = try input.read(upToCount: nameLen) ?? Data()
            guard skipped.count == nameLen else { throw XORError.corrupt }
        }
        if keyLen > 0 {
            let skipped = try input.read(upToCount: keyLen) ?? Data()
            guard skipped.count == keyLen else { throw XORError.corrupt }
        }

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        var restored: UInt64 = 0
        var crc = CRC32()
        var remaining = info.payloadSize
        var cursor = 0
        let chunkSize = 1024 * 1024

        do {
            while remaining > 0 {
                let n = Int(min(UInt64(chunkSize), remaining))
                let chunk = try input.read(upToCount: n) ?? Data()
                if chunk.isEmpty { throw XORError.corrupt }

                let plain = XOREngine.transform(chunk, key: key, cursor: &cursor)
                try output.write(contentsOf: plain)
                crc.update(plain)
                restored += UInt64(plain.count)
                remaining -= UInt64(chunk.count)
            }

            try output.synchronize()
            try output.close()

            if info.crc32 != 0, crc.final != info.crc32 {
                throw info.needsSecret ? XORError.wrongSecret : XORError.checksumFailed
            }
            if info.originalSize != 0, restored != info.originalSize {
                throw XORError.corrupt
            }
        } catch {
            try? output.close()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }

        return info
    }

    private static func decryptDirectory(at source: URL, to destination: URL, info: Info, key: XORKey) throws -> Info {
        let fm = FileManager.default
        let tempZip = fm.temporaryDirectory.appendingPathComponent("xor_unz_\(UUID().uuidString).zip")
        let tempExtract = fm.temporaryDirectory.appendingPathComponent("xor_ext_\(UUID().uuidString)")
        defer {
            try? fm.removeItem(at: tempZip)
            try? fm.removeItem(at: tempExtract)
        }

        _ = try decryptStreaming(at: source, to: tempZip, info: info, key: key)

        try validateZipArchive(at: tempZip)

        try fm.createDirectory(at: tempExtract, withIntermediateDirectories: true)
        try unzip(tempZip, toDirectory: tempExtract)

        try validateExtractedTree(root: tempExtract)

        let children = try fm.contentsOfDirectory(
            at: tempExtract,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ).filter { $0.lastPathComponent != ".DS_Store" }

        let staging: URL
        if children.isEmpty {
            staging = tempExtract.appendingPathComponent("_empty")
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        } else if children.count == 1 {
            staging = children[0]
        } else {
            staging = tempExtract.appendingPathComponent("_root")
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            for child in children {
                try fm.moveItem(at: child, to: staging.appendingPathComponent(child.lastPathComponent))
            }
        }

        if info.encryptsNames {
            try decryptNamesInTree(at: staging, key: key)
        }

        try writeAtomically(to: destination) { tempDest in
            if fm.fileExists(atPath: tempDest.path) {
                try fm.removeItem(at: tempDest)
            }
            try fm.moveItem(at: staging, to: tempDest)
        }

        return info
    }

    private static func decryptNamesInTree(at root: URL, key: XORKey) throws {
        let fm = FileManager.default
        let children = try fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )

        for child in children {
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                throw XORError.unsafeArchivePath(child.lastPathComponent)
            }
            if values.isDirectory == true {
                try decryptNamesInTree(at: child, key: key)
            }
        }

        for child in children {
            guard fm.fileExists(atPath: child.path) else { continue }
            let plain = XOREngine.transformFileName(child.lastPathComponent, key: key, decrypt: true)
            if plain != child.lastPathComponent {
                var finalDest = child.deletingLastPathComponent().appendingPathComponent(plain)
                if fm.fileExists(atPath: finalDest.path) {
                    finalDest = XOREngine.uniqueURL(
                        in: child.deletingLastPathComponent(),
                        preferredName: plain
                    )
                }
                try fm.moveItem(at: child, to: finalDest)
            }
        }
    }

    // MARK: - ZIP safety

    private static let zipLocalSig: UInt32 = 0x04034b50
    private static let zipCentralSig: UInt32 = 0x02014b50
    private static let zipEOCDSig: UInt32 = 0x06054b50
    private static let zipUnixSymlinkMode: UInt32 = 0o120000

    public static func validateZipArchive(at url: URL) throws {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        try validateZipData(data)
    }

    public static func validateZipData(_ data: Data) throws {
        if let eocd = findEndOfCentralDirectory(in: data) {
            try validateZipCentralDirectory(data, eocdOffset: eocd)
            return
        }
        try validateZipLocalHeaders(data)
    }

    public static func findEndOfCentralDirectory(in data: Data) -> Int? {
        let minEOCD = 22
        guard data.count >= minEOCD else { return nil }
        let maxComment = 65_535
        let searchStart = max(0, data.count - (maxComment + minEOCD))
        var i = data.count - minEOCD
        while i >= searchStart {
            if data.readUInt32LE(atAbsolute: i) == zipEOCDSig {
                let commentLen = Int(data.readUInt16LE(atAbsolute: i + 20))
                if i + minEOCD + commentLen == data.count {
                    return i
                }
            }
            if i == 0 { break }
            i -= 1
        }
        return nil
    }

    private static func validateZipCentralDirectory(_ data: Data, eocdOffset: Int) throws {
        guard eocdOffset + 22 <= data.count else { throw XORError.corrupt }

        let totalEntries = Int(data.readUInt16LE(atAbsolute: eocdOffset + 10))
        let cdSize = data.readUInt32LE(atAbsolute: eocdOffset + 12)
        let cdOffset = data.readUInt32LE(atAbsolute: eocdOffset + 16)

        guard let cdStart = Int(exactly: cdOffset),
              let cdBytes = Int(exactly: cdSize),
              cdStart >= 0,
              cdStart <= data.count,
              cdBytes >= 0,
              cdStart <= data.count - cdBytes else {
            throw XORError.corrupt
        }

        var offset = cdStart
        let cdEnd = cdStart + cdBytes
        var seen = 0

        while offset + 46 <= cdEnd {
            let sig = data.readUInt32LE(atAbsolute: offset)
            guard sig == zipCentralSig else { break }

            let externalAttrs = data.readUInt32LE(atAbsolute: offset + 38)
            let nameLen = Int(data.readUInt16LE(atAbsolute: offset + 28))
            let extraLen = Int(data.readUInt16LE(atAbsolute: offset + 30))
            let commentLen = Int(data.readUInt16LE(atAbsolute: offset + 32))

            let nameStart = offset + 46
            guard nameStart <= data.count,
                  nameLen >= 0,
                  nameStart <= data.count - nameLen else {
                throw XORError.corrupt
            }
            let nameEnd = nameStart + nameLen
            let nameData = data.subdata(in: nameStart..<nameEnd)
            let name = String(data: nameData, encoding: .utf8)
                ?? String(data: nameData, encoding: .isoLatin1)
                ?? ""
            try validateArchiveEntryPath(name)

            let mode = (externalAttrs >> 16) & 0xFFFF
            if (mode & 0xF000) == zipUnixSymlinkMode {
                throw XORError.unsafeArchivePath(name.isEmpty ? "(symlink)" : name)
            }

            let recordEnd = nameEnd + extraLen + commentLen
            guard recordEnd >= nameEnd, recordEnd <= data.count else {
                throw XORError.corrupt
            }
            offset = recordEnd
            seen += 1
        }

        if totalEntries > 0, seen == 0 {
            throw XORError.corrupt
        }
    }

    private static func validateZipLocalHeaders(_ data: Data) throws {
        var offset = 0

        while offset + 4 <= data.count {
            let sig = data.readUInt32LE(atAbsolute: offset)
            if sig == zipCentralSig || sig == zipEOCDSig {
                break
            }
            guard sig == zipLocalSig else {
                offset += 1
                continue
            }
            guard offset + 30 <= data.count else { throw XORError.corrupt }

            let flags = data.readUInt16LE(atAbsolute: offset + 6)
            let compSize = data.readUInt32LE(atAbsolute: offset + 18)
            let nameLen = Int(data.readUInt16LE(atAbsolute: offset + 26))
            let extraLen = Int(data.readUInt16LE(atAbsolute: offset + 28))
            let nameStart = offset + 30
            guard nameStart <= data.count - nameLen else { throw XORError.corrupt }
            let nameEnd = nameStart + nameLen

            let nameData = data.subdata(in: nameStart..<nameEnd)
            let name = String(data: nameData, encoding: .utf8)
                ?? String(data: nameData, encoding: .isoLatin1)
                ?? ""
            try validateArchiveEntryPath(name)

            guard nameEnd <= data.count - extraLen else { throw XORError.corrupt }
            var next = nameEnd + extraLen

            if (flags & 0x08) != 0 {
                offset = next
                while offset + 4 <= data.count {
                    let s = data.readUInt32LE(atAbsolute: offset)
                    if s == zipLocalSig || s == zipCentralSig || s == zipEOCDSig {
                        break
                    }
                    offset += 1
                }
                continue
            }

            guard let comp = Int(exactly: compSize) else { throw XORError.corrupt }
            guard next <= data.count - comp else { throw XORError.corrupt }
            next += comp
            offset = next
        }
    }

    public static func validateArchiveEntryPath(_ name: String) throws {
        if name.isEmpty { return }
        if name.hasPrefix("/") || name.hasPrefix("\\") {
            throw XORError.unsafeArchivePath(name)
        }
        if name.contains("\0") {
            throw XORError.unsafeArchivePath(name)
        }
        if name.count >= 2, name[name.index(name.startIndex, offsetBy: 1)] == ":" {
            throw XORError.unsafeArchivePath(name)
        }
        let parts = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for part in parts {
            if part == ".." {
                throw XORError.unsafeArchivePath(name)
            }
            if part.contains("\\") {
                let sub = part.split(separator: "\\").map(String.init)
                if sub.contains("..") {
                    throw XORError.unsafeArchivePath(name)
                }
            }
        }
    }

    public static func validateExtractedTree(root: URL) throws {
        let fm = FileManager.default
        let rootResolved = root.resolvingSymlinksInPath().standardizedFileURL
        let rootComponents = rootResolved.pathComponents

        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return }

        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                throw XORError.unsafeArchivePath(fileURL.lastPathComponent)
            }
            let resolved = fileURL.resolvingSymlinksInPath().standardizedFileURL
            let childComponents = resolved.pathComponents
            guard childComponents.starts(with: rootComponents) else {
                throw XORError.unsafeArchivePath(fileURL.lastPathComponent)
            }
            let relative = childComponents.dropFirst(rootComponents.count).joined(separator: "/")
            if !relative.isEmpty {
                try validateArchiveEntryPath(relative)
            }
        }
    }

    public static func isPath(_ child: URL, under root: URL) -> Bool {
        let r = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let c = child.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        return c.starts(with: r)
    }

    // MARK: - ZIP via ditto

    private static func zipDirectory(_ source: URL, to zipURL: URL) throws {
        if FileManager.default.fileExists(atPath: zipURL.path) {
            try FileManager.default.removeItem(at: zipURL)
        }
        try runDitto(arguments: ["-c", "-k", "--keepParent", source.path, zipURL.path])
    }

    private static func unzip(_ zipURL: URL, toDirectory directory: URL) throws {
        try runDitto(arguments: ["-x", "-k", zipURL.path, directory.path])
    }

    private static func runDitto(arguments: [String]) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        proc.arguments = arguments
        let err = Pipe()
        proc.standardError = err
        proc.standardOutput = Pipe()
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw XORError.zipFailed(msg.isEmpty ? "ditto exit \(proc.terminationStatus)" : msg)
        }
    }

    // MARK: - Paths

    public static func archiveURL(for source: URL, key: XORKey = XORKey(""), encryptNames: Bool = false) -> URL {
        let dir = source.deletingLastPathComponent()
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: source.path, isDirectory: &isDir)

        let baseName: String
        if encryptNames, !key.isEmpty {
            baseName = XOREngine.transformFileName(source.lastPathComponent, key: key)
        } else {
            baseName = source.lastPathComponent
        }

        if isDir.boolValue {
            return XOREngine.uniqueURL(
                in: dir,
                preferredName: "\(baseName).\(fileExtension)"
            )
        }

        if source.pathExtension.lowercased() == fileExtension {
            return XOREngine.uniqueURL(in: dir, preferredName: baseName)
        }

        if encryptNames {
            return XOREngine.uniqueURL(in: dir, preferredName: "\(baseName).\(fileExtension)")
        }
        let stem = source.deletingPathExtension().lastPathComponent
        return XOREngine.uniqueURL(in: dir, preferredName: "\(stem).\(fileExtension)")
    }

    public static func restoreURL(for archive: URL, info: Info, key: XORKey? = nil) -> URL {
        let dir = archive.deletingLastPathComponent()
        let resolved = key ?? info.xorKey
        let name = sanitizeName(info.restoredName(using: resolved))
            ?? sanitizeName(info.originalName)
            ?? archive.deletingPathExtension().lastPathComponent
        return XOREngine.uniqueURL(in: dir, preferredName: name)
    }

    public static func directoryContentSize(_ url: URL) -> Int {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return 0 }

        var total = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [
                .isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey
            ]) else { continue }
            if values.isSymbolicLink == true { continue }
            guard values.isRegularFile == true else { continue }
            total += values.fileSize ?? 0
        }
        return total
    }

    public static func validateKey(_ key: XORKey) throws {
        guard !key.isEmpty else { throw XORError.emptyKey }
        if key.kind == .hex, XOREngine.parseHex(key.raw) == nil {
            throw XORError.invalidHexKey
        }
    }

    private static func sanitizeName(_ name: String?) -> String? {
        guard var n = name?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty else {
            return nil
        }
        n = (n as NSString).lastPathComponent
        if n == "." || n == ".." || n.contains("/") { return nil }
        return n
    }
}

// MARK: - Errors

public enum XORError: LocalizedError, Equatable {
    case notXOR
    case badVersion(Int)
    case corrupt
    case checksumFailed
    case nameTooLong
    case keyTooLong
    case emptyKey
    case keyRequired
    case wrapPassphraseRequired
    case wrongSecret
    case invalidHexKey
    case unknownMethod(Int)
    case notDirectory
    case zipFailed(String)
    case unsafeArchivePath(String)

    public var errorDescription: String? {
        switch self {
        case .notXOR:
            return "Not a .xor file."
        case .badVersion(let v):
            return "Unsupported .xor version \(v)."
        case .corrupt:
            return "The .xor file is damaged or incomplete."
        case .checksumFailed:
            return "Checksum failed — the archive may be corrupted."
        case .nameTooLong:
            return "Filename is too long."
        case .keyTooLong:
            return "Key is too long to store in the .xor header (max 65,535 bytes). Choose Don’t store and keep the key file separately."
        case .emptyKey:
            return "Enter a key."
        case .keyRequired:
            return "This .xor file does not store the key. Enter the same key used to encrypt."
        case .wrapPassphraseRequired:
            return "This .xor file’s key is encrypted. Enter the wrap passphrase."
        case .wrongSecret:
            return "Wrong key or wrap passphrase — the file did not decrypt."
        case .invalidHexKey:
            return "Hex key needs an even number of hex digits (0–9, A–F)."
        case .unknownMethod(let m):
            return "Unknown key method (\(m)) in this .xor file."
        case .notDirectory:
            return "Not a directory."
        case .zipFailed(let detail):
            return "Could not pack/unpack folder: \(detail)"
        case .unsafeArchivePath(let path):
            return "Refusing unsafe path in archive: \(path)"
        }
    }
}

// MARK: - Binary helpers

public extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }

    mutating func appendUInt64LE(_ value: UInt64) {
        for i in 0..<8 { append(UInt8((value >> (i * 8)) & 0xFF)) }
    }

    func readUInt16LE(at offset: inout Int) -> UInt16 {
        precondition(offset + 2 <= count, "readUInt16LE out of bounds")
        let v = UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
        offset += 2
        return v
    }

    func readUInt32LE(at offset: inout Int) -> UInt32 {
        precondition(offset + 4 <= count, "readUInt32LE out of bounds")
        let v = UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
        offset += 4
        return v
    }

    func readUInt64LE(at offset: inout Int) -> UInt64 {
        precondition(offset + 8 <= count, "readUInt64LE out of bounds")
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(self[offset + i]) << (i * 8) }
        offset += 8
        return v
    }

    func readUInt16LE(atAbsolute offset: Int) -> UInt16 {
        precondition(offset + 2 <= count, "readUInt16LE absolute out of bounds")
        return UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func readUInt32LE(atAbsolute offset: Int) -> UInt32 {
        precondition(offset + 4 <= count, "readUInt32LE absolute out of bounds")
        return UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }
}

// MARK: - CRC-32

public struct CRC32: Sendable {
    private static let table: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    private var value: UInt32 = 0xFFFFFFFF

    mutating func update(_ data: Data) {
        for byte in data {
            value = CRC32.table[Int((value ^ UInt32(byte)) & 0xFF)] ^ (value >> 8)
        }
    }

    public var final: UInt32 { value ^ 0xFFFFFFFF }

    public static func checksum(_ data: Data) -> UInt32 {
        var c = CRC32()
        c.update(data)
        return c.final
    }
}
