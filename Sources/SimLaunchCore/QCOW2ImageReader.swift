import Foundation

final class ReadOnlyImageFile {
    private let handle: FileHandle
    let length: UInt64

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        length = try handle.seekToEnd()
    }

    deinit { try? handle.close() }

    func read(_ offset: UInt64, _ count: Int) throws -> Data {
        try Task.checkCancellation()
        guard count >= 0, offset <= length, UInt64(count) <= length - offset else { throw CocoaError(.fileReadCorruptFile) }
        if count == 0 { return Data() }
        try handle.seek(toOffset: offset)
        guard let data = try handle.read(upToCount: count), data.count == count else { throw CocoaError(.fileReadCorruptFile) }
        return data
    }
}

/// Reads standard, uncompressed QCOW2 clusters with the selected SDK's raw backing image.
/// Neither image is opened for writing. Unsupported layouts are rejected.
final class QCOW2ImageReader {
    private static let offsetMask: UInt64 = 0x00FF_FFFF_FFFF_FE00
    private static let copiedFlag: UInt64 = 1 << 63
    private let image: ReadOnlyImageFile
    private let backing: ReadOnlyImageFile
    let length: UInt64
    private let clusterSize: UInt64
    private let l1: Data
    private let zeroFlag: UInt64
    private var cachedL2: (offset: UInt64, entries: Data)?

    init(url: URL, backingURL: URL) throws {
        let image = try ReadOnlyImageFile(url: url)
        let header = try image.read(0, 104)
        let version = header.bigEndian32(4)
        let clusterBits = header.bigEndian32(20)
        let size = header.bigEndian64(24)
        guard header.bigEndian32(0) == 0x514649FB, version == 2 || version == 3,
              (9...21).contains(clusterBits), size > 0, header.bigEndian32(32) == 0,
              version == 2 || header.bigEndian64(72) == 0 else { throw CocoaError(.fileReadUnsupportedScheme) }
        let clusterSize: UInt64 = 1 << clusterBits
        let backingOffset = header.bigEndian64(8)
        let backingSize = UInt64(header.bigEndian32(16))
        guard backingOffset >= (version == 2 ? 72 : 104), backingOffset < clusterSize,
              (1...1023).contains(backingSize), backingSize <= clusterSize - backingOffset,
              let name = String(data: try image.read(backingOffset, Int(backingSize)), encoding: .utf8),
              !name.utf8.contains(0) else { throw CocoaError(.fileReadCorruptFile) }
        let namedBacking = name.hasPrefix("/") ? URL(fileURLWithPath: name) : url.deletingLastPathComponent().appendingPathComponent(name)
        guard namedBacking.resolvingSymlinksInPath().standardizedFileURL == backingURL.resolvingSymlinksInPath().standardizedFileURL else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let l1Count = UInt64(header.bigEndian32(36))
        let l1Offset = header.bigEndian64(40)
        let bytesPerL1Entry = clusterSize * (clusterSize / 8)
        guard l1Count >= (size - 1) / bytesPerL1Entry + 1, l1Count <= 131_072,
              l1Offset >= clusterSize, l1Offset.isMultiple(of: clusterSize) else { throw CocoaError(.fileReadCorruptFile) }
        self.l1 = try image.read(l1Offset, Int(l1Count * 8))
        self.image = image
        self.backing = try ReadOnlyImageFile(url: backingURL)
        self.length = size
        self.clusterSize = clusterSize
        zeroFlag = version == 3 ? 1 : 0
    }

    func read(_ offset: UInt64, _ count: Int) throws -> Data {
        guard count >= 0, offset <= length, UInt64(count) <= length - offset else { throw CocoaError(.fileReadCorruptFile) }
        var result = Data(capacity: count)
        var position = offset
        while result.count < count {
            try Task.checkCancellation()
            let cluster = position / clusterSize
            let within = position % clusterSize
            let amount = min(count - result.count, Int(clusterSize - within))
            let entry = try clusterEntry(cluster)
            let mapped = entry & Self.offsetMask
            if entry & zeroFlag != 0 {
                result.append(Data(count: amount))
            } else if mapped != 0 {
                guard mapped.isMultiple(of: clusterSize) else { throw CocoaError(.fileReadCorruptFile) }
                result.append(try image.read(mapped + within, amount))
            } else {
                guard entry == 0 else { throw CocoaError(.fileReadCorruptFile) }
                let available = position < backing.length ? Int(min(UInt64(amount), backing.length - position)) : 0
                if available > 0 { result.append(try backing.read(position, available)) }
                if available < amount { result.append(Data(count: amount - available)) }
            }
            position += UInt64(amount)
        }
        return result
    }

    private func clusterEntry(_ cluster: UInt64) throws -> UInt64 {
        let l2Count = clusterSize / 8
        let entry = l1.bigEndian64(Int((cluster / l2Count) * 8))
        guard entry & ~(Self.offsetMask | Self.copiedFlag) == 0 else { throw CocoaError(.fileReadCorruptFile) }
        if entry == 0 { return 0 }
        let offset = entry & Self.offsetMask
        guard offset >= clusterSize, offset.isMultiple(of: clusterSize) else { throw CocoaError(.fileReadCorruptFile) }
        if cachedL2?.offset != offset {
            cachedL2 = (offset, try image.read(offset, Int(clusterSize)))
        }
        let descriptor = cachedL2!.entries.bigEndian64(Int((cluster % l2Count) * 8))
        guard descriptor & ~(Self.offsetMask | Self.copiedFlag | zeroFlag) == 0 else { throw CocoaError(.fileReadUnsupportedScheme) }
        return descriptor
    }
}

private extension Data {
    func bigEndian32(_ offset: Int) -> UInt32 {
        withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }
    func bigEndian64(_ offset: Int) -> UInt64 {
        withUnsafeBytes { UInt64(bigEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) }
    }
}
