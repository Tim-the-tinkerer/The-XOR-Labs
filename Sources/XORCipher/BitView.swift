import SwiftUI
import XORCore

/// Eight bits of plaintext ⊕ key = ciphertext for one selected byte.
struct BitBoardView: View {
    let step: ByteAlign?

    var body: some View {
        if let step {
            VStack(alignment: .leading, spacing: 8) {
                Text("Byte \(step.id)  ·  \(String(format: "%02X", step.plain)) ⊕ \(String(format: "%02X", step.key)) = \(String(format: "%02X", step.cipher))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                bitRow(label: "P", byte: step.plain, glyph: step.plainGlyph, tint: Color.primary)
                bitRow(label: "K", byte: step.key, glyph: step.keyGlyph, tint: Color.accentColor)
                Divider()
                bitRow(label: "C", byte: step.cipher, glyph: step.cipherGlyph, tint: Color.accentColor, emphasize: true)

                Text("A bit is 1 in C only when P and K disagree. XOR twice with the same key restores P.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
        } else {
            Text("Type text and a key to see the bits.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func bitRow(label: String, byte: UInt8, glyph: String, tint: Color, emphasize: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(.caption, design: .monospaced).weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 14)

            HStack(spacing: 4) {
                ForEach(0..<8, id: \.self) { i in
                    let on = ((byte >> (7 - i)) & 1) == 1
                    Text(on ? "1" : "0")
                        .font(.system(size: 13, weight: emphasize ? .bold : .medium, design: .monospaced))
                        .foregroundStyle(on ? tint : Color.secondary.opacity(0.55))
                        .frame(minWidth: 18, idealWidth: 24, maxWidth: 32, minHeight: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(on ? tint.opacity(emphasize ? 0.22 : 0.12) : Color.primary.opacity(0.04))
                        )
                }
            }

            Text(String(format: "%02X", byte))
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 28, alignment: .trailing)

            Text(glyph)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 16)
        }
    }
}

/// Wrapping columns of plain / key / cipher bytes.
struct ByteAlignmentView: View {
    let steps: [ByteAlign]
    @Binding var selected: Int

    var body: some View {
        if steps.isEmpty {
            Text("Type text and a key to see each byte XOR.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 28, maximum: 36), spacing: 4)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(steps) { step in
                    let isOn = selected == step.id
                    VStack(spacing: 1) {
                        Text(String(format: "%02X", step.plain))
                            .foregroundStyle(.primary)
                        Text(String(format: "%02X", step.key))
                            .foregroundStyle(Color.accentColor)
                        Text(String(format: "%02X", step.cipher))
                            .fontWeight(.bold)
                            .foregroundStyle(Color.accentColor)
                    }
                    .font(.system(size: 9, design: .monospaced))
                    .frame(minWidth: 26)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(isOn ? Color.accentColor.opacity(0.18) : Color.accentColor.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(isOn ? Color.accentColor.opacity(0.7) : Color.clear, lineWidth: 1)
                    )
                    .help(step.help)
                    .onTapGesture { selected = step.id }
                }
            }
        }
    }
}

struct AlignmentLegend: View {
    var body: some View {
        HStack(spacing: 12) {
            legendSwatch("P", "plaintext")
            legendSwatch("K", "repeating key")
            legendSwatch("C", "ciphertext")
            Text("click a column for bits")
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }

    private func legendSwatch(_ letter: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(letter)
                .font(.system(.caption2, design: .monospaced).weight(.bold))
                .foregroundStyle(letter == "P" ? Color.primary : Color.accentColor)
            Text(label)
        }
    }
}
