import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

private final class DropTargetState: ObservableObject {
    @Published var overA = false
    @Published var overB = false
    @Published var overStage = false
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @StateObject private var dropTargets = DropTargetState()

    private func dropTarget(_ keyPath: ReferenceWritableKeyPath<DropTargetState, Bool>) -> Binding<Bool> {
        let state = dropTargets
        return Binding(get: { state[keyPath: keyPath] }, set: { state[keyPath: keyPath] = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            hairline
            HStack(spacing: 0) {
                sources
                    .frame(width: 248)
                hairlineV
                stage
                hairlineV
                inspector
                    .frame(width: 292)
            }
            hairline
            footer
        }
        .background(Theme.bg)
        .preferredColorScheme(.dark)
        .tint(Theme.amber)
    }

    private var hairline: some View {
        Rectangle().fill(Theme.line.opacity(0.7)).frame(height: 1)
    }

    private var hairlineV: some View {
        Rectangle().fill(Theme.line.opacity(0.7)).frame(width: 1)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text("PARITY PAINTER")
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .tracking(3)
                    .foregroundStyle(Theme.paper)
                Text("Black where they match. White where they differ.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.muted)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(model.heroNumber)
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.paper)
                    .opacity(model.report == nil || model.reportIsCurrent ? 1 : 0.4)
                Text(model.heroCaption)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(Theme.amber)
            }
            Button("Save") { model.savePanel() }
                .buttonStyle(ParityButtonStyle(kind: .primary))
                .disabled(!model.canSave)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Theme.panel)
    }

    private var sources: some View {
        VStack(spacing: 0) {
            well(.a, over: dropTarget(\.overA))
            swapRow
            well(.b, over: dropTarget(\.overB))
        }
        .background(Theme.panel)
    }

    private var swapRow: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Theme.line.opacity(0.7)).frame(height: 1)
            Button {
                model.swap()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.arrow.down")
                    Text("Swap")
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.text)
            }
            .buttonStyle(.plain)
            .disabled(!model.hasA && !model.hasB)
            .help("Swap A and B. The nudge flips so the overlap stays put.")
            Rectangle().fill(Theme.line.opacity(0.7)).frame(height: 1)
        }
        .padding(.horizontal, 12)
    }

    private func well(_ slot: ImageSlot, over: Binding<Bool>) -> some View {
        let isA = slot == .a
        let image = isA ? model.previewA : model.previewB
        let accent = isA ? Theme.amber : Theme.steel
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(isA ? "A" : "B")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(accent)
                Text(isA ? model.nameA : model.nameB)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Button("Open") { model.openPanel(into: slot) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.muted)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.field)
                if let image {
                    StillImage(image: image, interpolation: .medium)
                        .equatable()
                        .padding(8)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "photo")
                            .font(.system(size: 22, weight: .light))
                        Text(isA ? "Drop image A" : "Drop image B")
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(Theme.muted)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        over.wrappedValue ? accent : Theme.line.opacity(0.85),
                        style: StrokeStyle(lineWidth: over.wrappedValue ? 1.5 : 1, dash: image == nil ? [4, 3] : [])
                    )
            )
            .onDrop(of: [.fileURL], isTargeted: over) { providers in
                collectFileURLs(providers) { urls in
                    guard let first = urls.first else { return }
                    model.load(url: first, into: slot)
                    if urls.count > 1 {
                        model.load(url: urls[1], into: isA ? .b : .a)
                    }
                }
            }
            HStack {
                Text(isA ? model.detailA : model.detailB)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                Spacer()
                if isA ? model.hasA : model.hasB {
                    Button("Clear") { model.clear(slot) }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.muted)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxHeight: .infinity)
    }

    private var stage: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(model.canSave ? model.recipe : "DIFFERENCE")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                Spacer()
                if model.isPainting {
                    Text("PAINTING")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.amber)
                }
            }
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.stage)
                if let image = model.resultImage {
                    StillImage(image: image, interpolation: .medium)
                        .equatable()
                        .padding(12)
                } else {
                    VStack(spacing: 8) {
                        Text(emptyTitle)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.text)
                        Text(emptyDetail)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.muted)
                            .multilineTextAlignment(.center)
                    }
                    .padding(24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(dropTargets.overStage ? Theme.paper.opacity(0.8) : Theme.line.opacity(0.8), lineWidth: 1)
            )
            .onDrop(of: [.fileURL], isTargeted: dropTarget(\.overStage)) { providers in
                collectFileURLs(providers) { urls in
                    model.load(urls: urls)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }

    private var emptyTitle: String {
        if !model.hasA && !model.hasB { return "Drop two images" }
        if model.hasA != model.hasB { return "Drop the second image" }
        return "Painting…"
    }

    private var emptyDetail: String {
        if model.hasA && model.hasB { return "The difference will land here." }
        return "Black where a pixel matches.\nWhite where it does not."
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("VIEW")
                    chipRow(PaintMode.allCases.map { mode in
                        (mode.title, model.options.mode == mode, mode.caption, { model.update { $0.mode = mode } })
                    })
                    Text(model.options.mode.caption)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("CHANNEL")
                    chipRow([
                        (.rgb, "All"), (.red, "R"), (.green, "G"), (.blue, "B"), (.luma, "Y"),
                    ].map { channel, title in
                        (title, model.options.channel == channel, channel.title, { model.update { $0.channel = channel } })
                    })
                }

                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("BIT PLANE")
                    HStack(spacing: 4) {
                        ForEach(0..<8, id: \.self) { bit in
                            bitButton(bit)
                        }
                    }
                    Text(model.options.plane == 0 ? "Bit 0 · finest grain" : "Bit \(model.options.plane) · coarser")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                }

                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("ALIGN")
                    chipRow(AlignMode.allCases.map { align in
                        (align.title, model.options.align == align, align.caption, { model.update { $0.align = align } })
                    })
                    Text(model.options.align.caption)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        sectionLabel("SLACK")
                        Spacer()
                        Text(model.options.slack == 0 ? "exact" : "\(model.options.slack)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.paper)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(model.options.slack) },
                            set: { value in model.update { $0.slack = Int(value.rounded()) } }
                        ),
                        in: 0...48,
                        step: 1
                    )
                    Text("Gaps at or under this stay a match. Use it to quiet JPEG noise.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("LIFT")
                    chipRow(PaintOptions.lifts.map { lift in
                        ("\(lift)", model.options.lift == lift, "Lift ×\(lift). Multiplies the XOR view.", { model.update { $0.lift = lift } })
                    })
                    Text("Makes a faint XOR bright enough to see. Mask stays black and white.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                nudgeBlock

                Toggle(isOn: Binding(
                    get: { model.options.invert },
                    set: { value in model.update { $0.invert = value } }
                )) {
                    Text("Invert")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.text)
                }
                .toggleStyle(.switch)
                .help("White where they match, black where they differ.")

                HStack(spacing: 8) {
                    Button("Copy") { model.copyImage() }
                        .buttonStyle(ParityButtonStyle())
                        .disabled(!model.canSave)
                    Button("Sample") { model.loadSample() }
                        .buttonStyle(ParityButtonStyle(kind: .ghost))
                        .help("A small pair: the sun moved, and a door was added.")
                }
            }
            .padding(16)
        }
        .background(Theme.panel)
    }

    private var nudgeBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionLabel("NUDGE")
                Spacer()
                Button("Zero") { model.zeroNudge() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.muted)
            }
            nudgeAxis("X", value: model.options.offsetX) { delta in
                model.nudge(dx: delta, dy: 0)
            } set: { value in
                model.update { $0.offsetX = value }
            }
            nudgeAxis("Y", value: model.options.offsetY) { delta in
                model.nudge(dx: 0, dy: delta)
            } set: { value in
                model.update { $0.offsetY = value }
            }
            Text("Slides B across A. Empty overlap compares against black. Positive X moves B right, positive Y moves B down.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func nudgeAxis(
        _ label: String,
        value: Int,
        step: @escaping (Int) -> Void,
        set: @escaping (Int) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.muted)
                    .frame(width: 12, alignment: .leading)
                stepButton("−10") { step(-10) }
                stepButton("−1") { step(-1) }
                Text("\(value)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.paper)
                    .frame(minWidth: 36)
                stepButton("+1") { step(1) }
                stepButton("+10") { step(10) }
            }
            Slider(
                value: Binding(
                    get: { Double(value) },
                    set: { set(Int($0.rounded())) }
                ),
                in: -Double(model.nudgeLimit)...Double(model.nudgeLimit)
            )
        }
    }

    private func stepButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(Capsule().fill(Theme.elevated))
    }

    private var footer: some View {
        HStack {
            Text(model.status)
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
            Spacer()
            Text("Sources stay untouched")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.muted.opacity(0.8))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Theme.panel)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .tracking(1.1)
            .foregroundStyle(Theme.muted)
    }

    private func chipRow(_ items: [(String, Bool, String, () -> Void)]) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                chip(item.0, selected: item.1, help: item.2, action: item.3)
            }
        }
    }

    private func chip(_ title: String, selected: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .foregroundStyle(selected ? Theme.ink : Theme.text)
                .background(Capsule().fill(selected ? Theme.paper : Theme.elevated))
                .overlay(Capsule().stroke(selected ? Theme.paper : Theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func bitButton(_ bit: Int) -> some View {
        let selected = model.options.plane == bit
        return Button {
            model.update { $0.plane = bit }
        } label: {
            Text("\(bit)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .frame(width: 26, height: 26)
                .foregroundStyle(selected ? Theme.ink : Theme.text)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(selected ? Theme.paper : Theme.field)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(selected ? Theme.paper : Theme.line, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help("Bit \(bit) of the XOR. 0 is the least significant bit.")
    }
}

/// Skips redrawing when the same picture is still on screen. Slider ticks republish the model.
private struct StillImage: View, Equatable {
    var image: NSImage
    var interpolation: Image.Interpolation

    static func == (lhs: StillImage, rhs: StillImage) -> Bool {
        lhs.image === rhs.image && lhs.interpolation == rhs.interpolation
    }

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(interpolation)
            .scaledToFit()
    }
}

@discardableResult
func collectFileURLs(_ providers: [NSItemProvider], _ done: @escaping ([URL]) -> Void) -> Bool {
    let group = DispatchGroup()
    let lock = NSLock()
    var found: [Int: URL] = [:]
    var any = false
    for (index, provider) in providers.enumerated() {
        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { continue }
        any = true
        group.enter()
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            defer { group.leave() }
            let url: URL?
            if let fileURL = item as? URL {
                url = fileURL
            } else if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else if let text = item as? String {
                url = URL(string: text)
            } else {
                url = nil
            }
            guard let url else { return }
            lock.lock()
            found[index] = url
            lock.unlock()
        }
    }
    guard any else { return false }
    group.notify(queue: .main) {
        let urls = found.keys.sorted().compactMap { found[$0] }
        if !urls.isEmpty { done(urls) }
    }
    return true
}
