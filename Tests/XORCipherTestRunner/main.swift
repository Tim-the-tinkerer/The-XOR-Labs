import Foundation
import XORCore

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

func expectThrows(_ body: () throws -> Void, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    do {
        try body()
        failures += 1
        print("FAIL \(file):\(line): expected throw — \(message)")
    } catch {
        // ok
    }
}

func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("xor_test_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

let key = XORKey("key")

// Hello ⊕ key → 23 00 15 07 0A
do {
    let enc = XOREngine.encrypt(Data("Hello".utf8), key: key)
    expectEqual(XOREngine.hexString(enc), "23 00 15 07 0A")
    let dec = XOREngine.decrypt(enc, key: key)
    expectEqual(String(data: dec, encoding: .utf8), "Hello")
    print("OK Hello ⊕ key")
}

// Involutive: XOR twice is identity
do {
    let data = Data((0..<300).map { UInt8($0 % 256) })
    let once = XOREngine.encrypt(data, key: key)
    let twice = XOREngine.encrypt(once, key: key)
    expectEqual(twice, data)
    expect(once != data, "XOR should change payload")
    print("OK involution")
}

// A ⊕ A = 0, A ⊕ 0 = A
do {
    let a: UInt8 = 0x65
    expectEqual(a ^ a, 0)
    expectEqual(a ^ 0, a)
    print("OK XOR identities")
}

// Wiki ⊕ pedia (repeating: p e d i)
do {
    let enc = XOREngine.encrypt(Data("Wiki".utf8), key: XORKey("pedia"))
    expectEqual(XOREngine.hexString(enc), "27 0C 0F 00")
    print("OK Wiki ⊕ pedia")
}

// Hex key matches text key
do {
    let text = XOREngine.encrypt(Data("Hello".utf8), key: XORKey("key", kind: .text))
    let hex = XOREngine.encrypt(Data("Hello".utf8), key: XORKey("6B 65 79", kind: .hex))
    expectEqual(text, hex)
    print("OK hex key == text key")
}

// Hex parse
do {
    expectEqual(XOREngine.parseHex("6B6579"), Data([0x6B, 0x65, 0x79]))
    expectEqual(XOREngine.parseHex("0x6B:65-79"), Data([0x6B, 0x65, 0x79]))
    expectEqual(XOREngine.parseHex("6B 65 79"), Data([0x6B, 0x65, 0x79]))
    expect(XOREngine.parseHex("6B65G9") == nil, "bad hex")
    expect(XOREngine.parseHex("6B65") != nil)
    expect(XOREngine.parseHex("6B6") == nil, "odd length")
    print("OK hex parse")
}

// Chunked transform matches one-shot (cursor continuity)
do {
    let data = Data((0..<5000).map { UInt8($0 % 251) })
    let whole = XOREngine.encrypt(data, key: key)
    var cursor = 0
    var chunked = Data()
    var offset = 0
    while offset < data.count {
        let end = min(offset + 777, data.count)
        let slice = data.subdata(in: offset..<end)
        chunked.append(XOREngine.transform(slice, key: key, cursor: &cursor))
        offset = end
    }
    expectEqual(chunked, whole)
    print("OK chunked cursor")
}

// Bits
expectEqual(XOREngine.bitString(0b1010_0001), "10100001")
expectEqual(XOREngine.bits(of: 0b1000_0000), [true, false, false, false, false, false, false, false])
print("OK bits")

// Empty key rejected
expectThrows({ try XORFormat.validateKey(XORKey("")) })
expectThrows({ try XORFormat.validateKey(XORKey("GG", kind: .hex)) })
print("OK key validation")

// Alignment
do {
    let steps = XOREngine.alignment(of: "Hello", key: key)
    expectEqual(steps.count, 5)
    expectEqual(steps.map(\.cipher), [0x23, 0x00, 0x15, 0x07, 0x0A])
    expectEqual(steps.map(\.key), [0x6B, 0x65, 0x79, 0x6B, 0x65])
    print("OK alignment")
}

// File round-trip
do {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let src = dir.appendingPathComponent("data.bin")
    let original = Data((0..<500).map { UInt8($0 % 256) })
    try original.write(to: src)
    let arch = dir.appendingPathComponent("data.xor")
    try XORFormat.encryptFile(at: src, to: arch, key: key)
    expect(XORFormat.isXORFile(at: arch))
    let info = try XORFormat.readInfo(from: arch)
    expectEqual(info.key, "key")
    expectEqual(info.originalName, "data.bin")
    let out = dir.appendingPathComponent("restored.bin")
    _ = try XORFormat.decrypt(at: arch, to: out)
    expectEqual(try Data(contentsOf: out), original)
    print("OK file round-trip")
}

// Zero-byte
do {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let src = dir.appendingPathComponent("empty.txt")
    try Data().write(to: src)
    let arch = dir.appendingPathComponent("empty.xor")
    try XORFormat.encryptFile(at: src, to: arch, key: key)
    let out = dir.appendingPathComponent("empty-out.txt")
    _ = try XORFormat.decrypt(at: arch, to: out)
    expectEqual(try Data(contentsOf: out), Data())
    print("OK zero-byte file")
}

// Unicode name
do {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let src = dir.appendingPathComponent("café.txt")
    try "hello".write(to: src, atomically: true, encoding: .utf8)
    let arch = XORFormat.archiveURL(for: src)
    try XORFormat.encryptFile(at: src, to: arch, key: key)
    let info = try XORFormat.readInfo(from: arch)
    expectEqual(info.originalName, "café.txt")
    let out = XORFormat.restoreURL(for: arch, info: info)
    _ = try XORFormat.decrypt(at: arch, to: out)
    expectEqual(try String(contentsOf: out, encoding: .utf8), "hello")
    print("OK unicode filename")
}

// Encrypt names
do {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let src = dir.appendingPathComponent("Report.pdf")
    try Data("PDF".utf8).write(to: src)
    let arch = XORFormat.archiveURL(for: src, key: key, encryptNames: true)
    try XORFormat.encryptFile(at: src, to: arch, key: key, encryptNames: true)
    let info = try XORFormat.readInfo(from: arch)
    expect(info.encryptsNames)
    expectEqual(info.restoredName, "Report.pdf")
    expect(info.originalName != "Report.pdf", "stored name should be hex")
    let outDir = dir.appendingPathComponent("restored")
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let out = outDir.appendingPathComponent("Report.pdf")
    _ = try XORFormat.decrypt(at: arch, to: out)
    expectEqual(try String(contentsOf: out, encoding: .utf8), "PDF")
    print("OK encrypt names")
}

// Directory
do {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let folder = dir.appendingPathComponent("Nested")
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
    try "a".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try Data([9, 8, 7]).write(to: folder.appendingPathComponent("sub/b.bin"))
    let arch = dir.appendingPathComponent("Nested.xor")
    try XORFormat.encryptDirectory(at: folder, to: arch, key: key)
    let info = try XORFormat.readInfo(from: arch)
    expect(info.isDirectory)
    let out = dir.appendingPathComponent("Nested-out")
    _ = try XORFormat.decrypt(at: arch, to: out)
    expectEqual(try String(contentsOf: out.appendingPathComponent("a.txt"), encoding: .utf8), "a")
    expectEqual(try Data(contentsOf: out.appendingPathComponent("sub/b.bin")), Data([9, 8, 7]))
    print("OK directory round-trip")
}

// Hex-key archive
do {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let src = dir.appendingPathComponent("note.txt")
    try "Hello".write(to: src, atomically: true, encoding: .utf8)
    let hexKey = XORKey("6B6579", kind: .hex)
    let arch = dir.appendingPathComponent("note.xor")
    try XORFormat.encryptFile(at: src, to: arch, key: hexKey)
    let info = try XORFormat.readInfo(from: arch)
    expectEqual(info.keyKind, KeyKind.hex)
    let out = dir.appendingPathComponent("note-out.txt")
    _ = try XORFormat.decrypt(at: arch, to: out)
    expectEqual(try String(contentsOf: out, encoding: .utf8), "Hello")
    print("OK hex-key archive")
}

// Omit key from archive
do {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let src = dir.appendingPathComponent("secret.txt")
    try "Hello".write(to: src, atomically: true, encoding: .utf8)
    let arch = dir.appendingPathComponent("secret.xor")
    try XORFormat.encryptFile(at: src, to: arch, key: key, storage: .omit)
    let info = try XORFormat.readInfo(from: arch)
    expect(info.omitsKey)
    expectEqual(info.keyData.count, 0)
    let omitBlob = try Data(contentsOf: arch)
    expect(omitBlob.range(of: Data("key".utf8)) == nil, "omitted key must not appear in file")
    expectThrows({
        _ = try XORFormat.decrypt(at: arch, to: dir.appendingPathComponent("fail.txt"))
    }, "decrypt without key")
    let out = dir.appendingPathComponent("secret-out.txt")
    _ = try XORFormat.decrypt(at: arch, to: out, suppliedKey: key)
    expectEqual(try String(contentsOf: out, encoding: .utf8), "Hello")
    expectThrows({
        _ = try XORFormat.decrypt(at: arch, to: dir.appendingPathComponent("wrong.txt"), suppliedKey: XORKey("nope"))
    }, "wrong omitted key")
    print("OK omit key")
}

// Wrap stored key with a passphrase
do {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let src = dir.appendingPathComponent("note.txt")
    try "Hello".write(to: src, atomically: true, encoding: .utf8)
    let arch = dir.appendingPathComponent("note.xor")
    try XORFormat.encryptFile(at: src, to: arch, key: key, storage: .wrap, wrapPassphrase: "hunter2")
    let info = try XORFormat.readInfo(from: arch)
    expect(info.wrapsKey)
    expect(info.key != "key", "wrapped key must not be stored in the clear")
    let wrapBlob = try Data(contentsOf: arch)
    expect(wrapBlob.range(of: Data("key".utf8)) == nil, "clear key must not appear")
    expectThrows({
        _ = try XORFormat.decrypt(at: arch, to: dir.appendingPathComponent("fail.txt"))
    }, "decrypt without wrap")
    expectThrows({
        _ = try XORFormat.decrypt(at: arch, to: dir.appendingPathComponent("wrong.txt"), wrapPassphrase: "wrong")
    }, "wrong wrap passphrase")
    let out = dir.appendingPathComponent("note-out.txt")
    _ = try XORFormat.decrypt(at: arch, to: out, wrapPassphrase: "hunter2")
    expectEqual(try String(contentsOf: out, encoding: .utf8), "Hello")
    print("OK wrap key")
}

// Binary key file
do {
    let fileKey = XORKey(fileBytes: Array("key".utf8), name: "secret.key")
    expectEqual(
        XOREngine.encrypt(Data("Hello".utf8), key: fileKey),
        XOREngine.encrypt(Data("Hello".utf8), key: key)
    )
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let keyPath = dir.appendingPathComponent("secret.key")
    try Data("key".utf8).write(to: keyPath)
    let loaded = try XORKey(contentsOf: keyPath)
    expectEqual(loaded.kind, KeyKind.file)
    expectEqual(loaded.byteValues, Array("key".utf8))

    let src = dir.appendingPathComponent("hello.txt")
    try "Hello".write(to: src, atomically: true, encoding: .utf8)
    let arch = dir.appendingPathComponent("hello.xor")
    try XORFormat.encryptFile(at: src, to: arch, key: loaded)
    let info = try XORFormat.readInfo(from: arch)
    expectEqual(info.keyKind, KeyKind.file)
    expectEqual(Array(info.keyData), Array("key".utf8))
    let out = dir.appendingPathComponent("hello-out.txt")
    _ = try XORFormat.decrypt(at: arch, to: out)
    expectEqual(try String(contentsOf: out, encoding: .utf8), "Hello")
    print("OK binary key file store")

    let omitArch = dir.appendingPathComponent("hello-omit.xor")
    try XORFormat.encryptFile(at: src, to: omitArch, key: loaded, storage: .omit)
    let omitInfo = try XORFormat.readInfo(from: omitArch)
    expect(omitInfo.omitsKey)
    expectEqual(omitInfo.keyKind, KeyKind.file)
    let omitOut = dir.appendingPathComponent("hello-omit-out.txt")
    _ = try XORFormat.decrypt(at: omitArch, to: omitOut, suppliedKey: loaded)
    expectEqual(try String(contentsOf: omitOut, encoding: .utf8), "Hello")
    print("OK binary key file omit")

    let wrapArch = dir.appendingPathComponent("hello-wrap.xor")
    try XORFormat.encryptFile(at: src, to: wrapArch, key: loaded, storage: .wrap, wrapPassphrase: "hunter2")
    let wrapInfo = try XORFormat.readInfo(from: wrapArch)
    expect(wrapInfo.wrapsKey)
    expect(Array(wrapInfo.keyData) != Array("key".utf8), "file key must be wrapped")
    let wrapOut = dir.appendingPathComponent("hello-wrap-out.txt")
    _ = try XORFormat.decrypt(at: wrapArch, to: wrapOut, wrapPassphrase: "hunter2")
    expectEqual(try String(contentsOf: wrapOut, encoding: .utf8), "Hello")
    print("OK binary key file wrap")

    let huge = XORKey(fileBytes: [UInt8](repeating: 7, count: XORFormat.maxStoredKeyBytes + 1), name: "huge.bin")
    expectThrows({
        try XORFormat.encryptFile(at: src, to: dir.appendingPathComponent("huge.xor"), key: huge)
    }, "stored key file over 64 KB")
    try XORFormat.encryptFile(
        at: src,
        to: dir.appendingPathComponent("huge-omit.xor"),
        key: huge,
        storage: .omit
    )
    print("OK huge key file omit")
}

// Text archive
do {
    let data = try XORFormat.encryptText("Hello", key: key)
    expect(data.prefix(4) == XORFormat.magic)
    print("OK encryptText")
}

// Path validation
expectThrows({ try XORFormat.validateArchiveEntryPath("../../etc/passwd") })
expectThrows({ try XORFormat.validateArchiveEntryPath("/absolute/path") })
expectThrows({ try XORFormat.validateArchiveEntryPath("C:\\windows\\system32") })
do { try XORFormat.validateArchiveEntryPath("folder/file.txt") } catch {
    failures += 1
    print("FAIL unexpected throw on safe path")
}
print("OK path validation")

if failures == 0 {
    print("\nAll tests passed.")
    exit(0)
} else {
    print("\n\(failures) failure(s).")
    exit(1)
}
