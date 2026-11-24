import Combine
import SwiftUI
import UniformTypeIdentifiers

private final class DropTargetState: ObservableObject {
    @Published var overA = false
    @Published var overB = false
}

struct ContentView: View {
    @ObservedObject private var model = CrosstalkModel.shared
    @StateObject private var dropTargets = DropTargetState()

    private func dropTarget(_ keyPath: ReferenceWritableKeyPath<DropTargetState, Bool>) -> Binding<Bool> {
        let state = dropTargets
        return Binding(get: { state[keyPath: keyPath] }, set: { state[keyPath: keyPath] = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.line).frame(height: 1)
            ScrollView {
                VStack(spacing: 14) {
                    scopeCard
                    HStack(alignment: .top, spacing: 14) {
                        sourceCard.frame(maxWidth: .infinity)
                        operationCard.frame(maxWidth: .infinity)
                        listenCard.frame(width: 280)
                    }
                }
                .padding(16)
            }
            footer
        }
        .background(Theme.bg)
        .preferredColorScheme(.dark)
        .onReceive(Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()) { _ in
            model.tick()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("CROSSTALK")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .tracking(2.2)
                        .foregroundColor(Theme.copper)
                    Text("XOR the channels of one file, a waveform with itself, two files, or a channel with a delayed copy of itself.")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 640, alignment: .leading)
                }
                Spacer(minLength: 12)
                status
                playButton
            }
            HStack(spacing: 8) {
                Chip(title: "Channels", on: model.mode == .channels, expands: false) { model.setMode(.channels) }
                Chip(title: "Waveform", on: model.mode == .waveform, expands: false) { model.setMode(.waveform) }
                Chip(title: "Files", on: model.mode == .files, expands: false) { model.setMode(.files) }
                Chip(title: "Delay", on: model.mode == .delay, expands: false) { model.setMode(.delay) }
                Spacer()
                if model.hasFile {
                    Chip(title: "Tones", on: false, expands: false) { model.clearToTones() }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Theme.bgElev)
    }

    private var status: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if let error = model.errorText, !error.isEmpty {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.danger)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(3)
                    .frame(maxWidth: 300, alignment: .trailing)
            } else if let notice = model.noticeText, !notice.isEmpty {
                Text(notice)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(Theme.erase)
                    .lineLimit(2)
                    .frame(maxWidth: 300, alignment: .trailing)
            } else {
                Text(model.isRendering ? "XORING" : (model.isPlaying ? "PLAYING" : "READY"))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(model.isPlaying || model.isRendering ? Theme.copper : Theme.muted)
            }
        }
    }

    private var playButton: some View {
        Button(action: { model.togglePlay() }) {
            ZStack {
                Circle()
                    .fill(model.isPlaying ? Theme.copper : Theme.copper.opacity(0.14))
                    .frame(width: 52, height: 52)
                Circle()
                    .stroke(Theme.copper, lineWidth: 1.5)
                    .frame(width: 52, height: 52)
                Image(systemName: model.isPlaying ? "stop.fill" : "play.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(model.isPlaying ? Theme.bg : Theme.copper)
                    .offset(x: model.isPlaying ? 0 : 1)
            }
        }
        .buttonStyle(.plain)
        .help(model.isPlaying ? "Stop" : "Play")
        .accessibilityLabel(model.isPlaying ? "Stop" : "Play")
    }

    private var scopeCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Text(model.meta)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(Theme.muted)
                legendDot(Theme.steel, legend.0)
                legendDot(Theme.lilac, legend.1)
                legendDot(model.erased ? Theme.erase : Theme.copper, "XOR")
                Spacer()
                if model.isRendering {
                    Text("XORING")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(Theme.copper)
                }
            }
            ScopeView(picture: model.picture, erased: model.erased)
            BitStrip(
                picture: model.picture,
                labels: legend,
                heading: model.isPlaying ? "Now" : "Loudest"
            )
            Text(model.caption)
                .font(.system(size: 12))
                .foregroundColor(model.erased ? Theme.erase : Theme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))
    }

    private var legend: (String, String, String) {
        if model.mode != .files && model.sourcePick == .both {
            return ("A", "B", "XOR")
        }
        switch model.mode {
        case .channels:
            return ("Left", "Right", "XOR")
        case .waveform:
            return ("Wave", model.fold == .reverse ? "Reverse" : "Other half", "XOR")
        case .files:
            return ("A", "B", "XOR")
        case .delay:
            return ("Now", "Delayed", "XOR")
        }
    }

    private func legendDot(_ color: Color, _ name: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(name)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(Theme.muted)
        }
    }

    private var sourceCard: some View {
        card("Source") {
            well(
                title: model.isLoadingA ? "Reading…" : model.titleA,
                detail: model.detailA,
                targeted: dropTargets.overA,
                hint: "First file"
            )
            .onDrop(of: [.fileURL], isTargeted: dropTarget(\.overA)) { takeDrop($0, slot: .source) }
            Button("Open…") { model.openPanel(slot: .source) }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.copper)
            well(
                title: model.isLoadingB ? "Reading…" : model.titleB,
                detail: model.detailB,
                targeted: dropTargets.overB,
                hint: "Second file"
            )
            .onDrop(of: [.fileURL], isTargeted: dropTarget(\.overB)) { takeDrop($0, slot: .other) }
            Button("Open Second File…") { model.openPanel(slot: .other) }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.copper)
            if model.mode != .files {
                HStack(spacing: 8) {
                    Text("Hear")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.muted)
                    Chip(title: "First", on: model.sourcePick == .first) { model.setSourcePick(.first) }
                    Chip(title: "Second", on: model.sourcePick == .second) { model.setSourcePick(.second) }
                    Chip(title: "Both", on: model.sourcePick == .both) { model.setSourcePick(.both) }
                }
                Text("First hears the top file. Second hears the other. Both runs this mode on each file, then XORs those results. The shorter one sets the length.")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var operationCard: some View {
        card(model.mode.label) {
            switch model.mode {
            case .channels:
                Text("Left XOR right, one sample at a time. Where the bits agree, they become zero. A mono file has the same waveform on both sides, so the result is silence.")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            case .waveform:
                HStack(spacing: 8) {
                    Chip(title: "Reverse", on: model.fold == .reverse) { model.setFold(.reverse) }
                    Chip(title: "Halves", on: model.fold == .halves) { model.setFold(.halves) }
                }
                Text(model.fold == .reverse
                     ? "Each sample XOR the one across from it. The built-in tone does not agree with its reverse."
                     : "The first half XOR the second half. The built-in tone is the same waveform twice, so the halves agree and XOR erases them.")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            case .files:
                HStack(spacing: 8) {
                    Chip(title: "Shorter", on: model.span == .shorter) { model.setSpan(.shorter) }
                    Chip(title: "Longer", on: model.span == .longer) { model.setSpan(.longer) }
                    Chip(title: "Loop", on: model.span == .loop) { model.setSpan(.loop) }
                }
                labeledValue("Slip", slipText)
                Slider(
                    value: Binding(get: { model.slipMs }, set: { model.setSlip($0) }),
                    in: -AppInfo.maxSlipMilliseconds...AppInfo.maxSlipMilliseconds
                )
                .tint(Theme.copper)
                Text("Positive slip starts the second file later, in whole samples. Shorter keeps the overlap. Longer fills a gap with zero. Loop repeats the shorter file.")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            case .delay:
                delayControls
            }
        }
    }

    private var delayControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Chip(title: "10 ms", on: model.delayIsTen) { model.setDelay(10) }
                Chip(title: "20 ms", on: model.delayIsTwenty) { model.setDelay(20) }
                Chip(title: "50 ms", on: model.delayIsFifty) { model.setDelay(50) }
                Chip(title: "Stack", on: model.stacked) { model.toggleStack() }
            }
            labeledValue("Time", Caption.millisecondsText(model.delayMs))
                .opacity(model.stacked ? 0.4 : 1)
            Slider(
                value: Binding(get: { model.delayMs }, set: { model.setDelay($0) }),
                in: 0...AppInfo.delaySliderMax
            )
            .tint(Theme.copper)
            .disabled(model.stacked)
            .opacity(model.stacked ? 0.4 : 1)
            labeledValue("Sweep", String(format: "%.2f Hz", model.sweepHz))
                .opacity(model.stacked ? 0.4 : 1)
            Slider(
                value: Binding(get: { model.sweepHz }, set: { model.setSweepHz($0) }),
                in: 0...AppInfo.maxSweepHz
            )
            .tint(Theme.steel)
            .disabled(model.stacked)
            .opacity(model.stacked ? 0.4 : 1)
            labeledValue("Depth", Caption.millisecondsText(model.sweepDepth))
                .opacity(model.stacked ? 0.4 : 1)
            Slider(
                value: Binding(get: { model.sweepDepth }, set: { model.setSweepDepth($0) }),
                in: 0...AppInfo.maxSweepDepthMilliseconds
            )
            .tint(Theme.steel)
            .disabled(model.stacked)
            .opacity(model.stacked ? 0.4 : 1)
            if model.showsBlend {
                Chip(title: "Blend", on: model.blendEnabled) { model.toggleBlend() }
                if model.blendEnabled {
                    labeledValue("Toward right", String(format: "%.2f", model.blend))
                    Slider(
                        value: Binding(get: { Double(model.blend) }, set: { model.setBlend(Float($0)) }),
                        in: 0...1
                    )
                    .tint(Theme.copper)
                }
            } else if model.showsToneSlider {
                labeledValue("Frequency", Caption.frequencyText(model.toneHz))
                Slider(
                    value: Binding(get: { model.toneHz }, set: { model.setToneHz($0) }),
                    in: AppInfo.minToneHz...AppInfo.maxToneHz
                )
                .tint(Theme.copper)
            }
            HStack(spacing: 8) {
                Chip(title: "Both", on: model.ears == .both) { model.setEars(.both) }
                Chip(title: "Left only", on: model.ears == .leftOnly) { model.setEars(.leftOnly) }
            }
            Text(delayNote)
                .font(.system(size: 12))
                .foregroundColor(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var delayNote: String {
        if model.stacked {
            return "10 ms, then 20 ms, then 50 ms. Each stage XORs the previous result with a delayed copy of itself. Sweep stays still."
        }
        var lines = [
            "Each sample is XORed with the one from this long ago. Depth moves that delay across the file, in whole samples.",
        ]
        if model.showsToneSlider {
            lines.append("220 Hz at 50 ms is 11 cycles, so that tone is erased.")
        }
        if model.showsBlend && model.blendEnabled {
            if model.sourceIsMono {
                lines.append("This file is one channel, so the two sides already match.")
            } else {
                lines.append("0 is the left channel. 1 is the right. Mixed before the XOR.")
            }
        }
        if model.ears == .leftOnly {
            lines.append("The right channel stays as it was, so you can compare.")
        }
        return lines.joined(separator: " ")
    }

    private var slipText: String {
        let samples = model.slipSamples
        if samples == 0 { return "0" }
        let sign = samples > 0 ? "+" : ""
        return "\(sign)\(samples) samples"
    }

    private var listenCard: some View {
        card("Listen") {
            HStack(spacing: 8) {
                Chip(title: "16-bit", on: model.bits == 16) { model.setBits(16) }
                Chip(title: "8-bit", on: model.bits == 8) { model.setBits(8) }
            }
            labeledValue("Playback", String(format: "%.2f", model.gain))
            Slider(
                value: Binding(get: { Double(model.gain) }, set: { model.setGain(Float($0)) }),
                in: 0...1
            )
            .tint(Theme.copper)
            Text(XORMath.fact)
                .font(.system(size: 12))
                .foregroundColor(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            labeledValue("Loop", model.loopClock)
            HStack(spacing: 8) {
                TextField(
                    "seconds",
                    value: Binding(get: { model.loopSeconds }, set: { model.setLoopSeconds($0) }),
                    format: .number.precision(.fractionLength(0))
                )
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
                .textFieldStyle(.roundedBorder)
                Text("sec")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Theme.muted)
                Slider(
                    value: Binding(get: { model.loopSeconds }, set: { model.setLoopSeconds($0) }),
                    in: 1...AppInfo.maxSongSeconds,
                    step: 1
                )
                .tint(Theme.copper)
            }
            Text("The XOR repeats until this time, up to 10 minutes. A last pass that does not fit is cut.")
                .font(.system(size: 12))
                .foregroundColor(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: { model.exportLoop() }) {
                Text(model.isExporting ? "Exporting…" : "Export loop")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(Theme.bg)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.copper))
            }
            .buttonStyle(.plain)
            .disabled(model.isExporting || model.isRendering)
            .help("Write the XOR again until the time limit. The original stays where it is.")
            Button(action: { model.exportWAV() }) {
                Text("Export one pass")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(Theme.text)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Theme.line, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .disabled(model.isExporting || model.isRendering)
            .help("Write the XOR once. At 16-bit, with matching rates, this is the file you can XOR back.")
        }
    }

    private func well(title: String, detail: String, targeted: Bool, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(hint)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(Theme.muted)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.text)
                .lineLimit(1)
            Text(detail)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Theme.muted)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(targeted ? Theme.copper.opacity(0.12) : Color.black.opacity(0.22))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(targeted ? Theme.copper : Theme.line, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        )
    }

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(Theme.muted)
            content()
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))
    }

    private func labeledValue(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name)
                .font(.system(size: 12))
                .foregroundColor(Theme.muted)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(Theme.text)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Space play  ·  1 2 3 4 mode  ·  R H fold  ·  S L P length  ·  T stack  ·  B blend")
            Text("⌘O open  ·  ⌘⇧O second  ·  ⌘E one pass  ·  ⌘⇧E loop  ·  ⌘K tones")
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundColor(Theme.muted)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
    }

    private func takeDrop(_ providers: [NSItemProvider], slot: LoadSlot) -> Bool {
        let loaders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !loaders.isEmpty else { return false }
        let group = DispatchGroup()
        let lock = NSLock()
        var found = [URL?](repeating: nil, count: loaders.count)
        for (index, provider) in loaders.enumerated() {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                let url: URL?
                if let direct = item as? URL {
                    url = direct
                } else if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let text = item as? String {
                    url = URL(string: text)
                } else {
                    url = nil
                }
                lock.lock()
                found[index] = url
                lock.unlock()
            }
        }
        group.notify(queue: .main) {
            model.receive(found.compactMap { $0 }, preferring: slot)
        }
        return true
    }
}

private struct Chip: View {
    var title: String
    var on: Bool
    var expands: Bool = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(on ? Theme.bg : Theme.text)
                .frame(maxWidth: expands ? .infinity : nil)
                .padding(.horizontal, expands ? 0 : 12)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(on ? Theme.copper : Theme.chip))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? Theme.copper : Theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

private struct BitStrip: View {
    var picture: WavePicture
    var labels: (String, String, String)
    var heading: String

    var body: some View {
        VStack(spacing: 3) {
            row(labels.0, picture.qA, on: Theme.steel)
            row(labels.1, picture.qB, on: Theme.lilac)
            row(labels.2, picture.qX, on: Theme.copper)
        }
        .help(heading)
        .accessibilityLabel("\(heading). \(labels.2) \(picture.qX)")
    }

    private func row(_ name: String, _ value: Int32, on: Color) -> some View {
        HStack(spacing: 3) {
            Text(name)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(Theme.muted)
                .frame(width: 64, alignment: .leading)
            ForEach(0..<picture.bits, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(bitOn(value, shift: picture.bits - 1 - index) ? on : Color.white.opacity(0.06))
                    .frame(height: 11)
            }
        }
    }

    private func bitOn(_ value: Int32, shift: Int) -> Bool {
        (Int(value) >> shift) & 1 == 1
    }
}

private struct ScopeView: View {
    var picture: WavePicture
    var erased: Bool

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            context.fill(Path(roundedRect: rect, cornerRadius: 8), with: .color(Color.black.opacity(0.28)))
            let peak = displayPeak()
            let mid = size.height / 2
            var axis = Path()
            axis.move(to: CGPoint(x: 0, y: mid))
            axis.addLine(to: CGPoint(x: size.width, y: mid))
            context.stroke(axis, with: .color(Theme.line.opacity(0.7)), lineWidth: 1)
            func y(_ value: Float) -> CGFloat {
                mid - CGFloat(value / peak) * (size.height * 0.46)
            }
            if picture.peaked {
                strokePeaks(picture.aLo, picture.aHi, size: size, y: y, context: context, color: Theme.steel, lineWidth: 1.2)
                strokePeaks(picture.bLo, picture.bHi, size: size, y: y, context: context, color: Theme.lilac.opacity(0.85), lineWidth: 1.2)
                strokePeaks(picture.xLo, picture.xHi, size: size, y: y, context: context, color: erased ? Theme.erase : Theme.copper, lineWidth: 1.5)
            } else {
                strokeLine(picture.aHi, width: size.width, y: y, context: context, color: Theme.steel, lineWidth: 1.25)
                strokeLine(picture.bHi, width: size.width, y: y, context: context, color: Theme.lilac.opacity(0.9), lineWidth: 1.25)
                strokeLine(picture.xHi, width: size.width, y: y, context: context, color: erased ? Theme.erase : Theme.copper, lineWidth: 1.6)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 160)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func displayPeak() -> Float {
        var peak: Float = 0.001
        for value in picture.aLo { peak = max(peak, abs(value)) }
        for value in picture.aHi { peak = max(peak, abs(value)) }
        for value in picture.bLo { peak = max(peak, abs(value)) }
        for value in picture.bHi { peak = max(peak, abs(value)) }
        for value in picture.xLo { peak = max(peak, abs(value)) }
        for value in picture.xHi { peak = max(peak, abs(value)) }
        return peak
    }

    private func strokeLine(
        _ samples: [Float],
        width: CGFloat,
        y: (Float) -> CGFloat,
        context: GraphicsContext,
        color: Color,
        lineWidth: CGFloat
    ) {
        guard samples.count > 1, width > 2 else { return }
        var path = Path()
        for index in 0..<samples.count {
            let point = CGPoint(
                x: width * CGFloat(index) / CGFloat(samples.count - 1),
                y: y(samples[index])
            )
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
    }

    private func strokePeaks(
        _ lo: [Float],
        _ hi: [Float],
        size: CGSize,
        y: (Float) -> CGFloat,
        context: GraphicsContext,
        color: Color,
        lineWidth: CGFloat
    ) {
        let n = min(lo.count, hi.count)
        guard n > 0 else { return }
        var path = Path()
        for index in 0..<n {
            let x = size.width * (CGFloat(index) + 0.5) / CGFloat(n)
            var y0 = y(hi[index])
            var y1 = y(lo[index])
            if abs(y0 - y1) < 0.75 {
                y0 -= 0.6
                y1 += 0.6
            }
            path.move(to: CGPoint(x: x, y: y0))
            path.addLine(to: CGPoint(x: x, y: y1))
        }
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
    }
}
