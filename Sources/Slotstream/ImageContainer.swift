import Foundation

/// Validate PNG framing/checksums before handing bytes to ImageIO's lazy decoder.
/// A corrupt IDAT CRC can otherwise fail only during drawing, leaving a blank
/// image and a retained provider cycle on the review machine. Other formats
/// continue through their existing decoder checks.
package enum ImageContainer {
    private static let pngSignature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 0 ? 0 : 0xEDB88320) }
        return crc
    }

    package static func validatePNG(_ data: Data) throws {
        guard data.starts(with: pngSignature) else { return }
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            func uint32(_ offset: Int) -> UInt32 {
                (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16)
                    | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
            }
            var offset = 8
            while offset < bytes.count {
                guard bytes.count - offset >= 12 else {
                    throw VisionError.msg("PNG chunk is truncated")
                }
                let length = Int(uint32(offset))
                guard length <= bytes.count - offset - 12 else {
                    throw VisionError.msg("PNG chunk is truncated")
                }
                let end = offset + 8 + length
                var crc: UInt32 = 0xFFFFFFFF
                for index in (offset + 4)..<end {
                    crc = crcTable[Int((crc ^ UInt32(bytes[index])) & 255)] ^ (crc >> 8)
                }
                guard crc ^ 0xFFFFFFFF == uint32(end) else {
                    throw VisionError.msg("PNG chunk checksum is invalid; send an intact image")
                }
                offset = end + 4
            }
        }
    }
}
