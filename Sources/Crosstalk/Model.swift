import AppKit
import Combine
import UniformTypeIdentifiers

enum LoadSlot {
    case source
    case other
}

final class CrosstalkModel: ObservableObject {
    static let shared = CrosstalkModel()

    @Published var mode: ListenMode = .channels
    /// Which file Channels, Waveform, and Delay hear. Files ignores this.
    @Published var sourcePick: SourcePick = .first
    @Published var fold: WaveFold = .reverse
    @Published var span: Span = .shorter
    @Published var bits = 16
    @Published var slipMs = 0.0
    @Published var gain = AppInfo.playbackGain
    /// How long an exported loop runs. One-pass export ignores this.
    @Published var loopSeconds = 30.0
    @Published var delayMs = 10.0
    @Published var stacked = false
    @Published var ears: EarMode = .both
    @Published var sweepHz = 0.0
    @Published var sweepDepth = 0.0
    @Published var blendEnabled = false
    @Published var blend: Float = 0.5
    @Published var toneHz = 220.0

    @Published var picture: WavePicture = .empty
    @Published var caption = ""
    @Published var erased = false
    @Published var meta = ""
    @Published var sampleRate = AppInfo.renderRate

    @Published var titleA = ""
    @Published var detailA = ""
    @Published var titleB = ""
    @Published var detailB = ""

    @Published var isPlaying = false
    @Published var isRendering = false
    @Published var isExporting = false
    @Published var isLoadingA = false
    @Published var isLoadingB = false
    @Published var errorText: String?
    @Published var noticeText: String?

    private let engine = PlayEngine()
    private let renderQueue = DispatchQueue(label: "crosstalk.render", qos: .userInitiated)
    private var renderItem: DispatchWorkItem?
    private var generation = 0
    private var tokenA = 0
    private var tokenB = 0
    private var clipA: Clip?
    private var clipB: Clip?
    private var take: Take?

    private init() {
        engine.onFailure = { [weak self] message in
            DispatchQueue.main.async {
                self?.isPlaying = false
                self?.errorText = "Audio stopped. \(message)"
            }
        }
        engine.setGain(gain)
        publishNames()
        apply(renderNow(makeRequest()))
    }

    var hasFile: Bool { clipA != nil || clipB != nil }
    var hasSource: Bool { clipA != nil }

    /// The frequency slider is the built-in tone. A loaded file on the other side is not mixed in.
    var showsToneSlider: Bool {
        guard mode == .delay else { return false }
        switch sourcePick {
        case .first:
            return clipA == nil
        case .second, .both:
            return clipA == nil && clipB == nil
        }
    }

    /// Blend applies to each loaded file this mode is about to hear.
    var showsBlend: Bool {
        guard mode == .delay else { return false }
        switch sourcePick {
        case .first:
            return clipA != nil
        case .second:
            return clipB != nil
        case .both:
            return clipA != nil || clipB != nil
        }
    }

    var sourceIsMono: Bool {
        switch sourcePick {
        case .first:
            return clipA?.isMono ?? false
        case .second:
            return clipB?.isMono ?? false
        case .both:
            let clips = [clipA, clipB].compactMap { $0 }
            return !clips.isEmpty && clips.allSatisfy(\.isMono)
        }
    }

    var delayIsTen: Bool { mode == .delay && !stacked && abs(delayMs - 10) < 0.05 }
    var delayIsTwenty: Bool { mode == .delay && !stacked && abs(delayMs - 20) < 0.05 }
    var delayIsFifty: Bool { mode == .delay && !stacked && abs(delayMs - 50) < 0.05 }

    var slipSamples: Int {
        XORMath.slipSamples(milliseconds: slipMs, sampleRate: sampleRate)
    }

    func tick() {
        guard isPlaying, let live = engine.snapshot(), !live.a.isEmpty else { return }
        picture = WavePicture(
            aLo: live.a,
            aHi: live.a,
            bLo: live.b,
            bHi: live.b,
            xLo: live.x,
            xHi: live.x,
            qA: live.qA,
            qB: live.qB,
            qX: live.qX,
            bits: live.bits,
            silent: false,
            peaked: false
        )
    }

    func togglePlay() {
        if isPlaying {
            stop()
            return
        }
        guard let take, take.count > 0 else {
            errorText = caption
            return
        }
        do {
            try engine.start()
            isPlaying = true
            errorText = nil
        } catch {
            isPlaying = false
            errorText = "Audio didn't start. \(error.localizedDescription)"
        }
    }

    func stop() {
        guard isPlaying else { return }
        engine.stop()
        isPlaying = false
        if let take { picture = take.picture }
    }

    func setMode(_ next: ListenMode) {
        guard mode != next else { return }
        mode = next
        schedule()
    }

    func setSourcePick(_ next: SourcePick) {
        guard sourcePick != next else { return }
        sourcePick = next
        guard mode != .files else { return }
        schedule()
    }

    func setFold(_ next: WaveFold) {
        let changeMode = mode != .waveform
        if fold == next && !changeMode { return }
        fold = next
        if changeMode { mode = .waveform }
        schedule()
    }

    func setSpan(_ next: Span) {
        let changeMode = mode != .files
        if span == next && !changeMode { return }
        span = next
        if changeMode { mode = .files }
        schedule()
    }

    func setBits(_ width: Int) {
        let next = width == 8 ? 8 : 16
        guard bits != next else { return }
        bits = next
        schedule()
    }

    func setSlip(_ ms: Double) {
        let next = min(AppInfo.maxSlipMilliseconds, max(-AppInfo.maxSlipMilliseconds, ms))
        guard abs(next - slipMs) > 0.0001 else { return }
        slipMs = next
        schedule()
    }

    func setDelay(_ ms: Double) {
        let next = min(AppInfo.delaySliderMax, max(0, ms.isFinite ? ms : 0))
        let enter = mode != .delay
        let wasStacked = stacked
        if !enter && !wasStacked && abs(next - delayMs) < 0.0001 { return }
        delayMs = next
        stacked = false
        if enter { mode = .delay }
        schedule()
    }

    func toggleStack() {
        if mode != .delay {
            stacked = true
            mode = .delay
            schedule()
            return
        }
        stacked.toggle()
        schedule()
    }

    func setSweepHz(_ hz: Double) {
        let next = min(AppInfo.maxSweepHz, max(0, hz.isFinite ? hz : 0))
        guard abs(next - sweepHz) > 0.0001 else { return }
        sweepHz = next
        guard mode == .delay, !stacked else { return }
        schedule()
    }

    func setSweepDepth(_ ms: Double) {
        let next = min(AppInfo.maxSweepDepthMilliseconds, max(0, ms.isFinite ? ms : 0))
        guard abs(next - sweepDepth) > 0.0001 else { return }
        sweepDepth = next
        guard mode == .delay, !stacked else { return }
        schedule()
    }

    func toggleBlend() {
        if mode != .delay {
            blendEnabled = true
            mode = .delay
            schedule()
            return
        }
        blendEnabled.toggle()
        schedule()
    }

    func setBlend(_ value: Float) {
        let next: Float = value.isFinite ? min(1, max(0, value)) : 0
        guard abs(next - blend) > 0.0001 else { return }
        blend = next
        guard showsBlend, blendEnabled else { return }
        schedule()
    }

    func setEars(_ next: EarMode) {
        let enter = mode != .delay
        if ears == next && !enter { return }
        ears = next
        if enter { mode = .delay }
        schedule()
    }

    func setToneHz(_ hz: Double) {
        let next = min(AppInfo.maxToneHz, max(AppInfo.minToneHz, hz.isFinite ? hz : 220))
        guard abs(next - toneHz) > 0.05 else { return }
        toneHz = next
        guard showsToneSlider else { return }
        schedule()
    }

    func setGain(_ value: Float) {
        let next: Float = value.isFinite ? min(1, max(0, value)) : 0
        gain = next
        engine.setGain(next)
    }

    func clearToTones() {
        clipA = nil
        clipB = nil
        slipMs = 0
        errorText = nil
        schedule()
    }

    func receive(_ urls: [URL], preferring slot: LoadSlot) {
        guard let first = urls.first else { return }
        if urls.count >= 2 {
            loadPair(first, urls[1])
            return
        }
        load(first, slot: slot)
    }

    func openPanel(slot: LoadSlot) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = slot == .source
        panel.canChooseDirectories = false
        panel.prompt = "Open"
        panel.message = slot == .other
            ? "This file stays loaded in every mode. Files XORs the two files. The other modes can use either, or both."
            : "Open an audio file. A second file can stay loaded too."
        if let clipA, let url = clipA.url { panel.directoryURL = url.deletingLastPathComponent() }
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            guard !urls.isEmpty else { return }
            if slot == .other {
                self?.load(urls[0], slot: .other)
            } else {
                self?.receive(urls, preferring: .source)
            }
        }
    }

    func setLoopSeconds(_ next: Double) {
        guard next.isFinite else { return }
        let clamped = min(max(next, 1), AppInfo.maxSongSeconds).rounded()
        if clamped == loopSeconds { return }
        loopSeconds = clamped
    }

    var loopClock: String {
        ExportPCM.durationLabel(frames: Int(loopSeconds.rounded()), sampleRate: 1)
    }

    func exportWAV() {
        beginExport(loop: false)
    }

    func exportLoop() {
        beginExport(loop: true)
    }

    private func beginExport(loop: Bool) {
        guard !isExporting, !isRendering else { return }
        guard let take, take.count > 0 else {
            errorText = caption
            return
        }
        if loop, ExportPCM.frameCount(seconds: loopSeconds, sampleRate: take.sampleRate) == 0 {
            errorText = "That time is shorter than one sample."
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav]
        panel.canCreateDirectories = true
        let pick = mode == .files ? SourcePick.first : sourcePick
        panel.nameFieldStringValue = loop
            ? Names.suggestedLoop(mode: mode, fold: fold, a: titleA, b: titleB, delayMs: delayMs, stacked: stacked, pick: pick)
            : Names.suggested(mode: mode, fold: fold, a: titleA, b: titleB, delayMs: delayMs, stacked: stacked, pick: pick)
        panel.prompt = "Export"
        panel.message = loop
            ? "The XOR repeats for \(loopClock). A last pass that does not fit is cut. The original stays where it is."
            : "The original file is left where it is. 16-bit export is the XOR itself."
        if let clipA, let url = clipA.url { panel.directoryURL = url.deletingLastPathComponent() }
        let seconds = loop ? loopSeconds : nil
        panel.begin { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            self.writeExport(to: url, loopSeconds: seconds)
        }
    }

    private func load(_ url: URL, slot: LoadSlot) {
        let token: Int
        if slot == .other {
            tokenB += 1
            token = tokenB
            isLoadingB = true
        } else {
            tokenA += 1
            token = tokenA
            isLoadingA = true
        }
        errorText = nil
        noticeText = nil
        let accessing = url.startAccessingSecurityScopedResource()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try ClipLoader.load(url: url) }
            if accessing { url.stopAccessingSecurityScopedResource() }
            DispatchQueue.main.async {
                let current = slot == .other ? self.tokenB : self.tokenA
                guard token == current else { return }
                if slot == .other { self.isLoadingB = false } else { self.isLoadingA = false }
                switch result {
                case .success(let clip):
                    self.slipMs = 0
                    if slot == .other {
                        self.clipB = clip
                    } else {
                        self.clipA = clip
                    }
                    self.schedule()
                case .failure(let error):
                    self.errorText = error.localizedDescription
                }
            }
        }
    }

    private func loadPair(_ first: URL, _ second: URL) {
        tokenA += 1
        tokenB += 1
        let ta = tokenA
        let tb = tokenB
        isLoadingA = true
        isLoadingB = true
        errorText = nil
        noticeText = nil
        let accessA = first.startAccessingSecurityScopedResource()
        let accessB = second.startAccessingSecurityScopedResource()
        DispatchQueue.global(qos: .userInitiated).async {
            let ra = Result { try ClipLoader.load(url: first) }
            let rb = Result { try ClipLoader.load(url: second) }
            if accessA { first.stopAccessingSecurityScopedResource() }
            if accessB { second.stopAccessingSecurityScopedResource() }
            DispatchQueue.main.async {
                guard ta == self.tokenA, tb == self.tokenB else { return }
                self.isLoadingA = false
                self.isLoadingB = false
                self.slipMs = 0
                if case .success(let clip) = ra { self.clipA = clip }
                if case .success(let clip) = rb { self.clipB = clip }
                if case .failure(let error) = ra {
                    self.errorText = error.localizedDescription
                } else if case .failure(let error) = rb {
                    self.errorText = error.localizedDescription
                }
                self.schedule()
            }
        }
    }

    private func writeExport(to url: URL, loopSeconds: Double?) {
        let sources = [clipA?.url, clipB?.url].compactMap { $0 }
        if sources.contains(where: { Names.isSameFile($0, url) }) {
            errorText = "That is one of the files being XORed. Pick a new name."
            return
        }
        guard let take else { return }
        isExporting = true
        errorText = nil
        let rate = take.sampleRate
        DispatchQueue.global(qos: .userInitiated).async {
            let pcm = loopSeconds.map { ExportPCM.repeated(take, seconds: $0) } ?? ExportPCM.channels(take)
            let note = loopSeconds == nil
                ? ""
                : " · \(ExportPCM.durationLabel(frames: pcm.left.count, sampleRate: rate))"
            guard !pcm.left.isEmpty else {
                DispatchQueue.main.async {
                    self.isExporting = false
                    self.errorText = "That time is shorter than one sample."
                }
                return
            }
            do {
                let data = WAV.encode(left: pcm.left, right: pcm.right, sampleRate: rate)
                try data.write(to: url, options: .atomic)
                DispatchQueue.main.async {
                    self.isExporting = false
                    self.noticeText = "Exported \(url.lastPathComponent)\(note)"
                }
            } catch {
                DispatchQueue.main.async {
                    self.isExporting = false
                    self.errorText = error.localizedDescription
                }
            }
        }
    }

    private enum RenderRequest {
        case job(Job)
        case pair(Job, Job)
        case idle(String, Int)
    }

    private func schedule() {
        generation += 1
        let gen = generation
        let request = makeRequest()
        publishNames()
        isRendering = true
        noticeText = nil
        renderItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            let rendered = self?.renderNow(request) ?? Take.idle(caption: "", bits: 16, demo: false)
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                self.apply(rendered)
            }
        }
        renderItem = item
        renderQueue.asyncAfter(deadline: .now() + 0.05, execute: item)
    }

    private func renderNow(_ request: RenderRequest) -> Take {
        switch request {
        case .job(let job):
            return XORMath.render(job)
        case .pair(let first, let second):
            return XORMath.combine(XORMath.render(first), XORMath.render(second), mode: first.mode)
        case .idle(let caption, let width):
            return Take.idle(caption: caption, bits: width, demo: false)
        }
    }

    private func apply(_ rendered: Take) {
        take = rendered
        picture = rendered.picture
        caption = rendered.caption
        erased = rendered.erased
        sampleRate = rendered.sampleRate
        let seconds = rendered.sampleRate > 0 ? Double(rendered.count) / rendered.sampleRate : 0
        meta = "\(rendered.bits)-bit · \(XORMath.rateLabel(rendered.sampleRate)) · \(XORMath.clock(seconds))"
        engine.setTake(rendered)
        isRendering = false
        if isPlaying { picture = rendered.picture }
    }

    private func makeRequest() -> RenderRequest {
        if mode == .files {
            if clipA == nil && clipB == nil {
                return .job(Job(
                    mode: .files, fold: fold, span: span, bits: bits, slipMs: slipMs,
                    a: BuiltIn.low, b: BuiltIn.high, demo: true
                ))
            }
            return .job(Job(
                mode: .files, fold: fold, span: span, bits: bits, slipMs: slipMs,
                a: clipA, b: clipB, demo: false
            ))
        }
        switch sourcePick {
        case .first:
            return .job(heardJob(clipA, demo: clipA == nil, secondDemo: false, hz: toneHz))
        case .second:
            if clipB == nil, clipA != nil {
                return .idle("Drop a second file.", bits)
            }
            if let clipB {
                return .job(heardJob(clipB, demo: false, secondDemo: false, hz: toneHz))
            }
            return .job(heardJob(nil, demo: true, secondDemo: true, hz: toneHz))
        case .both:
            if clipA == nil, clipB != nil {
                return .idle("Drop the first file.", bits)
            }
            if clipA != nil, clipB == nil {
                return .idle("Drop a second file.", bits)
            }
            let first = heardJob(clipA, demo: clipA == nil, secondDemo: false, hz: toneHz)
            let second = heardJob(clipB, demo: clipB == nil, secondDemo: true, hz: 330)
            return .pair(first, second)
        }
    }

    /// One mode, one source. A missing clip is the built-in for that side. Blend stays off for a tone.
    private func heardJob(_ clip: Clip?, demo: Bool, secondDemo: Bool, hz: Double) -> Job {
        let source: Clip
        if let clip {
            source = clip
        } else if mode == .delay {
            source = BuiltIn.tone(frequency: hz)
        } else if secondDemo {
            source = BuiltIn.swapped
        } else {
            source = BuiltIn.pair
        }
        return Job(
            mode: mode,
            fold: fold,
            span: .shorter,
            bits: bits,
            slipMs: 0,
            delayMs: delayMs,
            stacked: stacked,
            ears: ears,
            sweepHz: sweepHz,
            sweepDepth: sweepDepth,
            blendEnabled: mode == .delay && !demo && blendEnabled,
            blend: blend,
            toneHz: hz,
            a: source,
            b: nil,
            demo: demo
        )
    }

    private func publishNames() {
        if clipA == nil && clipB == nil {
            publishDemoNames()
            return
        }
        if let clipA {
            titleA = clipA.name
            detailA = mode != .files && sourcePick == .second
                ? "Loaded. Choose First or Both to hear it here."
                : detail(clipA)
        } else if mode != .files && sourcePick == .first {
            publishDemoSide(second: false)
        } else {
            titleA = "Drop the first file"
            detailA = mode == .files
                ? "XORed with the second file."
                : "Choose First to hear it in this mode."
        }
        if let clipB {
            titleB = clipB.name
            detailB = mode != .files && sourcePick == .first
                ? "Loaded. Choose Second or Both to hear it here."
                : detail(clipB)
        } else {
            titleB = "Drop a second file"
            detailB = mode == .files
                ? "Sample by sample, from the start."
                : "It stays loaded in every mode. Choose Both to hear it here."
        }
    }

    private func publishDemoNames() {
        switch mode {
        case .files:
            titleA = BuiltIn.low.name
            detailA = "built-in · mono · 44.1 kHz · 0:02"
            titleB = BuiltIn.high.name
            detailB = "built-in · mono · 44.1 kHz · 0:02"
        case .delay:
            publishDemoSide(second: false)
            if sourcePick == .both {
                titleB = Caption.frequencyText(330)
                detailB = "built-in · the other tone"
            } else {
                titleB = Caption.frequencyText(toneHz)
                detailB = "built-in · mono · \(XORMath.rateLabel(AppInfo.renderRate)) · \(XORMath.clock(AppInfo.delayDemoSeconds))"
            }
        default:
            titleA = BuiltIn.pair.name
            detailA = "built-in · stereo · 44.1 kHz · 0:02"
            titleB = BuiltIn.swapped.name
            detailB = "built-in · stereo · 44.1 kHz · 0:02"
        }
    }

    private func publishDemoSide(second: Bool) {
        if mode == .delay {
            let hz = second ? 330.0 : toneHz
            titleA = Caption.frequencyText(hz)
            detailA = "built-in · mono · \(XORMath.rateLabel(AppInfo.renderRate)) · \(XORMath.clock(AppInfo.delayDemoSeconds))"
        } else {
            let clip = second ? BuiltIn.swapped : BuiltIn.pair
            titleA = clip.name
            detailA = "built-in · stereo · 44.1 kHz · 0:02"
        }
    }

    private func detail(_ clip: Clip) -> String {
        let kind = clip.isMono ? "mono" : "stereo"
        let body = "\(kind) · \(XORMath.rateLabel(clip.sampleRate)) · \(XORMath.clock(clip.duration))"
        if clip.truncated { return "\(body) · first 10 min" }
        if clip.pcmLeft != nil { return "\(body) · 16-bit" }
        return body
    }
}
