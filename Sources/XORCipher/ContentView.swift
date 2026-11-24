import SwiftUI
import AppKit
import XORCore
import XORPassCore

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    private let labelWidth: CGFloat = 48
    private let passLabelWidth: CGFloat = 78

    var body: some View {
        VStack(spacing: 0) {
            header
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Group {
                if model.mode == .pass {
                    passBar
                } else {
                    keyBar
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            panes
            Divider()
            footer
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minWidth: 840, minHeight: model.mode == .pass ? 560 : 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(model.mode == .pass
              ? Color(red: 0.16, green: 0.55, blue: 0.62)
              : Color(red: 0.90, green: 0.58, blue: 0.12))
        .onFileDrop { model.add($0) }
        .alert("XOR Cipher", isPresented: alertBinding) {
            Button("OK", role: .cancel) { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
    }

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { model.alertMessage != nil },
            set: { if !$0 { model.alertMessage = nil } }
        )
    }

    /// Files and workshop share leftover height with explicit frames so they cannot paint over each other.
    private var panes: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                fileArea
                    .frame(width: geo.size.width, height: fileHeight(in: geo.size.height))
                    .clipped()
                if model.mode == .cipher, model.showText {
                    Divider()
                    workshopScroll
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func fileHeight(in total: CGFloat) -> CGFloat {
        guard model.mode == .cipher, model.showText else { return total }
        let workshopFloor: CGFloat = 340
        let filesFloor: CGFloat = 176
        if total < filesFloor + workshopFloor {
            return max(150, total * 0.34)
        }
        return min(max(filesFloor, total * 0.36), total - workshopFloor)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: model.mode.symbolName)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 2) {
                Text("XOR Cipher")
                    .font(.title2.weight(.semibold))
                Text(model.mode.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Picker("Mode", selection: Binding(
                get: { model.mode },
                set: { model.selectMode($0) }
            )) {
                ForEach(CipherMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 160)
            .help("Cipher is the repeating-key workshop and writes .xor. Pass seals a .xorpass with Argon2id.")

            if model.mode == .cipher {
                Button {
                    model.loadFamousExample()
                } label: {
                    Label("Hello ⊕ key", systemImage: "sparkles")
                }
                .controlSize(.small)
                .help("Hello ⊕ key → 23 00 15 07 0A")

                Button {
                    model.showText.toggle()
                } label: {
                    Label(model.showText ? "Hide Text" : "Text", systemImage: "text.alignleft")
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    // MARK: - Encrypt settings

    private var keyBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                rowLabel("Kind")

                Picker(selection: $model.keyKind) {
                    ForEach(KeyKind.allCases) { k in
                        Text(k.title).tag(k)
                    }
                } label: {
                    EmptyView()
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 280)

                Text(model.keyKind.detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            HStack(spacing: 10) {
                rowLabel("Key")

                if model.keyKind == .file {
                    Button {
                        model.chooseKeyFile()
                    } label: {
                        Label(
                            model.keyFileURL == nil ? "Choose Key File…" : "Change…",
                            systemImage: "doc"
                        )
                    }
                    .controlSize(.small)
                    .help("Use the raw bytes of a file as the repeating XOR key.")

                    if let url = model.keyFileURL {
                        Text(url.lastPathComponent)
                            .font(.system(.body, design: .monospaced).weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(url.path)
                        Button {
                            model.clearKeyFile()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Clear the key file")
                    }
                } else {
                    TextField(model.keyKind == .hex ? "Hex bytes" : "Passphrase", text: $model.keyword)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                        .frame(width: 220)
                        .help(model.keyKind == .hex
                              ? "Repeating keystream as hex. Spaces and 0x are allowed."
                              : "Repeating passphrase. Each UTF-8 byte XORs the next plaintext byte.")

                    ForEach(AppModel.famousKeys, id: \.self) { k in
                        Button(k) {
                            model.keyword = k
                            model.keyKind = .text
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(model.keyword == k && model.keyKind == .text ? Color.accentColor : nil)
                    }

                    Button {
                        model.generateRandomKey()
                    } label: {
                        Image(systemName: "die.face.5")
                    }
                    .help("Fill a random hex key")
                    .controlSize(.small)
                }

                Spacer(minLength: 8)

                Text(model.keyHint)
                    .font(.caption2)
                    .foregroundStyle(model.keyIsValid ? Color.secondary : Color.orange)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            HStack(spacing: 12) {
                rowLabel("File")

                Picker(selection: $model.keyStorage) {
                    ForEach(KeyStorage.allCases) { s in
                        Text(s.title).tag(s)
                    }
                } label: {
                    EmptyView()
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 320)
                .help("Store key writes it in the clear. Don't store omits it. Encrypt key XOR-wraps it with a passphrase.")

                Text(model.keyStorage.detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            if model.keyStorage == .wrap {
                HStack(spacing: 12) {
                    rowLabel("Wrap")

                    SecureField("Wrap passphrase", text: $model.wrapPassphrase)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 240)
                        .help("Not the XOR key. This passphrase wraps the key in the header. You will need it to decrypt.")

                    Text(XORKey(model.wrapPassphrase, kind: .text).isEmpty
                         ? "Required to encrypt or decrypt a wrapped key"
                         : "Kept only in memory — never written to the file")
                        .font(.caption2)
                        .foregroundStyle(XORKey(model.wrapPassphrase, kind: .text).isEmpty ? Color.orange : Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            HStack(spacing: 12) {
                Toggle("Encrypt file names", isOn: $model.encryptFileNames)
                    .toggleStyle(.checkbox)
                    .help("XOR file and folder names, then store them as hex so they stay path-safe.")
                    .disabled(!model.keyIsValid)
                    .fixedSize()

                if model.encryptFileNames, model.keyIsValid {
                    Text("e.g. Report.pdf → \(XOREngine.encryptedFileNamePreview("Report.pdf", key: model.xorKey)).xor")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                Text(footerKeyHint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private func rowLabel(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: labelWidth, alignment: .leading)
    }

    private var footerKeyHint: String {
        switch model.keyStorage {
        case .store:
            return "Decrypt reads the key from the .xor file"
        case .omit:
            return "Decrypt uses the Key field above"
        case .wrap:
            return "Decrypt uses the wrap passphrase"
        }
    }

    // MARK: - Pass

    private var passBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                passRowLabel("Password")
                passwordField("Password", text: $model.password)
                    .frame(maxWidth: 280)
                    .disabled(!model.passwordApplies)
                passwordField("Confirm", text: $model.confirm)
                    .frame(maxWidth: 280)
                    .disabled(!model.passwordApplies)
                Button {
                    model.revealPassword.toggle()
                } label: {
                    Image(systemName: model.revealPassword ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(model.revealPassword ? "Hide password" : "Show password")
                Spacer(minLength: 8)
                Text(confirmHint)
                    .font(.caption2)
                    .foregroundStyle(confirmColor)
                    .lineLimit(1)
            }

            HStack(spacing: 10) {
                passRowLabel("Key file")
                Button {
                    model.choosePassKeyFile()
                } label: {
                    Label(
                        model.passKeyFileURL == nil ? "Choose Key File…" : "Change…",
                        systemImage: "doc"
                    )
                }
                .controlSize(.small)
                .disabled(!model.passKeyFileApplies)
                .help("Use the raw bytes of a file as key material. The file is not written into the archive.")

                if let url = model.passKeyFileURL {
                    Text(url.lastPathComponent)
                        .font(.system(.body, design: .monospaced).weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(url.path)
                    Button {
                        model.clearPassKeyFile()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Clear the key file")
                }

                Text(model.passKeyFileHint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
            }

            HStack(spacing: 10) {
                passRowLabel("Stretch")
                Picker(selection: $model.passProfile) {
                    ForEach(XORPassProfile.choices) { profile in
                        Text(profile.name).tag(profile)
                    }
                } label: {
                    EmptyView()
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                Text(model.passProfile.parameterLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
            }

            HStack(spacing: 10) {
                passRowLabel("Padding")
                Picker(selection: $model.passPadding) {
                    ForEach(XORPassPadding.allCases) { padding in
                        Text(padding.title).tag(padding)
                    }
                } label: {
                    EmptyView()
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 280)
                Text(model.passPadding.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Toggle("Clear secrets when finished", isOn: $model.clearSecretsAfter)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .help("Clears the password, confirmation, and key file after Encrypt or Decrypt finishes.")
            }

            Text("Each file gets its own salt and nonce. Contents are padded. The original name is encrypted, and the archive is saved under a random name.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var confirmHint: String {
        if model.password.isEmpty { return model.passwordHint }
        if !model.passwordsMatch { return "Passwords do not match" }
        return model.passwordHint
    }

    private var confirmColor: Color {
        if !model.password.isEmpty, !model.passwordsMatch { return .orange }
        if !model.password.isEmpty, Data(model.password.utf8).count < 8 { return .orange }
        return .secondary
    }

    @ViewBuilder
    private func passwordField(_ title: String, text: Binding<String>) -> some View {
        if model.revealPassword {
            TextField(title, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
        } else {
            SecureField(title, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func passRowLabel(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: passLabelWidth, alignment: .leading)
    }

    // MARK: - Files

    private var fileArea: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Files & folders")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button {
                    model.openFiles()
                } label: {
                    Label("Open…", systemImage: "folder")
                }
                .controlSize(.small)
                .keyboardShortcut("o", modifiers: .command)
                .help("Choose files or folders")

                Button(role: .destructive) {
                    model.clear()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .controlSize(.small)
                .disabled(model.items.isEmpty)
                .help(model.isBusy ? "Cancels in-progress work and clears the list" : "Clear the list")

                Button {
                    model.processAll()
                } label: {
                    if model.isBusy {
                        Label("Working…", systemImage: "hourglass")
                    } else {
                        Label("Encrypt / Decrypt All", systemImage: model.mode.symbolName)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(model.items.isEmpty || model.isBusy)
                .keyboardShortcut(.return, modifiers: .command)
                .help(model.mode == .pass
                      ? "Encrypts files and folders to .xorpass, and decrypts .xorpass archives"
                      : "Encrypts files and folders to .xor, and decrypts .xor archives")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)

            if model.items.isEmpty {
                emptyState
            } else {
                fileList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text("Drop files or folders here")
                .font(.headline)
            Text(model.mode.emptyHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var fileList: some View {
        List {
            ForEach(model.items) { item in
                HStack(spacing: 12) {
                    Image(systemName: itemIcon(item.kind))
                        .foregroundStyle(item.kind == .archive ? Color.accentColor : .secondary)
                        .frame(width: 20)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Text(item.actionLabel(mode: model.mode))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("·")
                                .foregroundStyle(.tertiary)
                            Text(item.sizeLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if !item.detail.isEmpty {
                                Text("·")
                                    .foregroundStyle(.tertiary)
                                Text(item.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            statusLabel(item.status)
                        }
                    }

                    Spacer()

                    Button {
                        model.process(item)
                    } label: {
                        Text(item.kind == .archive ? "Decrypt" : "Encrypt")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.isBusy || {
                        if case .working = item.status { return true }
                        return false
                    }())

                    if case .done(let url) = item.status {
                        Button {
                            model.reveal(url)
                        } label: {
                            Image(systemName: "arrow.right.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .help("Show result in Finder")
                    }

                    Button {
                        model.remove(item)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.vertical, 2)
            }
        }
        .listStyle(.inset)
    }

    private func itemIcon(_ kind: AppModel.Item.Kind) -> String {
        switch kind {
        case .plain:      return "doc"
        case .directory:  return "folder.fill"
        case .archive:    return "lock.doc.fill"
        }
    }

    @ViewBuilder
    private func statusLabel(_ status: AppModel.Item.Status) -> some View {
        switch status {
        case .ready:
            EmptyView()
        case .working:
            ProgressView().controlSize(.small)
        case .done(let url):
            Text("→ \(url.lastPathComponent)")
                .font(.caption)
                .foregroundStyle(.green)
                .lineLimit(1)
        case .failed(let msg):
            Text(msg)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(1)
        }
    }

    // MARK: - Workshop

    private var workshopScroll: some View {
        ScrollView {
            textArea
        }
    }

    private var textArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Workshop")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize()

                Picker(selection: $model.textDecrypt) {
                    Text("Encrypt").tag(false)
                    Text("Decrypt").tag(true)
                } label: {
                    EmptyView()
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 160)
                .controlSize(.small)

                if !model.textDecrypt {
                    Picker(selection: $model.outputFormat) {
                        ForEach(OutputFormat.allCases) { f in
                            Text(f.title).tag(f)
                        }
                    } label: {
                        EmptyView()
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 280)
                    .controlSize(.small)
                }

                Spacer(minLength: 8)

                Button("Copy") {
                    model.copyOutput()
                }
                .disabled(model.textOutput.isEmpty)
                .controlSize(.small)

                Button("Save as .xor…") {
                    model.saveTextAsXOR()
                }
                .disabled(model.textInput.isEmpty || !model.keyIsValid)
                .controlSize(.small)
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.textDecrypt ? "Ciphertext (text or hex)" : "Plaintext")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    TextEditor(text: $model.textInput)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 56, maxHeight: 80)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.textDecrypt ? "Plaintext" : "Ciphertext")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    TextEditor(text: .constant(model.textOutput))
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 56, maxHeight: 80)
                        .disabled(true)
                        .opacity(0.9)
                }
            }

            AlignmentLegend()
            ByteAlignmentView(steps: model.alignment, selected: $model.selectedByte)
                .frame(minHeight: 52)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(8)

            BitBoardView(step: model.selectedAlign)

            Text(model.textDecrypt
                 ? "Paste hex (or raw bytes as text). XOR again with the same key to recover the original."
                 : "Each UTF-8 byte is XORed with the next key byte. Ciphertext is often not printable, so Hex is the usual view.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text(model.statusMessage ?? model.mode.footerFallback)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if model.mode == .pass {
                Text(model.passProfile.parameterLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }
}
