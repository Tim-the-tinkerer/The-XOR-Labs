import AppKit
import AVFoundation
import Combine
import Foundation

extension FrameBuffer {
    func nsImage() -> NSImage {
        guard let cg = cgImage() else { return NSImage() }
        return NSImage(cgImage: cg, size: NSSize(width: width, height: height))
    }
}

final class TicketBox {
    private let lock = NSLock()
    private var value = 0

    func bump() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    func matches(_ token: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value == token
    }
}

final class FrameSlot {
    private let lock = NSLock()
    private var image: NSImage?
    private var time: Double = 0
    private var dirty = false

    func store(_ image: NSImage, time: Double) {
        lock.lock()
        self.image = image
        self.time = time
        dirty = true
        lock.unlock()
    }

    func take() -> (NSImage, Double)? {
        lock.lock()
        defer { lock.unlock() }
        guard dirty, let image else { return nil }
        dirty = false
        return (image, time)
    }
}

final class GrabberBox {
    private var grabbers: [URL: StillGrabber] = [:]

    func grabber(for url: URL) -> StillGrabber {
        if let found = grabbers[url] { return found }
        let made = StillGrabber(url: url, exact: false)
        grabbers[url] = made
        return made
    }

    func removeAll() {
        grabbers.removeAll()
    }
}

final class AppModel: ObservableObject {
    enum Slot { case a, b }

    @Published var clipA: ClipFacts?
    @Published var clipB: ClipFacts?
    @Published var mode: PlaceMode = .fit
    @Published var mix: PictureMix = .identity
    @Published var soundMode: SoundMode = .fromA
    @Published var loop = true
    /// When set, playback and save stop at the shorter clip. Off keeps A's full length.
    @Published var matchLengths = false
    @Published var preview: NSImage?
    @Published var playing = false
    @Published var time: Double = 0
    @Published var busy = false
    @Published var progress: Double = 0
    @Published var status = "Drop two videos."
    @Published var statusIsError = false
    @Published var previewWidth = 0
    @Published var previewHeight = 0

    private let io = DispatchQueue(label: "com.tim.moire.io", qos: .userInitiated)
    private let playTicket = TicketBox()
    private let stillTicket = TicketBox()
    private let exportTicket = TicketBox()
    private let importTicket = TicketBox()
    private let converter = RunningProcess()
    private var ownedA: URL?
    private var ownedB: URL?
    private let slot = FrameSlot()
    private let grabbers = GrabberBox()
    private var audioPlayer: AVPlayer?
    private var xorSoundURL: URL?
    private var xorSoundKey: String?
    private var displayTimer: Timer?
    private var seekWork: DispatchWorkItem?
    private var pictureRefresh: DispatchWorkItem?
    /// Open-panel and drop URLs are security-scoped. Access has to stay open
    /// for the whole time the clip is loaded, or the file reads as empty.
    private var scopeA: ScopedFile?
    private var scopeB: ScopedFile?
    private var loadTokenA = 0
    private var loadTokenB = 0

    var duration: Double {
        guard let a = clipA else { return 0 }
        guard matchLengths, let b = clipB else { return a.durationSeconds }
        return MovieSpan.seconds(a: a.durationSeconds, b: b.durationSeconds, match: true)
    }
    var ready: Bool { clipA != nil && clipB != nil && !busy }

    func load(urls: [URL]) {
        let files = urls.filter { $0.isFileURL && !$0.hasDirectoryPath }
        guard !files.isEmpty else {
            fail(MovieError.unreadable("Drop a video file."))
            return
        }
        if files.count >= 2 {
            load(files[0], into: .a)
            load(files[1], into: .b)
        } else if clipA == nil {
            load(files[0], into: .a)
        } else if clipB == nil {
            load(files[0], into: .b)
        } else {
            load(files[0], into: .a)
        }
    }

    func load(_ url: URL, into slot: Slot) {
        stopPlayback()
        let scope = ScopedFile(url)
        let token = bumpLoad(slot)
        let job = importTicket.bump()
        switch slot {
        case .a: scopeA = scope
        case .b: scopeB = scope
        }
        statusIsError = false
        status = "Reading \(url.lastPathComponent)…"
        io.async {
            do {
                let opened = try MovieIntake.open(
                    url,
                    cancelled: { !self.importTicket.matches(job) },
                    progress: { fraction in
                        let percent = Int((fraction * 100).rounded())
                        DispatchQueue.main.async {
                            guard self.importTicket.matches(job), self.loadMatches(slot, token) else { return }
                            self.busy = true
                            self.progress = min(0.99, max(0.01, fraction))
                            self.status = "Converting \(url.lastPathComponent)… \(percent)%"
                            self.statusIsError = false
                        }
                    },
                    onProcess: { self.converter.track($0) }
                )
                DispatchQueue.main.async {
                    let live = self.loadMatches(slot, token) && self.importTicket.matches(job)
                    guard live else {
                        if let temporary = opened.temporary {
                            try? FileManager.default.removeItem(at: temporary)
                        }
                        return
                    }
                    if opened.temporary != nil {
                        switch slot {
                        case .a: self.scopeA = nil
                        case .b: self.scopeB = nil
                        }
                    }
                    self.storeOwned(opened.temporary, slot: slot)
                    switch slot {
                    case .a: self.clipA = opened.facts
                    case .b: self.clipB = opened.facts
                    }
                    if opened.temporary != nil {
                        self.busy = false
                        self.progress = 0
                    }
                    self.invalidateXorSound()
                    self.time = 0
                    if self.clipA == nil || self.clipB == nil {
                        self.preview = nil
                        self.previewWidth = 0
                        self.previewHeight = 0
                        self.status = self.clipA == nil
                            ? "B is ready. Drop the first video."
                            : "A is ready. Drop the second video."
                        self.statusIsError = false
                    } else {
                        self.requestStill()
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.loadMatches(slot, token) else { return }
                    switch slot {
                    case .a: self.scopeA = nil
                    case .b: self.scopeB = nil
                    }
                    if ForeignMovie.isContainer(url) {
                        self.busy = false
                        self.progress = 0
                    }
                    if case MovieError.cancelled = error {
                        self.status = "Cancelled."
                        self.statusIsError = false
                        return
                    }
                    self.fail(error, alert: true)
                }
            }
        }
    }

    func openPanel(into slot: Slot?) {
        guard !busy else { return }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        // A strict movie UTI greys out real MP4s whose type tag is odd.
        // Let every file be chosen, then reject anything that has no picture.
        panel.allowedContentTypes = [.item]
        panel.allowsOtherFileTypes = true
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.message = "Choose a video. MOV, MP4, MKV, and WebM."
        panel.prompt = "Open"
        panel.title = slot == .b ? "Open Video B" : "Open Video"
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let self else { return }
            let urls = panel.urls
            if urls.count >= 2 {
                self.load(urls[0], into: .a)
                self.load(urls[1], into: .b)
            } else if let url = urls.first {
                self.load(url, into: slot ?? .a)
            }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.center()
            finish(panel.runModal())
        }
    }

    func savePanel() {
        guard let a = clipA, let b = clipB, !busy else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = MovieNames.suggested()
        panel.title = "Save XOR Movie"
        panel.prompt = "Save"
        panel.begin { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            self.export(to: url, a: a, b: b)
        }
    }

    func clearAll() {
        guard !busy else { return }
        stopPlayback()
        seekWork?.cancel()
        clipA = nil
        clipB = nil
        scopeA = nil
        scopeB = nil
        loadTokenA += 1
        loadTokenB += 1
        _ = importTicket.bump()
        converter.stop()
        releaseOwned()
        preview = nil
        previewWidth = 0
        previewHeight = 0
        time = 0
        progress = 0
        status = "Drop two videos."
        statusIsError = false
        invalidateXorSound()
        io.async { self.grabbers.removeAll() }
    }

    func swapClips() {
        guard clipA != nil || clipB != nil else { return }
        stopPlayback()
        swap(&clipA, &clipB)
        swap(&scopeA, &scopeB)
        swap(&ownedA, &ownedB)
        invalidateXorSound()
        time = 0
        requestStill()
    }

    func setMode(_ mode: PlaceMode) {
        guard self.mode != mode else { return }
        self.mode = mode
        refreshPictureNow()
    }

    func setTurn(_ turn: QuarterTurn) {
        guard mix.turn != turn else { return }
        mix.turn = turn
        refreshPictureNow()
    }

    func setFlipHorizontal(_ on: Bool) {
        guard mix.flipHorizontal != on else { return }
        mix.flipHorizontal = on
        refreshPictureNow()
    }

    func setFlipVertical(_ on: Bool) {
        guard mix.flipVertical != on else { return }
        mix.flipVertical = on
        refreshPictureNow()
    }

    func setScale(_ value: Double) {
        let next = PictureMix.clampedScale(value)
        guard abs(mix.scale - next) > 0.0001 else { return }
        mix.scale = next
        schedulePictureRefresh()
    }

    func setOffsetX(_ value: Double) {
        let next = PictureMix.clampedOffset(value)
        guard abs(mix.offsetX - next) > 0.0001 else { return }
        mix.offsetX = next
        schedulePictureRefresh()
    }

    func setOffsetY(_ value: Double) {
        let next = PictureMix.clampedOffset(value)
        guard abs(mix.offsetY - next) > 0.0001 else { return }
        mix.offsetY = next
        schedulePictureRefresh()
    }

    /// Puts both offset axes back at zero. Scale, turn, flip, and delay stay as they are.
    func resetOffset() {
        guard !busy, !mix.offsetIsCentered else { return }
        mix.offsetX = 0
        mix.offsetY = 0
        refreshPictureNow()
    }

    func setDelay(_ value: Double) {
        let next = PictureMix.clampedDelay(value)
        guard abs(mix.delay - next) > 0.0001 else { return }
        mix.delay = next
        schedulePictureRefresh()
    }

    func setMatchLengths(_ on: Bool) {
        guard !busy, matchLengths != on else { return }
        matchLengths = on
        if duration > 0, time >= duration - 0.0005 {
            time = 0
        }
        refreshPictureNow()
    }

    private func schedulePictureRefresh() {
        pictureRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.refreshPicture()
        }
        pictureRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    private func refreshPictureNow() {
        pictureRefresh?.cancel()
        refreshPicture()
    }

    private func refreshPicture() {
        if playing {
            let at = time
            stopPlayback()
            time = at
            startPlayback()
        } else {
            requestStill()
        }
    }

    func setSoundMode(_ mode: SoundMode) {
        guard soundMode != mode else { return }
        soundMode = mode
        guard playing else { return }
        let at = time
        stopPlayback()
        time = at
        startPlayback()
    }

    func loadSample() {
        guard !busy else { return }
        stopPlayback()
        busy = true
        statusIsError = false
        status = "Making the sample pair…"
        io.async {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("MoireSample", isDirectory: true)
            do {
                let pair: (URL, URL)
                do {
                    pair = try SampleScene.writePair(to: directory, codec: .proRes4444)
                } catch {
                    pair = try SampleScene.writePair(to: directory, codec: .h264)
                }
                let a = try MovieProbe.facts(url: pair.0)
                let b = try MovieProbe.facts(url: pair.1)
                DispatchQueue.main.async {
                    self.busy = false
                    self.releaseOwned()
                    self.clipA = a
                    self.clipB = b
                    self.invalidateXorSound()
                    self.time = 0
                    self.requestStill()
                }
            } catch {
                DispatchQueue.main.async {
                    self.busy = false
                    self.fail(error)
                }
            }
        }
    }

    func togglePlay() {
        if playing {
            stopPlayback()
            describe()
        } else {
            startPlayback()
        }
    }

    func seek(to seconds: Double) {
        let limit = duration
        let clamped = min(max(0, seconds), limit > 0 ? limit : 0)
        if playing { stopPlayback() }
        time = clamped
        seekWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.requestStill()
        }
        seekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    func cancelWork() {
        converter.stop()
        _ = exportTicket.bump()
        _ = importTicket.bump()
        loadTokenA += 1
        loadTokenB += 1
        busy = false
        progress = 0
        status = "Cancelled."
        statusIsError = false
    }

    private func export(to url: URL, a: ClipFacts, b: ClipFacts) {
        if OutputGuard.collides(url, sources: [a.url, b.url]) {
            fail(MovieError.overwrite)
            return
        }
        stopPlayback()
        busy = true
        progress = 0
        status = "Saving…"
        statusIsError = false
        let token = exportTicket.bump()
        let request = ExportRequest(
            clipA: a.url,
            clipB: b.url,
            output: url,
            mode: mode,
            mix: mix,
            matchLengths: matchLengths,
            longEdge: MoireLimits.saveLongEdge,
            audio: soundMode
        )
        io.async {
            do {
                let result = try MovieExport.run(request, progress: { value in
                    DispatchQueue.main.async {
                        guard self.exportTicket.matches(token) else { return }
                        self.progress = value
                        self.status = "Saving… \(Int((value * 100).rounded()))%"
                    }
                }, cancelled: {
                    !self.exportTicket.matches(token)
                })
                DispatchQueue.main.async {
                    guard self.exportTicket.matches(token) else { return }
                    self.busy = false
                    self.progress = 1
                    let sound: String
                    if result.audio, self.soundMode == .xor {
                        sound = " · with XORed sound"
                    } else if result.audio {
                        sound = " · with A's sound"
                    } else {
                        sound = ""
                    }
                    self.status = "Saved \(result.frames) frames · \(result.width)×\(result.height)\(sound) → \(url.lastPathComponent)"
                    self.statusIsError = false
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.exportTicket.matches(token) else { return }
                    self.busy = false
                    self.progress = 0
                    self.fail(error)
                }
            }
        }
    }

    private func requestStill() {
        guard let a = clipA, let b = clipB, !playing else { return }
        let token = stillTicket.bump()
        let mode = mode
        let mix = mix
        let at = time
        io.async {
            guard self.stillTicket.matches(token) else { return }
            do {
                let frameA = try self.grabbers.grabber(for: a.url).frame(at: at, longEdge: MoireLimits.previewLongEdge)
                guard self.stillTicket.matches(token) else { return }
                let bAt = at - PictureMix.clampedDelay(mix.delay)
                let frameB: FrameBuffer
                if bAt >= -0.0005 {
                    frameB = try self.grabbers.grabber(for: b.url).frame(at: max(0, bAt), longEdge: MoireLimits.previewLongEdge)
                } else {
                    frameB = FrameBuffer(width: frameA.width, height: frameA.height)
                }
                guard self.stillTicket.matches(token) else { return }
                let placed = FrameXOR.place(frameB, ontoWidth: frameA.width, ontoHeight: frameA.height, mode: mode, mix: mix)
                let xor = FrameXOR.xor(frameA, placed)
                let image = xor.nsImage()
                DispatchQueue.main.async {
                    guard self.stillTicket.matches(token), !self.playing else { return }
                    self.preview = image
                    self.previewWidth = xor.width
                    self.previewHeight = xor.height
                    self.describe()
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.stillTicket.matches(token) else { return }
                    self.fail(error)
                }
            }
        }
    }

    private func startPlayback() {
        guard let a = clipA, let b = clipB, !busy else { return }
        if duration > 0, time >= duration - 0.04 { time = 0 }
        playing = true
        statusIsError = false
        let token = playTicket.bump()
        let start = time
        let mode = mode
        let mix = mix
        let shouldLoop = loop
        let soundMode = soundMode
        let match = matchLengths
        let key = xorKey(a, b)
        let cached = soundMode == .xor && xorSoundKey == key ? xorSoundURL : nil
        if soundMode == .xor, cached == nil, a.hasAudio || b.hasAudio {
            status = "Mixing sound…"
        } else {
            status = "Playing."
        }
        if soundMode == .fromA, a.hasAudio {
            startSound(url: a.url, at: start)
        } else if let cached {
            startSound(url: cached, at: start)
        } else {
            stopSound()
        }
        startDisplay()
        io.async {
            if soundMode == .xor, cached == nil, a.hasAudio || b.hasAudio {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("moire-xor-\(UUID().uuidString).caf")
                do {
                    let wrote = try AudioXOR.render(
                        clipA: a.url,
                        clipB: b.url,
                        startA: a.rangeStart,
                        startB: b.rangeStart,
                        duration: MovieSpan.time(a: a, b: b, match: match),
                        to: url,
                        cancelled: { !self.playTicket.matches(token) }
                    )
                    if !self.playTicket.matches(token) {
                        try? FileManager.default.removeItem(at: url)
                        return
                    }
                    if wrote {
                        DispatchQueue.main.async {
                            guard self.playTicket.matches(token) else {
                                try? FileManager.default.removeItem(at: url)
                                return
                            }
                            self.rememberXor(url, key: key)
                            self.startSound(url: url, at: start)
                            self.status = "Playing."
                            self.statusIsError = false
                        }
                    } else {
                        try? FileManager.default.removeItem(at: url)
                    }
                } catch {
                    try? FileManager.default.removeItem(at: url)
                    if case MovieError.cancelled = error { return }
                    DispatchQueue.main.async {
                        guard self.playTicket.matches(token) else { return }
                        self.report("Couldn't mix the sound. \(error.localizedDescription)")
                    }
                }
            }
            guard self.playTicket.matches(token) else { return }
            var cursor = start
            while self.playTicket.matches(token) {
                do {
                    let count = try Playback.runOnce(
                        a: a,
                        b: b,
                        from: cursor,
                        end: match ? MovieSpan.seconds(a: a.durationSeconds, b: b.durationSeconds, match: true) : nil,
                        mode: mode,
                        mix: mix,
                        token: token,
                        tickets: self.playTicket,
                        slot: self.slot
                    )
                    if count == 0 || !shouldLoop || !self.playTicket.matches(token) { break }
                    cursor = 0
                    DispatchQueue.main.async {
                        guard self.playTicket.matches(token), self.playing else { return }
                        self.restartSound()
                    }
                } catch {
                    DispatchQueue.main.async {
                        guard self.playTicket.matches(token) else { return }
                        self.fail(error)
                        self.stopPlayback()
                    }
                    return
                }
            }
            DispatchQueue.main.async {
                guard self.playTicket.matches(token) else { return }
                self.playing = false
                self.stopSound()
                self.displayTimer?.invalidate()
                self.displayTimer = nil
                if let last = self.slot.take() {
                    self.preview = last.0
                    self.time = last.1
                }
                self.describe()
            }
        }
    }

    private func stopPlayback() {
        _ = playTicket.bump()
        playing = false
        displayTimer?.invalidate()
        displayTimer = nil
        stopSound()
    }

    private func startDisplay() {
        displayTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self, let frame = self.slot.take() else { return }
            self.preview = frame.0
            self.time = frame.1
            self.previewWidth = Int(frame.0.size.width.rounded())
            self.previewHeight = Int(frame.0.size.height.rounded())
        }
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }

    private func startSound(url: URL, at seconds: Double) {
        let player = AVPlayer(url: url)
        audioPlayer = player
        let when = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: when, toleranceBefore: .zero, toleranceAfter: .zero) { [weak player] _ in
            player?.play()
        }
    }

    private func restartSound() {
        switch soundMode {
        case .off:
            return
        case .fromA:
            guard let clipA, clipA.hasAudio else { return }
            if let audioPlayer {
                audioPlayer.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak audioPlayer] _ in
                    audioPlayer?.play()
                }
            } else {
                startSound(url: clipA.url, at: 0)
            }
        case .xor:
            guard let xorSoundURL else { return }
            if let audioPlayer {
                audioPlayer.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak audioPlayer] _ in
                    audioPlayer?.play()
                }
            } else {
                startSound(url: xorSoundURL, at: 0)
            }
        }
    }

    private func xorKey(_ a: ClipFacts, _ b: ClipFacts) -> String {
        let match = matchLengths ? "1" : "0"
        return "\(a.url.path)|\(a.rangeDuration.value)/\(a.rangeDuration.timescale)|\(b.url.path)|\(b.rangeDuration.value)/\(b.rangeDuration.timescale)|match=\(match)"
    }

    private func rememberXor(_ url: URL, key: String) {
        if let old = xorSoundURL, old != url {
            try? FileManager.default.removeItem(at: old)
        }
        xorSoundURL = url
        xorSoundKey = key
    }

    private func invalidateXorSound() {
        xorSoundKey = nil
        guard let url = xorSoundURL else { return }
        xorSoundURL = nil
        io.async { try? FileManager.default.removeItem(at: url) }
    }

    private func stopSound() {
        audioPlayer?.pause()
        audioPlayer = nil
    }

    private func describe() {
        guard let a = clipA, let b = clipB else { return }
        _ = b
        let save = FrameSize.capped(
            width: a.orientedWidth,
            height: a.orientedHeight,
            longEdge: MoireLimits.saveLongEdge
        )
        let shown = previewWidth > 0 ? "\(previewWidth)×\(previewHeight) preview · " : ""
        let mixNote = mix.reshapes || mix.delay > 0.02 ? " · \(mix.summary)" : ""
        let matchNote = matchLengths ? " · matched" : ""
        status = "\(shown)save \(save.0)×\(save.1) · \(MoireFormat.fps(a.framesPerSecond)) fps · \(MoireFormat.clock(duration))\(matchNote) · \(mode.title)\(mixNote)"
        statusIsError = false
    }

    func report(_ message: String) {
        status = message
        statusIsError = true
    }

    private func fail(_ error: Error, alert: Bool = false) {
        let message = error.localizedDescription
        status = message
        statusIsError = true
        guard alert else { return }
        let notice = NSAlert()
        notice.messageText = "Couldn't open that video"
        notice.informativeText = message
        notice.alertStyle = .warning
        notice.addButton(withTitle: "OK")
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            notice.beginSheetModal(for: window)
        } else {
            notice.runModal()
        }
    }

    private func storeOwned(_ url: URL?, slot: Slot) {
        let previous: URL?
        switch slot {
        case .a:
            previous = ownedA
            ownedA = url
        case .b:
            previous = ownedB
            ownedB = url
        }
        guard let previous, previous != url else { return }
        io.async { try? FileManager.default.removeItem(at: previous) }
    }

    private func releaseOwned() {
        let urls = [ownedA, ownedB].compactMap { $0 }
        ownedA = nil
        ownedB = nil
        guard !urls.isEmpty else { return }
        io.async {
            for url in urls {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func bumpLoad(_ slot: Slot) -> Int {
        switch slot {
        case .a:
            loadTokenA += 1
            return loadTokenA
        case .b:
            loadTokenB += 1
            return loadTokenB
        }
    }

    private func loadMatches(_ slot: Slot, _ token: Int) -> Bool {
        switch slot {
        case .a: return loadTokenA == token
        case .b: return loadTokenB == token
        }
    }
}

final class RunningProcess {
    private let lock = NSLock()
    private var process: Process?

    func track(_ process: Process) {
        lock.lock()
        self.process = process
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let process = self.process
        lock.unlock()
        if process?.isRunning == true {
            process?.terminate()
        }
    }
}

/// Keeps a security-scoped URL readable until the clip is replaced or cleared.
final class ScopedFile {
    let url: URL
    private let open: Bool

    init(_ url: URL) {
        self.url = url
        open = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if open { url.stopAccessingSecurityScopedResource() }
    }
}

enum Playback {
    static func runOnce(
        a: ClipFacts,
        b: ClipFacts,
        from: Double,
        end: Double?,
        mode: PlaceMode,
        mix: PictureMix,
        token: Int,
        tickets: TicketBox,
        slot: FrameSlot
    ) throws -> Int {
        let aSize = FrameSize.capped(
            width: a.orientedWidth,
            height: a.orientedHeight,
            longEdge: MoireLimits.previewLongEdge
        )
        let bSize = FrameSize.capped(
            width: b.orientedWidth,
            height: b.orientedHeight,
            longEdge: MoireLimits.previewLongEdge
        )
        let start = CMTime(seconds: max(0, from), preferredTimescale: 600)
        let readerA = try OrientedReader(
            facts: a,
            renderWidth: aSize.0,
            renderHeight: aSize.1,
            frameDuration: a.frameDuration,
            start: start
        )
        let readerB = try OrientedReader(
            facts: b,
            renderWidth: bSize.0,
            renderHeight: bSize.1,
            frameDuration: a.frameDuration,
            start: CMTime(seconds: BSampler.readerStart(from: from, delay: mix.delay), preferredTimescale: 600)
        )
        defer {
            readerA.cancel()
            readerB.cancel()
        }
        let step = max(a.frameDuration.seconds, 1.0 / 60.0)
        var shown = from
        var produced = 0
        var bOpen = true
        var sampler = BSampler(from: from, delay: mix.delay)
        var deadline = Date()
        while tickets.matches(token) {
            if let end, shown >= end - 0.0005 { break }
            guard let rawA = readerA.next() else { break }
            let frameA = rawA.fitted(to: aSize)
            let frameB = placedB(
                open: &bOpen,
                sampler: &sampler,
                at: shown,
                read: { readerB.next() },
                canvas: aSize,
                mode: mode,
                mix: mix
            )
            let image = FrameXOR.xor(frameA, frameB).nsImage()
            slot.store(image, time: shown)
            produced += 1
            shown += step
            deadline = deadline.addingTimeInterval(step)
            let remain = deadline.timeIntervalSinceNow
            if remain > 0.001 {
                Thread.sleep(forTimeInterval: remain)
            } else {
                deadline = Date()
            }
        }
        return produced
    }
}
