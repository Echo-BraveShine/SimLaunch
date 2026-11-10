import Foundation

/// Bounded, read-only access to regular ext4 files. Never mounts or writes an image.
/// Only the selected file's directory chain and extent tree are read.
final class Ext4ImageReader {
    static let archiveLimit = 256 * 1024 * 1024
    private let readBytes: (UInt64, Int) throws -> Data
    private let length: UInt64
    private let blockSize: UInt64
    private let inodesPerGroup: UInt64
    private let inodeSize: UInt64
    private let descriptorSize: UInt64
    private let inodeCount: UInt64
    private let wide: Bool
    enum Failure: Error { case unsupported, corrupt, missing, tooLarge }
    convenience init(url: URL) throws {
        let image = try ReadOnlyImageFile(url: url)
        try self.init(length: image.length, read: image.read)
    }
    convenience init(qcow2URL: URL, backingURL: URL) throws {
        let image = try QCOW2ImageReader(url: qcow2URL, backingURL: backingURL)
        try self.init(length: image.length, read: image.read)
    }
    private init(length: UInt64, read: @escaping (UInt64, Int) throws -> Data) throws {
        self.length = length
        readBytes = read
        let superblock = try read(1024, 1024)
        guard superblock.count == 1024, superblock.u16(56) == 0xEF53 else { throw Failure.unsupported }
        let log = superblock.u32(24), incompatible = superblock.u32(96)
        // An encryption-capable filesystem can still contain ordinary inodes. contentSize rejects encrypted inodes.
        guard log <= 6, incompatible & (0x10 | 0x8000 | 0x100000) == 0, superblock.u32(100) & 0x200 == 0 else { throw Failure.unsupported }
        blockSize = 1024 << log; inodesPerGroup = UInt64(superblock.u32(40)); inodeSize = UInt64(superblock.u16(88))
        wide = incompatible & 0x80 != 0
        descriptorSize = wide ? max(64, UInt64(superblock.u16(254))) : 32
        inodeCount = UInt64(superblock.u32(0))
        guard inodesPerGroup > 0, inodeSize >= 128, inodeSize <= blockSize, descriptorSize <= blockSize else { throw Failure.corrupt }
    }
    private func read(_ offset: UInt64, _ count: Int) throws -> Data {
        try Task.checkCancellation()
        guard count >= 0, count <= 67_108_864, offset <= length, UInt64(count) <= length - offset else { throw Failure.corrupt }
        let data = try readBytes(offset, count)
        guard data.count == count else { throw Failure.corrupt }
        return data
    }
    private func inode(_ number: UInt64) throws -> Data {
        guard number > 0, number <= inodeCount else { throw Failure.corrupt }
        let group = (number - 1) / inodesPerGroup
        let descriptor = try read((blockSize == 1024 ? 2 : 1) * blockSize + group * descriptorSize, Int(descriptorSize))
        let table = UInt64(descriptor.u32(8)) | (wide ? UInt64(descriptor.u32(40)) << 32 : 0)
        guard table <= length / blockSize else { throw Failure.corrupt }
        return try read(table * blockSize + ((number - 1) % inodesPerGroup) * inodeSize, Int(inodeSize))
    }
    private struct Extent { let logical: UInt64; let count: UInt64; let physical: UInt64 }
    private func extents(_ node: Data, depth: Int = 0, seen: inout Set<UInt64>) throws -> [Extent] {
        guard node.count >= 12, node.u16(0) == 0xF30A, depth <= 5 else { throw Failure.unsupported }
        let entries = Int(node.u16(2)), level = Int(node.u16(6))
        guard level <= 5 - depth, 12 + entries * 12 <= node.count else { throw Failure.corrupt }
        var result: [Extent] = []
        for i in 0..<entries {
            let offset = 12 + i * 12
            if level == 0 {
                let count = UInt64(node.u16(offset + 4))
                guard count > 0, count <= 32768 else { continue } // Uninitialized extents are not file content.
                result.append(Extent(logical: UInt64(node.u32(offset)), count: count, physical: UInt64(node.u32(offset + 8)) | UInt64(node.u16(offset + 6)) << 32))
            } else {
                let block = UInt64(node.u32(offset + 4)) | UInt64(node.u16(offset + 8)) << 32
                guard block <= length / blockSize, seen.insert(block).inserted, seen.count <= 4096 else { throw Failure.corrupt }
                let child = try read(block * blockSize, Int(blockSize))
                guard Int(child.u16(6)) == level - 1 else { throw Failure.corrupt }
                result += try extents(child, depth: depth + 1, seen: &seen)
            }
            guard result.count <= 65536 else { throw Failure.corrupt }
        }
        return result
    }
    private func contentSize(_ record: Data, limit: Int) throws -> UInt64 {
        guard record.u32(32) & 0x80000 != 0, record.u32(32) & (0x4 | 0x800 | 0x10000000) == 0 else { throw Failure.unsupported }
        let size = UInt64(record.u32(4)) | UInt64(record.u32(108)) << 32
        guard limit > 0, size <= UInt64(limit) else { throw Failure.tooLarge }
        return size
    }
    private func readContents(_ record: Data, size: UInt64, consume: (UInt64, Data) throws -> Void) throws {
        var seen = Set<UInt64>()
        for extent in try extents(Data(record[40..<100]), seen: &seen) {
            guard extent.logical <= size / blockSize, extent.physical <= length / blockSize else { throw Failure.corrupt }
            let start = extent.logical * blockSize
            let count = min(extent.count * blockSize, size - start)
            let physical = extent.physical * blockSize
            let chunk: UInt64 = 1_048_576
            for offset in stride(from: 0, to: Int(count), by: Int(chunk)) {
                let relative = UInt64(offset)
                let bytes = try read(physical + relative, Int(min(chunk, count - relative)))
                try consume(start + relative, bytes)
            }
        }
    }
    private func contents(_ record: Data, limit: Int) throws -> Data {
        let size = try contentSize(record, limit: limit)
        var data = Data(count: Int(size))
        try readContents(record, size: size) { offset, bytes in
            let start = Int(offset)
            data.replaceSubrange(start..<(start + bytes.count), with: bytes)
        }
        return data
    }
    private func fileRecord(at path: String) throws -> Data {
        let components = path.split(separator: "/")
        guard !components.contains(".."), components.count <= 32 else { throw Failure.missing }
        var current: UInt64 = 2
        for component in components {
            let record = try inode(current)
            guard record.u16(0) & 0xF000 == 0x4000 else { throw Failure.missing }
            let directory = try contents(record, limit: 4_194_304)
            var offset = 0, found: UInt64?
            while offset + 8 <= directory.count {
                let next = Int(directory.u16(offset + 4)), nameLength = Int(directory[offset + 6])
                guard next >= 8, offset + next <= directory.count, nameLength <= next - 8 else { throw Failure.corrupt }
                let number = UInt64(directory.u32(offset))
                if number != 0, let name = String(data: directory[(offset + 8)..<(offset + 8 + nameLength)], encoding: .utf8), name == String(component) { found = number; break }
                offset += next
            }
            guard let found else { throw Failure.missing }; current = found
        }
        let record = try inode(current)
        guard record.u16(0) & 0xF000 == 0x8000 else { throw Failure.unsupported }
        return record
    }

    /// Copy the HAP to a fresh temporary file without loading the package into memory.
    func copyFile(at path: String, to destination: URL, limit: Int = Ext4ImageReader.archiveLimit) throws {
        let record = try fileRecord(at: path)
        let size = try contentSize(record, limit: min(limit, 512 * 1024 * 1024))
        guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            try output.truncate(atOffset: size)
            try readContents(record, size: size) { offset, bytes in
                try output.seek(toOffset: offset)
                try output.write(contentsOf: bytes)
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}
private extension Data {
    func u16(_ offset: Int) -> UInt16 { UInt16(self[offset]) | UInt16(self[offset + 1]) << 8 }
    func u32(_ offset: Int) -> UInt32 { UInt32(u16(offset)) | UInt32(u16(offset + 2)) << 16 }
}
