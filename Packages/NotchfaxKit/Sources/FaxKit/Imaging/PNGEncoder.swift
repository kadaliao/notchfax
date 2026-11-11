import Compression
import Foundation

/// Writes 1-bit grayscale PNGs (colour type 0, bit depth 1) by hand. ImageIO picks its
/// own pixel format and will not reliably emit a true 1-bit file, which the server requires.
enum PNGEncoder {
    static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// - Parameter ink: row-major, one byte per pixel, non-zero = black.
    static func encodeBilevel(width: Int, height: Int, ink: [UInt8]) -> Data {
        precondition(width > 0 && height > 0 && ink.count == width * height, "pixel count must match the size")
        let rowBytes = (width + 7) / 8
        var raw = [UInt8](repeating: 0, count: (rowBytes + 1) * height)
        for y in 0..<height {
            let start = y * (rowBytes + 1)
            raw[start] = 0 // filter: None
            for byte in 0..<rowBytes {
                var packed: UInt8 = 0
                for bit in 0..<8 {
                    let x = byte * 8 + bit
                    // In a grayscale PNG, 1 is white. Padding bits past the edge stay 0.
                    if x < width, ink[y * width + x] == 0 { packed |= 0x80 >> UInt8(bit) }
                }
                raw[start + 1 + byte] = packed
            }
        }

        var header = [UInt8]()
        header.appendBigEndian(UInt32(width))
        header.appendBigEndian(UInt32(height))
        header += [1, 0, 0, 0, 0] // bit depth 1, colour type 0, deflate, filter method 0, no interlace

        var png = Data(signature)
        appendChunk("IHDR", header, to: &png)
        appendChunk("IDAT", zlib(raw), to: &png)
        appendChunk("IEND", [], to: &png)
        return png
    }

    static func appendChunk(_ type: String, _ data: [UInt8], to png: inout Data) {
        var chunk = [UInt8]()
        chunk.appendBigEndian(UInt32(data.count))
        let typeBytes = Array(type.utf8)
        chunk += typeBytes
        chunk += data
        chunk.appendBigEndian(crc32(typeBytes + data))
        png.append(contentsOf: chunk)
    }

    // MARK: zlib (RFC 1950) around raw DEFLATE (RFC 1951)

    static func zlib(_ raw: [UInt8]) -> [UInt8] {
        if let deflated = deflate(raw) {
            return [0x78, 0x9C] + deflated + adler32(raw).bigEndianBytes
        }
        return [0x78, 0x01] + storedBlocks(raw) + adler32(raw).bigEndianBytes
    }

    /// Compression's `COMPRESSION_ZLIB` produces raw DEFLATE without the zlib wrapper.
    static func deflate(_ raw: [UInt8]) -> [UInt8]? {
        guard !raw.isEmpty else { return nil }
        let capacity = raw.count + raw.count / 64 + 1024
        var output = [UInt8](repeating: 0, count: capacity)
        let written = raw.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                compression_encode_buffer(
                    destination.baseAddress!, capacity,
                    source.baseAddress!, raw.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else { return nil }
        return Array(output.prefix(written))
    }

    /// DEFLATE without compression: always valid, used if the compressor declines.
    static func storedBlocks(_ raw: [UInt8]) -> [UInt8] {
        var out = [UInt8]()
        var offset = 0
        repeat {
            let length = min(65_535, raw.count - offset)
            let final = offset + length >= raw.count
            out.append(final ? 0x01 : 0x00)
            out.append(UInt8(length & 0xFF))
            out.append(UInt8(length >> 8))
            out.append(UInt8(~length & 0xFF))
            out.append(UInt8((~length >> 8) & 0xFF))
            out += raw[offset..<(offset + length)]
            offset += length
        } while offset < raw.count
        return out
    }

    static func adler32(_ bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        var index = 0
        while index < bytes.count {
            // 5552 is the largest block that cannot overflow before the modulo.
            let end = min(index + 5552, bytes.count)
            while index < end {
                a &+= UInt32(bytes[index])
                b &+= a
                index += 1
            }
            a %= 65_521
            b %= 65_521
        }
        return (b << 16) | a
    }

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in bytes { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}

extension UInt32 {
    var bigEndianBytes: [UInt8] {
        [UInt8(self >> 24), UInt8((self >> 16) & 0xFF), UInt8((self >> 8) & 0xFF), UInt8(self & 0xFF)]
    }
}

extension [UInt8] {
    mutating func appendBigEndian(_ value: UInt32) {
        append(contentsOf: value.bigEndianBytes)
    }
}
