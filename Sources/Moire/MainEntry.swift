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
            print("XOR, placement, orientation, sound, and a movie round-trip.")
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
    \(AppInfo.name) \(AppInfo.version) — XOR two videos

    Where a color byte agrees, it becomes 0. A matching pixel goes black.

    Usage:
      Moire                              Launch the app
      Moire --self-test                  Engine checks
      Moire A.mov B.mov [options]
      Moire --sample [options]

    Options:
      --place fit|fill|stretch|lock      How B sits on A's frame. Default fit.
      --turn none|90|180                 Turn B clockwise. Default none.
      --flip-h                           Mirror B left to right.
      --flip-v                           Mirror B top to bottom.
      --scale FACTOR                     Scale the placed copy. 0.25...2. Default 1.
      --offset-x FRACTION                Slide B sideways. -0.5...0.5. Right is positive.
      --offset-y FRACTION                Slide B down. -0.5...0.5. Down is positive.
      --delay SECONDS                    XOR with an earlier frame of B. 0...30.
      --match-lengths                    End at the shorter video. Default is A's length.
      --audio                            Write A's sound into the movie.
      --xor-audio                        XOR the two soundtracks into the movie.
      --long-edge N                      Cap the long edge. Default \(MoireLimits.saveLongEdge).
      -o, --out PATH                     Default: moire-yyyymmdd-hhmmss.mov

    The movie follows A: its frame, its rate, and its length. B is sampled
    at those times, then turned, flipped, scaled, and offset. --delay uses
    an earlier frame of B; before that, the picture stays A. After B ends,
    the tail is A. --match-lengths stops at the shorter video instead, and
    the sound stops there too. Sound is not delayed. Missing samples are
    silence. WebM and MKV are converted with ffmpeg on the way in. Source
    files are never overwritten.

    Examples:
      Moire a.mov b.mov -o xor.mov
      Moire a.mov b.mov --place fill --turn 90 --audio -o xor.mov
      Moire a.mov b.mov --scale 0.5 --offset-x 0.1 --delay 0.4 -o xor.mov
      Moire a.mov b.mov --match-lengths -o xor.mov
      Moire a.mov b.mov --xor-audio -o xor.mov
      Moire --sample -o sample-xor.mov
    """

    private static func wantsCLI(_ args: [String]) -> Bool {
        if args.contains("--sample") { return true }
        let flags: Set<String> = [
            "--place", "--turn", "--flip-h", "--flip-v", "--scale",
            "--offset-x", "--offset-y", "--delay", "--match-lengths",
            "--audio", "--xor-audio", "--long-edge", "-o", "--out",
        ]
        if args.contains(where: { flags.contains($0) }) { return true }
        return args.dropFirst().contains { !$0.hasPrefix("-") }
    }

    private static func runCLI(_ args: [String]) {
        let invocation: Invocation
        do {
            invocation = try Invocation.parse(args)
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }

        let clipA: URL
        let clipB: URL
        if invocation.sample {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("MoireSampleCLI", isDirectory: true)
            do {
                let pair: (URL, URL)
                do {
                    pair = try SampleScene.writePair(to: directory, codec: .proRes4444)
                } catch {
                    pair = try SampleScene.writePair(to: directory, codec: .h264)
                }
                clipA = pair.0
                clipB = pair.1
            } catch {
                fputs("error: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        } else {
            clipA = URL(fileURLWithPath: invocation.inputs[0])
            clipB = URL(fileURLWithPath: invocation.inputs[1])
        }

        let output = outputURL(invocation, clipA: clipA)
        if OutputGuard.collides(output, sources: [clipA, clipB]) {
            fputs("error: refusing to overwrite a source video\n", stderr)
            exit(1)
        }

        var lastMark = -1
        let result: ExportResult
        do {
            result = try MovieExport.run(
                ExportRequest(
                    clipA: clipA,
                    clipB: clipB,
                    output: output,
                    mode: invocation.mode,
                    mix: invocation.mix,
                    matchLengths: invocation.matchLengths,
                    longEdge: invocation.longEdge,
                    audio: invocation.audio
                ),
                progress: { value in
                    let mark = Int((value * 10).rounded(.down))
                    if mark != lastMark {
                        lastMark = mark
                        fputs("\r\(mark * 10)%", stderr)
                    }
                },
                cancelled: { false }
            )
        } catch {
            fputs("\nerror: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
        fputs("\n", stderr)
        let sound: String
        switch invocation.audio {
        case .xor where result.audio: sound = " · with XORed sound"
        case .fromA where result.audio: sound = " · with A's sound"
        default: sound = ""
        }
        let shape = invocation.mix.reshapes || invocation.mix.delay > 0.02 ? " · \(invocation.mix.summary)" : ""
        let matched = invocation.matchLengths ? " · matched" : ""
        print("XOR · \(result.width)×\(result.height) · \(result.frames) frames · \(invocation.mode.title)\(shape)\(matched)\(sound) → \(output.path)")
    }

    private static func outputURL(_ invocation: Invocation, clipA: URL) -> URL {
        if let path = invocation.output {
            return URL(fileURLWithPath: path)
        }
        let folder = invocation.sample
            ? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            : clipA.deletingLastPathComponent()
        return folder.appendingPathComponent(MovieNames.suggested())
    }
}

private struct Invocation {
    var inputs: [String] = []
    var output: String?
    var mode: PlaceMode = .fit
    var mix: PictureMix = .identity
    var matchLengths = false
    var audio: SoundMode = .off
    var longEdge = MoireLimits.saveLongEdge
    var sample = false

    static func parse(_ args: [String]) throws -> Invocation {
        var invocation = Invocation()
        var index = 1
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--sample":
                invocation.sample = true
            case "--audio":
                if invocation.audio == .xor { throw CLIError("choose either --audio or --xor-audio") }
                invocation.audio = .fromA
            case "--xor-audio":
                if invocation.audio == .fromA { throw CLIError("choose either --audio or --xor-audio") }
                invocation.audio = .xor
            case "--place":
                index += 1
                guard index < args.count, let mode = PlaceMode(rawValue: args[index]) else {
                    throw CLIError("--place expects fit, fill, stretch, or lock")
                }
                invocation.mode = mode
            case "--turn":
                index += 1
                guard index < args.count, let turn = QuarterTurn(rawValue: turnToken(args[index])) else {
                    throw CLIError("--turn expects none, 90, or 180")
                }
                invocation.mix.turn = turn
            case "--flip-h":
                invocation.mix.flipHorizontal = true
            case "--flip-v":
                invocation.mix.flipVertical = true
            case "--scale":
                index += 1
                guard index < args.count, let value = Double(args[index]) else {
                    throw CLIError("--scale expects a factor from 0.25 to 2")
                }
                invocation.mix.scale = PictureMix.clampedScale(value)
            case "--offset-x":
                index += 1
                guard index < args.count, let value = Double(args[index]) else {
                    throw CLIError("--offset-x expects a fraction from -0.5 to 0.5")
                }
                invocation.mix.offsetX = PictureMix.clampedOffset(value)
            case "--offset-y":
                index += 1
                guard index < args.count, let value = Double(args[index]) else {
                    throw CLIError("--offset-y expects a fraction from -0.5 to 0.5")
                }
                invocation.mix.offsetY = PictureMix.clampedOffset(value)
            case "--delay":
                index += 1
                guard index < args.count, let value = Double(args[index]) else {
                    throw CLIError("--delay expects seconds from 0 to 30")
                }
                invocation.mix.delay = PictureMix.clampedDelay(value)
            case "--match-lengths":
                invocation.matchLengths = true
            case "--long-edge":
                index += 1
                guard index < args.count, let edge = Int(args[index]), edge >= 2 else {
                    throw CLIError("--long-edge expects a number of pixels")
                }
                invocation.longEdge = edge
            case "-o", "--out":
                index += 1
                guard index < args.count else { throw CLIError("-o expects a path") }
                invocation.output = args[index]
            default:
                if arg.hasPrefix("-") { throw CLIError("unknown option \(arg)") }
                invocation.inputs.append(arg)
            }
            index += 1
        }
        if invocation.sample && !invocation.inputs.isEmpty {
            throw CLIError("--sample does not take input files")
        }
        if !invocation.sample && invocation.inputs.count != 2 {
            throw CLIError("expected two videos, or --sample")
        }
        return invocation
    }

    private static func turnToken(_ text: String) -> String {
        switch text.lowercased() {
        case "90", "clockwise": return QuarterTurn.clockwise.rawValue
        case "180", "half": return QuarterTurn.half.rawValue
        case "0", "none": return QuarterTurn.none.rawValue
        default: return text
        }
    }
}

private struct CLIError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private let model = AppModel()
    private var pendingURLs: [URL] = []
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        installKeys()

        let hosting = NSHostingView(rootView: ContentView(model: model))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = AppInfo.name
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.windowNS
        window.contentView = hosting
        window.minSize = NSSize(width: 860, height: 640)
        window.center()
        window.setFrameAutosaveName("MoireMainWindow")
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

    private func installKeys() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if NSApp.modalWindow != nil || self.window !== NSApp.keyWindow || NSApp.keyWindow?.firstResponder is NSTextView { return event }
            let bare = event.modifierFlags.intersection([.command, .control, .option]).isEmpty
            if bare && event.keyCode == 49 {
                self.model.togglePlay()
                return nil
            }
            return event
        }
    }

    @objc private func openPair(_ sender: Any?) { model.openPanel(into: nil) }
    @objc private func openA(_ sender: Any?) { model.openPanel(into: .a) }
    @objc private func openB(_ sender: Any?) { model.openPanel(into: .b) }
    @objc private func saveMovie(_ sender: Any?) { model.savePanel() }
    @objc private func clearAll(_ sender: Any?) { model.clearAll() }
    @objc private func loadSample(_ sender: Any?) { model.loadSample() }
    @objc private func swapClips(_ sender: Any?) { model.swapClips() }
    @objc private func togglePlay(_ sender: Any?) { model.togglePlay() }
    @objc private func setFit(_ sender: Any?) { model.setMode(.fit) }
    @objc private func setFill(_ sender: Any?) { model.setMode(.fill) }
    @objc private func setStretch(_ sender: Any?) { model.setMode(.stretch) }
    @objc private func setLock(_ sender: Any?) { model.setMode(.lock) }
    @objc private func setTurnNone(_ sender: Any?) { model.setTurn(.none) }
    @objc private func setTurn90(_ sender: Any?) { model.setTurn(.clockwise) }
    @objc private func setTurn180(_ sender: Any?) { model.setTurn(.half) }
    @objc private func toggleFlipH(_ sender: Any?) { model.setFlipHorizontal(!model.mix.flipHorizontal) }
    @objc private func toggleFlipV(_ sender: Any?) { model.setFlipVertical(!model.mix.flipVertical) }
    @objc private func resetOffset(_ sender: Any?) { model.resetOffset() }
    @objc private func toggleMatchLengths(_ sender: Any?) { model.setMatchLengths(!model.matchLengths) }
    @objc private func soundOff(_ sender: Any?) { model.setSoundMode(.off) }
    @objc private func soundFromA(_ sender: Any?) { model.setSoundMode(.fromA) }
    @objc private func soundXOR(_ sender: Any?) { model.setSoundMode(.xor) }

    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(setTurnNone(_:)):
            menuItem.state = model.mix.turn == .none ? .on : .off
        case #selector(setTurn90(_:)):
            menuItem.state = model.mix.turn == .clockwise ? .on : .off
        case #selector(setTurn180(_:)):
            menuItem.state = model.mix.turn == .half ? .on : .off
        case #selector(toggleFlipH(_:)):
            menuItem.state = model.mix.flipHorizontal ? .on : .off
        case #selector(toggleFlipV(_:)):
            menuItem.state = model.mix.flipVertical ? .on : .off
        case #selector(resetOffset(_:)):
            return !model.busy && !model.mix.offsetIsCentered
        case #selector(toggleMatchLengths(_:)):
            menuItem.state = model.matchLengths ? .on : .off
            return !model.busy
        case #selector(soundOff(_:)):
            menuItem.state = model.soundMode == .off ? .on : .off
        case #selector(soundFromA(_:)):
            menuItem.state = model.soundMode == .fromA ? .on : .off
        case #selector(soundXOR(_:)):
            menuItem.state = model.soundMode == .xor ? .on : .off
        default:
            break
        }
        return true
    }

    @objc private func showAbout(_ sender: Any?) {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: AppInfo.name,
            .version: AppInfo.version,
            .applicationVersion: "Version \(AppInfo.version) (\(AppInfo.build))",
            .credits: NSAttributedString(
                string: """
                Load two videos. Moire XORs their color bytes, \
                frame by frame. Where a pixel agrees, it goes black. \
                Where it differs, the color is the bits that disagree.

                The second video can be turned, flipped, scaled, \
                offset, or delayed before the XOR. Match Length ends the \
                movie at the shorter clip. Sound can follow the first \
                video, or the two soundtracks can be XORed the same way. \
                WebM and MKV are converted on open. \
                Source files are never overwritten.
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
        let about = appMenu.addItem(withTitle: "About Moire", action: #selector(showAbout(_:)), keyEquivalent: "")
        about.target = self
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Hide Moire", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(
            withTitle: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit Moire", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu
        add(fileMenu, "Open Two Videos…", #selector(openPair(_:)), "o")
        add(fileMenu, "Open Video A…", #selector(openA(_:)), "")
        add(fileMenu, "Open Video B…", #selector(openB(_:)), "o", [.command, .shift])
        fileMenu.addItem(NSMenuItem.separator())
        add(fileMenu, "Save Movie…", #selector(saveMovie(_:)), "s")
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
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(NSMenuItem.separator())
        add(editMenu, "Clear Selections", #selector(clearAll(_:)), "k")

        let movieMenuItem = NSMenuItem()
        mainMenu.addItem(movieMenuItem)
        let movieMenu = NSMenu(title: "Movie")
        movieMenuItem.submenu = movieMenu
        add(movieMenu, "Play / Pause", #selector(togglePlay(_:)), " ")
        movieMenu.addItem(NSMenuItem.separator())
        add(movieMenu, "Load Sample Pair", #selector(loadSample(_:)), "l")
        add(movieMenu, "Swap Videos", #selector(swapClips(_:)), "s", [.command, .option])
        movieMenu.addItem(NSMenuItem.separator())
        add(movieMenu, "Fit", #selector(setFit(_:)), "1")
        add(movieMenu, "Fill", #selector(setFill(_:)), "2")
        add(movieMenu, "Stretch", #selector(setStretch(_:)), "3")
        add(movieMenu, "Lock", #selector(setLock(_:)), "4")
        movieMenu.addItem(NSMenuItem.separator())
        add(movieMenu, "No Turn", #selector(setTurnNone(_:)), "")
        add(movieMenu, "Turn 90° Clockwise", #selector(setTurn90(_:)), "5")
        add(movieMenu, "Turn 180°", #selector(setTurn180(_:)), "6")
        add(movieMenu, "Flip Horizontal", #selector(toggleFlipH(_:)), "")
        add(movieMenu, "Flip Vertical", #selector(toggleFlipV(_:)), "")
        add(movieMenu, "Reset Offset", #selector(resetOffset(_:)), "0")
        add(movieMenu, "Match Lengths", #selector(toggleMatchLengths(_:)), "7")
        movieMenu.addItem(NSMenuItem.separator())
        add(movieMenu, "Sound Off", #selector(soundOff(_:)), "")
        add(movieMenu, "Sound from A", #selector(soundFromA(_:)), "")
        add(movieMenu, "XOR Sound", #selector(soundXOR(_:)), "")

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
            item.keyEquivalentModifierMask = key == " " ? [] : modifiers
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
    public func stop() { delegate.labStop() }
}

extension AppDelegate {
    fileprivate var labWindow: NSWindow? { window }
    fileprivate func labStop() { if model.playing { model.togglePlay() } }
}
