import AppKit
import SwiftUI

struct MainEntry {
    static func main(_ args: [String] = CommandLine.arguments) {

        if args.contains("--self-test") {
            if let err = SelfTest.run() {
                fputs("SELF-TEST FAILED: \(err)\n", stderr)
                exit(1)
            }
            print("SELF-TEST OK")
            print("Mask, XOR, plane, trace, slack, nudge, fit, PNG round-trip.")
            exit(0)
        }

        if args.contains("--help") || args.contains("-h") {
            print(helpText)
            exit(0)
        }

        if args.contains("--version") {
            print("\(AppInfo.name) \(AppInfo.version) (\(AppInfo.build))")
            exit(0)
        }

        if wantsCLI(args) {
            runCLI(args)
            exit(0)
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    private static let helpText = """
    \(AppInfo.name) \(AppInfo.version) — XOR two images, paint the difference

    Black where a pixel matches, white where it differs.

    Usage:
      ParityPainter                         Launch the app
      ParityPainter --self-test             Engine checks
      ParityPainter A.png B.png [options]
      ParityPainter --sample [options]

    Options:
      --mode mask|xor|plane|trace           Default mask
      --channel all|red|green|blue|luma     Default all
      --align fit|lock                      Fit scales B onto A. Lock does not resample.
      --slack N                             0...255. Gaps at or under N stay a match.
      --plane N                             0...7, used by --mode plane. 0 is the finest bit.
      --lift 1|2|4|8|16|32                  Brighten the XOR view.
      --dx N  --dy N                        Slide B. Positive X moves B right.
      --invert                              White where they match.
      --jpeg                                Default output is JPEG.
      -o, --out PATH                        Default: parity-<view>-yyyymmdd-hhmmss.png

    The result is A's size. Uncovered pixels compare against black.
    The long edge is capped at 8192. Source files are never overwritten.

    Examples:
      ParityPainter before.png after.png
      ParityPainter before.jpg after.jpg --slack 8 --mode trace -o edit.png
      ParityPainter --sample --mode xor -o sample-xor.png
    """

    private static func wantsCLI(_ args: [String]) -> Bool {
        if args.contains("--sample") { return true }
        let flags: Set<String> = [
            "--mode", "--channel", "--align", "--slack", "--plane",
            "--dx", "--dy", "--lift", "--invert", "--jpeg", "-o", "--out",
        ]
        if args.contains(where: { flags.contains($0) }) { return true }
        return args.dropFirst().contains { !$0.hasPrefix("-") }
    }

    private static func runCLI(_ args: [String]) {
        let invocation: PaintInvocation
        switch PaintInvocation.parse(args) {
        case .failure(let message):
            fputs("error: \(message)\n", stderr)
            exit(1)
        case .success(let parsed):
            invocation = parsed
        }

        let first: PixelBuffer
        let second: PixelBuffer
        let sources: [URL]
        let output: URL

        if invocation.sample {
            let pair = SampleScene.pair()
            first = pair.0
            second = pair.1
            sources = []
            output = outputURL(invocation, a: nil, b: nil)
        } else {
            let aURL = URL(fileURLWithPath: invocation.inputs[0])
            let bURL = URL(fileURLWithPath: invocation.inputs[1])
            let decodedA: DecodedImage
            let decodedB: DecodedImage
            do {
                decodedA = try ImageCodec.load(url: aURL)
                decodedB = try ImageCodec.load(url: bURL)
            } catch {
                fputs("error: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
            if decodedA.capped || decodedB.capped {
                fputs("note: long edge capped at \(ImageCodec.maxSide)\n", stderr)
            }
            first = decodedA.buffer
            second = decodedB.buffer
            sources = [aURL, bURL]
            output = outputURL(invocation, a: aURL, b: bURL)
        }

        if OutputGuard.collides(output, sources: sources) {
            fputs("error: refusing to overwrite a source image\n", stderr)
            exit(1)
        }

        let result = Painter.compare(first, second, options: invocation.options)
        let jpeg = wantsJPEG(output, invocation: invocation)
        do {
            try ImageCodec.write(result.image, to: output, jpeg: jpeg)
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
        let line = DecimalText.summary(
            differed: result.differed,
            pixels: result.image.pixelCount,
            width: result.image.width,
            height: result.image.height
        )
        print("\(invocation.options.mode.title) · \(line) → \(output.path)")
    }

    private static func outputURL(_ invocation: PaintInvocation, a: URL?, b: URL?) -> URL {
        if let path = invocation.output {
            return URL(fileURLWithPath: path)
        }
        let name = PaintInvocation.fileName(
            mode: invocation.options.mode,
            plane: invocation.options.plane,
            stamp: PaintInvocation.stamp(),
            jpeg: invocation.jpeg
        )
        let folder: URL
        if let a, !invocation.sample {
            folder = a.deletingLastPathComponent()
        } else {
            folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        }
        return folder.appendingPathComponent(name)
    }

    private static func wantsJPEG(_ output: URL, invocation: PaintInvocation) -> Bool {
        let ext = output.pathExtension.lowercased()
        if ext == "jpg" || ext == "jpeg" { return true }
        if ext == "png" { return false }
        return invocation.jpeg
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private let model = AppModel()
    private var pendingURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()

        let hosting = NSHostingView(rootView: ContentView(model: model))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = AppInfo.name
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.windowNS
        window.contentView = hosting
        window.minSize = NSSize(width: 980, height: 640)
        window.center()
        window.setFrameAutosaveName("ParityPainterMainWindow")
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window

        if !pendingURLs.isEmpty {
            model.load(urls: pendingURLs)
            pendingURLs = []
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func application(_ sender: NSApplication, open urls: [URL]) {
        if window == nil {
            pendingURLs = urls
        } else {
            model.load(urls: urls)
        }
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        if window == nil {
            pendingURLs = [url]
        } else {
            model.load(urls: [url])
        }
        return true
    }

    @objc private func openPair(_ sender: Any?) { model.openPairPanel() }
    @objc private func openA(_ sender: Any?) { model.openPanel(into: .a) }
    @objc private func openB(_ sender: Any?) { model.openPanel(into: .b) }
    @objc private func saveImage(_ sender: Any?) { model.savePanel() }
    @objc private func copyImage(_ sender: Any?) { model.copyImage() }
    @objc private func pasteImage(_ sender: Any?) { model.paste(into: nil) }
    @objc private func pasteA(_ sender: Any?) { model.paste(into: .a) }
    @objc private func clearAll(_ sender: Any?) { model.clearAll() }
    @objc private func loadSample(_ sender: Any?) { model.loadSample() }
    @objc private func swapImages(_ sender: Any?) { model.swap() }
    @objc private func zeroNudge(_ sender: Any?) { model.zeroNudge() }
    @objc private func invert(_ sender: Any?) { model.update { $0.invert.toggle() } }

    @objc private func setMask(_ sender: Any?) { model.update { $0.mode = .mask } }
    @objc private func setXOR(_ sender: Any?) { model.update { $0.mode = .xor } }
    @objc private func setPlane(_ sender: Any?) { model.update { $0.mode = .plane } }
    @objc private func setTrace(_ sender: Any?) { model.update { $0.mode = .trace } }

    @objc private func showAbout(_ sender: Any?) {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: AppInfo.name,
            .version: AppInfo.version,
            .applicationVersion: "Version \(AppInfo.version) (\(AppInfo.build))",
            .credits: NSAttributedString(
                string: """
                Load two pictures. Parity Painter XORs their \
                bit-planes and paints the difference: black where \
                a pixel matches, white where it does not.

                Mask is the comparison. XOR is the color of those \
                bits. Plane isolates one bit. Trace draws the \
                differences back onto the first picture.

                Slack treats small channel gaps as a match, which \
                quiets JPEG noise. The source files are never \
                overwritten.
                """,
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            ),
        ]
        if let icon = NSApp.applicationIconImage {
            options[.applicationIcon] = icon
        }
        NSApp.orderFrontStandardAboutPanel(options: options)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        let about = appMenu.addItem(withTitle: "About Parity Painter", action: #selector(showAbout(_:)), keyEquivalent: "")
        about.target = self
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Hide Parity Painter", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(
            withTitle: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit Parity Painter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu
        add(fileMenu, "Open Two Images…", #selector(openPair(_:)), "o")
        add(fileMenu, "Open Image A…", #selector(openA(_:)), "")
        add(fileMenu, "Open Image B…", #selector(openB(_:)), "o", [.command, .shift])
        fileMenu.addItem(NSMenuItem.separator())
        add(fileMenu, "Save Difference…", #selector(saveImage(_:)), "s")
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        add(editMenu, "Paste Image", #selector(pasteImage(_:)), "v")
        add(editMenu, "Paste into A", #selector(pasteA(_:)), "v", [.command, .shift])
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(NSMenuItem.separator())
        add(editMenu, "Copy Difference", #selector(copyImage(_:)), "c", [.command, .shift])
        add(editMenu, "Clear", #selector(clearAll(_:)), "k")

        let paintMenuItem = NSMenuItem()
        mainMenu.addItem(paintMenuItem)
        let paintMenu = NSMenu(title: "Paint")
        paintMenuItem.submenu = paintMenu
        add(paintMenu, "Load Sample Pair", #selector(loadSample(_:)), "l")
        add(paintMenu, "Swap Images", #selector(swapImages(_:)), "s", [.command, .option])
        add(paintMenu, "Zero Nudge", #selector(zeroNudge(_:)), "")
        paintMenu.addItem(NSMenuItem.separator())
        add(paintMenu, "Mask", #selector(setMask(_:)), "1")
        add(paintMenu, "XOR", #selector(setXOR(_:)), "2")
        add(paintMenu, "Plane", #selector(setPlane(_:)), "3")
        add(paintMenu, "Trace", #selector(setTrace(_:)), "4")
        paintMenu.addItem(NSMenuItem.separator())
        add(paintMenu, "Invert", #selector(invert(_:)), "i")

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(
            withTitle: "Bring All to Front",
            action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: ""
        )
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = mainMenu
    }

    private func add(
        _ menu: NSMenu,
        _ title: String,
        _ action: Selector,
        _ key: String,
        _ modifiers: NSEvent.ModifierFlags = .command
    ) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        if !key.isEmpty {
            item.keyEquivalentModifierMask = modifiers
        }
        item.target = self
    }
}

// Suite bridge: the original delegate retains the model and native menus.
@MainActor
public final class LabWorkspace {
    private let delegate = AppDelegate()
    private var menu: NSMenu?
    public init() {}
    public func show() -> (NSWindow, NSMenu) {
        if let window = delegate.labWindow, let menu {
            window.makeKeyAndOrderFront(nil)
            return (window, menu)
        }
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let window = delegate.labWindow!
        let menu = NSApp.mainMenu!
        self.menu = menu
        return (window, menu)
    }
    public func open(_ urls: [URL]) { delegate.application(NSApp, open: urls) }
    public static func cli(_ args: [String]) { MainEntry.main(args) }
}

extension AppDelegate { fileprivate var labWindow: NSWindow? { window } }
