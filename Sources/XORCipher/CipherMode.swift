import Foundation

/// Cipher is the repeating-key workshop and writes `.xor`.
/// Pass is XOR Pass: Argon2id, an HMAC-SHA256 counter keystream, and a tag.
/// Pass writes `.xorpass`. An archive follows the magic in its header.
enum CipherMode: String, CaseIterable, Identifiable, Hashable {
    case cipher
    case pass

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cipher: return "Cipher"
        case .pass: return "Pass"
        }
    }

    var menuTitle: String {
        switch self {
        case .cipher: return "Cipher"
        case .pass: return "Pass"
        }
    }

    var subtitle: String {
        switch self {
        case .cipher: return "Repeating-key bitwise exclusive-or · encrypt to .xor"
        case .pass: return "XOR cipher · Argon2id password · salt, nonce, padding · .xorpass"
        }
    }

    var switchedStatus: String {
        switch self {
        case .cipher:
            return "Cipher. Repeating-key XOR. A .xor file is not a .xorpass file."
        case .pass:
            return "Pass. Argon2id stretches the secret. A .xorpass file is not a .xor file."
        }
    }

    var emptyHint: String {
        switch self {
        case .cipher:
            return "File or folder → one .xor   ·   .xor → decrypts automatically"
        case .pass:
            return "One .xorpass per item  ·  decrypt restores the original name"
        }
    }

    var footerFallback: String {
        switch self {
        case .cipher: return "Educational XOR cipher — not strong encryption"
        case .pass: return "Password is not written into the file"
        }
    }

    var symbolName: String {
        switch self {
        case .cipher: return "circle.lefthalf.filled"
        case .pass: return "key.horizontal.fill"
        }
    }
}

/// Which container a dropped archive is. Plain files have none until Encrypt.
enum ArchiveFamily: Equatable, Sendable {
    case xor
    case xorpass
}
