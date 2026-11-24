import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

enum ImageSlot {
    case a
    case b
}

struct DifferenceReport: Equatable {
    var differed: Int
    var pixels: Int
    var width: Int
    var height: Int
}

private struct LoadedImage {
    var buffer: PixelBuffer
    var name: String
    var url: URL?
    var capped: Bool
}

enum ImageFiles {
    static let extensions: Set<String> = [
        "png", "jpg", "jpeg", "tif", "tiff", "heic", "heif", "gif", "bmp", "webp",
    ]

    static func isImage(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    static var contentTypes: [UTType] {
        var types: [UTType] = [.png, .jpeg, .tiff, .gif, .bmp, .image]
        if let heic = UTType("public.heic") { types.insert(heic, at: 2) }
        if let webp = UTType("org.webmproject.webp") { types.append(webp) }
        return types
    }
}

final class AppModel: ObservableObject {
    @Published var options = PaintOptions()
    @Published var status = "Drop two images. Black where they match, white where they differ."
    @Published var nameA = "Image A"
    @Published var nameB = "Image B"
    @Published var detailA = "Drop a picture"
    @Published var detailB = "Drop a picture"
    @Published var previewA: NSImage?
    @Published var previewB: NSImage?
    @Published var resultImage: NSImage?
    @Published var report: DifferenceReport?
    @Published var reportIsCurrent = false
    @Published var showingPreview = false
    @Published var isPainting = false
    @Published var hasA = false
    @Published var hasB = false

    /// Channel, align, slack, and nudge. The view (mode, plane, lift, invert) is not part of it.
    private struct CompareKey: Equatable {
        var channel: PaintChannel
        var align: AlignMode
        var slack: Int
        var offsetX: Int
        var offsetY: Int
        var generation: UInt64
    }

    /// Decimated A and B already scaled onto that grid. Reused while the pictures and align stay put.
    private struct PreviewCache {
        var generation: UInt64
        var align: AlignMode
        var stride: Int
        var a: PixelBuffer
        var b: PixelBuffer
        var reduced: Bool
    }

    /// Full-resolution B after Fit. Slack, nudge, and the view do not scale it again.
    private struct FittedCache {
        var generation: UInt64
        var align: AlignMode
        var width: Int
        var height: Int
        var buffer: PixelBuffer
    }

    private var loadedA: LoadedImage?
    private var loadedB: LoadedImage?
    private var paintTicket = 0
    private var statusEpoch = 0
    private var paintDirty = false
    private var paintingInBackground = false
    private var paintWork: DispatchWorkItem?
    private var imageGeneration: UInt64 = 0
    private var cachedCount: (key: CompareKey, differed: Int)?
    private var previewCache: PreviewCache?
    private var fittedCache: FittedCache?
    private let paintQueue = DispatchQueue(label: "com.tim.paritypainter.paint", qos: .userInitiated)
    private let ticketLock = NSLock()

    var canSave: Bool { hasA && hasB }

    var nudgeLimit: Int {
        let width = max(loadedA?.buffer.width ?? 0, loadedB?.buffer.width ?? 0)
        let height = max(loadedA?.buffer.height ?? 0, loadedB?.buffer.height ?? 0)
        return max(256, max(width, height))
    }

    var heroNumber: String {
        guard let report, report.pixels > 0 else { return "—" }
        if report.differed == 0 { return "0%" }
        let pct = Double(report.differed) * 100 / Double(report.pixels)
        if pct >= 10 { return String(format: "%.1f%%", pct) }
        return String(format: "%.2f%%", pct)
    }

    var heroCaption: String {
        guard report != nil else { return "two images" }
        if !reportIsCurrent { return "counting" }
        if report?.differed == 0 { return "exact match" }
        return showingPreview ? "differ · full frame" : "differ"
    }

    var recipe: String {
        var parts = [
            options.mode.title.uppercased(),
            options.channel.title.uppercased(),
            options.align.title.uppercased(),
        ]
        if options.slack > 0 { parts.append("SLACK \(options.slack)") }
        if options.mode == .plane { parts.append("BIT \(options.plane)") }
        if options.mode == .xor && options.lift > 1 { parts.append("×\(options.lift)") }
        if options.offsetX != 0 || options.offsetY != 0 {
            parts.append("NUDGE \(options.offsetX), \(options.offsetY)")
        }
        if options.invert { parts.append("INVERT") }
        return parts.joined(separator: "  ·  ")
    }

    func update(_ body: (inout PaintOptions) -> Void) {
        var next = options
        body(&next)
        let clean = next.sanitized()
        guard clean != options else { return }
        options = clean
        schedulePaint()
    }

    func nudge(dx: Int, dy: Int) {
        let limit = nudgeLimit
        update {
            $0.offsetX = min(limit, max(-limit, $0.offsetX + dx))
            $0.offsetY = min(limit, max(-limit, $0.offsetY + dy))
        }
    }

    func zeroNudge() {
        update {
            $0.offsetX = 0
            $0.offsetY = 0
        }
    }

    func swap() {
        Swift.swap(&loadedA, &loadedB)
        Swift.swap(&previewA, &previewB)
        Swift.swap(&nameA, &nameB)
        Swift.swap(&detailA, &detailB)
        Swift.swap(&hasA, &hasB)
        var next = options
        next.offsetX = -next.offsetX
        next.offsetY = -next.offsetY
        options = next
        noteImagesChanged()
        schedulePaint(immediate: true)
    }

    func load(url: URL, into slot: ImageSlot) {
        statusNote("Reading \(url.lastPathComponent)…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let decoded = try ImageCodec.load(url: url)
                let thumb = Self.previewBuffer(decoded.buffer, maxSide: 720)
                let loaded = LoadedImage(
                    buffer: decoded.buffer,
                    name: url.lastPathComponent,
                    url: url,
                    capped: decoded.capped
                )
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.assign(loaded, thumb: ImageCodec.nsImage(thumb), into: slot)
                    self.clampNudge()
                    self.schedulePaint(immediate: true)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.statusNote(error.localizedDescription)
                }
            }
        }
    }

    func load(urls: [URL]) {
        let files = urls.filter { url in
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                return false
            }
            return true
        }
        let images = files.filter { ImageFiles.isImage($0) }
        let chosen = images.isEmpty ? files : images
        guard let first = chosen.first else {
            statusNote("Drop a PNG or JPEG.")
            return
        }
        if chosen.count >= 2 {
            load(url: first, into: .a)
            load(url: chosen[1], into: .b)
        } else if !hasA {
            load(url: first, into: .a)
        } else {
            load(url: first, into: .b)
        }
    }

    func loadSample() {
        let pair = SampleScene.pair()
        assign(
            LoadedImage(buffer: pair.0, name: "Sample A", url: nil, capped: false),
            thumb: ImageCodec.nsImage(pair.0),
            into: .a
        )
        assign(
            LoadedImage(buffer: pair.1, name: "Sample B", url: nil, capped: false),
            thumb: ImageCodec.nsImage(pair.1),
            into: .b
        )
        schedulePaint(immediate: true)
    }

    func paste(into slot: ImageSlot?) {
        let pasteboard = NSPasteboard.general
        let target = slot ?? (hasA ? ImageSlot.b : ImageSlot.a)
        if let image = NSImage(pasteboard: pasteboard) {
            statusNote("Reading clipboard…")
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                do {
                    let decoded = try ImageCodec.load(nsImage: image)
                    let thumb = Self.previewBuffer(decoded.buffer, maxSide: 720)
                    let loaded = LoadedImage(
                        buffer: decoded.buffer,
                        name: "Clipboard",
                        url: nil,
                        capped: decoded.capped
                    )
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.assign(loaded, thumb: ImageCodec.nsImage(thumb), into: target)
                        self.clampNudge()
                        self.schedulePaint(immediate: true)
                    }
                } catch {
                    DispatchQueue.main.async {
                        self?.statusNote(error.localizedDescription)
                    }
                }
            }
            return
        }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            if let slot {
                if let first = urls.first { load(url: first, into: slot) }
            } else {
                load(urls: urls)
            }
            return
        }
        statusNote("Clipboard has no image.")
    }

    func clear(_ slot: ImageSlot) {
        switch slot {
        case .a:
            loadedA = nil
            hasA = false
            nameA = "Image A"
            detailA = "Drop a picture"
            previewA = nil
        case .b:
            loadedB = nil
            hasB = false
            nameB = "Image B"
            detailB = "Drop a picture"
            previewB = nil
        }
        noteImagesChanged()
        schedulePaint(immediate: true)
    }

    func clearAll() {
        loadedA = nil
        loadedB = nil
        hasA = false
        hasB = false
        nameA = "Image A"
        nameB = "Image B"
        detailA = "Drop a picture"
        detailB = "Drop a picture"
        previewA = nil
        previewB = nil
        noteImagesChanged()
        schedulePaint(immediate: true)
        statusNote("Cleared.")
    }

    func openPairPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ImageFiles.contentTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.title = "Open Two Images"
        panel.prompt = "Open"
        begin(panel) { [weak self] in
            self?.load(urls: panel.urls)
        }
    }

    func openPanel(into slot: ImageSlot) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ImageFiles.contentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = slot == .a ? "Open Image A" : "Open Image B"
        panel.prompt = "Open"
        begin(panel) { [weak self] in
            guard let url = panel.url else { return }
            self?.load(url: url, into: slot)
        }
    }

    func savePanel() {
        guard canSave else {
            statusNote("Load two images first.")
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.title = "Save Difference"
        panel.nameFieldStringValue = suggestedName(jpeg: false)
        guard let window = NSApp.keyWindow ?? NSApp.windows.first else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.save(to: url)
        }
    }

    func save(to url: URL) {
        guard let a = loadedA, let b = loadedB else {
            statusNote("Load two images first.")
            return
        }
        let sources = [a.url, b.url].compactMap { $0 }
        if OutputGuard.collides(url, sources: sources) {
            statusNote("Won't overwrite a source image.")
            return
        }
        let ext = url.pathExtension.lowercased()
        let jpeg = ext == "jpg" || ext == "jpeg"
        let options = self.options
        let bufferA = a.buffer
        let bufferB = b.buffer
        let generation = imageGeneration
        statusNote("Painting full resolution…")
        paintQueue.async { [weak self] in
            let result = Painter.compare(
                bufferA,
                self?.sourceForCount(a: bufferA, b: bufferB, align: options.align, generation: generation) ?? bufferB,
                options: self?.locked(options) ?? options
            )
            do {
                try ImageCodec.write(result.image, to: url, jpeg: jpeg)
                DispatchQueue.main.async {
                    self?.statusNote("Wrote \(url.lastPathComponent) · \(result.image.width)×\(result.image.height).")
                }
            } catch {
                DispatchQueue.main.async {
                    self?.statusNote(error.localizedDescription)
                }
            }
        }
    }

    func copyImage() {
        guard let a = loadedA, let b = loadedB else {
            statusNote("Nothing to copy.")
            return
        }
        let options = self.options
        let bufferA = a.buffer
        let bufferB = b.buffer
        let generation = imageGeneration
        statusNote("Copying full resolution…")
        paintQueue.async { [weak self] in
            let result = Painter.compare(
                bufferA,
                self?.sourceForCount(a: bufferA, b: bufferB, align: options.align, generation: generation) ?? bufferB,
                options: self?.locked(options) ?? options
            )
            guard let image = ImageCodec.nsImage(result.image) else {
                DispatchQueue.main.async { self?.statusNote("Could not copy the image.") }
                return
            }
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([image])
                self?.statusNote("Copied \(result.image.width)×\(result.image.height).")
            }
        }
    }

    func suggestedName(jpeg: Bool) -> String {
        PaintInvocation.fileName(
            mode: options.mode,
            plane: options.plane,
            stamp: PaintInvocation.stamp(),
            jpeg: jpeg
        )
    }

    // One preview runs at a time. Moving a control bumps the ticket, the full-frame
    // count notices and quits, and the finish handler paints a single frame with the
    // latest options. The picture does not wait out a debounce or the full count.
    private func schedulePaint(immediate: Bool = false) {
        paintWork?.cancel()
        let ticket = bumpTicket()
        guard hasA, hasB else {
            resultImage = nil
            report = nil
            reportIsCurrent = false
            showingPreview = false
            isPainting = false
            return
        }
        if cachedCount?.key != compareKey(options) {
            reportIsCurrent = false
        }
        isPainting = true
        if immediate {
            kick(ticket: ticket)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.kick(ticket: ticket)
        }
        paintWork = work
        DispatchQueue.main.async(execute: work)
    }

    private func bumpTicket() -> Int {
        ticketLock.lock()
        paintTicket += 1
        let ticket = paintTicket
        ticketLock.unlock()
        return ticket
    }

    private func paintStale(_ ticket: Int) -> Bool {
        ticketLock.lock()
        defer { ticketLock.unlock() }
        return paintTicket != ticket
    }

    private func kick(ticket: Int) {
        guard ticket == paintTicket else { return }
        if paintingInBackground {
            paintDirty = true
            return
        }
        runPaint(ticket: ticket)
    }

    private func runPaint(ticket: Int) {
        guard ticket == paintTicket, let a = loadedA?.buffer, let b = loadedB?.buffer else {
            isPainting = false
            return
        }
        let options = self.options
        let epoch = statusEpoch
        let fullWidth = a.width
        let fullHeight = a.height
        let fullPixels = fullWidth * fullHeight
        let generation = imageGeneration
        let key = compareKey(options)
        let known = cachedCount?.key == key ? cachedCount?.differed : nil
        paintingInBackground = true
        paintDirty = false
        isPainting = true
        paintQueue.async { [weak self] in
            guard let self else { return }
            let live = self.livePreview(a: a, b: b, options: options, generation: generation)
            let preview = Painter.compare(live.a, live.b, options: live.options)
            let reduced = live.reduced
            let cg = ImageCodec.cgImage(preview.image)
            if let store = live.store {
                self.previewCache = store
            }
            let countNow = known != nil || !reduced
            if !countNow {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.paintTicket == ticket, !self.paintDirty else { return }
                    self.show(cg: cg, reduced: reduced)
                }
            }
            let differed: Int?
            if let known {
                differed = known
            } else if !reduced {
                differed = preview.differed
            } else if self.paintStale(ticket) {
                differed = nil
            } else {
                let sourceB = self.sourceForCount(a: a, b: b, align: options.align, generation: generation)
                differed = Painter.differCount(a, sourceB, options: self.locked(options)) { [weak self] in
                    self?.paintStale(ticket) ?? true
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.paintingInBackground = false
                if self.paintTicket != ticket || self.paintDirty {
                    self.paintDirty = false
                    if self.hasA, self.hasB {
                        self.runPaint(ticket: self.paintTicket)
                    } else {
                        self.isPainting = false
                    }
                    return
                }
                if countNow || self.resultImage == nil {
                    self.show(cg: cg, reduced: reduced)
                } else {
                    self.showingPreview = reduced
                }
                if let differed {
                    if known == nil, self.imageGeneration == generation {
                        self.cachedCount = (key, differed)
                    }
                    self.report = DifferenceReport(
                        differed: differed,
                        pixels: fullPixels,
                        width: fullWidth,
                        height: fullHeight
                    )
                    self.reportIsCurrent = true
                }
                self.isPainting = false
                if self.statusEpoch == epoch {
                    self.status = self.resultSentence()
                }
            }
        }
    }

    /// Fit's full-resolution B, cached for this pair. Lock returns B unchanged.
    private func sourceForCount(
        a: PixelBuffer,
        b: PixelBuffer,
        align: AlignMode,
        generation: UInt64
    ) -> PixelBuffer {
        if align != .fit || (b.width == a.width && b.height == a.height) {
            return b
        }
        if let fittedCache,
           fittedCache.generation == generation,
           fittedCache.align == align,
           fittedCache.width == a.width,
           fittedCache.height == a.height {
            return fittedCache.buffer
        }
        let scaled = b.scaledBilinear(width: a.width, height: a.height)
        fittedCache = FittedCache(
            generation: generation,
            align: align,
            width: a.width,
            height: a.height,
            buffer: scaled
        )
        return scaled
    }

    private func locked(_ options: PaintOptions) -> PaintOptions {
        var copy = options
        copy.align = .lock
        return copy
    }

    /// Preview-sized buffers. B is already on A's grid, so the paint itself uses Lock.
    private func livePreview(
        a: PixelBuffer,
        b: PixelBuffer,
        options: PaintOptions,
        generation: UInt64
    ) -> (a: PixelBuffer, b: PixelBuffer, options: PaintOptions, reduced: Bool, store: PreviewCache?) {
        if let previewCache, previewCache.generation == generation, previewCache.align == options.align {
            var shifted = options
            shifted.align = .lock
            if previewCache.stride > 1 {
                shifted.offsetX = options.offsetX / previewCache.stride
                shifted.offsetY = options.offsetY / previewCache.stride
            }
            return (previewCache.a, previewCache.b, shifted.sanitized(), previewCache.reduced, nil)
        }
        let prepared = Painter.preparePreview(a: a, b: b, options: options, maxSide: 1500)
        guard prepared.reduced else {
            return (prepared.a, prepared.b, prepared.options, false, nil)
        }
        let fitted: PixelBuffer
        if prepared.b.width == prepared.a.width && prepared.b.height == prepared.a.height {
            fitted = prepared.b
        } else if a.width == b.width && a.height == b.height {
            // Same pixels as A's grid. A full resample here is what made large pairs feel late.
            fitted = b.decimated(stride: prepared.stride)
        } else {
            fitted = b.scaledDisplay(width: prepared.a.width, height: prepared.a.height)
        }
        var shifted = prepared.options
        shifted.align = .lock
        let store = PreviewCache(
            generation: generation,
            align: options.align,
            stride: prepared.stride,
            a: prepared.a,
            b: fitted,
            reduced: true
        )
        return (prepared.a, fitted, shifted, true, store)
    }

    private func show(cg: CGImage?, reduced: Bool) {
        if let cg {
            resultImage = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
        showingPreview = reduced
    }

    private func compareKey(_ options: PaintOptions) -> CompareKey {
        CompareKey(
            channel: options.channel,
            align: options.align,
            slack: options.slack,
            offsetX: options.offsetX,
            offsetY: options.offsetY,
            generation: imageGeneration
        )
    }

    private func noteImagesChanged() {
        imageGeneration &+= 1
        cachedCount = nil
        let generation = imageGeneration
        // previewCache is only touched on the paint queue.
        paintQueue.async { [weak self] in
            guard let self else { return }
            if self.previewCache?.generation != generation {
                self.previewCache = nil
            }
            if self.fittedCache?.generation != generation {
                self.fittedCache = nil
            }
        }
    }

    private func resultSentence() -> String {
        guard let report else { return status }
        var line = DecimalText.summary(
            differed: report.differed,
            pixels: report.pixels,
            width: report.width,
            height: report.height
        )
        if showingPreview { line += " · preview grid" }
        return line
    }

    private func assign(_ loaded: LoadedImage, thumb: NSImage?, into slot: ImageSlot) {
        let detail = sizeDetail(loaded)
        switch slot {
        case .a:
            loadedA = loaded
            hasA = true
            nameA = loaded.name
            detailA = detail
            previewA = thumb
        case .b:
            loadedB = loaded
            hasB = true
            nameB = loaded.name
            detailB = detail
            previewB = thumb
        }
        noteImagesChanged()
    }

    private func sizeDetail(_ image: LoadedImage) -> String {
        var line = "\(image.buffer.width)×\(image.buffer.height)"
        if image.capped { line += " · capped at \(ImageCodec.maxSide)" }
        return line
    }

    private func clampNudge() {
        let limit = nudgeLimit
        guard abs(options.offsetX) > limit || abs(options.offsetY) > limit else { return }
        var next = options
        next.offsetX = min(limit, max(-limit, next.offsetX))
        next.offsetY = min(limit, max(-limit, next.offsetY))
        options = next
    }

    private func statusNote(_ message: String) {
        statusEpoch += 1
        status = message
    }

    private func begin(_ panel: NSOpenPanel, done: @escaping () -> Void) {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first else {
            if panel.runModal() == .OK { done() }
            return
        }
        panel.beginSheetModal(for: window) { response in
            if response == .OK { done() }
        }
    }

    private static func previewBuffer(_ buffer: PixelBuffer, maxSide: Int) -> PixelBuffer {
        let long = max(buffer.width, buffer.height)
        guard long > maxSide, maxSide > 0 else { return buffer }
        let scale = Double(maxSide) / Double(long)
        let width = max(1, Int((Double(buffer.width) * scale).rounded()))
        let height = max(1, Int((Double(buffer.height) * scale).rounded()))
        return buffer.scaledDisplay(width: width, height: height)
    }
}
