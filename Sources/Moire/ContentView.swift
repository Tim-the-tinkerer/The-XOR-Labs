import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            stage
            transport
            footer
        }
        .background(Theme.bg)
        .onDrop(of: [.fileURL, .movie, .item], isTargeted: nil) { providers in
            accept(providers, into: nil)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                clipWell(.a, clip: model.clipA, tint: Theme.magenta, title: "A")
                clipWell(.b, clip: model.clipB, tint: Theme.cyan, title: "B")
            }
            HStack(spacing: 8) {
                ForEach(PlaceMode.allCases) { mode in
                    Button(mode.title) { model.setMode(mode) }
                        .buttonStyle(MoireButtonStyle(kind: model.mode == mode ? .primary : .secondary))
                        .disabled(model.busy)
                        .help(mode.caption)
                }
                Spacer()
                Button("Sample") { model.loadSample() }
                    .buttonStyle(MoireButtonStyle(kind: .ghost))
                    .disabled(model.busy)
                    .help("A red square crosses a blue square. Overlap is magenta.")
                Button("Swap") { model.swapClips() }
                    .buttonStyle(MoireButtonStyle(kind: .ghost))
                    .disabled(model.busy || (model.clipA == nil && model.clipB == nil))
                Button("Clear") { model.clearAll() }
                    .buttonStyle(MoireButtonStyle(kind: .ghost))
                    .disabled(model.busy || (model.clipA == nil && model.clipB == nil))
                    .help("Clear both videos. ⌘K")
            }
            HStack(spacing: 12) {
                Text("Turn")
                    .foregroundStyle(Theme.muted)
                Picker("Turn", selection: Binding(
                    get: { model.mix.turn },
                    set: { model.setTurn($0) }
                )) {
                    ForEach(QuarterTurn.allCases) { turn in
                        Text(turn.title).tag(turn)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 180)
                .disabled(model.busy)
                .help("Turns B clockwise before it is placed. 90° sends the top edge to the right.")
                Toggle("Flip H", isOn: Binding(
                    get: { model.mix.flipHorizontal },
                    set: { model.setFlipHorizontal($0) }
                ))
                .toggleStyle(.checkbox)
                .disabled(model.busy)
                .help("Mirrors B left to right.")
                Toggle("Flip V", isOn: Binding(
                    get: { model.mix.flipVertical },
                    set: { model.setFlipVertical($0) }
                ))
                .toggleStyle(.checkbox)
                .disabled(model.busy)
                .help("Mirrors B top to bottom.")
                Spacer()
                Button("Reset Offset") { model.resetOffset() }
                    .buttonStyle(MoireButtonStyle(kind: .ghost))
                    .disabled(model.busy || model.mix.offsetIsCentered)
                    .help("Put Offset X and Offset Y back at zero. ⌘0")
            }
            .font(.system(size: 11))
            HStack(spacing: 16) {
                mixSlider(
                    "Scale",
                    value: Binding(get: { model.mix.scale }, set: { model.setScale($0) }),
                    range: 0.25...2,
                    label: "\(Int((model.mix.scale * 100).rounded()))%",
                    help: "Scales the placed copy of B. 100% leaves the size alone. Gaps stay A's picture."
                )
                mixSlider(
                    "Offset X",
                    value: Binding(get: { model.mix.offsetX }, set: { model.setOffsetX($0) }),
                    range: -0.5...0.5,
                    label: signedPercent(model.mix.offsetX),
                    help: "Slides B sideways, as a fraction of A's width. Positive moves right."
                )
            }
            HStack(spacing: 16) {
                mixSlider(
                    "Offset Y",
                    value: Binding(get: { model.mix.offsetY }, set: { model.setOffsetY($0) }),
                    range: -0.5...0.5,
                    label: signedPercent(model.mix.offsetY),
                    help: "Slides B up or down, as a fraction of A's height. Positive moves down."
                )
                mixSlider(
                    "Delay",
                    value: Binding(get: { model.mix.delay }, set: { model.setDelay($0) }),
                    range: 0...5,
                    label: MoireFormat.clock(model.mix.delay),
                    help: "XOR with an earlier frame of B. The sound stays on A's clock."
                )
            }
            Text(model.mode.caption)
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
            Text(model.mix.summary)
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
        }
        .padding(16)
        .background(Theme.panel)
    }

    private var stage: some View {
        ZStack {
            FrameScreen(image: model.preview)
            if model.preview == nil {
                VStack(spacing: 6) {
                    Text("Drop two videos")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text("The XOR plays here. Matching color goes black.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.55))
    }

    private var transport: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button(model.playing ? "Pause" : "Play") { model.togglePlay() }
                    .buttonStyle(MoireButtonStyle(kind: .primary))
                    .disabled(!model.ready)
                Text(MoireFormat.clock(model.time))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.text)
                    .frame(width: 64, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { model.time },
                        set: { model.seek(to: $0) }
                    ),
                    in: 0...max(model.duration, 0.01)
                )
                .disabled(!model.ready)
                Text(MoireFormat.clock(model.duration))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.muted)
                    .frame(width: 64, alignment: .trailing)
            }
            HStack(spacing: 16) {
                Toggle("Loop", isOn: $model.loop)
                    .toggleStyle(.checkbox)
                    .disabled(model.busy)
                Toggle("Match Length", isOn: Binding(
                    get: { model.matchLengths },
                    set: { model.setMatchLengths($0) }
                ))
                .toggleStyle(.checkbox)
                .disabled(model.busy)
                .help("End at the shorter video. The longer tail is left out, picture and sound. ⌘7")
                Text("Sound")
                    .foregroundStyle(Theme.muted)
                Picker("Sound", selection: Binding(
                    get: { model.soundMode },
                    set: { model.setSoundMode($0) }
                )) {
                    ForEach(SoundMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 220)
                .disabled(model.busy)
                .help(model.soundMode.caption)
                Spacer()
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.text)
            Text(model.soundMode.caption)
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.panel)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if model.busy && model.progress > 0 && model.progress < 1 {
                Button("Cancel") { model.cancelWork() }
                    .buttonStyle(MoireButtonStyle(kind: .ghost))
            } else {
                Button("Save Movie…") { model.savePanel() }
                    .buttonStyle(MoireButtonStyle(kind: .primary))
                    .disabled(!model.ready)
            }
            if model.busy && model.progress > 0 {
                ProgressView(value: model.progress)
                    .frame(width: 120)
            }
            Text(model.status)
                .font(.system(size: 11))
                .foregroundStyle(model.statusIsError ? Theme.magenta : Theme.muted)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.bg)
    }

    private func clipWell(_ slot: AppModel.Slot, clip: ClipFacts?, tint: Color, title: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(tint)
            Text(clip?.displayName ?? "Drop a video")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(clip == nil ? Theme.muted : Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(meta(clip))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.field)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(tint.opacity(clip == nil ? 0.35 : 0.9), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture { model.openPanel(into: slot) }
        .onDrop(of: [.fileURL, .movie, .item], isTargeted: nil) { providers in
            accept(providers, into: slot)
        }
        .help("Drop a video, or click to open one.")
    }

    private func signedPercent(_ value: Double) -> String {
        let mark = Int((value * 100).rounded())
        return mark > 0 ? "+\(mark)%" : "\(mark)%"
    }

    private func mixSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        label: String,
        help: String
    ) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .foregroundStyle(Theme.muted)
                .frame(width: 54, alignment: .leading)
            Slider(value: value, in: range)
                .controlSize(.small)
                .disabled(model.busy)
            Text(label)
                .foregroundStyle(Theme.text)
                .frame(width: 48, alignment: .trailing)
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .help(help)
    }

    private func meta(_ clip: ClipFacts?) -> String {
        guard let clip else { return "mov, mp4, mkv, webm" }
        return "\(clip.orientedWidth)×\(clip.orientedHeight) · \(MoireFormat.fps(clip.framesPerSecond)) fps · \(MoireFormat.clock(clip.durationSeconds))"
    }

    private func accept(_ providers: [NSItemProvider], into slot: AppModel.Slot?) -> Bool {
        guard !model.busy, !providers.isEmpty else { return false }
        let lock = NSLock()
        var urls: [URL] = []
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            resolve(provider) { url in
                defer { group.leave() }
                guard let url else { return }
                lock.lock()
                urls.append(url)
                lock.unlock()
            }
        }
        group.notify(queue: .main) {
            if urls.isEmpty {
                model.report("That drop didn't include a video file.")
                return
            }
            if let slot, let first = urls.first, urls.count == 1 {
                model.load(first, into: slot)
            } else {
                model.load(urls: urls)
            }
        }
        return true
    }

    private func resolve(_ provider: NSItemProvider, completion: @escaping (URL?) -> Void) {
        let fileURL = UTType.fileURL.identifier
        if provider.hasItemConformingToTypeIdentifier(fileURL) {
            provider.loadItem(forTypeIdentifier: fileURL, options: nil) { item, _ in
                completion(DropURL.resolve(item))
            }
            return
        }
        let movie = UTType.movie.identifier
        guard provider.hasItemConformingToTypeIdentifier(movie) else {
            completion(nil)
            return
        }
        // A movie promise is deleted when this callback returns, so copy it first.
        provider.loadFileRepresentation(forTypeIdentifier: movie) { url, _ in
            guard let url else {
                completion(nil)
                return
            }
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("MoireDrop-\(UUID().uuidString).\(url.pathExtension.isEmpty ? "mov" : url.pathExtension)")
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: url, to: dest)
                completion(dest)
            } catch {
                completion(nil)
            }
        }
    }
}

struct FrameScreen: NSViewRepresentable {
    var image: NSImage?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.contentsGravity = .resizeAspect
        view.layer?.backgroundColor = NSColor.black.cgColor
        view.layer?.magnificationFilter = .trilinear
        view.layer?.minificationFilter = .trilinear
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        view.layer?.contents = image
    }
}
