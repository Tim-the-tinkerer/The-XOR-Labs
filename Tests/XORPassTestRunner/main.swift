import Foundation
import XORPassCore
import CArgon2

var failures = 0

func expect(_ cond: @autoclosure () -> Bool, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    if !cond() {
        failures += 1
        print("FAIL \(file):\(line): \(message)")
    }
}

func expectEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    if a != b {
        failures += 1
        print("FAIL \(file):\(line): \(message) — \(a) != \(b)")
    }
}

func expectError(_ expected: XORPassError, _ body: () throws -> Void, file: StaticString = #file, line: UInt = #line) {
    do {
        try body()
        failures += 1
        print("FAIL \(file):\(line): expected \(expected)")
    } catch let error as XORPassError {
        if error != expected {
            failures += 1
            print("FAIL \(file):\(line): expected \(expected), got \(error)")
        }
    } catch {
        failures += 1
        print("FAIL \(file):\(line): expected \(expected), got \(error)")
    }
}

func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("xorpass_test_\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

let fast = XORPassProfile(name: "Test", memoryKiB: 8_192, iterations: 2, parallelism: 1)
let password = "xorpass-secret-password-9f3a"
let salt = Data(repeating: 0x11, count: 16)
let nonce = Data(repeating: 0x22, count: 16)

// RFC 9106 §5.3 Argon2id. Memory 32 KiB, t=3, p=4, with secret and associated data.
do {
    let pwd = [UInt8](repeating: 0x01, count: 32)
    let rfcSalt = [UInt8](repeating: 0x02, count: 16)
    let secret = [UInt8](repeating: 0x03, count: 8)
    let ad = [UInt8](repeating: 0x04, count: 12)
    var out = [UInt8](repeating: 0, count: 32)
    let rc = pwd.withUnsafeBufferPointer { pwdPtr in
        rfcSalt.withUnsafeBufferPointer { saltPtr in
            secret.withUnsafeBufferPointer { secretPtr in
                ad.withUnsafeBufferPointer { adPtr in
                    out.withUnsafeMutableBufferPointer { outPtr in
                        xorpass_argon2id_raw_ex(
                            pwdPtr.baseAddress, pwdPtr.count,
                            saltPtr.baseAddress, saltPtr.count,
                            secretPtr.baseAddress, secretPtr.count,
                            adPtr.baseAddress, adPtr.count,
                            3, 32, 4,
                            outPtr.baseAddress, outPtr.count
                        )
                    }
                }
            }
        }
    }
    let expected: [UInt8] = [
        0x0d, 0x64, 0x0d, 0xf5, 0x8d, 0x78, 0x76, 0x6c,
        0x08, 0xc0, 0x37, 0xa3, 0x4a, 0x8b, 0x53, 0xc9,
        0xd0, 0x1e, 0xf0, 0x45, 0x2d, 0x75, 0xb6, 0x5e,
        0xb5, 0x25, 0x20, 0xe9, 0x6b, 0x01, 0xe6, 0x59
    ]
    expect(rc == 0, "argon2 rc \(rc)")
    expectEqual(out, expected, "RFC 9106 Argon2id tag")
    print("OK Argon2id RFC 9106 vector")
}

// Size buckets. Small files hide in 256-byte steps; larger files in 4 KiB steps.
do {
    func bucket(_ n: UInt64, _ padding: XORPassPadding = .standard) -> UInt64? {
        XORPassEngine.cipherLength(forPlaintextBytes: n, padding: padding)
    }
    expectEqual(bucket(0), .some(UInt64(256)))
    expectEqual(bucket(100), .some(UInt64(256)))
    expectEqual(bucket(216), .some(UInt64(256)))
    expectEqual(bucket(217), .some(UInt64(512)))
    expectEqual(bucket(4056), .some(UInt64(4096)))
    expectEqual(bucket(4057), .some(UInt64(8192)))
    expectEqual(bucket(5_000), .some(UInt64(8192)))
    expect(XORPassEngine.cipherLength(forPlaintextBytes: UInt64.max) == nil, "length overflow")
    expect(XORPassEngine.cipherLength(forPlaintextBytes: XORPassEngine.maxPayload + 1) == nil, "over the cap")
    print("OK padding buckets")
}

do {
    expectError(.missingSecret) {
        _ = try XORPassEngine.seal(Data("x".utf8), name: "a.txt", password: "", profile: fast)
    }
    expectError(.unsafeName) {
        _ = try XORPassEngine.seal(Data("x".utf8), name: "../x", password: "pw", profile: fast)
    }
    expectError(.nameTooLong) {
        _ = try XORPassEngine.seal(
            Data("x".utf8),
            name: String(repeating: "a", count: 256),
            password: "pw",
            profile: fast
        )
    }
    print("OK rejected password and names")
}

let plain = Data("Hello XOR Pass keystream".utf8)
var sealed = Data()
do {
    sealed = try XORPassEngine.seal(
        plain,
        name: "DistinctiveName-ZZ.txt",
        password: password,
        profile: fast,
        salt: salt,
        nonce: nonce
    )
    let again = try XORPassEngine.seal(
        plain,
        name: "DistinctiveName-ZZ.txt",
        password: password,
        profile: fast,
        salt: salt,
        nonce: nonce
    )
    let otherNonce = try XORPassEngine.seal(
        plain,
        name: "DistinctiveName-ZZ.txt",
        password: password,
        profile: fast,
        salt: salt,
        nonce: Data(repeating: 0x33, count: 16)
    )
    let start = XORPassEngine.headerLength
    let end = start + 8 + plain.count
    expectEqual(sealed.subdata(in: start..<end), again.subdata(in: start..<end), "same salt and nonce, same keystream")
    expect(sealed.subdata(in: 64..<320) != again.subdata(in: 64..<320), "name padding differs")
    expect(sealed.subdata(in: start..<end) != otherNonce.subdata(in: start..<end), "nonce changes the keystream")
    expectEqual(sealed.subdata(in: 24..<40), salt)
    expectEqual(sealed.subdata(in: 40..<56), nonce)
    expectEqual(
        sealed.count,
        XORPassEngine.headerLength + Int(XORPassEngine.cipherLength(forPlaintextBytes: UInt64(plain.count))!) + XORPassEngine.tagLength
    )
    expect(!sealed.contains(Data(password.utf8)), "password bytes in package")
    expect(!sealed.contains(Data("DistinctiveName-ZZ.txt".utf8)), "filename bytes in package")
    let opened = try XORPassEngine.open(sealed, password: password)
    expectEqual(opened.plaintext, plain)
    expectEqual(opened.name, "DistinctiveName-ZZ.txt")
    expectEqual(opened.directory, false)
    expectEqual(opened.profile.memoryKiB, fast.memoryKiB)
    print("OK seal, keystream, hidden name")
} catch {
    failures += 1
    sealed = Data()
    print("FAIL seal: \(error)")
}

do {
    let empty = try XORPassEngine.seal(Data(), name: "empty.txt", password: password, profile: fast)
    expectEqual(empty.count, 320 + 256 + 32)
    let opened = try XORPassEngine.open(empty, password: password)
    expectEqual(opened.plaintext, Data())
    expectEqual(opened.name, "empty.txt")
    print("OK empty plaintext")
} catch {
    failures += 1
    print("FAIL empty: \(error)")
}

do {
    let name = String(repeating: "b", count: 255)
    let package = try XORPassEngine.seal(Data("x".utf8), name: name, password: password, profile: fast)
    let opened = try XORPassEngine.open(package, password: password)
    expectEqual(opened.name, name)
    print("OK 255-byte name")
} catch {
    failures += 1
    print("FAIL long name: \(error)")
}

do {
    let nfc = "caf\u{00e9}"
    let nfd = nfc.decomposedStringWithCanonicalMapping
    expect(
        Data(nfc.utf8).count != Data(nfd.utf8).count,
        "NFC \(Data(nfc.utf8).count) bytes, NFD \(Data(nfd.utf8).count) bytes"
    )
    expectEqual(XORPassEngine.normalizePassword(nfd), nfc, "password is stored as NFC")
    let package = try XORPassEngine.seal(Data("hi".utf8), name: "n.txt", password: nfd, profile: fast)
    let opened = try XORPassEngine.open(package, password: nfc)
    expectEqual(opened.plaintext, Data("hi".utf8))
    print("OK NFC password")
} catch {
    failures += 1
    print("FAIL NFC: \(error)")
}

do {
    let big = Data((0..<1_100_000).map { UInt8($0 % 251) })
    let package = try XORPassEngine.seal(big, name: "big.bin", password: password, profile: fast)
    expectEqual(
        package.count,
        XORPassEngine.headerLength + Int(XORPassEngine.cipherLength(forPlaintextBytes: UInt64(big.count))!) + XORPassEngine.tagLength
    )
    let opened = try XORPassEngine.open(package, password: password)
    expectEqual(opened.plaintext, big)
    print("OK chunked round trip")
} catch {
    failures += 1
    print("FAIL chunked: \(error)")
}

if !sealed.isEmpty {
    var flipped = sealed
    flipped[XORPassEngine.headerLength + 8] ^= 0x01
    expectError(.authenticationFailed) {
        _ = try XORPassEngine.open(flipped, password: password)
    }

    var badTag = sealed
    badTag[badTag.count - 1] ^= 0x01
    expectError(.authenticationFailed) {
        _ = try XORPassEngine.open(badTag, password: password)
    }

    expectError(.authenticationFailed) {
        _ = try XORPassEngine.open(sealed, password: "wrong-password")
    }

    var weak = sealed
    weak[8] = 100
    weak[9] = 0
    weak[10] = 0
    weak[11] = 0
    expectError(.kdfParametersRejected) {
        _ = try XORPassEngine.open(weak, password: password)
    }

    var version = sealed
    version[4] = 2
    expectError(.badVersion(2)) {
        _ = try XORPassEngine.open(version, password: password)
    }

    var magic = sealed
    magic[0] = 0
    expectError(.notXORPass) {
        _ = try XORPassEngine.open(magic, password: password)
    }

    var flagged = sealed
    flagged[6] = 0x20
    expectError(.unsupportedFeature) {
        _ = try XORPassEngine.open(flagged, password: password)
    }
    print("OK authentication and header checks")
}

do {
    let package = try XORPassEngine.seal(
        Data("zip-bytes".utf8),
        name: "Folder",
        password: password,
        profile: fast,
        directory: true
    )
    expect(package[6] == 1, "directory flag")
    let opened = try XORPassEngine.open(package, password: password)
    expectEqual(opened.directory, true)
    expectEqual(opened.name, "Folder")
    expectEqual(opened.plaintext, Data("zip-bytes".utf8))
    print("OK directory flag")
} catch {
    failures += 1
    print("FAIL directory flag: \(error)")
}

do {
    let package = try XORPassEngine.seal(
        Data("Hi".utf8),
        name: "s.txt",
        password: password,
        profile: .standard
    )
    let opened = try XORPassEngine.open(package, password: password)
    expectEqual(opened.plaintext, Data("Hi".utf8))
    expectEqual(opened.profile, .standard)
    print("OK standard Argon2id profile")
} catch {
    failures += 1
    print("FAIL standard profile: \(error)")
}

do {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("DistinctiveName-ZZ.txt")
    let payload = Data("payload-marker-hello".utf8)
    try payload.write(to: source)
    let archive = try XORPassFormat.archiveURL(near: source)
    try XORPassFormat.encryptFile(at: source, to: archive, password: password, profile: fast)
    expect(archive.lastPathComponent.hasPrefix("XORPass-"))
    expectEqual(archive.deletingPathExtension().lastPathComponent.count, 24)
    expect(archive.pathExtension == "xorpass")
    expect(!archive.lastPathComponent.contains("DistinctiveName"))
    let packed = try Data(contentsOf: archive)
    expect(!packed.contains(Data(password.utf8)))
    expect(!packed.contains(Data("DistinctiveName-ZZ.txt".utf8)))
    let peek = try XORPassFormat.peek(at: archive)
    expectEqual(peek.profile.memoryKiB, fast.memoryKiB)
    expectEqual(peek.directory, false)

    let namesBefore = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        .map(\.lastPathComponent).sorted()
    expectError(.authenticationFailed) {
        _ = try XORPassFormat.decrypt(at: archive, password: "nope")
    }
    let namesAfter = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        .map(\.lastPathComponent).sorted()
    expectEqual(namesAfter, namesBefore, "wrong password wrote a file")

    try FileManager.default.removeItem(at: source)
    let restored = try XORPassFormat.decrypt(at: archive, password: password)
    expectEqual(restored.lastPathComponent, "DistinctiveName-ZZ.txt")
    expectEqual(try Data(contentsOf: restored), payload)
    print("OK file round trip")
} catch {
    failures += 1
    print("FAIL file round trip: \(error)")
}

do {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let folder = dir.appendingPathComponent("Photos")
    try FileManager.default.createDirectory(
        at: folder.appendingPathComponent("sub"),
        withIntermediateDirectories: true
    )
    try Data("alpha".utf8).write(to: folder.appendingPathComponent("a.txt"))
    try Data("beta".utf8).write(to: folder.appendingPathComponent("sub/note.txt"))
    let archive = try XORPassFormat.archiveURL(near: folder)
    try XORPassFormat.encryptDirectory(at: folder, to: archive, password: password, profile: fast)
    let packed = try Data(contentsOf: archive)
    expect(!packed.contains(Data("Photos".utf8)))
    expect(!packed.contains(Data("note.txt".utf8)))
    let peek = try XORPassFormat.peek(at: archive)
    expectEqual(peek.directory, true)

    try FileManager.default.removeItem(at: folder)
    let restored = try XORPassFormat.decrypt(at: archive, password: password)
    expectEqual(restored.lastPathComponent, "Photos")
    expectEqual(try Data(contentsOf: restored.appendingPathComponent("a.txt")), Data("alpha".utf8))
    expectEqual(try Data(contentsOf: restored.appendingPathComponent("sub/note.txt")), Data("beta".utf8))
    print("OK folder round trip")
} catch {
    failures += 1
    print("FAIL folder: \(error)")
}

do {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let folder = dir.appendingPathComponent("Linked")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: folder.appendingPathComponent("a.txt"))
    try FileManager.default.createSymbolicLink(
        at: folder.appendingPathComponent("link"),
        withDestinationURL: folder.appendingPathComponent("a.txt")
    )
    let archive = try XORPassFormat.archiveURL(near: folder)
    expectError(.symlinkRejected("link")) {
        try XORPassFormat.encryptDirectory(at: folder, to: archive, password: password, profile: fast)
    }
    print("OK symlink rejected")
} catch {
    failures += 1
    print("FAIL symlink: \(error)")
}

let keyFile = Data("binary-key-file-9f3a".utf8)
do {
    let only = try XORPassEngine.seal(
        Data("from-key-file".utf8),
        name: "key.txt",
        password: "",
        profile: fast,
        keyFile: keyFile
    )
    expect(only[6] == 0x02, "key-file flag")
    expect(!only.contains(keyFile), "key file bytes in package")
    let opened = try XORPassEngine.open(only, password: "", keyFile: keyFile)
    expectEqual(opened.plaintext, Data("from-key-file".utf8))
    let ignoredPassword = try XORPassEngine.open(only, password: "typed-but-unused", keyFile: keyFile)
    expectEqual(ignoredPassword.plaintext, Data("from-key-file".utf8))
    expectError(.keyFileRequired) {
        _ = try XORPassEngine.open(only, password: "", keyFile: Data())
    }
    expectError(.authenticationFailed) {
        _ = try XORPassEngine.open(only, password: "", keyFile: Data("other-key-file-xxxx".utf8))
    }

    let both = try XORPassEngine.seal(
        Data("both".utf8),
        name: "both.txt",
        password: password,
        profile: fast,
        keyFile: keyFile
    )
    expect(both[6] == 0x06, "password and key-file flags")
    let openedBoth = try XORPassEngine.open(both, password: password, keyFile: keyFile)
    expectEqual(openedBoth.plaintext, Data("both".utf8))
    expectError(.emptyPassword) {
        _ = try XORPassEngine.open(both, password: "", keyFile: keyFile)
    }
    expectError(.authenticationFailed) {
        _ = try XORPassEngine.open(both, password: password, keyFile: Data("other-key-file-xxxx".utf8))
    }

    let passwordOnly = try XORPassEngine.seal(
        Data("pw".utf8),
        name: "pw.txt",
        password: password,
        profile: fast
    )
    expect(passwordOnly[6] == 0, "password-only leaves the key-file flag clear")
    let openedAnyway = try XORPassEngine.open(passwordOnly, password: password, keyFile: keyFile)
    expectEqual(openedAnyway.plaintext, Data("pw".utf8))
    let peek = try XORPassEngine.peek(both)
    expectEqual(peek.needsKeyFile, true)
    expectEqual(peek.needsPassword, true)
    print("OK binary key file")
} catch {
    failures += 1
    print("FAIL key file: \(error)")
}

do {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("notes.txt")
    let keyURL = dir.appendingPathComponent("pad.key")
    try Data("file-payload".utf8).write(to: source)
    try keyFile.write(to: keyURL)
    let archive = try XORPassFormat.archiveURL(near: source)
    try XORPassFormat.encryptFile(
        at: source, to: archive, password: "", profile: fast, keyFile: keyFile
    )
    let packed = try Data(contentsOf: archive)
    expect(!packed.contains(keyFile))
    try FileManager.default.removeItem(at: source)
    let restored = try XORPassFormat.decrypt(at: archive, password: "", keyFile: keyFile)
    expectEqual(restored.lastPathComponent, "notes.txt")
    expectEqual(try Data(contentsOf: restored), Data("file-payload".utf8))
    print("OK key file round trip")
} catch {
    failures += 1
    print("FAIL key file round trip: \(error)")
}

func le16(_ value: UInt16) -> Data {
    Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
}

func le64(_ value: UInt64) -> Data {
    var data = Data(count: 8)
    var remainder = value
    for index in 0..<8 {
        data[index] = UInt8(remainder & 0xFF)
        remainder >>= 8
    }
    return data
}

func le32(_ value: UInt32) -> Data {
    Data([
        UInt8(value & 0xFF),
        UInt8((value >> 8) & 0xFF),
        UInt8((value >> 16) & 0xFF),
        UInt8((value >> 24) & 0xFF)
    ])
}

func storedZip(name: String, mode: UInt16, payload: Data = Data([0x78])) -> Data {
    let nameBytes = Data(name.utf8)
    var local = Data([0x50, 0x4B, 0x03, 0x04])
    local.append(le16(20))
    local.append(le16(0))
    local.append(le16(0))
    local.append(le16(0))
    local.append(le16(0))
    local.append(le32(0))
    local.append(le32(UInt32(payload.count)))
    local.append(le32(UInt32(payload.count)))
    local.append(le16(UInt16(nameBytes.count)))
    local.append(le16(0))
    local.append(nameBytes)
    local.append(payload)

    var central = Data([0x50, 0x4B, 0x01, 0x02])
    central.append(le16(0x0314))
    central.append(le16(20))
    central.append(le16(0))
    central.append(le16(0))
    central.append(le16(0))
    central.append(le16(0))
    central.append(le32(0))
    central.append(le32(UInt32(payload.count)))
    central.append(le32(UInt32(payload.count)))
    central.append(le16(UInt16(nameBytes.count)))
    central.append(le16(0))
    central.append(le16(0))
    central.append(le16(0))
    central.append(le16(0))
    central.append(le32(UInt32(mode) << 16))
    central.append(le32(0))
    central.append(nameBytes)

    var end = Data([0x50, 0x4B, 0x05, 0x06])
    end.append(le16(0))
    end.append(le16(0))
    end.append(le16(1))
    end.append(le16(1))
    end.append(le32(UInt32(central.count)))
    end.append(le32(UInt32(local.count)))
    end.append(le16(0))
    return local + central + end
}

func argonTag(password: [UInt8], salt: [UInt8], secret: [UInt8], time: UInt32, memory: UInt32, lanes: UInt32) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: 32)
    let rc: Int32 = password.withUnsafeBufferPointer { passwordPtr in
        salt.withUnsafeBufferPointer { saltPtr in
            secret.withUnsafeBufferPointer { secretPtr in
                out.withUnsafeMutableBufferPointer { outPtr in
                    xorpass_argon2id_raw_ex(
                        passwordPtr.baseAddress, passwordPtr.count,
                        saltPtr.baseAddress, saltPtr.count,
                        secretPtr.baseAddress, secretPtr.count,
                        nil, 0,
                        time, memory, lanes,
                        outPtr.baseAddress, outPtr.count
                    )
                }
            }
        }
    }
    expect(rc == 0, "argon rc \(rc)")
    return out
}

// Tags shared by the previous clean-room Argon2 and PHC Argon2 20190702.
do {
    let salt = [UInt8](repeating: 0x11, count: 16)
    let password = Array("password".utf8)
    let secret = Array("binary-key-file-9f3a".utf8)
    expectEqual(
        argonTag(password: password, salt: salt, secret: [], time: 2, memory: 8192, lanes: 1),
        [UInt8](hex: "81365c3bc38dca3946c62545b6a9d66bc551d8bb31f1c9e68df1ade3f4b5d6c6")
    )
    expectEqual(
        argonTag(password: [], salt: salt, secret: secret, time: 2, memory: 8192, lanes: 1),
        [UInt8](hex: "e99ca2ad48718d30fc121771138a4dea6926767ef8c819aee236e11c35eeb762")
    )
    expectEqual(
        argonTag(password: password, salt: salt, secret: secret, time: 2, memory: 8192, lanes: 1),
        [UInt8](hex: "8c01a7a418d8c09afe9b1eaccab7301f4850df29c9e6772d8c8d205c7bf1c932")
    )
    expectEqual(
        argonTag(password: password, salt: salt, secret: [], time: 3, memory: 65536, lanes: 4),
        [UInt8](hex: "2873a4abfa895f40c27f5a8d306eb7ab444c2aa7b6e1d07f1c11dc37e7fe5df5")
    )
    var flipped = secret
    flipped[0] ^= 1
    expect(
        argonTag(password: password, salt: salt, secret: secret, time: 2, memory: 8192, lanes: 1)
            != argonTag(password: password, salt: salt, secret: flipped, time: 2, memory: 8192, lanes: 1),
        "secret byte changes the tag"
    )
    print("OK Argon2 matches PHC 20190702")
}

extension Array where Element == UInt8 {
    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self = bytes
    }
}

do {
    let body = Data(repeating: 0xAB, count: 1000)
    let hidden = try XORPassEngine.seal(body, name: "h.bin", password: password, profile: fast, padding: .hidden)
    let maximum = try XORPassEngine.seal(body, name: "m.bin", password: password, profile: fast, padding: .maximum)
    expect(hidden[6] & 0x18 == 0x08, "private padding flag")
    expect(maximum[6] & 0x18 == 0x10, "maximum padding flag")
    expectEqual(XORPassEngine.cipherLength(forPlaintextBytes: 1000, padding: .hidden), .some(UInt64(4096)))
    expectEqual(XORPassEngine.cipherLength(forPlaintextBytes: 1000, padding: .maximum), .some(UInt64(2048)))
    expectEqual(try XORPassEngine.open(hidden, password: password).plaintext, body)
    expectEqual(try XORPassEngine.open(maximum, password: password).plaintext, body)
    expectEqual(try XORPassEngine.open(hidden, password: password).padding, .hidden)
    var badMode = hidden
    badMode[6] = (badMode[6] & ~0x18) | 0x18
    expectError(.unsupportedFeature) {
        _ = try XORPassEngine.open(badMode, password: password)
    }
    print("OK padding modes")
} catch {
    failures += 1
    print("FAIL padding modes: \(error)")
}

do {
    let sample = try XORPassEngine.seal(Data("edge".utf8), name: "e.txt", password: password, profile: fast)
    for length in [0, 1, 3, 4, 16, 319, 320, 351] {
        do {
            _ = try XORPassEngine.open(Data(sample.prefix(length)), password: password)
            failures += 1
            print("FAIL truncated \(length) opened")
        } catch {
            // rejected before any plaintext is produced
        }
    }
    var huge = sample
    for i in 0..<8 { huge[56 + i] = 0xFF }
    expectError(.corrupt) {
        _ = try XORPassEngine.open(huge, password: password)
    }
    print("OK truncated and absurd lengths")
} catch {
    failures += 1
    print("FAIL malformed header: \(error)")
}

do {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("plain.txt")
    try Data("perm".utf8).write(to: source)
    let archive = try XORPassFormat.archiveURL(near: source)
    try XORPassFormat.encryptFile(at: source, to: archive, password: password, profile: fast)
    try FileManager.default.removeItem(at: source)
    let restored = try XORPassFormat.decrypt(at: archive, password: password)
    let mode = try FileManager.default.attributesOfItem(atPath: restored.path)[.posixPermissions] as? NSNumber
    expectEqual((mode?.uint16Value ?? 0) & 0o777, UInt16(0o600))
    let before = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).map(\.lastPathComponent)
    expectError(.authenticationFailed) {
        _ = try XORPassFormat.decrypt(at: archive, password: "nope")
    }
    let after = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).map(\.lastPathComponent)
    expectEqual(after.sorted(), before.sorted())
    expect(after.allSatisfy { !$0.contains("xorpass-partial") })
    print("OK plaintext permissions")
} catch {
    failures += 1
    print("FAIL permissions: \(error)")
}

do {
    let tempsBefore = (try? FileManager.default.contentsOfDirectory(
        at: FileManager.default.temporaryDirectory,
        includingPropertiesForKeys: nil
    ))?.filter { $0.lastPathComponent.hasPrefix("xorpass-") }.count ?? 0

    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    func reject(_ name: String, _ mode: UInt16) throws {
        let zip = storedZip(name: name, mode: mode)
        let package = try XORPassEngine.seal(
            zip, name: "Folder", password: password, profile: fast, directory: true
        )
        let archive = dir.appendingPathComponent("bad-\(UUID().uuidString).xorpass")
        try package.write(to: archive)
        expectError(.unsafeArchivePath(name)) {
            _ = try XORPassFormat.decrypt(at: archive, password: password)
        }
    }
    try reject("../evil.txt", 0o100644)
    try reject("/tmp/evil.txt", 0o100644)
    try reject("link", 0o120755)

    // ZIP64 locator offset at the top of the 64-bit range. The size check must reject it.
    var locator = Data([0x50, 0x4B, 0x06, 0x07])
    locator.append(le32(0))
    locator.append(le64(UInt64.max))
    locator.append(le32(1))
    var eocd = Data([0x50, 0x4B, 0x05, 0x06])
    eocd.append(le16(0))
    eocd.append(le16(0))
    eocd.append(le16(0xFFFF))
    eocd.append(le16(0xFFFF))
    eocd.append(le32(0xFFFF_FFFF))
    eocd.append(le32(0xFFFF_FFFF))
    eocd.append(le16(0))
    let bomb = try XORPassEngine.seal(
        locator + eocd, name: "Folder", password: password, profile: fast, directory: true
    )
    let bombURL = dir.appendingPathComponent("zip64.xorpass")
    try bomb.write(to: bombURL)
    expectError(.corrupt) {
        _ = try XORPassFormat.decrypt(at: bombURL, password: password)
    }
    let tempsAfter = (try? FileManager.default.contentsOfDirectory(
        at: FileManager.default.temporaryDirectory,
        includingPropertiesForKeys: nil
    ))?.filter { $0.lastPathComponent.hasPrefix("xorpass-") }.count ?? 0
    expectEqual(tempsAfter, tempsBefore, "failed extract left a work directory")
    print("OK zip preflight")
} catch {
    failures += 1
    print("FAIL zip preflight: \(error)")
}

if failures == 0 {
    print("All XOR Pass tests passed")
} else {
    print("\(failures) failure(s)")
    exit(1)
}
