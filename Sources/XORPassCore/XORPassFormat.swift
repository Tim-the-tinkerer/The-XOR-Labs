import Foundation
import Darwin

/// `.xorpass` archives (XOP1). File bytes are XOR'd with the Argon2id keystream.
public enum XORPassFormat {
    public static let fileExtension = "xorpass"

    public static func isArchive(at url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              !isDir.boolValue else { return false }
        if url.pathExtension.lowercased() == fileExtension { return true }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let magic = try? handle.read(upToCount: 4)
        return magic == XORPassEngine.magic
    }

    public static func peek(at url: URL) throws -> XORPassEngine.Peek {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try readExactly(handle, XORPassEngine.headerLength)
        return try XORPassEngine.peek(header)
    }

    public static func archiveURL(near source: URL) throws -> URL {
        let directory = source.deletingLastPathComponent()
        for _ in 0..<8 {
            let name = try opaqueFileName()
            let url = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return uniqueURL(in: directory, preferredName: try opaqueFileName())
    }

    public static func encryptFile(
        at source: URL,
        to destination: URL,
        password: String,
        profile: XORPassProfile,
        storedName: String? = nil,
        directory: Bool = false,
        keyFile: Data = Data(),
        padding: XORPassPadding = .standard
    ) throws {
        let name = storedName ?? source.lastPathComponent
        let size = try fileSize(source)
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let partial = partialURL(for: destination)
        try writePartial(partial, plaintext: false) { output in
            try XORPassEngine.encryptReader(
                plainBytes: size,
                name: name,
                password: password,
                profile: profile,
                directory: directory,
                salt: nil,
                nonce: nil,
                keyFile: keyFile,
                padding: padding,
                read: { count in try readExactly(input, count) },
                write: { try output.write(contentsOf: $0) }
            )
        }
        try moveReplacing(from: partial, to: destination, plaintext: false)
    }

    public static func encryptDirectory(
        at source: URL,
        to destination: URL,
        password: String,
        profile: XORPassProfile,
        keyFile: Data = Data(),
        padding: XORPassPadding = .standard
    ) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDir),
              isDir.boolValue else { throw XORPassError.notDirectory }
        try rejectSymlinks(in: source)

        let work = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let zip = work.appendingPathComponent("payload.zip")
        try zipDirectory(source, to: zip)
        try encryptFile(
            at: zip,
            to: destination,
            password: password,
            profile: profile,
            storedName: source.lastPathComponent,
            directory: true,
            keyFile: keyFile,
            padding: padding
        )
    }

    /// Restores the encrypted file or folder next to `source`. Returns the restored URL.
    @discardableResult
    public static func decrypt(at source: URL, password: String, keyFile: Data = Data()) throws -> URL {
        let total = try fileSize(source)
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let verified = try XORPassEngine.verifyPackage(
            password: password,
            keyFile: keyFile,
            totalSize: total,
            readAt: { offset, count in
                try input.seek(toOffset: offset)
                return try readExactly(input, count)
            }
        )

        let parent = source.deletingLastPathComponent()
        if verified.directory {
            return try decryptDirectory(
                verified: verified,
                cipherLength: verified.cipherLength,
                parent: parent,
                readAt: { offset, count in
                    try input.seek(toOffset: offset)
                    return try readExactly(input, count)
                }
            )
        }

        let destination = uniqueURL(in: parent, preferredName: verified.name)
        let partial = partialURL(for: destination)
        try writePartial(partial, plaintext: true) { output in
            _ = try XORPassEngine.writeCheckedPlaintext(
                verified: verified,
                cipherLength: verified.cipherLength,
                readAt: { offset, count in
                    try input.seek(toOffset: offset)
                    return try readExactly(input, count)
                },
                write: { try output.write(contentsOf: $0) }
            )
        }
        try moveReplacing(from: partial, to: destination, plaintext: true)
        return destination
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
            if n > 10_000 { return directory.appendingPathComponent("\(stem)-\(UUID().uuidString).\(ext)") }
        }
    }

    // MARK: - Directory restore

    private static func decryptDirectory(
        verified: XORPassEngine.Verified,
        cipherLength: UInt64,
        parent: URL,
        readAt: (UInt64, Int) throws -> Data
    ) throws -> URL {
        let work = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let zip = work.appendingPathComponent("payload.zip")
        try writePartial(zip, plaintext: true) { output in
            _ = try XORPassEngine.writeCheckedPlaintext(
                verified: verified,
                cipherLength: cipherLength,
                readAt: readAt,
                write: { try output.write(contentsOf: $0) }
            )
        }
        try XORPassZip.preflight(at: zip)

        let extract = work.appendingPathComponent("extract", isDirectory: true)
        try FileManager.default.createDirectory(at: extract, withIntermediateDirectories: true)
        try setMode(extract, 0o700)
        try unzip(zip, toDirectory: extract)
        try validateExtractedTree(root: extract)

        let children = try FileManager.default.contentsOfDirectory(
            at: extract,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ).filter { $0.lastPathComponent != "__MACOSX" }
        guard children.count == 1 else { throw XORPassError.corrupt }

        let destination = uniqueURL(in: parent, preferredName: verified.name)
        try moveReplacing(from: children[0], to: destination, plaintext: false)
        return destination
    }

    // MARK: - Paths and IO

    private static func opaqueFileName() throws -> String {
        let bytes = try XORPassEngine.randomBytes(8)
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return "XORPass-\(hex).\(fileExtension)"
    }

    private static func partialURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).xorpass-partial")
    }

    private static func fileSize(_ url: URL) throws -> UInt64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize else { throw XORPassError.corrupt }
        return UInt64(size)
    }

    private static func writePartial(
        _ url: URL,
        plaintext: Bool,
        body: (FileHandle) throws -> Void
    ) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        guard fm.createFile(atPath: url.path, contents: nil) else {
            throw XORPassError.corrupt
        }
        if plaintext {
            try setMode(url, 0o600)
        }
        let handle = try FileHandle(forWritingTo: url)
        var closed = false
        do {
            try body(handle)
            try handle.synchronize()
            try handle.close()
            closed = true
        } catch {
            if !closed { try? handle.close() }
            try? fm.removeItem(at: url)
            throw error
        }
    }

    private static func moveReplacing(from source: URL, to destination: URL, plaintext: Bool) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: source)
        } else {
            do {
                try fm.moveItem(at: source, to: destination)
            } catch {
                try fm.copyItem(at: source, to: destination)
                try? fm.removeItem(at: source)
            }
        }
        if plaintext {
            try setMode(destination, 0o600)
        }
    }

    private static func makeWorkDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("xorpass-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try setMode(url, 0o700)
        return url
    }

    private static func setMode(_ url: URL, _ mode: mode_t) throws {
        if chmod(url.path, mode) != 0 {
            throw XORPassError.permissionFailed
        }
    }

    private static func readExactly(_ handle: FileHandle, _ count: Int) throws -> Data {
        var data = Data()
        data.reserveCapacity(count)
        while data.count < count {
            guard let chunk = try handle.read(upToCount: count - data.count), !chunk.isEmpty else {
                throw XORPassError.corrupt
            }
            data.append(chunk)
        }
        return data
    }

    // MARK: - ZIP

    private static func rejectSymlinks(in directory: URL) throws {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return }
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                throw XORPassError.symlinkRejected(fileURL.lastPathComponent)
            }
        }
    }

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
            throw XORPassError.zipFailed(msg.isEmpty ? "ditto exit \(proc.terminationStatus)" : msg)
        }
    }

    // MARK: - Extract safety

    private static func validateArchiveEntryPath(_ name: String) throws {
        if name.isEmpty || name.contains("\0") || name.hasPrefix("/") {
            throw XORPassError.unsafeArchivePath(name)
        }
        let parts = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for part in parts {
            if part == ".." || part.contains("\\") {
                throw XORPassError.unsafeArchivePath(name)
            }
        }
    }

    private static func validateExtractedTree(root: URL) throws {
        let fm = FileManager.default
        let rootResolved = root.resolvingSymlinksInPath().standardizedFileURL
        let rootComponents = rootResolved.pathComponents
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return }

        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                throw XORPassError.unsafeArchivePath(fileURL.lastPathComponent)
            }
            let info = try fileURL.resourceValues(forKeys: [.linkCountKey, .isDirectoryKey])
            if info.isDirectory != true, let links = info.linkCount, links > 1 {
                throw XORPassError.unsafeArchivePath(fileURL.lastPathComponent)
            }
            let resolved = fileURL.resolvingSymlinksInPath().standardizedFileURL
            let childComponents = resolved.pathComponents
            guard childComponents.starts(with: rootComponents) else {
                throw XORPassError.unsafeArchivePath(fileURL.lastPathComponent)
            }
            let relative = childComponents.dropFirst(rootComponents.count).joined(separator: "/")
            if !relative.isEmpty {
                try validateArchiveEntryPath(relative)
            }
        }
    }
}
