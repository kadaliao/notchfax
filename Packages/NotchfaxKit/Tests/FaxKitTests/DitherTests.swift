import Compression
import CoreGraphics
import Foundation
import ImageIO
import PrintKit
import Testing

@testable import FaxKit

/// A port of the server's check (server/src/png.ts): signature, IHDR first with colour
/// type 0 and bit depth 1, every chunk's length and CRC, an IDAT, IEND last, ≤ 64 KB.
private func serverAccepts(_ png: Data) -> (ok: Bool, width: Int, height: Int, reason: String) {
    let bytes = [UInt8](png)
    guard bytes.count <= 64 * 1024 else { return (false, 0, 0, "too large") }
    guard bytes.count >= 45, Array(bytes[0..<8]) == PNGEncoder.signature else { return (false, 0, 0, "signature") }
    func u32(_ i: Int) -> Int { Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16 | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3]) }
    var offset = 8, first = true, width = 0, height = 0, sawIDAT = false, sawIEND = false
    while offset < bytes.count {
        guard offset + 12 <= bytes.count else { return (false, 0, 0, "truncated") }
        let length = u32(offset)
        let type = String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self)
        let dataEnd = offset + 8 + length
        guard dataEnd + 4 <= bytes.count else { return (false, 0, 0, "truncated chunk") }
        guard UInt32(u32(dataEnd)) == PNGEncoder.crc32(bytes[(offset + 4)..<dataEnd]) else { return (false, 0, 0, "crc \(type)") }
        if first {
            guard type == "IHDR", length == 13 else { return (false, 0, 0, "IHDR first") }
            width = u32(offset + 8)
            height = u32(offset + 12)
            let (depth, colour, compression, filter, interlace) = (bytes[offset + 16], bytes[offset + 17], bytes[offset + 18], bytes[offset + 19], bytes[offset + 20])
            guard colour == 0, depth == 1, compression == 0, filter == 0, interlace <= 1 else { return (false, 0, 0, "IHDR fields") }
            guard (1...384).contains(width), (1...768).contains(height) else { return (false, 0, 0, "dimensions") }
            first = false
        } else if type == "IDAT" {
            sawIDAT = true
        } else if type == "IEND" {
            sawIEND = true
            offset = dataEnd + 4
            break
        }
        offset = dataEnd + 4
    }
    guard sawIDAT, sawIEND, offset == bytes.count else { return (false, 0, 0, "structure") }
    return (true, width, height, "")
}

/// Decodes with ImageIO and returns ink per pixel (1 = black), to prove the zlib stream is valid.
private func decodeInk(_ png: Data) -> [UInt8]? {
    guard let source = CGImageSourceCreateWithData(png as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
    else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard let data = context.data else { return nil }
    let pixels = data.assumingMemoryBound(to: UInt8.self)
    return (0..<(image.width * image.height)).map { pixels[$0] < 128 ? 1 : 0 }
}

private func gradient(width: Int, height: Int) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let colours = [CGColor(srgbRed: 0.05, green: 0.1, blue: 0.3, alpha: 1), CGColor(srgbRed: 1, green: 0.85, blue: 0.6, alpha: 1)] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colours, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
    return context.makeImage()!
}

/// White noise: the least compressible picture there is.
private func noise(width: Int, height: Int) -> CGImage {
    var generator = SystemRandomNumberGenerator()
    let bytes = (0..<(width * height)).map { _ in UInt8.random(in: 0...255, using: &generator) }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                   decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

@Suite struct DitherTests {
    @Test func `a photo becomes a 1-bit grayscale PNG the server accepts`() throws {
        let result = try FaxDither.make(from: gradient(width: 1600, height: 1200))
        #expect(result.width == 276 && result.height == 207)
        let bytes = [UInt8](result.png)
        // IHDR straight after the signature: width, height, bit depth 1, colour type 0.
        #expect(Array(bytes[12..<16]) == Array("IHDR".utf8))
        #expect(Array(bytes[16..<24]) == [0, 0, 1, 0x14, 0, 0, 0, 0xCF])
        #expect(bytes[24] == 1, "bit depth")
        #expect(bytes[25] == 0, "colour type")
        #expect(Array(bytes[26..<29]) == [0, 0, 0], "deflate, filter 0, not interlaced")
        let check = serverAccepts(result.png)
        #expect(check.ok, "\(check.reason)")
        #expect(result.png.count <= 64 * 1024)
    }

    @Test func `the PNG decodes to exactly the dots that were previewed`() throws {
        let result = try FaxDither.make(from: gradient(width: 500, height: 500))
        let decoded = try #require(decodeInk(result.png))
        #expect(decoded == result.bits.ink)
        // A gradient dithers to a mix, not to all black or all white.
        let inked = result.bits.ink.reduce(0) { $0 + Int($1) }
        #expect(inked > result.bits.ink.count / 10 && inked < result.bits.ink.count * 9 / 10)
    }

    @Test func `the worst case still fits under 64 KB`() throws {
        let result = try FaxDither.make(from: noise(width: 384, height: 768))
        #expect(result.width == 276 && result.height == 552)
        #expect(result.png.count <= 64 * 1024)
        #expect(serverAccepts(result.png).ok)
    }

    @Test(arguments: [(4000, 1000, 276, 69), (300, 3000, 77, 768), (100, 100, 276, 276), (384, 768, 276, 552)])
    func `pictures fill the print width within the page limits`(input: (Int, Int, Int, Int)) {
        let size = FaxDither.targetSize(width: input.0, height: input.1)
        #expect(size.width == input.2 && size.height == input.3)
    }

    @Test func `odd widths pad their last byte and still validate`() throws {
        let ink = (0..<(13 * 7)).map { UInt8($0 % 3 == 0 ? 1 : 0) }
        let png = PNGEncoder.encodeBilevel(width: 13, height: 7, ink: ink)
        #expect(serverAccepts(png).ok)
        #expect(decodeInk(png) == ink)
    }

    @Test func `stored deflate blocks are a valid fallback`() throws {
        let raw = (0..<150_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        let stream = [0x78, 0x01] + PNGEncoder.storedBlocks(raw) + PNGEncoder.adler32(raw).bigEndianBytes
        let inflated = try #require(inflate(Data(stream)))
        #expect([UInt8](inflated) == raw)
    }

    @Test func `checksums match known values`() {
        #expect(PNGEncoder.crc32(Array("IEND".utf8)) == 0xAE42_6082)
        #expect(PNGEncoder.adler32(Array("Wikipedia".utf8)) == 0x11E6_0398)
    }

    @Test func `pictures are dithered at the width of the print head`() {
        #expect(FaxDither.printWidth == Paper.thermalContentDots)
        #expect(FaxDither.printWidth <= FaxDither.maxWidth)
    }

    @Test func `a wider picture from another client is reduced dot for dot, a native one is left alone`() throws {
        let native = try #require(try FaxDither.make(from: gradient(width: 800, height: 600)).bits.cgImage())
        #expect(FaxDither.printable(native).width == 276)
        let wide = try #require(BilevelImage(width: 384, height: 10, ink: (0..<3840).map { UInt8($0 % 2) }).cgImage())
        let reduced = FaxDither.printable(wide)
        #expect(reduced.width == 276)
        let bits = try #require(BilevelImage(thresholding: reduced))
        #expect(bits.ink.contains(0) && bits.ink.contains(1))
    }

    @Test func `fitting the dots to the compose sheet keeps them strictly black or white`() throws {
        let result = try FaxDither.make(from: gradient(width: 800, height: 600))
        let small = result.bits.resampled(toWidth: 276)
        #expect(small.width == 276 && small.height == 207)
        #expect(small.ink.allSatisfy { $0 == 0 || $0 == 1 })
        // Tone survives: the share of inked dots barely moves.
        let before = Double(result.bits.ink.reduce(0) { $0 + Int($1) }) / Double(result.bits.ink.count)
        let after = Double(small.ink.reduce(0) { $0 + Int($1) }) / Double(small.ink.count)
        #expect(abs(before - after) < 0.03)
    }

    @Test func `blank and solid pictures are handled`() throws {
        let white = PNGEncoder.encodeBilevel(width: 8, height: 2, ink: [UInt8](repeating: 0, count: 16))
        let black = PNGEncoder.encodeBilevel(width: 8, height: 2, ink: [UInt8](repeating: 1, count: 16))
        #expect(serverAccepts(white).ok && serverAccepts(black).ok)
        #expect(decodeInk(black) == [UInt8](repeating: 1, count: 16))
    }
}

/// zlib inflate via Compression (skipping the 2-byte header), for checking stored blocks.
private func inflate(_ zlib: Data) -> Data? {
    let body = [UInt8](zlib.dropFirst(2).dropLast(4))
    var output = [UInt8](repeating: 0, count: 400_000)
    let count = body.withUnsafeBufferPointer { source in
        output.withUnsafeMutableBufferPointer { destination in
            compression_decode_buffer(destination.baseAddress!, destination.count, source.baseAddress!, source.count, nil, COMPRESSION_ZLIB)
        }
    }
    return count > 0 ? Data(output.prefix(count)) : nil
}

