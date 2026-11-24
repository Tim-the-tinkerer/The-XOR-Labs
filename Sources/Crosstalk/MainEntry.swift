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
            renderCLI(args)
        }

        let app = NSApplication.shared
        app.appearance = NSAppearance(named: .darkAqua)
        let delegate = AppDelegate.shared
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    private static func wantsCLI(_ args: [String]) -> Bool {
        let flags: Set<String> = [
            "--out", "--channels", "--waveform", "--files", "--delay", "--fold", "--length",
            "--slip", "--bits", "--repeat", "--delay-ms", "--stack", "--blend", "--mix",
            "--left-only", "--sweep-hz", "--sweep-ms", "--hz", "--seconds",
            "--with", "--pick",
        ]
        return args.dropFirst().contains { flags.contains($0) || !$0.hasPrefix("-") }
    }

    private static let helpText = """
    Crosstalk — XOR channels, a waveform, two files, or a delayed copy

    Usage:
      Crosstalk                         Launch the app
      Crosstalk --self-test             XOR math, folds, delay, WAV round trip
      Crosstalk --version
      Crosstalk --channels song.wav --out song-channels.wav
      Crosstalk --waveform song.wav --fold reverse --out song-reverse.wav
      Crosstalk --waveform song.wav --fold halves --out song-halves.wav
      Crosstalk a.wav b.wav --out a-xor-b.wav
      Crosstalk a.wav b.wav --length longer --slip 12 --bits 16 --out out.wav
      Crosstalk --channels song.wav --repeat 30 --out song-channels-loop.wav
      Crosstalk --delay song.wav --delay-ms 20 --out song-delay.wav
      Crosstalk --delay song.wav --stack --out song-stack.wav
      Crosstalk --delay song.wav --blend --mix 0.5 --out song-blend.wav
      Crosstalk --delay --hz 220 --delay-ms 50 --seconds 8 --out tone.wav
      Crosstalk --channels a.wav --with b.wav --pick both --out a-and-b-channels.wav

    Channels XORs left with right. Both ears hear that. A mono file
    agrees with itself, so the result is silence.

    Waveform folds each channel with itself.
      --fold reverse   Each sample XOR the one across from it.
                       Doing this again is silence.
      --fold halves    The first half XOR the second half.

    Files XORs two recordings, sample by sample. The first file sets
    the sample rate. A different rate is resampled linearly.
      --length shorter   The overlap only. This is the default.
      --length longer    Past the shorter file, the missing side is
                         zero, and XOR with zero leaves those samples.
      --length loop      The shorter file repeats.
      --slip MS          Slide the second file. Positive starts it later.
                         Limited to ±2000 ms, then rounded to samples.

    Delay XORs each channel with a delayed copy of itself.
      --delay-ms MS    How far back, from 0 to 100. The default is 10.
                       0 XORs each sample with itself and is silence.
      --stack          10 ms, then 20 ms, then 50 ms.
      --sweep-hz N     How fast the delay moves, from 0 to 4.
      --sweep-ms MS    How far it moves, from 0 to 20. Ignored with --stack.
                       The delay jumps by whole samples.
      --blend          Mix the file's left and right before the XOR.
      --mix 0.5        0 is the left channel, 1 is the right. Needs --blend.
      --left-only      The right channel stays as it was.
      --hz N           Pitch of the tone, when no file is given.
      --seconds N      Length of that tone, up to 600. The default is 8.

    220 Hz at 50 ms is 11 cycles, so that tone is erased.
    The first samples, before the delay has filled, pass through.

    Two files can stay loaded in Channels, Waveform, and Delay.
      --with FILE      The second file. It does not switch the mode.
      --pick first     Hear the first file. This is the default.
      --pick second    Hear the second file. Needs --with.
      --pick both      Run the mode on each file, then XOR those results.
                       The shorter one sets the length.
    Files already takes two files, so --with and --pick are not for it.
    One loaded file is not XORed with a built-in tone.

    --bits 8 or 16. The default is 16. 1000 XOR 2000 is 1080.
    At 16-bit, with matching rates, XOR the result with the second
    file and the first one comes back. 8-bit is a coarser integer,
    written up to 16-bit so a player can open it.

    --repeat SECONDS   Write the XOR again until this time.
                       From just over 0 to 600 seconds. The last
                       pass is cut at that time. Without it, the
                       file is one pass, which is the one you can
                       XOR back at 16-bit.

    Volume is playback only. Export writes the XOR at full scale.
    A sweep is part of that XOR. A loop repeats the pass, so the
    sweep starts again.
    Export does not replace the file you opened.
    Playback follows the output device. The file stays at its own rate.
    The first 10 minutes are loaded.

    Keys:
      Space            Play / Stop
      1  2  3  4       Channels, Waveform, Files, Delay
      R  H             Reverse, Halves
      S  L  P          Shorter, Longer, Loop
      T                Stack 10, then 20, then 50
      B                Blend the file's left and right
      ⌘O               Open audio
      ⌘⇧O              Open the second file
      ⌘E               Export one pass
      ⌘⇧E              Export a repeating loop
      ⌘K               Back to the built-in tones
    """

    private static func renderCLI(_ args: [String]) -> Never {
        var outPath: String?
        var positionals: [String] = []
        var mode: ListenMode?
        var fold = WaveFold.reverse
        var span = Span.shorter
        var bits = 16
        var slip = 0.0
        var sawSlip = false
        var sawFold = false
        var sawLength = false
        var repeatSeconds: Double?
        var sawRepeat = false
        var delayMs = 10.0
        var sawDelayMs = false
        var stacked = false
        var blendOn = false
        var mix: Float = 0.5
        var sawMix = false
        var leftOnly = false
        var sweepHz = 0.0
        var sawSweepHz = false
        var sweepDepth = 0.0
        var sawSweepDepth = false
        var toneHz: Double?
        var sawHz = false
        var sineSeconds = AppInfo.delayDemoSeconds
        var sawSeconds = false
        var withPath: String?
        var sawWith = false
        var pick = SourcePick.first
        var sawPick = false

        var index = 1
        while index < args.count {
            let arg = args[index]
            func value(_ name: String) -> String {
                guard index + 1 < args.count else {
                    fputs("error: \(name) needs a value\n", stderr)
                    exit(1)
                }
                index += 1
                return args[index]
            }
            switch arg {
            case "--out":
                outPath = value(arg)
            case "--channels":
                mode = .channels
            case "--waveform":
                mode = .waveform
            case "--files":
                mode = .files
            case "--delay":
                mode = .delay
            case "--fold":
                sawFold = true
                switch value(arg) {
                case "reverse": fold = .reverse
                case "halves": fold = .halves
                default:
                    fputs("error: --fold is reverse or halves\n", stderr)
                    exit(1)
                }
            case "--length":
                sawLength = true
                switch value(arg) {
                case "shorter": span = .shorter
                case "longer": span = .longer
                case "loop": span = .loop
                default:
                    fputs("error: --length is shorter, longer, or loop\n", stderr)
                    exit(1)
                }
            case "--bits":
                bits = Int(value(arg)) ?? 0
            case "--slip":
                sawSlip = true
                slip = Double(value(arg)) ?? .nan
            case "--repeat":
                sawRepeat = true
                repeatSeconds = Double(value(arg)) ?? .nan
            case "--delay-ms":
                sawDelayMs = true
                delayMs = Double(value(arg)) ?? .nan
            case "--stack":
                stacked = true
            case "--blend":
                blendOn = true
            case "--mix":
                sawMix = true
                mix = Float(value(arg)) ?? .nan
            case "--left-only":
                leftOnly = true
            case "--sweep-hz":
                sawSweepHz = true
                sweepHz = Double(value(arg)) ?? .nan
            case "--sweep-ms":
                sawSweepDepth = true
                sweepDepth = Double(value(arg)) ?? .nan
            case "--hz":
                sawHz = true
                toneHz = Double(value(arg))
            case "--seconds":
                sawSeconds = true
                sineSeconds = Double(value(arg)) ?? .nan
            case "--with":
                sawWith = true
                withPath = value(arg)
            case "--pick":
                sawPick = true
                switch value(arg) {
                case "first": pick = .first
                case "second": pick = .second
                case "both": pick = .both
                default:
                    fputs("error: --pick is first, second, or both\n", stderr)
                    exit(1)
                }
            case "--self-test", "--help", "-h", "--version":
                break
            default:
                if arg.hasPrefix("-") {
                    fputs("error: unknown argument \(arg)\n", stderr)
                    exit(1)
                }
                positionals.append(arg)
            }
            index += 1
        }

        guard let outPath else {
            fputs("error: --out needs a file path\n", stderr)
            exit(1)
        }
        if bits != 8 && bits != 16 {
            fputs("error: --bits must be 8 or 16\n", stderr)
            exit(1)
        }
        if sawSlip && (!slip.isFinite || abs(slip) > AppInfo.maxSlipMilliseconds) {
            fputs("error: --slip must be from -2000 to 2000 milliseconds\n", stderr)
            exit(1)
        }
        if sawRepeat {
            let seconds = repeatSeconds ?? .nan
            if !seconds.isFinite || seconds <= 0 || seconds > AppInfo.maxSongSeconds {
                fputs("error: --repeat must be from just over 0 to 600 seconds\n", stderr)
                exit(1)
            }
        }
        let delayOnly = sawDelayMs || stacked || blendOn || sawMix || leftOnly || sawSweepHz || sawSweepDepth || sawHz || sawSeconds
        if delayOnly && mode != .delay {
            fputs("error: those options are for --delay\n", stderr)
            exit(1)
        }
        if sawDelayMs && (!delayMs.isFinite || delayMs < 0 || delayMs > AppInfo.maxDelayMilliseconds) {
            fputs("error: --delay-ms must be from 0 to 100 milliseconds\n", stderr)
            exit(1)
        }
        if sawSweepHz && (!sweepHz.isFinite || sweepHz < 0 || sweepHz > AppInfo.maxSweepHz) {
            fputs("error: --sweep-hz must be from 0 to 4\n", stderr)
            exit(1)
        }
        if sawSweepDepth && (!sweepDepth.isFinite || sweepDepth < 0 || sweepDepth > AppInfo.maxSweepDepthMilliseconds) {
            fputs("error: --sweep-ms must be from 0 to 20 milliseconds\n", stderr)
            exit(1)
        }
        if sawMix && !blendOn {
            fputs("error: --mix needs --blend\n", stderr)
            exit(1)
        }
        if blendOn && (!mix.isFinite || mix < 0 || mix > 1) {
            fputs("error: --mix must be from 0 to 1\n", stderr)
            exit(1)
        }
        if sawHz, toneHz == nil || toneHz?.isFinite != true || (toneHz ?? 0) <= 0 {
            fputs("error: --hz needs a frequency in Hz\n", stderr)
            exit(1)
        }
        if sawSeconds && (!sineSeconds.isFinite || sineSeconds <= 0 || sineSeconds > AppInfo.maxSongSeconds) {
            fputs("error: --seconds must be from just over 0 to 600\n", stderr)
            exit(1)
        }
        if sawWith && (withPath ?? "").isEmpty {
            fputs("error: --with needs a file path\n", stderr)
            exit(1)
        }
        if sawWith && pick == .first {
            fputs("error: --with needs --pick second or --pick both\n", stderr)
            exit(1)
        }

        let resolved: ListenMode
        if let mode {
            resolved = mode
        } else if positionals.count == 2 {
            if sawWith || sawPick {
                fputs("error: files mode already takes two files\n", stderr)
                exit(1)
            }
            resolved = .files
        } else {
            fputs("error: use --channels, --waveform, --delay, or pass two files\n", stderr)
            exit(1)
        }
        if resolved == .files {
            if sawWith || sawPick {
                fputs("error: files mode already takes two files\n", stderr)
                exit(1)
            }
            guard positionals.count == 2 else {
                fputs("error: files mode needs two audio files\n", stderr)
                exit(1)
            }
        } else if resolved == .delay {
            guard positionals.count <= 1 else {
                fputs("error: delay mode takes one audio file, or none for the tone\n", stderr)
                exit(1)
            }
            if sawSlip || sawLength || sawFold {
                fputs("error: --slip, --length, and --fold are not for delay\n", stderr)
                exit(1)
            }
            if pick == .second && withPath == nil && !positionals.isEmpty {
                fputs("error: second needs --with\n", stderr)
                exit(1)
            }
            if pick == .both {
                let twoFiles = positionals.count == 1 && withPath != nil
                let twoTones = positionals.isEmpty && withPath == nil
                if !twoFiles && !twoTones {
                    fputs("error: both needs two audio files\n", stderr)
                    exit(1)
                }
            }
            let heardIsFile: Bool
            switch pick {
            case .first: heardIsFile = !positionals.isEmpty
            case .second: heardIsFile = withPath != nil
            case .both: heardIsFile = !positionals.isEmpty && withPath != nil
            }
            if blendOn && !heardIsFile {
                fputs("error: --blend mixes the left and right of a file\n", stderr)
                exit(1)
            }
            if (!positionals.isEmpty || withPath != nil) && (sawHz || sawSeconds) {
                fputs("error: --hz and --seconds are for the tone, not a file\n", stderr)
                exit(1)
            }
        } else {
            guard positionals.count == 1 else {
                fputs("error: \(resolved.label.lowercased()) mode needs one audio file\n", stderr)
                exit(1)
            }
            if pick == .second && withPath == nil {
                fputs("error: second needs --with\n", stderr)
                exit(1)
            }
            if pick == .both && withPath == nil {
                fputs("error: both needs two audio files\n", stderr)
                exit(1)
            }
            if sawSlip || span != .shorter {
                fputs("error: --slip and --length are for two files\n", stderr)
                exit(1)
            }
        }

        let outURL = URL(fileURLWithPath: outPath)
        let inputs = positionals.map { URL(fileURLWithPath: $0) }
        let withURL = withPath.map { URL(fileURLWithPath: $0) }
        if (inputs + [withURL].compactMap { $0 }).contains(where: { Names.isSameFile($0, outURL) }) {
            fputs("error: --out is one of the files being XORed. Pick a new name.\n", stderr)
            exit(1)
        }

        do {
            let hz = toneHz ?? 220
            func clipJob(_ clip: Clip, demo: Bool, tone: Double) -> Job {
                Job(
                    mode: resolved,
                    fold: fold,
                    span: span,
                    bits: bits,
                    slipMs: resolved == .files ? slip : 0,
                    delayMs: delayMs,
                    stacked: stacked,
                    ears: leftOnly ? .leftOnly : .both,
                    sweepHz: sweepHz,
                    sweepDepth: sweepDepth,
                    blendEnabled: blendOn && !demo,
                    blend: mix,
                    toneHz: tone,
                    a: clip,
                    b: nil,
                    demo: demo
                )
            }
            let take: Take
            let demo: Bool
            let truncated: Bool
            if resolved == .files {
                let first = try ClipLoader.load(url: inputs[0])
                let second = try ClipLoader.load(url: inputs[1])
                demo = false
                truncated = first.truncated || second.truncated
                take = XORMath.render(Job(
                    mode: .files,
                    fold: fold,
                    span: span,
                    bits: bits,
                    slipMs: slip,
                    delayMs: delayMs,
                    stacked: stacked,
                    ears: leftOnly ? .leftOnly : .both,
                    sweepHz: sweepHz,
                    sweepDepth: sweepDepth,
                    blendEnabled: blendOn,
                    blend: mix,
                    toneHz: hz,
                    a: first,
                    b: second,
                    demo: false
                ))
            } else if pick == .both && inputs.isEmpty && withURL == nil {
                let first = BuiltIn.tone(frequency: hz, seconds: sineSeconds)
                let second = BuiltIn.tone(frequency: 330, seconds: sineSeconds)
                demo = true
                truncated = false
                take = XORMath.combine(
                    XORMath.render(clipJob(first, demo: true, tone: hz)),
                    XORMath.render(clipJob(second, demo: true, tone: 330)),
                    mode: resolved
                )
            } else if pick == .both, let withURL {
                let first = try ClipLoader.load(url: inputs[0])
                let second = try ClipLoader.load(url: withURL)
                demo = false
                truncated = first.truncated || second.truncated
                take = XORMath.combine(
                    XORMath.render(clipJob(first, demo: false, tone: hz)),
                    XORMath.render(clipJob(second, demo: false, tone: hz)),
                    mode: resolved
                )
            } else if pick == .second {
                let clip: Clip
                if let withURL {
                    clip = try ClipLoader.load(url: withURL)
                    demo = false
                    truncated = clip.truncated
                } else {
                    clip = BuiltIn.tone(frequency: hz, seconds: sineSeconds)
                    demo = true
                    truncated = false
                }
                take = XORMath.render(clipJob(clip, demo: demo, tone: hz))
            } else if resolved == .delay && inputs.isEmpty {
                demo = true
                truncated = false
                take = XORMath.render(clipJob(BuiltIn.tone(frequency: hz, seconds: sineSeconds), demo: true, tone: hz))
            } else {
                let first = try ClipLoader.load(url: inputs[0])
                demo = false
                truncated = first.truncated
                take = XORMath.render(clipJob(first, demo: false, tone: hz))
            }
            guard take.count > 0 else {
                fputs("error: \(take.caption)\n", stderr)
                exit(1)
            }
            let pcm: (left: [Int16], right: [Int16])
            let loopNote: String
            if let repeatSeconds {
                pcm = ExportPCM.repeated(take, seconds: repeatSeconds)
                guard !pcm.left.isEmpty else {
                    fputs("error: that time is shorter than one sample\n", stderr)
                    exit(1)
                }
                loopNote = ", looped \(ExportPCM.durationLabel(frames: pcm.left.count, sampleRate: take.sampleRate))"
            } else {
                pcm = ExportPCM.channels(take)
                loopNote = ""
            }
            let data = WAV.encode(left: pcm.left, right: pcm.right, sampleRate: take.sampleRate)
            try data.write(to: outURL, options: .atomic)
            let note = !demo && truncated ? ", first 10 minutes" : ""
            print("wrote \(outURL.path) — \(take.caption)\(loopNote)\(note)")
            exit(0)
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let shared = AppDelegate()

    private var window: NSWindow?
    private let minSize = NSSize(width: 980, height: 680)
    private let defaultSize = NSSize(width: 1120, height: 1000)
    private var playItem: NSMenuItem?
    private var channelsItem: NSMenuItem?
    private var waveformItem: NSMenuItem?
    private var filesItem: NSMenuItem?
    private var delayItem: NSMenuItem?
    private var firstFileItem: NSMenuItem?
    private var secondFileItem: NSMenuItem?
    private var bothFilesItem: NSMenuItem?
    private var reverseItem: NSMenuItem?
    private var halvesItem: NSMenuItem?
    private var shorterItem: NSMenuItem?
    private var longerItem: NSMenuItem?
    private var loopItem: NSMenuItem?
    private var tenItem: NSMenuItem?
    private var twentyItem: NSMenuItem?
    private var fiftyItem: NSMenuItem?
    private var stackItem: NSMenuItem?
    private var blendItem: NSMenuItem?
    private var bothItem: NSMenuItem?
    private var leftOnlyItem: NSMenuItem?
    private var bit16Item: NSMenuItem?
    private var bit8Item: NSMenuItem?
    private var keyMonitor: Any?

    private override init() { super.init() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        showMainWindow()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            Self.handleKey(event)
        }
    }

    private static func handleKey(_ event: NSEvent) -> NSEvent? {
        guard let window = shared.window, NSApp.keyWindow === window else { return event }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.command) || mods.contains(.control) || mods.contains(.option) {
            return event
        }
        if NSApp.modalWindow != nil || NSApp.keyWindow?.attachedSheet != nil {
            return event
        }
        if NSApp.keyWindow?.firstResponder is NSTextView {
            return event
        }
        if event.isARepeat { return nil }
        let model = CrosstalkModel.shared
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "1": model.setMode(.channels)
        case "2": model.setMode(.waveform)
        case "3": model.setMode(.files)
        case "4": model.setMode(.delay)
        case "r": model.setFold(.reverse)
        case "h": model.setFold(.halves)
        case "s": model.setSpan(.shorter)
        case "l": model.setSpan(.longer)
        case "p": model.setSpan(.loop)
        case "t": model.toggleStack()
        case "b": model.toggleBlend()
        case " ": model.togglePlay()
        default: return event
        }
        return nil
    }

    func applicationWillTerminate(_ notification: Notification) {
        CrosstalkModel.shared.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() } else {
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        CrosstalkModel.shared.receive(urls, preferring: .source)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let model = CrosstalkModel.shared
        playItem?.title = model.isPlaying ? "Stop" : "Play"
        channelsItem?.state = model.mode == .channels ? .on : .off
        waveformItem?.state = model.mode == .waveform ? .on : .off
        filesItem?.state = model.mode == .files ? .on : .off
        delayItem?.state = model.mode == .delay ? .on : .off
        firstFileItem?.state = model.sourcePick == .first ? .on : .off
        secondFileItem?.state = model.sourcePick == .second ? .on : .off
        bothFilesItem?.state = model.sourcePick == .both ? .on : .off
        reverseItem?.state = model.fold == .reverse ? .on : .off
        halvesItem?.state = model.fold == .halves ? .on : .off
        shorterItem?.state = model.span == .shorter ? .on : .off
        longerItem?.state = model.span == .longer ? .on : .off
        loopItem?.state = model.span == .loop ? .on : .off
        tenItem?.state = model.delayIsTen ? .on : .off
        twentyItem?.state = model.delayIsTwenty ? .on : .off
        fiftyItem?.state = model.delayIsFifty ? .on : .off
        stackItem?.state = model.mode == .delay && model.stacked ? .on : .off
        blendItem?.state = model.mode == .delay && model.blendEnabled ? .on : .off
        bothItem?.state = model.mode == .delay && model.ears == .both ? .on : .off
        leftOnlyItem?.state = model.mode == .delay && model.ears == .leftOnly ? .on : .off
        bit16Item?.state = model.bits == 16 ? .on : .off
        bit8Item?.state = model.bits == 8 ? .on : .off
    }

    private func showMainWindow() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let root = ContentView().frame(minWidth: minSize.width, minHeight: minSize.height)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: defaultSize)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = AppInfo.name
        window.backgroundColor = Theme.windowNS
        window.contentView = hosting
        window.setContentSize(defaultSize)
        window.contentMinSize = minSize
        window.isRestorable = true
        window.center()
        window.setFrameAutosaveName("CrosstalkMain")
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    @objc private func showAbout(_ sender: Any?) {
        let credits = NSAttributedString(
            string: """
            XOR the channels of one file, a waveform with itself, \
            or two files against each other.

            Where the bits agree, they become zero. 1000 XOR 2000 is 1080.

            Channels is left XOR right. A mono file agrees with itself \
            and the result is silence.

            Reverse XORs each sample with the one across from it. \
            Doing that again is silence. Halves XORs the first half \
            with the second. The built-in tone is erased that way, \
            because each half is the same waveform.

            Two files are XORed sample by sample. At 16-bit, when the \
            rates match, XOR the result with the second file and the \
            first one comes back.

            Delay XORs each channel with a delayed copy of itself. \
            10 ms, 20 ms, and 50 ms are the three delays. Stack runs \
            them in that order. Sweep moves the delay across the file. \
            220 Hz at 50 ms is 11 cycles, so that tone is erased.

            Two files can stay loaded in every mode. First hears the \
            top file. Second hears the other. Both runs the mode on \
            each file, then XORs those results. The shorter one sets \
            the length. Files still XORs the two recordings directly.

            Blend mixes the left and right of a file before the XOR. \
            It stays off unless you turn it on. The tone is not blended. \
            Left only keeps the right channel as it was.

            Originals are never overwritten.

            Export loop repeats the XOR for a time you set, up to \
            10 minutes. Export one pass writes it once.
            """,
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: AppInfo.name,
            .applicationVersion: "Version \(AppInfo.version) (\(AppInfo.build))",
            .version: AppInfo.build,
            .credits: credits,
        ])
    }

    @objc private func menuPlay(_ sender: Any?) { CrosstalkModel.shared.togglePlay() }
    @objc private func menuOpen(_ sender: Any?) { CrosstalkModel.shared.openPanel(slot: .source) }
    @objc private func menuOpenSecond(_ sender: Any?) { CrosstalkModel.shared.openPanel(slot: .other) }
    @objc private func menuExport(_ sender: Any?) { CrosstalkModel.shared.exportWAV() }
    @objc private func menuExportLoop(_ sender: Any?) { CrosstalkModel.shared.exportLoop() }
    @objc private func menuTones(_ sender: Any?) { CrosstalkModel.shared.clearToTones() }
    @objc private func menuChannels(_ sender: Any?) { CrosstalkModel.shared.setMode(.channels) }
    @objc private func menuWaveform(_ sender: Any?) { CrosstalkModel.shared.setMode(.waveform) }
    @objc private func menuFiles(_ sender: Any?) { CrosstalkModel.shared.setMode(.files) }
    @objc private func menuDelay(_ sender: Any?) { CrosstalkModel.shared.setMode(.delay) }
    @objc private func menuFirstFile(_ sender: Any?) { CrosstalkModel.shared.setSourcePick(.first) }
    @objc private func menuSecondFile(_ sender: Any?) { CrosstalkModel.shared.setSourcePick(.second) }
    @objc private func menuBothFiles(_ sender: Any?) { CrosstalkModel.shared.setSourcePick(.both) }
    @objc private func menuDelay10(_ sender: Any?) { CrosstalkModel.shared.setDelay(10) }
    @objc private func menuDelay20(_ sender: Any?) { CrosstalkModel.shared.setDelay(20) }
    @objc private func menuDelay50(_ sender: Any?) { CrosstalkModel.shared.setDelay(50) }
    @objc private func menuStack(_ sender: Any?) { CrosstalkModel.shared.toggleStack() }
    @objc private func menuBlend(_ sender: Any?) { CrosstalkModel.shared.toggleBlend() }
    @objc private func menuBoth(_ sender: Any?) { CrosstalkModel.shared.setEars(.both) }
    @objc private func menuLeftOnly(_ sender: Any?) { CrosstalkModel.shared.setEars(.leftOnly) }
    @objc private func menuReverse(_ sender: Any?) { CrosstalkModel.shared.setFold(.reverse) }
    @objc private func menuHalves(_ sender: Any?) { CrosstalkModel.shared.setFold(.halves) }
    @objc private func menuShorter(_ sender: Any?) { CrosstalkModel.shared.setSpan(.shorter) }
    @objc private func menuLonger(_ sender: Any?) { CrosstalkModel.shared.setSpan(.longer) }
    @objc private func menuLoop(_ sender: Any?) { CrosstalkModel.shared.setSpan(.loop) }
    @objc private func menu16(_ sender: Any?) { CrosstalkModel.shared.setBits(16) }
    @objc private func menu8(_ sender: Any?) { CrosstalkModel.shared.setBits(8) }

    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        let about = appMenu.addItem(withTitle: "About Crosstalk", action: #selector(showAbout(_:)), keyEquivalent: "")
        about.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Crosstalk", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(
            withTitle: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Crosstalk", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu
        let open = fileMenu.addItem(withTitle: "Open Audio…", action: #selector(menuOpen(_:)), keyEquivalent: "o")
        open.target = self
        let second = fileMenu.addItem(withTitle: "Open Second File…", action: #selector(menuOpenSecond(_:)), keyEquivalent: "O")
        second.target = self
        let export = fileMenu.addItem(withTitle: "Export One Pass…", action: #selector(menuExport(_:)), keyEquivalent: "e")
        export.target = self
        let exportLoop = fileMenu.addItem(withTitle: "Export Loop…", action: #selector(menuExportLoop(_:)), keyEquivalent: "E")
        exportLoop.target = self
        let tones = fileMenu.addItem(withTitle: "Built-in Tones", action: #selector(menuTones(_:)), keyEquivalent: "k")
        tones.target = self
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let playItemMenu = NSMenuItem()
        main.addItem(playItemMenu)
        let playMenu = NSMenu(title: "Play")
        playItemMenu.submenu = playMenu
        playMenu.delegate = self
        let play = playMenu.addItem(withTitle: "Play", action: #selector(menuPlay(_:)), keyEquivalent: " ")
        play.target = self
        playItem = play
        playMenu.addItem(.separator())
        channelsItem = keyed(playMenu, "Channels", #selector(menuChannels(_:)), "1")
        waveformItem = keyed(playMenu, "Waveform", #selector(menuWaveform(_:)), "2")
        filesItem = keyed(playMenu, "Files", #selector(menuFiles(_:)), "3")
        delayItem = keyed(playMenu, "Delay", #selector(menuDelay(_:)), "4")
        playMenu.addItem(.separator())
        firstFileItem = keyed(playMenu, "First File", #selector(menuFirstFile(_:)), "")
        secondFileItem = keyed(playMenu, "Second File", #selector(menuSecondFile(_:)), "")
        bothFilesItem = keyed(playMenu, "Both Files", #selector(menuBothFiles(_:)), "")
        playMenu.addItem(.separator())
        reverseItem = keyed(playMenu, "Reverse", #selector(menuReverse(_:)), "r")
        halvesItem = keyed(playMenu, "Halves", #selector(menuHalves(_:)), "h")
        playMenu.addItem(.separator())
        shorterItem = keyed(playMenu, "Shorter", #selector(menuShorter(_:)), "s")
        longerItem = keyed(playMenu, "Longer", #selector(menuLonger(_:)), "l")
        loopItem = keyed(playMenu, "Loop", #selector(menuLoop(_:)), "p")
        playMenu.addItem(.separator())
        tenItem = keyed(playMenu, "10 ms", #selector(menuDelay10(_:)), "")
        twentyItem = keyed(playMenu, "20 ms", #selector(menuDelay20(_:)), "")
        fiftyItem = keyed(playMenu, "50 ms", #selector(menuDelay50(_:)), "")
        stackItem = keyed(playMenu, "Stack", #selector(menuStack(_:)), "t")
        blendItem = keyed(playMenu, "Blend Left and Right", #selector(menuBlend(_:)), "b")
        bothItem = keyed(playMenu, "Both", #selector(menuBoth(_:)), "")
        leftOnlyItem = keyed(playMenu, "Left Only", #selector(menuLeftOnly(_:)), "")
        playMenu.addItem(.separator())
        bit16Item = keyed(playMenu, "16-bit", #selector(menu16(_:)), "")
        bit8Item = keyed(playMenu, "8-bit", #selector(menu8(_:)), "")

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        editItem.submenu = edit
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
    }

    private func keyed(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }
}

// Suite bridge: the original delegate retains the model and native menus.
@MainActor
public final class LabWorkspace {
    private let delegate = AppDelegate.shared
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
    public func stop() { CrosstalkModel.shared.stop() }
}

extension AppDelegate { fileprivate var labWindow: NSWindow? { window } }
