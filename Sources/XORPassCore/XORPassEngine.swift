import Foundation
import CryptoKit
import Security
import CArgon2
import Darwin

// MARK: - Profile

/// Argon2id settings stored in the file so a later default still opens it.
public struct XORPassProfile: Equatable, Hashable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var memoryKiB: UInt32
    public var iterations: UInt32
    public var parallelism: UInt32

    public init(name: String, memoryKiB: UInt32, iterations: UInt32, parallelism: UInt32) {
        self.name = name
        self.memoryKiB = memoryKiB
        self.iterations = iterations
        self.parallelism = parallelism
    }

    /// RFC 9106 second recommendation: 64 MiB, t=3, p=4.
    public static let standard = XORPassProfile(
        name: "Standard", memoryKiB: 65_536, iterations: 3, parallelism: 4
    )

    /// Heavier stretch for a password that protects something more valuable.
    public static let high = XORPassProfile(
        name: "High", memoryKiB: 131_072, iterations: 4, parallelism: 4
    )

    public static let choices: [XORPassProfile] = [.standard, .high]

    public static let minMemoryKiB: UInt32 = 8_192
    public static let maxMemoryKiB: UInt32 = 262_144
    public static let minIterations: UInt32 = 2
    public static let maxIterations: UInt32 = 8
    public static let minParallelism: UInt32 = 1
    public static let maxParallelism: UInt32 = 4

    public var parameterLabel: String {
        let miB = Double(memoryKiB) / 1024.0
        let mem = miB >= 10
            ? String(format: "%.0f MiB", miB)
            : String(format: "%.1f MiB", miB)
        let lanes = parallelism == 1 ? "1 lane" : "\(parallelism) lanes"
        let passes = iterations == 1 ? "1 pass" : "\(iterations) passes"
        return "Argon2id · \(mem) · \(passes) · \(lanes)"
    }

    public func validate() throws {
        guard memoryKiB >= Self.minMemoryKiB, memoryKiB <= Self.maxMemoryKiB,
              iterations >= Self.minIterations, iterations <= Self.maxIterations,
              parallelism >= Self.minParallelism, parallelism <= Self.maxParallelism
        else { throw XORPassError.kdfParametersRejected }
    }

    static func stored(memoryKiB: UInt32, iterations: UInt32, parallelism: UInt32) -> XORPassProfile {
        if let known = choices.first(where: {
            $0.memoryKiB == memoryKiB && $0.iterations == iterations && $0.parallelism == parallelism
        }) {
            return known
        }
        return XORPassProfile(
            name: "Stored",
            memoryKiB: memoryKiB,
            iterations: iterations,
            parallelism: parallelism
        )
    }
}

// MARK: - Errors

public enum XORPassError: LocalizedError, Equatable {
    case emptyPassword
    case missingSecret
    case keyFileRequired
    case keyFileTooLarge
    case passwordTooLong
    case notXORPass
    case badVersion(Int)
    case unsupportedFeature
    case corrupt
    case authenticationFailed
    case kdfParametersRejected
    case keyDerivationFailed
    case randomFailed
    case nameTooLong
    case unsafeName
    case payloadTooLarge
    case notDirectory
    case zipFailed(String)
    case symlinkRejected(String)
    case unsafeArchivePath(String)
    case permissionFailed

    public var errorDescription: String? {
        switch self {
        case .emptyPassword:
            return "Enter a password."
        case .missingSecret:
            return "Enter a password or choose a key file."
        case .keyFileRequired:
            return "Choose the key file used to encrypt this archive."
        case .keyFileTooLarge:
            return "Key file is larger than 64 MiB."
        case .passwordTooLong:
            return "Password is too long."
        case .notXORPass:
            return "Not a .xorpass file."
        case .badVersion(let v):
            return "Unsupported .xorpass version \(v)."
        case .unsupportedFeature:
            return "This file uses a feature this version of XOR Pass does not read."
        case .corrupt:
            return "The .xorpass file is damaged or incomplete."
        case .authenticationFailed:
            return "Wrong password or key file, or the file was modified."
        case .kdfParametersRejected:
            return "This file's Argon2id settings are outside the limits this app will run."
        case .keyDerivationFailed:
            return "Argon2id key derivation failed."
        case .randomFailed:
            return "Could not generate secure random bytes."
        case .nameTooLong:
            return "The file name is longer than 255 bytes."
        case .unsafeName:
            return "The file name is not safe to write."
        case .payloadTooLarge:
            return "The file is larger than 32 GiB."
        case .notDirectory:
            return "Not a folder."
        case .zipFailed(let detail):
            return "Could not pack or unpack the folder: \(detail)"
        case .symlinkRejected(let name):
            return "This folder contains a symlink (\(name)). XOR Pass will not pack symlinks."
        case .unsafeArchivePath(let path):
            return "Refusing an unsafe path in the archive: \(path)"
        case .permissionFailed:
            return "Could not set file permissions."
        }
    }
}

// MARK: - Opened package

public struct XORPassOpened: Sendable, Equatable {
    public var name: String
    public var plaintext: Data
    public var directory: Bool
    public var profile: XORPassProfile
    public var padding: XORPassPadding
}

/// How much the ciphertext hides the plaintext length. Standard is the 1.0 layout.
public enum XORPassPadding: UInt16, CaseIterable, Identifiable, Sendable {
    case standard = 0
    case hidden = 1
    case maximum = 2

    public var id: UInt16 { rawValue }

    public var title: String {
        switch self {
        case .standard: return "Standard"
        case .hidden: return "Private"
        case .maximum: return "Maximum"
        }
    }

    public var detail: String {
        switch self {
        case .standard:
            return "256-byte buckets under 4 KiB, then 4 KiB"
        case .hidden:
            return "4 KiB, then 64 KiB, 1 MiB, and 16 MiB buckets"
        case .maximum:
            return "Next power of two"
        }
    }
}

// MARK: - Engine

/// Password file cipher. The bytes are XOR'd with a keystream.
///
/// ```
/// master   = Argon2id(password, salt) → 32 bytes
/// bodyKey  = HMAC-SHA256(master, "XORPass-body-v1" ‖ nonce)
/// nameKey  = HMAC-SHA256(master, "XORPass-name-v1" ‖ nonce)
/// macKey   = HMAC-SHA256(master, "XORPass-mac-v1" ‖ nonce)
/// KS_i     = HMAC-SHA256(purposeKey, uint64_be(i))
/// C        = P ⊕ KS
/// tag      = HMAC-SHA256(macKey, header ‖ ciphertext)
/// ```
///
/// The password is not written into the file. Salt and nonce are random per file.
public enum XORPassEngine {
    public static let magic = Data([0x58, 0x4F, 0x50, 0x31]) // XOP1
    public static let version: UInt16 = 1
    public static let headerLength = 320
    public static let saltLength = 16
    public static let nonceLength = 16
    public static let nameFieldLength = 256
    public static let tagLength = 32
    public static let keyLength = 32
    public static let maxPayload: UInt64 = 32 * 1024 * 1024 * 1024
    public static let maxPasswordBytes = 4096
    /// Raw key files are hashed into Argon2id. This cap avoids loading a huge file by mistake.
    public static let maxKeyFileBytes = 64 * 1024 * 1024

    static let flagDirectory: UInt16 = 0x0001
    static let flagKeyFile: UInt16 = 0x0002
    /// Set only together with `flagKeyFile`, when a password was used as well.
    static let flagPassword: UInt16 = 0x0004
    /// Bits 3–4. 0 standard, 1 private, 2 maximum. 3 is rejected.
    static let flagPadMask: UInt16 = 0x0018
    static let knownFlags: UInt16 = flagDirectory | flagKeyFile | flagPassword | flagPadMask
    static let chunkSize = 1 << 20

    public struct Peek: Sendable, Equatable {
        public var directory: Bool
        public var needsKeyFile: Bool
        public var needsPassword: Bool
        public var padding: XORPassPadding
        public var profile: XORPassProfile
        public var cipherBytes: UInt64

        public var protectionLabel: String {
            if needsKeyFile && needsPassword { return "Protection: Password + key file" }
            if needsKeyFile { return "Protection: Key file only" }
            return "Protection: Password"
        }
    }

    // MARK: Password

    public static func normalizePassword(_ password: String) -> String {
        password.precomposedStringWithCanonicalMapping
    }

    // MARK: In-memory seal / open

    /// `salt` and `nonce` are optional so tests can pin them. The app leaves both nil.
    public static func seal(
        _ plaintext: Data,
        name: String,
        password: String,
        profile: XORPassProfile = .standard,
        directory: Bool = false,
        salt: Data? = nil,
        nonce: Data? = nil,
        keyFile: Data = Data(),
        padding: XORPassPadding = .standard
    ) throws -> Data {
        var offset = 0
        var output = Data()
        output.reserveCapacity(headerLength + plaintext.count + tagLength + 4096)
        try encryptReader(
            plainBytes: UInt64(plaintext.count),
            name: name,
            password: password,
            profile: profile,
            directory: directory,
            salt: salt,
            nonce: nonce,
            keyFile: keyFile,
            padding: padding,
            read: { count in
                let end = min(offset + count, plaintext.count)
                guard offset <= end else { throw XORPassError.corrupt }
                let slice = plaintext.subdata(in: offset..<end)
                offset = end
                return slice
            },
            write: { output.append($0) }
        )
        return output
    }

    public static func open(_ package: Data, password: String, keyFile: Data = Data()) throws -> XORPassOpened {
        var plain = Data()
        let verified = try verifyPackage(
            password: password,
            keyFile: keyFile,
            totalSize: UInt64(package.count),
            readAt: { offset, count in
                try slice(package, offset: offset, count: count)
            }
        )
        let count = try writeCheckedPlaintext(
            verified: verified,
            cipherLength: verified.cipherLength,
            readAt: { offset, count in
                try slice(package, offset: offset, count: count)
            },
            write: { plain.append($0) }
        )
        guard UInt64(plain.count) == count else { throw XORPassError.corrupt }
        return XORPassOpened(
            name: verified.name,
            plaintext: plain,
            directory: verified.directory,
            profile: verified.profile,
            padding: verified.padding
        )
    }

    public static func peek(_ package: Data) throws -> Peek {
        guard package.count >= headerLength else { throw XORPassError.corrupt }
        let header = package.prefix(headerLength)
        let parsed = try parseHeader(Data(header))
        return Peek(
            directory: parsed.directory,
            needsKeyFile: parsed.needsKeyFile,
            needsPassword: parsed.needsPassword,
            padding: parsed.padding,
            profile: parsed.profile,
            cipherBytes: parsed.cipherLength
        )
    }

    /// Nil when the length cannot be padded without overflowing `UInt64`.
    public static func cipherLength(
        forPlaintextBytes count: UInt64,
        padding: XORPassPadding = .standard
    ) -> UInt64? {
        guard count <= maxPayload else { return nil }
        let (minTotal, overflow) = count.addingReportingOverflow(40)
        if overflow { return nil }
        switch padding {
        case .standard:
            let grain: UInt64 = minTotal <= 4096 ? 256 : 4096
            return roundUp(minTotal, grain: grain)
        case .hidden:
            let grain: UInt64
            if minTotal <= 64 * 1024 {
                grain = 4096
            } else if minTotal <= 1024 * 1024 {
                grain = 64 * 1024
            } else if minTotal <= 16 * 1024 * 1024 {
                grain = 1024 * 1024
            } else {
                grain = 16 * 1024 * 1024
            }
            return roundUp(minTotal, grain: grain)
        case .maximum:
            return nextPowerOfTwo(atLeast: max(minTotal, 256))
        }
    }

    private static func roundUp(_ value: UInt64, grain: UInt64) -> UInt64? {
        guard grain > 0 else { return nil }
        let (sum, overflow) = value.addingReportingOverflow(grain - 1)
        if overflow { return nil }
        return (sum / grain) * grain
    }

    private static func nextPowerOfTwo(atLeast value: UInt64) -> UInt64? {
        if value <= 1 { return 1 }
        var power: UInt64 = 1
        while power < value {
            let (next, overflow) = power.multipliedReportingOverflow(by: 2)
            if overflow { return nil }
            power = next
        }
        return power
    }

    // MARK: Streaming

    static func encryptReader(
        plainBytes: UInt64,
        name: String,
        password: String,
        profile: XORPassProfile,
        directory: Bool,
        salt suppliedSalt: Data?,
        nonce suppliedNonce: Data?,
        keyFile: Data = Data(),
        padding: XORPassPadding = .standard,
        read: (Int) throws -> Data,
        write: (Data) throws -> Void
    ) throws {
        let password = try normalizedPassword(password)
        guard !password.isEmpty || !keyFile.isEmpty else { throw XORPassError.missingSecret }
        guard keyFile.count <= maxKeyFileBytes else { throw XORPassError.keyFileTooLarge }
        try profile.validate()
        guard plainBytes <= maxPayload else { throw XORPassError.payloadTooLarge }
        let safeName = try validatedName(name)

        let salt = try suppliedOrRandom(suppliedSalt, length: saltLength)
        let nonce = try suppliedOrRandom(suppliedNonce, length: nonceLength)
        let master = try deriveMaster(password: password, keyFile: keyFile, salt: salt, profile: profile)
        let bodyKey = subkey(master: master, label: "XORPass-body-v1", nonce: nonce)
        let nameKey = subkey(master: master, label: "XORPass-name-v1", nonce: nonce)
        let macKey = subkey(master: master, label: "XORPass-mac-v1", nonce: nonce)

        let encryptedName = try sealName(safeName, key: nameKey)
        guard let cLen = cipherLength(forPlaintextBytes: plainBytes, padding: padding),
              cLen >= plainBytes &+ 40 else {
            throw XORPassError.payloadTooLarge
        }
        let header = buildHeader(
            profile: profile,
            salt: salt,
            nonce: nonce,
            cipherLength: cLen,
            encryptedName: encryptedName,
            flags: headerFlags(
                directory: directory,
                password: password,
                keyFile: keyFile,
                padding: padding
            )
        )

        var mac = HMAC<SHA256>(key: macKey)
        mac.update(data: header)
        try write(header)

        var stream = Keystream(key: bodyKey)
        let prefix = stream.xor(uint64LE(plainBytes))
        mac.update(data: prefix)
        try write(prefix)

        var left = plainBytes
        while left > 0 {
            let n = Int(min(left, UInt64(chunkSize)))
            let chunk = try read(n)
            guard chunk.count == n else { throw XORPassError.corrupt }
            let cipher = stream.xor(chunk)
            mac.update(data: cipher)
            try write(cipher)
            left -= UInt64(n)
        }

        var padLeft = cLen - plainBytes - 8
        while padLeft > 0 {
            let n = Int(min(padLeft, UInt64(chunkSize)))
            let rnd = try randomBytes(n)
            let cipher = stream.xor(rnd)
            mac.update(data: cipher)
            try write(cipher)
            padLeft -= UInt64(n)
        }

        try write(Data(mac.finalize()))
    }

    struct Verified {
        var name: String
        var directory: Bool
        var profile: XORPassProfile
        var bodyKey: SymmetricKey
        var cipherOffset: UInt64
        var cipherLength: UInt64
        var padding: XORPassPadding
    }

    static func verifyPackage(
        password: String,
        keyFile: Data = Data(),
        totalSize: UInt64,
        readAt: (UInt64, Int) throws -> Data
    ) throws -> Verified {
        let password = try normalizedPassword(password)
        guard totalSize >= UInt64(headerLength + tagLength) else { throw XORPassError.corrupt }

        let header = try readAt(0, headerLength)
        guard header.count == headerLength else { throw XORPassError.corrupt }
        let parsed = try parseHeader(header)

        let overhead = UInt64(headerLength + tagLength)
        guard totalSize >= overhead else { throw XORPassError.corrupt }
        guard parsed.cipherLength == totalSize - overhead else { throw XORPassError.corrupt }
        guard parsed.cipherLength >= 256, parsed.cipherLength % 256 == 0 else {
            throw XORPassError.corrupt
        }
        guard parsed.cipherLength <= maxPayload + 8192 else { throw XORPassError.payloadTooLarge }

        if parsed.needsKeyFile, keyFile.isEmpty { throw XORPassError.keyFileRequired }
        if parsed.needsPassword, password.isEmpty { throw XORPassError.emptyPassword }
        let usedPassword = parsed.needsPassword ? password : ""
        let usedKey = parsed.needsKeyFile ? keyFile : Data()
        guard usedKey.count <= maxKeyFileBytes else { throw XORPassError.keyFileTooLarge }
        let master = try deriveMaster(
            password: usedPassword,
            keyFile: usedKey,
            salt: parsed.salt,
            profile: parsed.profile
        )
        let bodyKey = subkey(master: master, label: "XORPass-body-v1", nonce: parsed.nonce)
        let nameKey = subkey(master: master, label: "XORPass-name-v1", nonce: parsed.nonce)
        let macKey = subkey(master: master, label: "XORPass-mac-v1", nonce: parsed.nonce)

        var mac = HMAC<SHA256>(key: macKey)
        mac.update(data: header)
        var offset = UInt64(headerLength)
        var left = parsed.cipherLength
        while left > 0 {
            let n = Int(min(left, UInt64(chunkSize)))
            let chunk = try readAt(offset, n)
            guard chunk.count == n else { throw XORPassError.corrupt }
            mac.update(data: chunk)
            offset += UInt64(n)
            left -= UInt64(n)
        }
        let tag = try readAt(offset, tagLength)
        guard tag.count == tagLength else { throw XORPassError.corrupt }
        guard constantTimeEqual(tag, Data(mac.finalize())) else {
            throw XORPassError.authenticationFailed
        }

        let name = try openName(parsed.encryptedName, key: nameKey)
        return Verified(
            name: name,
            directory: parsed.directory,
            profile: parsed.profile,
            bodyKey: bodyKey,
            cipherOffset: UInt64(headerLength),
            cipherLength: parsed.cipherLength,
            padding: parsed.padding
        )
    }

    /// Decrypts the length prefix and checks it against the size bucket.
    /// `verifyPackage` authenticates first; this is called only after that succeeds.
    static func writeCheckedPlaintext(
        verified: Verified,
        cipherLength: UInt64,
        readAt: (UInt64, Int) throws -> Data,
        write: (Data) throws -> Void
    ) throws -> UInt64 {
        var stream = Keystream(key: verified.bodyKey)
        var cursor = verified.cipherOffset
        let prefixCipher = try readAt(cursor, 8)
        guard prefixCipher.count == 8 else { throw XORPassError.corrupt }
        cursor += 8
        let declared = uint64LE(stream.xor(prefixCipher))
        guard declared <= maxPayload else { throw XORPassError.payloadTooLarge }
        guard let expected = Self.cipherLength(forPlaintextBytes: declared, padding: verified.padding),
              expected == cipherLength else {
            throw XORPassError.corrupt
        }

        var left = declared
        while left > 0 {
            let n = Int(min(left, UInt64(chunkSize)))
            let chunk = try readAt(cursor, n)
            guard chunk.count == n else { throw XORPassError.corrupt }
            cursor += UInt64(n)
            try write(stream.xor(chunk))
            left -= UInt64(n)
        }
        return declared
    }

    // MARK: Names

    static func validatedName(_ name: String) throws -> String {
        let base = (name as NSString).lastPathComponent
        guard base == name else { throw XORPassError.unsafeName }
        guard !base.isEmpty, base != ".", base != ".." else { throw XORPassError.unsafeName }
        if base.unicodeScalars.contains(where: { $0.value == 0 || $0 == "/" || $0 == "\\" }) {
            throw XORPassError.unsafeName
        }
        guard Data(base.utf8).count <= 255 else { throw XORPassError.nameTooLong }
        return base
    }

    static func sealName(_ name: String, key: SymmetricKey) throws -> Data {
        let utf = Data(name.utf8)
        guard utf.count <= 255 else { throw XORPassError.nameTooLong }
        var frame = Data(count: nameFieldLength)
        frame[0] = UInt8(utf.count)
        if !utf.isEmpty {
            frame.replaceSubrange(1..<(1 + utf.count), with: utf)
        }
        let padStart = 1 + utf.count
        if padStart < nameFieldLength {
            let pad = try randomBytes(nameFieldLength - padStart)
            frame.replaceSubrange(padStart..<nameFieldLength, with: pad)
        }
        var stream = Keystream(key: key)
        return stream.xor(frame)
    }

    static func openName(_ sealed: Data, key: SymmetricKey) throws -> String {
        guard sealed.count == nameFieldLength else { throw XORPassError.corrupt }
        var stream = Keystream(key: key)
        let frame = stream.xor(sealed)
        let count = Int(frame[0])
        guard count <= 255 else { throw XORPassError.corrupt }
        let bytes = frame.subdata(in: 1..<(1 + count))
        guard let name = String(bytes: bytes, encoding: .utf8) else { throw XORPassError.corrupt }
        return try validatedName(name)
    }

    // MARK: Header

    struct ParsedHeader {
        var directory: Bool
        var needsKeyFile: Bool
        var needsPassword: Bool
        var padding: XORPassPadding
        var profile: XORPassProfile
        var salt: Data
        var nonce: Data
        var cipherLength: UInt64
        var encryptedName: Data
    }

    static func buildHeader(
        profile: XORPassProfile,
        salt: Data,
        nonce: Data,
        cipherLength: UInt64,
        encryptedName: Data,
        flags: UInt16
    ) -> Data {
        var header = Data()
        header.reserveCapacity(headerLength)
        header.append(magic)
        header.appendUInt16LE(version)
        header.appendUInt16LE(flags)
        header.appendUInt32LE(profile.memoryKiB)
        header.appendUInt32LE(profile.iterations)
        header.appendUInt32LE(profile.parallelism)
        header.appendUInt32LE(UInt32(keyLength))
        header.append(salt)
        header.append(nonce)
        header.appendUInt64LE(cipherLength)
        header.append(encryptedName)
        precondition(header.count == headerLength)
        return header
    }

    static func parseHeader(_ data: Data) throws -> ParsedHeader {
        guard data.count >= headerLength else { throw XORPassError.corrupt }
        guard data.prefix(4) == magic else { throw XORPassError.notXORPass }
        let version = data.readUInt16LE(atAbsolute: 4)
        guard version == Self.version else { throw XORPassError.badVersion(Int(version)) }
        let flags = data.readUInt16LE(atAbsolute: 6)
        guard flags & ~knownFlags == 0 else { throw XORPassError.unsupportedFeature }
        let needsKeyFile = (flags & flagKeyFile) != 0
        let needsPassword = !needsKeyFile || (flags & flagPassword) != 0
        let padding = try paddingMode(from: flags)
        let memory = data.readUInt32LE(atAbsolute: 8)
        let iterations = data.readUInt32LE(atAbsolute: 12)
        let parallelism = data.readUInt32LE(atAbsolute: 16)
        let outLen = data.readUInt32LE(atAbsolute: 20)
        guard outLen == UInt32(keyLength) else { throw XORPassError.corrupt }
        let profile = XORPassProfile.stored(
            memoryKiB: memory,
            iterations: iterations,
            parallelism: parallelism
        )
        try profile.validate()
        return ParsedHeader(
            directory: (flags & flagDirectory) != 0,
            needsKeyFile: needsKeyFile,
            needsPassword: needsPassword,
            padding: padding,
            profile: profile,
            salt: data.subdata(in: 24..<40),
            nonce: data.subdata(in: 40..<56),
            cipherLength: data.readUInt64LE(atAbsolute: 56),
            encryptedName: data.subdata(in: 64..<320)
        )
    }

    // MARK: KDF and keystream

    static func headerFlags(
        directory: Bool,
        password: String,
        keyFile: Data,
        padding: XORPassPadding
    ) -> UInt16 {
        var flags: UInt16 = 0
        if directory { flags |= flagDirectory }
        if !keyFile.isEmpty {
            flags |= flagKeyFile
            if !password.isEmpty { flags |= flagPassword }
        }
        flags |= (padding.rawValue << 3) & flagPadMask
        return flags
    }

    static func paddingMode(from flags: UInt16) throws -> XORPassPadding {
        let raw = (flags & flagPadMask) >> 3
        guard let mode = XORPassPadding(rawValue: raw) else {
            throw XORPassError.unsupportedFeature
        }
        return mode
    }

    /// Password-only derivation matches 1.0.0. A key file is the Argon2id secret and is not stored.
    static func deriveMaster(
        password: String,
        keyFile: Data,
        salt: Data,
        profile: XORPassProfile
    ) throws -> SymmetricKey {
        try profile.validate()
        guard salt.count == saltLength else { throw XORPassError.corrupt }
        var pwd = Array(password.utf8)
        defer { wipe(&pwd) }
        var secret = [UInt8](keyFile)
        defer { wipe(&secret) }
        guard !pwd.isEmpty || !secret.isEmpty else { throw XORPassError.missingSecret }
        guard secret.count <= maxKeyFileBytes else { throw XORPassError.keyFileTooLarge }

        let saltArr = Array(salt)
        var out = [UInt8](repeating: 0, count: keyLength)
        defer { wipe(&out) }

        let rc: Int32
        if secret.isEmpty {
            rc = pwd.withUnsafeBufferPointer { pwdPtr in
                saltArr.withUnsafeBufferPointer { saltPtr in
                    out.withUnsafeMutableBufferPointer { outPtr in
                        xorpass_argon2id_raw(
                            pwdPtr.baseAddress, pwdPtr.count,
                            saltPtr.baseAddress, saltPtr.count,
                            profile.iterations,
                            profile.memoryKiB,
                            profile.parallelism,
                            outPtr.baseAddress,
                            outPtr.count
                        )
                    }
                }
            }
        } else {
            rc = pwd.withUnsafeBufferPointer { pwdPtr in
                saltArr.withUnsafeBufferPointer { saltPtr in
                    secret.withUnsafeBufferPointer { secretPtr in
                        out.withUnsafeMutableBufferPointer { outPtr in
                            xorpass_argon2id_raw_ex(
                                pwdPtr.baseAddress, pwdPtr.count,
                                saltPtr.baseAddress, saltPtr.count,
                                secretPtr.baseAddress, secretPtr.count,
                                nil, 0,
                                profile.iterations,
                                profile.memoryKiB,
                                profile.parallelism,
                                outPtr.baseAddress,
                                outPtr.count
                            )
                        }
                    }
                }
            }
        }
        guard rc == 0 else { throw XORPassError.keyDerivationFailed }
        return SymmetricKey(data: out)
    }

    static func subkey(master: SymmetricKey, label: String, nonce: Data) -> SymmetricKey {
        var message = Data(label.utf8)
        message.append(nonce)
        let code = HMAC<SHA256>.authenticationCode(for: message, using: master)
        return SymmetricKey(data: Data(code))
    }

    static func randomBytes(_ count: Int) throws -> Data {
        precondition(count >= 0)
        if count == 0 { return Data() }
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { raw in
            SecRandomCopyBytes(kSecRandomDefault, count, raw.baseAddress!)
        }
        guard status == errSecSuccess else { throw XORPassError.randomFailed }
        return data
    }

    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count {
            diff |= a[i] ^ b[i]
        }
        return diff == 0
    }

    static func normalizedPassword(_ password: String) throws -> String {
        let normalized = normalizePassword(password)
        guard Data(normalized.utf8).count <= maxPasswordBytes else { throw XORPassError.passwordTooLong }
        return normalized
    }

    private static func suppliedOrRandom(_ supplied: Data?, length: Int) throws -> Data {
        if let supplied {
            guard supplied.count == length else { throw XORPassError.corrupt }
            return supplied
        }
        return try randomBytes(length)
    }

    private static func slice(_ data: Data, offset: UInt64, count: Int) throws -> Data {
        let start = Int(offset)
        let end = start + count
        guard start >= 0, end >= start, end <= data.count else { throw XORPassError.corrupt }
        return data.subdata(in: start..<end)
    }

    private static func wipe(_ bytes: inout [UInt8]) {
        bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress, raw.count > 0 else { return }
            memset(base, 0, raw.count)
        }
    }
}

// MARK: - Keystream

/// HMAC-SHA256 in counter mode. Each block is 32 bytes. The cipher is XOR.
struct Keystream {
    private let key: SymmetricKey
    private var counter: UInt64 = 0
    private var block = [UInt8](repeating: 0, count: 32)
    private var index = 32

    init(key: SymmetricKey) {
        self.key = key
    }

    private mutating func refill() {
        var bigEndianCounter = counter.bigEndian
        let message = withUnsafeBytes(of: &bigEndianCounter) { Data($0) }
        block = Array(HMAC<SHA256>.authenticationCode(for: message, using: key))
        counter += 1
        index = 0
    }

    mutating func xor(_ input: Data) -> Data {
        if input.isEmpty { return Data() }
        let source = [UInt8](input)
        var output = [UInt8](repeating: 0, count: source.count)
        var cursor = 0
        while cursor < source.count {
            if index == 32 { refill() }
            let n = min(32 - index, source.count - cursor)
            for j in 0..<n {
                output[cursor + j] = source[cursor + j] ^ block[index + j]
            }
            cursor += n
            index += n
        }
        return Data(output)
    }
}

// MARK: - Binary

func uint64LE(_ value: UInt64) -> Data {
    var data = Data()
    data.appendUInt64LE(value)
    return data
}

func uint64LE(_ data: Data) -> UInt64 {
    precondition(data.count >= 8)
    return data.readUInt64LE(atAbsolute: 0)
}

extension Data {
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
        for shift in stride(from: 0, to: 64, by: 8) {
            append(UInt8((value >> shift) & 0xFF))
        }
    }

    func readUInt16LE(atAbsolute offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func readUInt32LE(atAbsolute offset: Int) -> UInt32 {
        UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }

    func readUInt64LE(atAbsolute offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<8 {
            value |= UInt64(self[offset + i]) << (i * 8)
        }
        return value
    }
}
