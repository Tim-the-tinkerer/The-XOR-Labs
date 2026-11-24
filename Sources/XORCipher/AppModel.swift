import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine
import XORCore
import XORPassCore

enum OutputFormat: String, CaseIterable, Identifiable {
    case hex
    case ascii
    case base64
    case binary

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hex:    return "Hex"
        case .ascii:  return "ASCII"
        case .base64: return "Base64"
        case .binary: return "Binary"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    struct Item: Identifiable, Equatable {
        enum Kind: Equatable, Sendable { case plain, directory, archive }
        enum Status: Equatable {
            case ready
            case working
            case done(URL)
            case failed(String)
        }

        let id: UUID
        let url: URL
        let kind: Kind
        let byteCount: Int
        var status: Status
        var family: ArchiveFamily?
        var detail: String
        var needsPassword: Bool?
        var needsKeyFile: Bool?

        init(
            id: UUID = UUID(),
            url: URL,
            kind: Kind,
            byteCount: Int,
            status: Status = .ready,
            family: ArchiveFamily? = nil,
            detail: String = "",
            needsPassword: Bool? = nil,
            needsKeyFile: Bool? = nil
        ) {
            self.id = id
            self.url = url
            self.kind = kind
            self.byteCount = byteCount
            self.status = status
            self.family = family
            self.detail = detail
            self.needsPassword = needsPassword
            self.needsKeyFile = needsKeyFile
        }

        var name: String { url.lastPathComponent }

        var sizeLabel: String {
            switch kind {
            case .directory:
                if byteCount <= 0 { return "Folder" }
                let formatted = ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
                return "Folder · \(formatted)"
            case .plain, .archive:
                return ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
            }
        }

        func actionLabel(mode: CipherMode) -> String {
            switch kind {
            case .plain:
                return mode == .pass ? "Encrypt → .xorpass" : "Encrypt → .xor"
            case .directory:
                return mode == .pass ? "Encrypt folder → .xorpass" : "Encrypt folder → .xor"
            case .archive:
                return family == .xorpass ? "Decrypt → original name" : "Decrypt → original"
            }
        }
    }

    static let famousKeys = ["key", "SECRET", "xor", "pedia"]

    @Published var mode: CipherMode = .cipher
    @Published var keyword: String = "key"
    @Published var keyKind: KeyKind = .text
    @Published var keyStorage: KeyStorage = .store
    @Published var wrapPassphrase: String = ""
    @Published var keyFileURL: URL?
    @Published var keyFileBytes: [UInt8] = []
    @Published var encryptFileNames = false

    @Published var password = ""
    @Published var confirm = ""
    @Published var revealPassword = false
    @Published var passKeyFileURL: URL?
    @Published var passKeyFileBytes = Data()
    @Published var passProfile: XORPassProfile = .standard
    @Published var passPadding: XORPassPadding = .standard
    @Published var clearSecretsAfter = true
    @Published var items: [Item] = []
    @Published var statusMessage: String?
    @Published var alertMessage: String?
    @Published var isBusy = false

    @Published var textInput = "Hello"
    @Published var textDecrypt = false
    @Published var showText = true
    @Published var outputFormat: OutputFormat = .hex
    @Published var selectedByte: Int = 0

    private var workTask: Task<Void, Never>?
    private var jobGeneration: UInt64 = 0
    private var saveToken: UUID?
    private var recentOpenKeys: [String: Date] = [:]
    private let fileWorker = FileWorkActor()

    var xorKey: XORKey {
        switch keyKind {
        case .text, .hex:
            return XORKey(keyword, kind: keyKind)
        case .file:
            return XORKey(fileBytes: keyFileBytes, name: keyFileURL?.lastPathComponent ?? "key")
        }
    }

    var keyIsValid: Bool { !xorKey.isEmpty }

    var keyInvalidMessage: String {
        switch keyKind {
        case .file:
            return "Choose a key file."
        case .hex:
            return XORError.invalidHexKey.errorDescription ?? "Invalid hex key."
        case .text:
            return XORError.emptyKey.errorDescription ?? "Enter a key."
        }
    }

    var keyHint: String {
        switch keyKind {
        case .file:
            if keyFileBytes.isEmpty { return "Choose a binary key file" }
            if keyStorage != .omit, keyFileBytes.count > XORFormat.maxStoredKeyBytes {
                return "Larger than 64 KB — use Don’t store"
            }
            return xorKey.summary
        case .hex:
            if keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Enter hex bytes (e.g. 6B 65 79)"
            }
            if XOREngine.parseHex(keyword) == nil {
                return "Need an even number of hex digits"
            }
            return xorKey.summary
        case .text:
            if keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Enter a repeating key"
            }
            return xorKey.summary
        }
    }

    /// Bytes the workshop operates on: UTF-8 of the field, or parsed hex when decrypting hex-looking input.
    var inputBytes: Data {
        if textDecrypt, let hex = XOREngine.parseHex(textInput), !hex.isEmpty {
            return hex
        }
        return Data(textInput.utf8)
    }

    var outputBytes: Data {
        guard keyIsValid, !inputBytes.isEmpty else { return Data() }
        return XOREngine.encrypt(inputBytes, key: xorKey)
    }

    var textOutput: String {
        guard !outputBytes.isEmpty else { return "" }
        if textDecrypt {
            if let s = String(data: outputBytes, encoding: .utf8), !s.isEmpty {
                return s
            }
            return XOREngine.asciiPreview(outputBytes)
        }
        switch outputFormat {
        case .hex:
            return XOREngine.hexString(outputBytes)
        case .ascii:
            return XOREngine.asciiPreview(outputBytes)
        case .base64:
            return outputBytes.base64EncodedString()
        case .binary:
            return outputBytes.prefix(48).map { XOREngine.bitString($0) }.joined(separator: " ")
        }
    }

    var alignment: [ByteAlign] {
        guard keyIsValid, !inputBytes.isEmpty else { return [] }
        return XOREngine.alignment(of: inputBytes, key: xorKey)
    }

    var selectedAlign: ByteAlign? {
        let steps = alignment
        guard !steps.isEmpty else { return nil }
        let idx = min(max(0, selectedByte), steps.count - 1)
        return steps[idx]
    }

    func selectMode(_ newMode: CipherMode) {
        guard mode != newMode else { return }
        mode = newMode
        statusMessage = newMode.switchedStatus
    }

    func loadFamousExample() {
        mode = .cipher
        keyword = "key"
        keyKind = .text
        textInput = "Hello"
        textDecrypt = false
        outputFormat = .hex
        showText = true
        selectedByte = 0
        statusMessage = "Hello ⊕ key → 23 00 15 07 0A  (e ⊕ e = 00)"
    }

    func loadWikiExample() {
        mode = .cipher
        keyword = "pedia"
        keyKind = .text
        textInput = "Wiki"
        textDecrypt = false
        outputFormat = .hex
        showText = true
        selectedByte = 0
        statusMessage = "Wiki ⊕ pedia → 27 0C 0F 00"
    }

    func generateRandomKey() {
        mode = .cipher
        let n = max(1, min(32, xorKey.byteValues.count == 0 ? 8 : xorKey.byteValues.count))
        keyword = XOREngine.randomHexKey(byteCount: n)
        keyKind = .hex
        statusMessage = "Random \(n)-byte key"
    }

    func chooseKeyFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose Key File"
        panel.message = "The file’s raw bytes become the repeating XOR key."
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.data, .item]
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadKeyFile(url)
    }

    func loadKeyFile(_ url: URL) {
        do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard !data.isEmpty else {
                alertMessage = "The key file is empty."
                return
            }
            keyFileURL = url
            keyFileBytes = Array(data)
            keyKind = .file
            if data.count > XORFormat.maxStoredKeyBytes, keyStorage != .omit {
                keyStorage = .omit
                statusMessage = "\(url.lastPathComponent) is larger than 64 KB — not stored in the .xor file. Keep this key file to decrypt."
            } else {
                statusMessage = "Key file \(url.lastPathComponent) · \(xorKey.summary)"
            }
        } catch {
            alertMessage = "Could not read key file: \(error.localizedDescription)"
        }
    }

    func clearKeyFile() {
        keyFileURL = nil
        keyFileBytes = []
        statusMessage = "Key file cleared"
    }

    var passwordsMatch: Bool {
        XORPassEngine.normalizePassword(password) == XORPassEngine.normalizePassword(confirm)
    }

    var passwordIsUsable: Bool {
        !XORPassEngine.normalizePassword(password).isEmpty
    }

    var hasPassKeyFile: Bool { !passKeyFileBytes.isEmpty }

    var passKeyFileHint: String {
        guard hasPassKeyFile else { return "Optional. Raw bytes, not stored in the archive." }
        let name = passKeyFileURL?.lastPathComponent ?? "key"
        let size = ByteCountFormatter.string(fromByteCount: Int64(passKeyFileBytes.count), countStyle: .file)
        return "\(name) · \(size) · needed again to decrypt"
    }

    var passwordHint: String {
        if password.isEmpty {
            return hasPassKeyFile ? "Optional while a key file is chosen" : "Or choose a key file"
        }
        if Data(password.utf8).count < 8 { return "Short passwords are easier to guess" }
        return "Kept in this window only"
    }

    var passwordApplies: Bool {
        items.isEmpty || items.contains { $0.needsPassword != false }
    }

    var passKeyFileApplies: Bool {
        items.isEmpty || items.contains { $0.needsKeyFile != false }
    }

    func choosePassKeyFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose Key File"
        panel.message = "The file’s raw bytes are mixed into the key. The file is not stored in the archive."
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.data, .item]
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadPassKeyFile(url)
    }

    func loadPassKeyFile(_ url: URL) {
        do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard !data.isEmpty else {
                alertMessage = "The key file is empty."
                return
            }
            guard data.count <= XORPassEngine.maxKeyFileBytes else {
                alertMessage = XORPassError.keyFileTooLarge.errorDescription
                return
            }
            passKeyFileURL = url
            passKeyFileBytes = data
            statusMessage = "Key file \(url.lastPathComponent) · \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))"
        } catch {
            alertMessage = "Could not read key file: \(error.localizedDescription)"
        }
    }

    func clearPassKeyFile() {
        passKeyFileURL = nil
        passKeyFileBytes = Data()
        statusMessage = "Key file cleared"
    }

    /// Drops the password, confirmation, and Pass key file. Swift cannot guarantee the bytes are gone from every copy.
    func wipePassSecrets() {
        password = ""
        confirm = ""
        passKeyFileURL = nil
        passKeyFileBytes = Data()
    }

    func copyOutput() {
        let s = textOutput
        guard !s.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        statusMessage = "Copied \(outputFormat.title.lowercased())"
    }

    // MARK: - Add files / folders

    func openFiles() {
        let panel = NSOpenPanel()
        panel.title = "Choose Files or Folders"
        panel.message = mode == .pass
            ? "Pick files or folders to encrypt, or .xorpass files to decrypt."
            : "Pick files or folders to encrypt, or .xor and .xorpass files to decrypt."
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.item]
        panel.allowsOtherFileTypes = true
        panel.treatsFilePackagesAsDirectories = true
        guard panel.runModal() == .OK else { return }
        add(panel.urls, autoDecryptArchives: true, dedupe: false)
    }

    @discardableResult
    func add(_ urls: [URL], autoDecryptArchives: Bool = true, dedupe: Bool = true) -> [UUID] {
        let filtered = dedupe ? dedupeIncoming(urls) : urls

        var newIDs: [UUID] = []
        for url in filtered {
            guard url.isFileURL else { continue }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
                continue
            }

            if let existing = items.firstIndex(where: {
                $0.url.standardizedFileURL == url.standardizedFileURL
            }) {
                if items[existing].kind == .archive, autoDecryptArchives {
                    if case .ready = items[existing].status {
                        newIDs.append(items[existing].id)
                    } else if case .failed = items[existing].status {
                        items[existing].status = .ready
                        newIDs.append(items[existing].id)
                    }
                }
                continue
            }

            let item = makeItem(url: url, isDir: isDir.boolValue)
            items.append(item)
            newIDs.append(item.id)

            if item.kind == .directory {
                refreshDirectorySize(id: item.id, url: url)
            }
        }

        noteArchiveModes(in: newIDs)

        if autoDecryptArchives {
            let archiveIDs = newIDs.filter { id in
                guard let item = items.first(where: { $0.id == id }), item.kind == .archive else {
                    return false
                }
                return canDecrypt(item)
            }
            let locked = newIDs.filter { id in
                guard let item = items.first(where: { $0.id == id }), item.kind == .archive else {
                    return false
                }
                return !canDecrypt(item)
            }
            if !archiveIDs.isEmpty {
                runJobs(ids: archiveIDs, revealResults: false)
            } else if let lockedItem = items.first(where: { locked.contains($0.id) }) {
                statusMessage = decryptHint(for: lockedItem)
                if lockedItem.family != .xorpass {
                    revealSecretFields(for: lockedItem.url)
                }
            } else if !newIDs.isEmpty {
                statusMessage = "Added \(newIDs.count) item\(newIDs.count == 1 ? "" : "s")"
            }
        } else if !newIDs.isEmpty {
            statusMessage = "Added \(newIDs.count) item\(newIDs.count == 1 ? "" : "s")"
        }

        return newIDs
    }

    private func dedupeIncoming(_ urls: [URL]) -> [URL] {
        let now = Date()
        recentOpenKeys = recentOpenKeys.filter { now.timeIntervalSince($0.value) < 2.0 }
        var result: [URL] = []
        for url in urls {
            let key = url.standardizedFileURL.path
            if let last = recentOpenKeys[key], now.timeIntervalSince(last) < 1.5 {
                continue
            }
            recentOpenKeys[key] = now
            result.append(url)
        }
        return result
    }

    func handleOpenedFiles(_ urls: [URL], revealResults: Bool) {
        NSApp.activate(ignoringOtherApps: true)

        let filtered = dedupeIncoming(urls)
        guard !filtered.isEmpty else { return }

        var archiveIDs: [UUID] = []
        var otherCount = 0

        for url in filtered {
            guard url.isFileURL else { continue }

            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
                continue
            }

            let family = archiveFamily(of: url, isDir: isDir.boolValue)
            let isArchive = family != nil

            if isArchive {
                if let idx = items.firstIndex(where: {
                    $0.url.standardizedFileURL == url.standardizedFileURL
                }) {
                    if case .working = items[idx].status { continue }
                    items[idx].status = .ready
                    archiveIDs.append(items[idx].id)
                } else {
                    let item = makeItem(url: url, isDir: false)
                    items.append(item)
                    archiveIDs.append(item.id)
                }
            } else {
                _ = addBypassingDedupe([url], autoDecryptArchives: false)
                otherCount += 1
            }
        }

        noteArchiveModes(in: archiveIDs)

        let ready = archiveIDs.filter { id in
            guard let item = items.first(where: { $0.id == id }) else { return false }
            return canDecrypt(item)
        }
        let locked = archiveIDs.filter { id in
            guard let item = items.first(where: { $0.id == id }) else { return false }
            return !canDecrypt(item)
        }

        if !ready.isEmpty {
            runJobs(ids: ready, revealResults: revealResults)
        } else if let lockedItem = items.first(where: { locked.contains($0.id) }) {
            statusMessage = decryptHint(for: lockedItem)
            if lockedItem.family != .xorpass {
                revealSecretFields(for: lockedItem.url)
            }
        } else if otherCount > 0 {
            statusMessage = "Added \(otherCount) item\(otherCount == 1 ? "" : "s") — click Encrypt when ready"
        }
    }

    private func revealSecretFields(for url: URL) {
        guard let info = try? XORFormat.readInfo(from: url) else { return }
        keyKind = info.keyKind
        if info.wrapsKey { keyStorage = .wrap }
        if info.omitsKey { keyStorage = .omit }
    }

    private func canDecrypt(_ item: Item) -> Bool {
        guard item.kind == .archive else { return false }
        if item.family == .xorpass {
            return passDecryptBlock(for: item.url) == nil
        }
        return canDecryptXOR(at: item.url)
    }

    private func canDecryptXOR(at url: URL) -> Bool {
        guard let info = try? XORFormat.readInfo(from: url) else { return false }
        if info.omitsKey { return keyIsValid }
        if info.wrapsKey { return !XORKey(wrapPassphrase, kind: .text).isEmpty }
        return true
    }

    private func passDecryptBlock(for url: URL) -> String? {
        guard let peek = try? XORPassFormat.peek(at: url) else { return nil }
        if peek.needsPassword, !passwordIsUsable { return XORPassError.emptyPassword.errorDescription }
        if peek.needsKeyFile, !hasPassKeyFile { return XORPassError.keyFileRequired.errorDescription }
        return nil
    }

    private func decryptHint(for item: Item) -> String {
        if item.family == .xorpass {
            return passDecryptBlock(for: item.url) ?? "Enter the password or choose the key file, then Decrypt"
        }
        guard let info = try? XORFormat.readInfo(from: item.url) else {
            return "Enter the key, then click Decrypt"
        }
        if info.omitsKey {
            return "This .xor does not store the key — type it, then Decrypt"
        }
        if info.wrapsKey {
            return "This .xor’s key is encrypted — enter the wrap passphrase, then Decrypt"
        }
        return "Ready to decrypt"
    }

    private func makeItem(url: URL, isDir: Bool) -> Item {
        let family = archiveFamily(of: url, isDir: isDir)
        let kind: Item.Kind = isDir ? .directory : (family == nil ? .plain : .archive)
        var detail = ""
        var needsPassword: Bool?
        var needsKeyFile: Bool?
        if family == .xorpass {
            (detail, needsPassword, needsKeyFile) = passArchiveDetail(url)
        }
        let size = isDir ? 0 : fileByteCount(url)
        return Item(
            url: url,
            kind: kind,
            byteCount: size,
            family: family,
            detail: detail,
            needsPassword: needsPassword,
            needsKeyFile: needsKeyFile
        )
    }

    private func archiveFamily(of url: URL, isDir: Bool) -> ArchiveFamily? {
        guard !isDir else { return nil }
        if XORPassFormat.isArchive(at: url) { return .xorpass }
        if url.pathExtension.lowercased() == XORFormat.fileExtension || XORFormat.isXORFile(at: url) {
            return .xor
        }
        return nil
    }

    private func passArchiveDetail(_ url: URL) -> (String, Bool?, Bool?) {
        guard let peek = try? XORPassFormat.peek(at: url) else {
            return ("", true, true)
        }
        var parts = [peek.profile.parameterLabel, peek.protectionLabel]
        if peek.directory { parts.append("folder") }
        if peek.padding != .standard { parts.append("\(peek.padding.title) padding") }
        return (parts.joined(separator: " · "), peek.needsPassword, peek.needsKeyFile)
    }

    private func fileByteCount(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
    }

    private func noteArchiveModes(in ids: [UUID]) {
        let families: [ArchiveFamily] = ids.compactMap { id in
            guard let item = items.first(where: { $0.id == id }), item.kind == .archive else { return nil }
            return item.family
        }
        guard let last = families.last else { return }
        mode = last == .xorpass ? .pass : .cipher
    }

    private func addBypassingDedupe(_ urls: [URL], autoDecryptArchives: Bool) -> [UUID] {
        var newIDs: [UUID] = []
        for url in urls {
            guard url.isFileURL else { continue }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
                continue
            }
            if items.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
                continue
            }
            let item = makeItem(url: url, isDir: isDir.boolValue)
            items.append(item)
            newIDs.append(item.id)
            if item.kind == .directory {
                refreshDirectorySize(id: item.id, url: url)
            }
        }
        return newIDs
    }

    private func refreshDirectorySize(id: UUID, url: URL) {
        Task { [weak self] in
            let bytes = await Task.detached(priority: .utility) {
                XORFormat.directoryContentSize(url)
            }.value
            await MainActor.run {
                guard let self,
                      let idx = self.items.firstIndex(where: { $0.id == id }) else { return }
                let old = self.items[idx]
                self.items[idx] = Item(
                    id: old.id,
                    url: old.url,
                    kind: old.kind,
                    byteCount: bytes,
                    status: old.status,
                    family: old.family,
                    detail: old.detail,
                    needsPassword: old.needsPassword,
                    needsKeyFile: old.needsKeyFile
                )
            }
        }
    }

    func remove(_ item: Item) {
        if case .working = item.status { return }
        items.removeAll { $0.id == item.id }
    }

    func clear() {
        workTask?.cancel()
        jobGeneration &+= 1
        saveToken = nil
        isBusy = false
        items.removeAll()
        statusMessage = nil
    }

    // MARK: - Process (background)

    func processAll() {
        guard !isBusy else { return }
        let ids = items.map(\.id)
        if let message = secretProblem(for: ids) {
            revealModeForSecretProblem(ids)
            alertMessage = message
            return
        }
        runJobs(ids: ids, revealResults: false)
    }

    func process(_ item: Item) {
        guard !isBusy else { return }
        if item.kind == .archive {
            if item.family == .xorpass {
                mode = .pass
            } else {
                mode = .cipher
                revealSecretFields(for: item.url)
            }
        }
        if let message = secretProblem(for: [item.id]) {
            alertMessage = message
            return
        }
        runJobs(ids: [item.id], revealResults: false)
    }

    private func secretProblem(for ids: [UUID]) -> String? {
        let needsEncrypt = ids.contains { id in
            guard let item = items.first(where: { $0.id == id }) else { return false }
            return item.kind != .archive
        }
        if needsEncrypt {
            if mode == .pass {
                if !passwordIsUsable, !hasPassKeyFile {
                    return XORPassError.missingSecret.errorDescription
                }
                if passwordIsUsable, !passwordsMatch {
                    return "Type the same password in both fields."
                }
            } else if !keyIsValid {
                return keyInvalidMessage
            } else if keyStorage == .wrap, XORKey(wrapPassphrase, kind: .text).isEmpty {
                return XORError.wrapPassphraseRequired.errorDescription
            }
        }
        for id in ids {
            guard let item = items.first(where: { $0.id == id }), item.kind == .archive else { continue }
            if let message = missingSecretMessage(for: item) { return message }
        }
        return nil
    }

    /// Shows the fields that match the check that stopped the batch.
    private func revealModeForSecretProblem(_ ids: [UUID]) {
        let needsEncrypt = ids.contains { id in
            guard let item = items.first(where: { $0.id == id }) else { return false }
            return item.kind != .archive
        }
        if needsEncrypt {
            if mode == .pass {
                let passwordBlocked = (!passwordIsUsable && !hasPassKeyFile)
                    || (passwordIsUsable && !passwordsMatch)
                if passwordBlocked {
                    mode = .pass
                    return
                }
            } else if !keyIsValid || (keyStorage == .wrap && XORKey(wrapPassphrase, kind: .text).isEmpty) {
                mode = .cipher
                return
            }
        }
        for id in ids {
            guard let item = items.first(where: { $0.id == id }), item.kind == .archive else { continue }
            if item.family == .xorpass, passDecryptBlock(for: item.url) != nil {
                mode = .pass
                return
            }
            if item.family != .xorpass, missingSecretMessage(for: item) != nil {
                mode = .cipher
                revealSecretFields(for: item.url)
                return
            }
        }
    }

    private func missingSecretMessage(for item: Item) -> String? {
        guard item.kind == .archive else { return nil }
        if item.family == .xorpass {
            return passDecryptBlock(for: item.url)
        }
        guard let info = try? XORFormat.readInfo(from: item.url) else { return nil }
        if info.omitsKey, !keyIsValid { return XORError.keyRequired.errorDescription }
        if info.wrapsKey, XORKey(wrapPassphrase, kind: .text).isEmpty {
            return XORError.wrapPassphraseRequired.errorDescription
        }
        return nil
    }

    private func runJobs(ids: [UUID], revealResults: Bool) {
        guard !ids.isEmpty else { return }

        workTask?.cancel()
        jobGeneration &+= 1
        let generation = jobGeneration

        let key = xorKey
        let encryptNames = encryptFileNames
        let storage = keyStorage
        let wrap = wrapPassphrase
        let password = password
        let passKey = passKeyFileBytes
        let profile = passProfile
        let padding = passPadding
        let encryptMode = mode
        let jobs: [(UUID, WorkAction, URL)] = ids.compactMap { id in
            guard let item = items.first(where: { $0.id == id }) else { return nil }
            return (id, workAction(for: item, mode: encryptMode), item.url)
        }
        guard !jobs.isEmpty else { return }
        let batchUsesPass = jobs.contains { action in
            switch action.1 {
            case .passFile, .passDirectory, .passArchive: return true
            case .cipherFile, .cipherDirectory, .cipherArchive: return false
            }
        }

        isBusy = true
        statusMessage = batchUsesPass ? "Stretching the key with Argon2id…" : "Working…"

        workTask = Task { [weak self] in
            var outputs: [URL] = []
            var ok = 0
            var fail = 0

            for (id, action, url) in jobs {
                if Task.isCancelled { break }

                let stillCurrent = await MainActor.run { () -> Bool in
                    guard let self, self.jobGeneration == generation else { return false }
                    self.setStatus(id, .working)
                    return true
                }
                guard stillCurrent else { return }

                let worker = await MainActor.run { [weak self] in self?.fileWorker }
                guard let worker else { return }

                let result: Result<URL, Error>
                do {
                    let out = try await worker.run(
                        action: action,
                        url: url,
                        key: key,
                        encryptNames: encryptNames,
                        storage: storage,
                        wrapPassphrase: wrap,
                        password: password,
                        passKey: passKey,
                        profile: profile,
                        padding: padding
                    )
                    result = .success(out)
                } catch {
                    result = .failure(error)
                }

                let apply = await MainActor.run { () -> Bool in
                    guard let self, self.jobGeneration == generation else { return false }
                    switch result {
                    case .success(let out):
                        self.setStatus(id, .done(out))
                        outputs.append(out)
                        ok += 1
                    case .failure(let error):
                        self.setStatus(id, .failed(error.localizedDescription))
                        fail += 1
                    }
                    return true
                }
                guard apply else { return }
            }

            await MainActor.run {
                guard let self, self.jobGeneration == generation else { return }
                self.isBusy = false
                if fail == 0 && ok > 0 {
                    if ok == 1, let out = outputs.first {
                        self.statusMessage = "Done → \(out.lastPathComponent)"
                    } else {
                        self.statusMessage = "Done — \(ok) item\(ok == 1 ? "" : "s")"
                    }
                } else if ok > 0 {
                    self.statusMessage = "Finished: \(ok) ok, \(fail) failed"
                } else if fail > 0 {
                    self.statusMessage = "Failed"
                    if case .failed(let msg) = self.items.first(where: { ids.contains($0.id) })?.status {
                        self.alertMessage = msg
                    }
                } else if Task.isCancelled {
                    self.statusMessage = "Cancelled"
                }
                if revealResults, !outputs.isEmpty {
                    NSWorkspace.shared.activateFileViewerSelecting(outputs)
                }
                if batchUsesPass, self.clearSecretsAfter {
                    self.wipePassSecrets()
                }
            }
        }
    }

    private func workAction(for item: Item, mode: CipherMode) -> WorkAction {
        switch item.kind {
        case .archive:
            return item.family == .xorpass ? .passArchive : .cipherArchive
        case .plain:
            return mode == .pass ? .passFile : .cipherFile
        case .directory:
            return mode == .pass ? .passDirectory : .cipherDirectory
        }
    }

    private func setStatus(_ id: UUID, _ status: Item.Status) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].status = status
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Text → .xor

    func saveTextAsXOR() {
        guard !textInput.isEmpty, !isBusy else { return }
        guard keyIsValid else {
            alertMessage = keyInvalidMessage
            return
        }
        let panel = NSSavePanel()
        panel.title = "Save .xor"
        panel.nameFieldStringValue = "message.\(XORFormat.fileExtension)"
        panel.allowedContentTypes = [
            UTType(filenameExtension: XORFormat.fileExtension) ?? .data
        ]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        if keyStorage == .wrap, XORKey(wrapPassphrase, kind: .text).isEmpty {
            alertMessage = XORError.wrapPassphraseRequired.errorDescription
            return
        }
        let text = textInput
        let key = xorKey
        let storage = keyStorage
        let wrap = wrapPassphrase
        isBusy = true
        statusMessage = "Saving…"
        let token = UUID()
        saveToken = token

        Task { [weak self] in
            do {
                let data = try await Task.detached {
                    try XORFormat.encryptText(text, key: key, storage: storage, wrapPassphrase: wrap)
                }.value
                try data.write(to: url, options: .atomic)
                await MainActor.run {
                    guard let self, self.saveToken == token else { return }
                    self.saveToken = nil
                    self.isBusy = false
                    self.statusMessage = "Saved \(url.lastPathComponent)"
                }
            } catch {
                await MainActor.run {
                    guard let self, self.saveToken == token else { return }
                    self.saveToken = nil
                    self.isBusy = false
                    self.alertMessage = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Serial file I/O

private enum WorkAction: Sendable {
    case cipherFile
    case cipherDirectory
    case cipherArchive
    case passFile
    case passDirectory
    case passArchive
}

private actor FileWorkActor {
    func run(
        action: WorkAction,
        url: URL,
        key: XORKey,
        encryptNames: Bool,
        storage: KeyStorage,
        wrapPassphrase: String,
        password: String,
        passKey: Data,
        profile: XORPassProfile,
        padding: XORPassPadding
    ) throws -> URL {
        switch action {
        case .cipherFile:
            let out = XORFormat.archiveURL(for: url, key: key, encryptNames: encryptNames)
            try XORFormat.encryptFile(
                at: url,
                to: out,
                key: key,
                encryptNames: encryptNames,
                storage: storage,
                wrapPassphrase: wrapPassphrase
            )
            return out
        case .cipherDirectory:
            let out = XORFormat.archiveURL(for: url, key: key, encryptNames: encryptNames)
            try XORFormat.encryptDirectory(
                at: url,
                to: out,
                key: key,
                encryptNames: encryptNames,
                storage: storage,
                wrapPassphrase: wrapPassphrase
            )
            return out
        case .cipherArchive:
            let info = try XORFormat.readInfo(from: url)
            let resolved = try XORFormat.resolveKey(
                from: info,
                suppliedKey: key,
                wrapPassphrase: wrapPassphrase
            )
            let out = XORFormat.restoreURL(for: url, info: info, key: resolved)
            _ = try XORFormat.decrypt(
                at: url,
                to: out,
                suppliedKey: key,
                wrapPassphrase: wrapPassphrase
            )
            return out
        case .passFile:
            let out = try XORPassFormat.archiveURL(near: url)
            try XORPassFormat.encryptFile(
                at: url,
                to: out,
                password: password,
                profile: profile,
                keyFile: passKey,
                padding: padding
            )
            return out
        case .passDirectory:
            let out = try XORPassFormat.archiveURL(near: url)
            try XORPassFormat.encryptDirectory(
                at: url,
                to: out,
                password: password,
                profile: profile,
                keyFile: passKey,
                padding: padding
            )
            return out
        case .passArchive:
            return try XORPassFormat.decrypt(at: url, password: password, keyFile: passKey)
        }
    }
}
