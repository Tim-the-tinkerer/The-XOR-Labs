import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Moire
import ParityPainter
import Crosstalk
import XORCipher

private enum Lab: String, CaseIterable, Identifiable {
    case moire, parity, crosstalk, cipher
    var id: String { rawValue }
    var title: String {
        switch self { case .moire: return "Moire"; case .parity: return "Parity Painter"; case .crosstalk: return "Crosstalk"; case .cipher: return "XOR Cipher" }
    }
    var medium: String {
        switch self { case .moire: return "VIDEO LAB"; case .parity: return "IMAGE LAB"; case .crosstalk: return "AUDIO LAB"; case .cipher: return "DATA LAB" }
    }
    var detail: String {
        switch self {
        case .moire: return "Frame-by-frame interference, rotation, offset and delay."
        case .parity: return "Pixel differences, bit planes, masks and image traces."
        case .crosstalk: return "Sample-level XOR, channel folds, delay and audio experiments."
        case .cipher: return "Binary XOR, key experiments and the separate Pass mode."
        }
    }
    var symbol: String {
        switch self { case .moire: return "film"; case .parity: return "photo"; case .crosstalk: return "waveform"; case .cipher: return "lock.shield" }
    }
    var accent: Color {
        switch self { case .moire: return Color(red: 0.69, green: 0.57, blue: 1); case .parity: return Color(red: 1, green: 0.72, blue: 0.32); case .crosstalk: return Color(red: 0.30, green: 0.87, blue: 0.75); case .cipher: return Color(red: 0.40, green: 0.68, blue: 1) }
    }
}

private struct HomeView: View {
    let open: (Lab) -> Void

    var body: some View {
        ScrollView {
            dashboard
        }
        .foregroundStyle(.white)
        .background(Color(red: 0.065, green: 0.078, blue: 0.105))
        .preferredColorScheme(.dark)
    }

    private var dashboard: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible())], spacing: 14) {
                ForEach(Lab.allCases) { lab in
                    labCard(lab)
                }
            }
            Divider()
            footer
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 20)
    }

    private var header: some View {
        HStack(spacing: 20) {
            ZStack {
                RoundedRectangle(cornerRadius: 17)
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 76, height: 76)
                Text("⊕")
                    .font(.system(size: 58, weight: .ultraLight, design: .monospaced))
                    .foregroundStyle(Color(red: 0.34, green: 0.90, blue: 0.82))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("THE XOR LABS")
                    .font(.system(size: 32, weight: .semibold, design: .monospaced))
                    .tracking(2)
                    .accessibilityAddTraits(.isHeader)
                Text("One operation. Four laboratories.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func labCard(_ lab: Lab) -> some View {
        Button { open(lab) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: lab.symbol)
                        .font(.system(size: 23, weight: .medium))
                    Spacer()
                    Text(lab.medium)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .tracking(1)
                }
                .foregroundStyle(lab.accent)
                Text(lab.title)
                    .font(.system(size: 23, weight: .semibold))
                Text(lab.detail)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                HStack {
                    Text("Open laboratory")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Image(systemName: "arrow.up.right")
                }
                .foregroundStyle(lab.accent)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 166, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(lab.accent.opacity(0.30), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(lab.title)")
    }

    private var footer: some View {
        HStack {
            Text("0 ⊕ 0 = 0   ·   0 ⊕ 1 = 1   ·   1 ⊕ 0 = 1   ·   1 ⊕ 1 = 0")
                .font(.system(size: 12, design: .monospaced))
            Spacer()
            Text("v1.0.0")
                .font(.system(size: 11, design: .monospaced))
        }
        .foregroundStyle(.secondary)
    }
}

@MainActor
private final class SuiteDelegate: NSObject, NSApplicationDelegate {
    private lazy var video = Moire.LabWorkspace()
    private lazy var image = ParityPainter.LabWorkspace()
    private lazy var audio = Crosstalk.LabWorkspace()
    private lazy var data = XORCipher.LabWorkspace()
    private var home: NSWindow?
    private var homeMenu: NSMenu?
    private var windows: [Lab: NSWindow] = [:]
    private var menus: [Lab: NSMenu] = [:]
    private var observer: NSObjectProtocol?
    private var closeObserver: NSObjectProtocol?
    private var pending: [URL] = []
    private var ready = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.windowChanged(note.object as? NSWindow) }
        }
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.windowClosed(note.object as? NSWindow) }
        }
        showHome(nil)
        ready = true
        if !pending.isEmpty { let urls = pending; pending.removeAll(); route(urls) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showHome(nil); return true }
    func applicationWillTerminate(_ notification: Notification) {
        if windows[.crosstalk] != nil { audio.stop() }
        if windows[.moire] != nil { video.stop() }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
    }
    func application(_ application: NSApplication, open urls: [URL]) { receive(urls) }
    func application(_ sender: NSApplication, openFile filename: String) -> Bool { receive([URL(fileURLWithPath: filename)]); return true }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        receive(filenames.map { URL(fileURLWithPath: $0) }); sender.reply(toOpenOrPrint: .success)
    }
    private func receive(_ urls: [URL]) { if ready { route(urls) } else { pending += urls } }
    private func route(_ urls: [URL]) {
        var grouped: [Lab: [URL]] = [:]
        let current = windows.first(where: { $0.value === NSApp.keyWindow })?.key
        for url in urls {
            let ext = url.pathExtension.lowercased()
            let type = UTType(filenameExtension: ext)
            let lab: Lab
            if ["xor", "xorpass"].contains(ext) { lab = .cipher }
            else if current == .cipher { lab = .cipher }
            else if ["mkv", "webm", "mov", "mp4", "m4v", "avi"].contains(ext) || type?.conforms(to: .movie) == true { lab = .moire }
            else if type?.conforms(to: .image) == true { lab = .parity }
            else if type?.conforms(to: .audio) == true || ["flac", "wav", "aiff", "mp3", "m4a", "ogg"].contains(ext) { lab = .crosstalk }
            else { lab = .cipher }
            grouped[lab, default: []].append(url)
        }
        for lab in Lab.allCases {
            guard let files = grouped[lab] else { continue }
            show(lab)
            switch lab { case .moire: video.open(files); case .parity: image.open(files); case .crosstalk: audio.open(files); case .cipher: data.open(files) }
        }
    }
    @objc private func showHome(_ sender: Any?) {
        if home == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 575), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "The XOR Labs"
            w.appearance = NSAppearance(named: .darkAqua)
            let view = NSHostingView(rootView: HomeView(open: { [weak self] lab in self?.show(lab) }))
            view.sizingOptions = []
            w.contentView = view
            w.contentMinSize = NSSize(width: 760, height: 530)
            w.isReleasedWhenClosed = false
            w.center(); w.setFrameAutosaveName("XORLabsHome")
            home = w; homeMenu = makeHomeMenu()
        }
        home?.makeKeyAndOrderFront(nil)
        if let homeMenu { install(homeMenu) }
        NSApp.activate(ignoringOtherApps: true)
    }
    private func show(_ lab: Lab) {
        let pair: (NSWindow, NSMenu)
        switch lab { case .moire: pair = video.show(); case .parity: pair = image.show(); case .crosstalk: pair = audio.show(); case .cipher: pair = data.show() }
        let (window, menu) = pair
        if menus[lab] == nil {
            addLabs(to: menu)
            if let app = menu.items.first?.submenu {
                for item in app.items {
                    if item.title.hasPrefix("Quit ") { item.title = "Quit The XOR Labs" }
                    if item.title.hasPrefix("Hide ") && item.action == #selector(NSApplication.hide(_:)) { item.title = "Hide The XOR Labs" }
                }
            }
        }
        windows[lab] = window; menus[lab] = menu
        window.title = "\(lab.title) — The XOR Labs"
        install(menu)
        NSApp.activate(ignoringOtherApps: true)
    }
    private func windowClosed(_ window: NSWindow?) {
        guard let window else { return }
        if window === windows[.moire] { video.stop() }
        if window === windows[.crosstalk] { audio.stop() }
    }
    private func windowChanged(_ window: NSWindow?) {
        guard let window else { return }
        if window === home, let homeMenu { install(homeMenu); return }
        if let lab = windows.first(where: { $0.value === window })?.key, let menu = menus[lab] { install(menu) }
    }
    private func install(_ menu: NSMenu) {
        NSApp.mainMenu = menu
        NSApp.windowsMenu = menu.items.compactMap(\.submenu).first(where: { $0.title == "Window" })
    }
    private func makeHomeMenu() -> NSMenu {
        let menu = NSMenu()
        let item = NSMenuItem(); menu.addItem(item)
        let app = NSMenu(title: "The XOR Labs"); item.submenu = app
        let about = app.addItem(withTitle: "About The XOR Labs", action: #selector(showAbout(_:)), keyEquivalent: ""); about.target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Hide The XOR Labs", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Quit The XOR Labs", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        addLabs(to: menu)
        return menu
    }
    private func addLabs(to main: NSMenu) {
        let top = NSMenuItem(); let menu = NSMenu(title: "Labs"); top.submenu = menu
        main.insertItem(top, at: min(1, main.items.count))
        let home = menu.addItem(withTitle: "Laboratory Home", action: #selector(showHome(_:)), keyEquivalent: "0")
        home.target = self; home.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(.separator())
        for (index, lab) in Lab.allCases.enumerated() {
            let item = menu.addItem(withTitle: lab.title, action: #selector(openLab(_:)), keyEquivalent: String(index + 1))
            item.target = self; item.representedObject = lab.rawValue; item.keyEquivalentModifierMask = [.command, .option]
        }
    }
    @objc private func openLab(_ sender: NSMenuItem) { if let raw = sender.representedObject as? String, let lab = Lab(rawValue: raw) { show(lab) } }
    @objc private func showAbout(_ sender: Any?) { NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "The XOR Labs", .applicationVersion: "1.0.0", .credits: NSAttributedString(string: "Moire · Parity Painter · Crosstalk · XOR Cipher\nOne operation. Four laboratories.")]) }
}

@main
struct XORLabsMain {
    @MainActor static func main() {
        let args = CommandLine.arguments
        if args.count > 1 {
            let forwarded = [args[1]] + Array(args.dropFirst(2))
            switch args[1].lowercased() {
            case "moire" where args.count > 2: Moire.LabWorkspace.cli(forwarded); return
            case "parity" where args.count > 2, "paritypainter" where args.count > 2: ParityPainter.LabWorkspace.cli(forwarded); return
            case "crosstalk" where args.count > 2: Crosstalk.LabWorkspace.cli(forwarded); return
            case "--help", "-h": print("The XOR Labs\nUsage: XORLabs [moire|parity|crosstalk] --help\nLaunch without arguments for the laboratory home."); return
            case "--version": print("The XOR Labs 1.0.0"); return
            default: break
            }
        }
        let app = NSApplication.shared
        let delegate = SuiteDelegate()
        app.delegate = delegate; app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}
