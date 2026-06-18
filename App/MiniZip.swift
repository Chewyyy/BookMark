import Foundation
import Compression

/// A minimal read-only ZIP central-directory parser used by `EPUBImporter` to pull a
/// handful of files (container.xml, content.opf, cover image) out of an EPUB without
/// requiring a third-party ZIP library. Only supports Store (no compression) and Deflate.
enum MiniZip {
    struct Archive {
        var data: Data
        var entries: [String: Entry]

        func extract(name: String) -> Data? {
            guard let e = entries[name] ?? entries.first(where: { $0.key.hasSuffix(name) })?.value else { return nil }
            return e.readData(from: data)
        }
    }

    struct Entry {
        var name: String
        var method: UInt16  // 0 = Store, 8 = Deflate
        var compressedSize: UInt32
        var uncompressedSize: UInt32
        var localHeaderOffset: UInt32

        func readData(from data: Data) -> Data? {
            // Re-parse local file header to find true data offset (filename+extra lengths can differ).
            let lh = Int(localHeaderOffset)
            guard data.count > lh + 30 else { return nil }
            let sig: UInt32 = data.readLE(at: lh)
            guard sig == 0x04034b50 else { return nil }
            let nameLen: UInt16 = data.readLE(at: lh + 26)
            let extraLen: UInt16 = data.readLE(at: lh + 28)
            let dataStart = lh + 30 + Int(nameLen) + Int(extraLen)
            let compEnd = dataStart + Int(compressedSize)
            guard data.count >= compEnd else { return nil }
            let body = data.subdata(in: dataStart..<compEnd)

            switch method {
            case 0:
                return body
            case 8:
                return inflate(body, uncompressedSize: Int(uncompressedSize))
            default:
                return nil
            }
        }

        /// Cap individual-entry decompression so a malformed or malicious EPUB
        /// can't ask us to allocate gigabytes. MiniZip is only used by
        /// `EPUBImporter` for tiny metadata + cover files; 32 MB is comfortably
        /// above the largest real-world EPUB cover but well below the device's
        /// memory budget.
        private static let maxInflateBytes = 32 * 1024 * 1024

        private func inflate(_ data: Data, uncompressedSize: Int) -> Data? {
            let claimed = uncompressedSize
            let estimated = max(claimed, data.count * 8, 1024)
            let capacity = min(estimated, Entry.maxInflateBytes)
            guard capacity > 0 else { return nil }
            var dest = Data(count: capacity)
            let written = dest.withUnsafeMutableBytes { destBuffer -> Int in
                data.withUnsafeBytes { srcBuffer -> Int in
                    guard let src = srcBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                          let dst = destBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self)
                    else { return 0 }
                    return compression_decode_buffer(dst, capacity, src, data.count, nil, COMPRESSION_ZLIB)
                }
            }
            guard written > 0 else { return nil }
            return dest.prefix(written)
        }
    }

    /// Find the End-of-Central-Directory record and walk every entry.
    static func readCentralDirectory(data: Data) -> Archive? {
        guard let eocdOffset = findEOCD(in: data) else { return nil }
        let cdSize: UInt32 = data.readLE(at: eocdOffset + 12)
        let cdOffset: UInt32 = data.readLE(at: eocdOffset + 16)
        let cdEnd = Int(cdOffset) + Int(cdSize)
        guard cdEnd <= data.count else { return nil }

        var entries: [String: Entry] = [:]
        var ptr = Int(cdOffset)
        while ptr < cdEnd {
            let sig: UInt32 = data.readLE(at: ptr)
            guard sig == 0x02014b50 else { break }
            let method: UInt16 = data.readLE(at: ptr + 10)
            let compSize: UInt32 = data.readLE(at: ptr + 20)
            let uncompSize: UInt32 = data.readLE(at: ptr + 24)
            let nameLen: UInt16 = data.readLE(at: ptr + 28)
            let extraLen: UInt16 = data.readLE(at: ptr + 30)
            let commentLen: UInt16 = data.readLE(at: ptr + 32)
            let localOffset: UInt32 = data.readLE(at: ptr + 42)
            let nameStart = ptr + 46
            let nameEnd = nameStart + Int(nameLen)
            guard nameEnd <= data.count else { break }
            let nameData = data.subdata(in: nameStart..<nameEnd)
            let name = String(data: nameData, encoding: .utf8) ?? ""
            if !name.isEmpty, !name.hasSuffix("/") {
                entries[name] = Entry(
                    name: name,
                    method: method,
                    compressedSize: compSize,
                    uncompressedSize: uncompSize,
                    localHeaderOffset: localOffset
                )
            }
            ptr = nameEnd + Int(extraLen) + Int(commentLen)
        }
        return Archive(data: data, entries: entries)
    }

    private static func findEOCD(in data: Data) -> Int? {
        let sig: [UInt8] = [0x50, 0x4b, 0x05, 0x06]
        let n = data.count
        let scanFrom = max(0, n - 0xFFFF - 22)
        var i = n - 22
        while i >= scanFrom {
            if data[i] == sig[0], data[i + 1] == sig[1], data[i + 2] == sig[2], data[i + 3] == sig[3] {
                return i
            }
            i -= 1
        }
        return nil
    }
}

private extension Data {
    func readU16(at offset: Int) -> UInt16 {
        precondition(offset + 2 <= count, "OOB readU16 in MiniZip")
        let lo = UInt16(self[offset])
        let hi = UInt16(self[offset + 1])
        return lo | (hi << 8)
    }

    func readU32(at offset: Int) -> UInt32 {
        precondition(offset + 4 <= count, "OOB readU32 in MiniZip")
        let b0 = UInt32(self[offset])
        let b1 = UInt32(self[offset + 1])
        let b2 = UInt32(self[offset + 2])
        let b3 = UInt32(self[offset + 3])
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }

    func readLE<T: FixedWidthInteger>(at offset: Int) -> T {
        if T.self == UInt16.self { return T(readU16(at: offset)) }
        if T.self == UInt32.self { return T(readU32(at: offset)) }
        return 0
    }
}
