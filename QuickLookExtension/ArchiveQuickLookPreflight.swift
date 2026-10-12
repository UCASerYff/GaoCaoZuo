import Foundation
import Darwin

/// A small, bounded 7z header validator used before the system library sees an
/// untrusted encoded header. It neither decompresses nor extracts any member.
/// Format reference: https://github.com/ip7z/7zip/blob/main/DOC/7zFormat.txt
/// Unusual graphs, codecs, external metadata and encrypted headers are left to
/// the main application instead of being partially accepted by Quick Look.
enum ArchiveQuickLookPreflight {
    private enum Failure: LocalizedError {
        case malformed, budget, unsupported, encrypted
        var errorDescription: String? {
            switch self {
            case .malformed: return "压缩包目录不完整或格式异常，请用搞操作打开。"
            case .budget: return "压缩包目录超出空格预览预算，请用搞操作打开。"
            case .unsupported: return "此 7Z 目录结构暂不支持空格预览，请用搞操作打开。"
            case .encrypted: return "此压缩包目录已加密，请用搞操作打开并输入密码。"
            }
        }
    }

    static func validate(handle: FileHandle, maxMetadataBytes: Int = 4 * 1_024 * 1_024,
                         maxDictionaryBytes: Int = 64 * 1_024 * 1_024,
                         maxEntries: Int = 10_000,
                         maxDataBytes: UInt64 = 128 * 1_024 * 1_024, timeoutSeconds: Double = 5) throws {
        guard timeoutSeconds.isFinite, timeoutSeconds > 0 else { throw Failure.budget }
        let deadline = ProcessInfo.processInfo.systemUptime + timeoutSeconds
        var status = stat()
        guard fstat(handle.fileDescriptor, &status) == 0, status.st_size >= 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw Failure.malformed }
        let fileSize = UInt64(status.st_size)
        let prefix = try read(handle.fileDescriptor, offset: 0, count: Int(min(fileSize, 32)))
        guard prefix.count >= 6, Array(prefix.prefix(6)) == [0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c] else { return }
        guard prefix.count == 32, prefix[6] == 0 else { throw Failure.malformed }
        guard maxMetadataBytes > 0, maxDictionaryBytes > 0, maxEntries > 0 else { throw Failure.budget }
        guard crc32(prefix.subdata(in: 12..<32)) == little32(prefix, 8) else { throw Failure.malformed }
        let relative = little64(prefix, 12), length = little64(prefix, 20)
        let (position, overflow) = relative.addingReportingOverflow(32)
        guard !overflow, position <= fileSize, length <= fileSize - position else { throw Failure.malformed }
        guard length <= UInt64(maxMetadataBytes) else { throw Failure.budget }
        if length == 0 { return }
        let bytes = try read(handle.fileDescriptor, offset: position, count: Int(length))
        guard crc32(bytes) == little32(prefix, 28) else { throw Failure.malformed }
        var cursor = Cursor(bytes: bytes, maxMetadata: maxMetadataBytes,
                            maxDictionary: maxDictionaryBytes, maxEntries: maxEntries,
                            maxData: maxDataBytes, headerPosition: position, deadline: deadline)
        let kind = try cursor.byte()
        if kind == 0x17 {
            try cursor.streams(encoded: true)
        } else if kind == 0x01 {
            try cursor.header()
        } else { throw Failure.unsupported }
        guard cursor.position == bytes.count else { throw Failure.malformed }
        if kind == 0x17 {
            guard let metadata = cursor.encoded else { throw Failure.unsupported }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure.budget }
            let packed = try read(handle.fileDescriptor, offset: metadata.position, count: metadata.packedSize)
            let decoded: Data
            if metadata.method == 0 {
                guard packed.count == metadata.unpackedSize else { throw Failure.malformed }; decoded = packed
            } else if metadata.method == 0x030101 {
                // The system decoder sees only a bounded LZMA-alone stream, not
                // a 7z header. It cannot allocate a 7z entry table before our
                // file-count and codec-budget checks have run.
                var alone = metadata.properties
                let amount = UInt64(metadata.unpackedSize)
                for shift in 0..<8 { alone.append(UInt8(truncatingIfNeeded: amount >> (shift * 8))) }
                alone.append(packed)
                decoded = try decodeLZMA(alone, expected: metadata.unpackedSize, deadline: deadline)
            } else { throw Failure.unsupported }
            var decodedCursor = Cursor(bytes: decoded, maxMetadata: maxMetadataBytes,
                                       maxDictionary: maxDictionaryBytes, maxEntries: maxEntries,
                                       maxData: maxDataBytes, headerPosition: position, deadline: deadline)
            guard try decodedCursor.byte() == 0x01 else { throw Failure.unsupported }
            try decodedCursor.header()
            guard decodedCursor.position == decoded.count else { throw Failure.malformed }
        }
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure.budget }
    }

    private static func read(_ descriptor: Int32, offset: UInt64, count: Int) throws -> Data {
        guard count >= 0, offset <= UInt64(Int64.max), UInt64(count) <= UInt64(Int64.max) - offset else { throw Failure.malformed }
        var bytes = Data(count: count), actual = 0, interrupts = 0
        try bytes.withUnsafeMutableBytes { buffer in
            while actual < count {
                let result = pread(descriptor, buffer.baseAddress!.advanced(by: actual), count - actual, off_t(offset) + off_t(actual))
                if result < 0, errno == EINTR, interrupts < 8 { interrupts += 1; continue }
                guard result > 0 else { throw Failure.malformed }
                actual += result
            }
        }
        return bytes
    }
    private static func little32(_ bytes: Data, _ offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << ($1 * 8) }
    }
    private static func little64(_ bytes: Data, _ offset: Int) -> UInt64 {
        (0..<8).reduce(0) { $0 | UInt64(bytes[offset + $1]) << ($1 * 8) }
    }
    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xedb88320) }
        return crc
    }
    private static func crc32(_ bytes: Data) -> UInt32 {
        var result: UInt32 = 0xffff_ffff
        for byte in bytes { result = crcTable[Int((result ^ UInt32(byte)) & 255)] ^ (result >> 8) }
        return result ^ 0xffff_ffff
    }

    private struct EncodedMetadata {
        var method: UInt64 = 0
        var properties = Data()
        var position: UInt64 = 0
        var packedSize = 0
        var unpackedSize = 0
    }

    /// Only bounded header bytes are decoded. No archive extraction/write API
    /// or external-program filter is registered.
    private static func decodeLZMA(_ input: Data, expected: Int, deadline: Double) throws -> Data {
        guard let library = dlopen("/usr/lib/libarchive.2.dylib", RTLD_NOW | RTLD_LOCAL) else { throw Failure.unsupported }
        defer { dlclose(library) }
        func bind<T>(_ name: String, _ type: T.Type) throws -> T {
            guard let symbol = dlsym(library, name) else { throw Failure.unsupported }
            return unsafeBitCast(symbol, to: type)
        }
        typealias New = @convention(c) () -> UnsafeMutableRawPointer?
        typealias Single = @convention(c) (UnsafeMutableRawPointer?) -> Int32
        typealias Open = @convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?, Int) -> Int32
        typealias Header = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32
        typealias Read = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int) -> Int
        let new = try bind("archive_read_new", New.self), free = try bind("archive_read_free", Single.self)
        let filter = try bind("archive_read_support_filter_lzma", Single.self), raw = try bind("archive_read_support_format_raw", Single.self)
        let open = try bind("archive_read_open_memory", Open.self), header = try bind("archive_read_next_header", Header.self)
        let read = try bind("archive_read_data", Read.self)
        guard let reader = new() else { throw Failure.unsupported }
        defer { _ = free(reader) }
        guard filter(reader) == 0, raw(reader) == 0 else { throw Failure.unsupported }
        return try input.withUnsafeBytes { source in
            guard open(reader, source.baseAddress, source.count) == 0 else { throw Failure.malformed }
            var entry: UnsafeMutableRawPointer?
            guard header(reader, &entry) == 0 else { throw Failure.malformed }
            var output = Data(count: expected + 1), actual = 0
            try output.withUnsafeMutableBytes { destination in
                while actual < destination.count {
                    guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure.budget }
                    let amount = read(reader, destination.baseAddress!.advanced(by: actual), min(65_536, destination.count - actual))
                    guard amount >= 0 else { throw Failure.malformed }
                    if amount == 0 { break }
                    actual += amount
                }
            }
            guard actual == expected else { throw Failure.budget }
            output.count = expected
            return output
        }
    }

    private struct Folder { let outputs: Int; var hasCRC = false }
    private struct Cursor {
        let bytes: Data
        let maxMetadata: Int
        let maxDictionary: Int
        let maxEntries: Int
        let maxData: UInt64
        let headerPosition: UInt64
        let deadline: Double
        var position = 0
        var encoded: EncodedMetadata?

        mutating func byte() throws -> UInt8 {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure.budget }
            guard position < bytes.count else { throw Failure.malformed }
            defer { position += 1 }; return bytes[position]
        }
        mutating func number() throws -> UInt64 {
            let first = try byte(); var mask: UInt8 = 0x80, result: UInt64 = 0
            for index in 0..<8 {
                if first & mask == 0 { return result | (UInt64(first & (mask - 1)) << (index * 8)) }
                result |= UInt64(try byte()) << (index * 8); mask >>= 1
            }
            return result
        }
        mutating func count(_ maximum: Int) throws -> Int {
            let value = try number()
            guard value <= UInt64(maximum) else { throw Failure.budget }
            return Int(value)
        }
        mutating func skip(_ amount: Int) throws {
            guard amount >= 0, amount <= bytes.count - position else { throw Failure.malformed }
            position += amount
        }
        mutating func digests(_ count: Int) throws -> [Bool] {
            guard count >= 0, count <= maxEntries else { throw Failure.budget }
            let all = try byte(); guard all <= 1 else { throw Failure.malformed }
            var values = [Bool](repeating: all == 1, count: count)
            if all == 0 {
                var mask: UInt8 = 0, bits: UInt8 = 0
                for index in 0..<count {
                    if mask == 0 { bits = try byte(); mask = 0x80 }
                    values[index] = bits & mask != 0; mask >>= 1
                }
            }
            try skip(values.filter { $0 }.count * 4)
            return values
        }
        mutating func folder(encoded: Bool) throws -> Folder {
            let coders = try count(8); guard coders > 0 else { throw Failure.unsupported }
            var inputs = 0, outputs = 0
            for _ in 0..<coders {
                let flags = try byte(), idLength = Int(flags & 0x0f)
                guard flags & 0xc0 == 0, idLength > 0, idLength <= 8 else { throw Failure.unsupported }
                var method: UInt64 = 0
                for _ in 0..<idLength { method = (method << 8) | UInt64(try byte()) }
                let inCount = flags & 0x10 != 0 ? try count(16) : 1
                let outCount = flags & 0x10 != 0 ? try count(16) : 1
                guard inCount > 0, outCount > 0, !encoded || (inCount == 1 && outCount == 1) else { throw Failure.unsupported }
                inputs += inCount; outputs += outCount
                let propertiesCount = flags & 0x20 != 0 ? try count(64) : 0
                let start = position; try skip(propertiesCount)
                let properties = bytes.subdata(in: start..<position)
                if encoded { self.encoded?.method = method; self.encoded?.properties = properties }
                if method == 0x06f10701 { throw Failure.encrypted }
                let dictionaryLimit = encoded ? min(maxDictionary, 8 * 1_024 * 1_024) : maxDictionary
                switch method {
                case 0:
                    guard properties.isEmpty else { throw Failure.unsupported }
                case 0x030101:
                    guard properties.count == 5, properties[0] < 225 else { throw Failure.unsupported }
                    let lc = Int(properties[0]) % 9, lp = (Int(properties[0]) / 9) % 5
                    guard lc + lp <= 4 else { throw Failure.unsupported }
                    guard UInt64(ArchiveQuickLookPreflight.little32(properties, 1)) <= UInt64(dictionaryLimit) else { throw Failure.budget }
                case 0x21:
                    guard properties.count == 1, properties[0] <= 40 else { throw Failure.unsupported }
                    let property = UInt64(properties[0])
                    let dictionary: UInt64 = property == 40 ? 0xffff_ffff : (2 | (property & 1)) << (property / 2 + 11)
                    guard dictionary <= UInt64(dictionaryLimit) else { throw Failure.budget }
                case 0x03030103, 0x03030205, 0x03030401, 0x03030501, 0x03030701, 0x03030805, 0x0a:
                    guard !encoded, properties.count == 0 || properties.count == 4 else { throw Failure.unsupported }
                case 0x03:
                    guard !encoded, properties.count == 1 else { throw Failure.unsupported }
                default: throw Failure.unsupported
                }
            }
            guard outputs > 0, inputs >= outputs, inputs <= 64, outputs <= 64, !encoded || coders == 1 else { throw Failure.unsupported }
            let bindings = outputs - 1
            var boundInputs = Set<Int>(), boundOutputs = Set<Int>()
            for _ in 0..<bindings {
                let input = try count(inputs - 1), output = try count(outputs - 1)
                guard boundInputs.insert(input).inserted, boundOutputs.insert(output).inserted else { throw Failure.malformed }
            }
            let packed = inputs - bindings
            guard packed > 0 else { throw Failure.malformed }
            if packed > 1 {
                var indices = Set<Int>()
                for _ in 0..<packed {
                    let index = try count(inputs - 1)
                    guard !boundInputs.contains(index), indices.insert(index).inserted else { throw Failure.malformed }
                }
            }
            return Folder(outputs: outputs)
        }
        mutating func streams(encoded: Bool) throws {
            var id = try byte(), packedCount = 0, folders: [Folder] = []
            if encoded { self.encoded = EncodedMetadata() }
            if id == 0x06 {
                let packedPosition = try number(); packedCount = try count(maxEntries)
                guard packedCount > 0, !encoded || packedCount == 1 else { throw Failure.unsupported }
                id = try byte(); guard id == 0x09 else { throw Failure.malformed }
                var packedTotal: UInt64 = 0
                for _ in 0..<packedCount {
                    let length = try number(), (sum, overflow) = packedTotal.addingReportingOverflow(length)
                    guard !overflow else { throw Failure.malformed }; packedTotal = sum
                }
                let (packedAbsolute, overflow) = packedPosition.addingReportingOverflow(32)
                guard !overflow, packedAbsolute <= headerPosition, packedTotal <= headerPosition - packedAbsolute else { throw Failure.malformed }
                if encoded, packedTotal > UInt64(maxMetadata) { throw Failure.budget }
                if encoded { self.encoded?.position = packedAbsolute; self.encoded?.packedSize = Int(packedTotal) }
                id = try byte()
                if id == 0x0a { _ = try digests(packedCount); id = try byte() }
                guard id == 0 else { throw Failure.unsupported }; id = try byte()
            }
            if id == 0x07 {
                guard try byte() == 0x0b else { throw Failure.malformed }
                let total = try count(maxEntries)
                guard total > 0, !encoded || total == 1, try byte() == 0 else { throw Failure.unsupported }
                for _ in 0..<total { folders.append(try folder(encoded: encoded)) }
                guard try byte() == 0x0c else { throw Failure.malformed }
                var totalOutput: UInt64 = 0
                for item in folders {
                    for _ in 0..<item.outputs {
                        let value = try number(), limit = encoded ? UInt64(maxMetadata) : maxData
                        guard value <= limit else { throw Failure.budget }
                        if encoded { self.encoded?.unpackedSize = Int(value) }
                        let (sum, overflow) = totalOutput.addingReportingOverflow(value)
                        guard !overflow, sum <= limit else { throw Failure.budget }; totalOutput = sum
                    }
                }
                id = try byte()
                if id == 0x0a {
                    let hasCRC = try digests(folders.count)
                    for index in folders.indices { folders[index].hasCRC = hasCRC[index] }
                    id = try byte()
                }
                guard id == 0 else { throw Failure.unsupported }; id = try byte()
            }
            if encoded { guard packedCount == 1, folders.count == 1, id == 0 else { throw Failure.unsupported }; return }
            if id == 0x08 {
                var counts = [Int](repeating: 1, count: folders.count)
                id = try byte()
                if id == 0x0d {
                    var total = 0
                    for index in counts.indices {
                        counts[index] = try count(maxEntries); total += counts[index]
                        guard total <= maxEntries else { throw Failure.budget }
                    }
                    id = try byte()
                }
                if id == 0x09 {
                    for amount in counts { for _ in 0..<max(0, amount - 1) { guard try number() <= maxData else { throw Failure.budget } } }
                    id = try byte()
                }
                if id == 0x0a {
                    var digestCount = 0
                    for index in counts.indices { if counts[index] != 1 || !folders[index].hasCRC { digestCount += counts[index] } }
                    _ = try digests(digestCount); id = try byte()
                }
                guard id == 0 else { throw Failure.unsupported }; id = try byte()
            }
            guard id == 0 else { throw Failure.unsupported }
        }
        mutating func header() throws {
            var id = try byte()
            if id == 0x02 {
                while true {
                    let property = try byte(); if property == 0 { break }
                    try skip(try count(maxMetadata))
                }
                id = try byte()
            }
            // External metadata can reference a separately compressed stream.
            // This preview deliberately accepts inline metadata only.
            guard id != 0x03 else { throw Failure.unsupported }
            if id == 0x04 { try streams(encoded: false); id = try byte() }
            if id == 0x05 {
                let files = try count(maxEntries)
                while true {
                    let property = try byte(); if property == 0 { break }
                    let length = try count(maxMetadata), start = position
                    try skip(length)
                    let data = bytes.subdata(in: start..<position)
                    if property == 0x11 {
                        guard !data.isEmpty, data[0] == 0, (data.count - 1) % 2 == 0 else { throw Failure.unsupported }
                        var terminators = 0
                        for offset in stride(from: 1, to: data.count, by: 2) { if data[offset] == 0, data[offset + 1] == 0 { terminators += 1 } }
                        guard terminators == files else { throw Failure.malformed }
                    } else if [0x12, 0x13, 0x14, 0x15].contains(property) {
                        guard !data.isEmpty, data[0] <= 1 else { throw Failure.malformed }
                        let external = data[0] == 1 ? 1 : 1 + (files + 7) / 8
                        guard external < data.count, data[external] == 0 else { throw Failure.unsupported }
                    }
                }
                id = try byte()
            }
            guard id == 0 else { throw Failure.unsupported }
        }
    }
}
