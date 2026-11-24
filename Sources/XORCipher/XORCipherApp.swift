import SwiftUI
import AppKit
import XORCore

@MainActor
public final class LabWorkspace: NSObject {
    private let model = AppModel()
    private var window: NSWindow?
    private var menu: NSMenu?
    public override init() { super.init() }
    public func show() -> (NSWindow, NSMenu) {
        if let window, let menu {
            window.makeKeyAndOrderFront(nil)
            return (window, menu)
        }
        let root = ContentView().environmentObject(model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 860), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "XOR Cipher — The XOR Labs"
        window.contentView = NSHostingView(rootView: root)
        window.minSize = NSSize(width: 840, height: 620)
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("XORLabsCipherWindow")
        let menu = buildMenu()
        self.menu = menu
        self.window = window
        window.makeKeyAndOrderFront(nil)
        return (window, menu)
    }
    public func open(_ urls: [URL]) { model.handleOpenedFiles(urls, revealResults: true) }
    @objc private func openFiles(_ sender: Any?) { model.openFiles() }
    @objc private func process(_ sender: Any?) { model.processAll() }
    @objc private func cipher(_ sender: Any?) { model.selectMode(.cipher) }
    @objc private func pass(_ sender: Any?) { model.selectMode(.pass) }
    @objc private func hello(_ sender: Any?) { model.loadFamousExample() }
    @objc private func wiki(_ sender: Any?) { model.loadWikiExample() }
    @objc private func randomKey(_ sender: Any?) { model.generateRandomKey() }
    @objc public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(process(_:)) { return !model.items.isEmpty && !model.isBusy }
        if item.action == #selector(cipher(_:)) { item.state = model.mode == .cipher ? .on : .off }
        if item.action == #selector(pass(_:)) { item.state = model.mode == .pass ? .on : .off }
        return true
    }
    private func buildMenu() -> NSMenu {
        let main = NSMenu()
        func section(_ name: String) -> NSMenu {
            let item = NSMenuItem(); main.addItem(item)
            let menu = NSMenu(title: name); item.submenu = menu; return menu
        }
        func add(_ menu: NSMenu, _ title: String, _ selector: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) {
            let item = menu.addItem(withTitle: title, action: selector, keyEquivalent: key)
            item.target = self; item.keyEquivalentModifierMask = mods
        }
        let app = section("The XOR Labs")
        app.addItem(withTitle: "Quit The XOR Labs", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let file = section("File")
        add(file, "Open Files…", #selector(openFiles(_:)), "o")
        add(file, "Encrypt / Decrypt All", #selector(process(_:)), "\r")
        let edit = section("Edit")
        for (title, selector, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: NSSelectorFromString(selector), keyEquivalent: key)
        }
        let mode = section("Mode")
        add(mode, "Cipher", #selector(cipher(_:)), "1")
        add(mode, "Pass", #selector(pass(_:)), "2")
        let workshop = section("Workshop")
        add(workshop, "Hello ⊕ key", #selector(hello(_:)), "e", [.command, .shift])
        add(workshop, "Wiki ⊕ pedia", #selector(wiki(_:)), "k", [.command, .shift])
        add(workshop, "Random Hex Key", #selector(randomKey(_:)), "r", [.command, .shift])
        add(section("Help"), "XOR Cipher Help", #selector(showHelp(_:)))
        return main
    }
    @objc private func showHelp(_ sender: Any?) {
        let a = NSAlert()
        a.messageText = "How it works"
        a.informativeText = """
        Cipher and Pass are two modes. Cipher writes .xor. Pass writes .xorpass. Dropping an archive switches to the mode named by the file.

        CIPHER
        XOR flips a bit when the key bit is 1 and leaves it when the key bit is 0.

            P  01001000   H
            K  01101011   k
            C  00100011   #

        The same operation undoes itself: C ⊕ K = P. A repeating key is the Vernam / XOR cipher.

        Famous example: Hello ⊕ key → 23 00 15 07 0A. The second byte is 00 because e ⊕ e = 0.

        Choose Text, Hex, or a binary key file, then Encrypt. One .xor per file or folder.
        • Store key writes the key in the header (max 64 KB)
        • Don't store omits it
        • Encrypt key XOR-wraps the stored key with a passphrase
        • Encrypt file names XORs names, then stores them as hex

        A .xor that stores its key decrypts on open. The others need the key, key file, or wrap passphrase.

        Cipher is educational. A short repeating key is trivial to break.

        PASS
        The cipher is still XOR. The password is not the key, and it is not written into the file.

            password + salt  →  Argon2id  →  32-byte key
            key + nonce      →  HMAC-SHA256 counter  →  keystream
            ciphertext       =  plaintext  ⊕  keystream

        Each file gets a new salt and nonce. Standard stretch is 64 MiB, 3 passes, 4 lanes. A key file’s raw bytes can be the secret, with a password, or both. The original name is encrypted. On disk the archive is XORPass- plus random hex, with the extension .xorpass.

        Type the same password and choose the same key file to decrypt. Clear secrets when finished is on by default.
        """
        a.addButton(withTitle: "OK")
        a.runModal()
    }
}
