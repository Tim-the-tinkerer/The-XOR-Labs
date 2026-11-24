import Foundation

/// Reads a ZIP central directory and rejects entries before anything is extracted.
enum XORPassZip {
    static func preflight(at url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        guard fileSize >= 22 else { throw XORPassError.corrupt }
        let window = min(fileSize, 22 + 65_535)
        try handle.seek(toOffset: fileSize - window)
        let tail = try readExactly(handle, Int(window))
        guard let eocd = endOfCentralDirectory(in: tail) else { throw XORPassError.corrupt }

        var cdOffset = eocd.offset
        var cdSize = eocd.size
        if eocd.needsZip64 {
            let located = try zip64CentralDirectory(handle: handle, fileSize: fileSize, eocdFileOffset: fileSize - window + UInt64(eocd.index))
            cdOffset = located.offset
            cdSize = located.size
        }
        guard cdOffset <= fileSize, cdSize <= fileSize, fileSize - cdOffset >= cdSize else {
            throw XORPassError.corrupt
        }
        guard cdSize <= Int.max else { throw XORPassError.corrupt }
        try handle.seek(toOffset: cdOffset)
        let directory = try readExactly(handle, Int(cdSize))
        try walkCentralDirectory(directory)
    }

    private struct EOCD {
        var index: Int
        var offset: UInt64
        var size: UInt64
        var needsZip64: Bool
    }

    private static func endOfCentralDirectory(in tail: Data) -> EOCD? {
        guard tail.count >= 22 else { return nil }
        var index = tail.count - 22
        while index >= 0 {
            if tail[index] == 0x50, tail[index + 1] == 0x4B,
               tail[index + 2] == 0x05, tail[index + 3] == 0x06 {
                let commentLength = int16(tail, index + 20)
                if index + 22 + commentLength == tail.count {
                    let size = UInt64(uint32(tail, index + 12))
                    let offset = UInt64(uint32(tail, index + 16))
                    let entries = int16(tail, index + 10)
                    let needsZip64 = size == 0xFFFF_FFFF || offset == 0xFFFF_FFFF || entries == 0xFFFF
                    return EOCD(index: index, offset: offset, size: size, needsZip64: needsZip64)
                }
            }
            if index == 0 { break }
            index -= 1
            if tail.count - index > 22 + 65_535 { break }
        }
        return nil
    }

    private static func zip64CentralDirectory(
        handle: FileHandle,
        fileSize: UInt64,
        eocdFileOffset: UInt64
    ) throws -> (offset: UInt64, size: UInt64) {
        guard eocdFileOffset >= 20 else { throw XORPassError.corrupt }
        try handle.seek(toOffset: eocdFileOffset - 20)
        let locator = try readExactly(handle, 20)
        guard locator[0] == 0x50, locator[1] == 0x4B, locator[2] == 0x06, locator[3] == 0x07 else {
            throw XORPassError.corrupt
        }
        let zip64Offset = uint64(locator, 8)
        guard zip64Offset <= fileSize, fileSize - zip64Offset >= 56 else { throw XORPassError.corrupt }
        try handle.seek(toOffset: zip64Offset)
        let record = try readExactly(handle, 56)
        guard record[0] == 0x50, record[1] == 0x4B, record[2] == 0x06, record[3] == 0x06 else {
            throw XORPassError.corrupt
        }
        return (uint64(record, 48), uint64(record, 40))
    }

    private static func walkCentralDirectory(_ directory: Data) throws {
        var index = 0
        while index < directory.count {
            guard index + 46 <= directory.count else { throw XORPassError.corrupt }
            guard directory[index] == 0x50, directory[index + 1] == 0x4B,
                  directory[index + 2] == 0x01, directory[index + 3] == 0x02 else {
                throw XORPassError.corrupt
            }
            let madeBy = int16(directory, index + 4)
            let nameLength = int16(directory, index + 28)
            let extraLength = int16(directory, index + 30)
            let commentLength = int16(directory, index + 32)
            let external = uint32(directory, index + 38)
            let nameStart = index + 46
            let nameEnd = nameStart + nameLength
            guard nameEnd <= directory.count else { throw XORPassError.corrupt }
            let name = directory.subdata(in: nameStart..<nameEnd)
            try validate(name: name, madeBy: madeBy, externalAttributes: external)
            let (withExtra, extraOverflow) = nameEnd.addingReportingOverflow(extraLength)
            let (next, commentOverflow) = withExtra.addingReportingOverflow(commentLength)
            if extraOverflow || commentOverflow || next > directory.count || next <= index {
                throw XORPassError.corrupt
            }
            index = next
        }
    }

    private static func validate(name: Data, madeBy: Int, externalAttributes: UInt32) throws {
        if name.isEmpty || name.contains(0) {
            throw XORPassError.unsafeArchivePath(display(name))
        }
        if name[0] == 0x2F || name[0] == 0x5C {
            throw XORPassError.unsafeArchivePath(display(name))
        }
        if name.count >= 2, name[1] == 0x3A {
            throw XORPassError.unsafeArchivePath(display(name))
        }

        var parts: [Data] = []
        var current = Data()
        for byte in name {
            if byte == 0x2F || byte == 0x5C {
                parts.append(current)
                current = Data()
            } else {
                current.append(byte)
            }
        }
        parts.append(current)
        if parts.last?.isEmpty == true {
            parts.removeLast()
        }
        for part in parts {
            if part.isEmpty || part == Data("..".utf8) {
                throw XORPassError.unsafeArchivePath(display(name))
            }
        }

        let host = madeBy >> 8
        let mode = Int((externalAttributes >> 16) & 0xFFFF)
        let kind = mode & 0xF000
        if host == 3 || kind != 0 {
            let regular = 0x8000
            let directory = 0x4000
            if kind != regular && kind != directory {
                throw XORPassError.unsafeArchivePath(display(name))
            }
        }
    }

    private static func display(_ name: Data) -> String {
        if let text = String(data: name, encoding: .utf8), !text.isEmpty {
            return text
        }
        return "zip entry"
    }

    private static func int16(_ data: Data, _ offset: Int) -> Int {
        Int(UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8))
    }

    private static func uint32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func uint64(_ data: Data, _ offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<8 {
            value |= UInt64(data[offset + i]) << (i * 8)
        }
        return value
    }

    private static func readExactly(_ handle: FileHandle, _ count: Int) throws -> Data {
        var data = Data()
        data.reserveCapacity(count)
        while data.count < count {
            guard let chunk = try handle.read(upToCount: count - data.count), !chunk.isEmpty else {
                throw XORPassError.corrupt
            }
            data.append(chunk)
        }
        return data
    }
}
