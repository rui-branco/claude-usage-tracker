import Foundation

// MARK: - Grok Rate Limit Status

struct GrokRateLimitStatus {
    /// Percent of weekly SuperGrok limit used (0-100).
    let usedPercent: Double
    /// Start of the current billing period.
    let periodStart: Date?
    /// When the weekly limit resets.
    let resetAt: Date?
    /// When this data was fetched.
    let updatedAt: Date

    /// Stale when the reset window has passed or the observation is too old.
    var isStale: Bool {
        if let reset = resetAt, reset < Date() { return true }
        return Date().timeIntervalSince(updatedAt) > 30 * 60
    }
}

// MARK: - gRPC-Web Response Parser

/// Parses the gRPC-Web/protobuf response from Grok's GetGrokCreditsConfig endpoint.
///
/// Response wire format (observed):
/// - Frame 1: 5-byte header [0x00, length(4 BE)] + protobuf payload
/// - Frame 2: trailers [0x80, length(4 BE)] + "grpc-status:0\r\n"
///
/// The protobuf payload is a top-level message whose field 1 is the usage config:
/// - field 1 (fixed32): percent used as IEEE 754 float (1.0 = 1%)
/// - field 4 (message): period start Timestamp { seconds(1), nanos(2) }
/// - field 5 (message): next reset Timestamp { seconds(1), nanos(2) }
enum GrokProtobufParser {
    struct ParseResult {
        let usedPercent: Double
        let periodStart: Date?
        let resetAt: Date?
    }

    enum ParseError: Error {
        case malformed
        case authRequired(grpcStatus: Int, message: String?)
        case serverError(grpcStatus: Int, message: String?)
    }

    /// Parses the raw gRPC-Web response bytes.
    /// Returns success with parsed data, or throws an error for auth/server failures.
    static func parse(_ data: Data) throws -> ParseResult {
        guard data.count >= 5 else { throw ParseError.malformed }

        // Read first frame header
        let compressed = data[0]
        guard compressed == 0 else { throw ParseError.malformed } // uncompressed only
        let payloadLength = Int(UInt32(bigEndian: data[1..<5].withUnsafeBytes { $0.load(as: UInt32.self) }))
        guard data.count >= 5 + payloadLength else { throw ParseError.malformed }

        let payload = data[5..<(5 + payloadLength)]

        // Parse trailers frame to check gRPC status
        let trailersStart = 5 + payloadLength
        if data.count > trailersStart + 5 {
            let trailerFlag = data[trailersStart]
            if trailerFlag == 0x80 {
                let trailerLen = Int(UInt32(bigEndian: data[(trailersStart + 1)..<(trailersStart + 5)].withUnsafeBytes { $0.load(as: UInt32.self) }))
                if data.count >= trailersStart + 5 + trailerLen {
                    let trailerData = data[(trailersStart + 5)..<(trailersStart + 5 + trailerLen)]
                    if let trailerStr = String(data: trailerData, encoding: .utf8) {
                        // Check for grpc-status
                        if let range = trailerStr.range(of: "grpc-status:") {
                            let statusStart = trailerStr[range.upperBound...]
                            let statusEnd = statusStart.firstIndex(of: "\r") ?? statusStart.endIndex
                            let statusStr = String(statusStart[..<statusEnd])
                            if let statusCode = Int(statusStr), statusCode != 0 {
                                // Extract grpc-message if present
                                var message: String?
                                if let msgRange = trailerStr.range(of: "grpc-message:") {
                                    let msgStart = trailerStr[msgRange.upperBound...]
                                    let msgEnd = msgStart.firstIndex(of: "\r") ?? msgStart.endIndex
                                    message = String(msgStart[..<msgEnd])
                                        .removingPercentEncoding
                                }

                                // Status 16 = UNAUTHENTICATED, 7 = PERMISSION_DENIED
                                // These indicate auth issues, not zero usage
                                if statusCode == 16 || statusCode == 7 ||
                                   (message?.lowercased().contains("no-credentials") == true) ||
                                   (message?.lowercased().contains("unauthenticated") == true) {
                                    throw ParseError.authRequired(grpcStatus: statusCode, message: message)
                                }

                                throw ParseError.serverError(grpcStatus: statusCode, message: message)
                            }
                        }
                    }
                }
            }
        }

        // Parse the top-level protobuf: field 1 is the nested config message
        guard let configData = extractField(from: payload, fieldNumber: 1, wireType: .lengthDelimited) else {
            throw ParseError.malformed
        }

        // Parse the config message
        var usedPercent: Double = 0
        var periodStart: Date?
        var resetAt: Date?

        // Field 1: percent used (fixed32 = float)
        if let floatData = extractField(from: configData, fieldNumber: 1, wireType: .fixed32),
           floatData.count == 4 {
            let bits = floatData.withUnsafeBytes { $0.load(as: UInt32.self) }
            let floatVal = Float(bitPattern: bits)
            usedPercent = Double(floatVal)
        }

        // Field 4: period start Timestamp
        if let tsData = extractField(from: configData, fieldNumber: 4, wireType: .lengthDelimited) {
            periodStart = parseTimestamp(tsData)
        }

        // Field 5: next reset Timestamp
        if let tsData = extractField(from: configData, fieldNumber: 5, wireType: .lengthDelimited) {
            resetAt = parseTimestamp(tsData)
        }

        return ParseResult(usedPercent: usedPercent, periodStart: periodStart, resetAt: resetAt)
    }

    // MARK: - Protobuf Primitives

    private enum WireType: Int {
        case varint = 0
        case fixed64 = 1
        case lengthDelimited = 2
        case fixed32 = 5
    }

    /// Extracts the first occurrence of a field from a protobuf message.
    private static func extractField(from data: Data, fieldNumber: Int, wireType: WireType) -> Data? {
        var offset = data.startIndex
        while offset < data.endIndex {
            let (tag, tagLen) = readVarint(data, at: offset)
            guard tagLen > 0 else { break }
            offset = data.index(offset, offsetBy: tagLen)

            let fieldNum = Int(tag >> 3)
            let wire = Int(tag & 0x7)

            // Determine field length
            let fieldLen: Int
            let fieldStart: Data.Index
            switch wire {
            case 0: // varint
                let (_, vLen) = readVarint(data, at: offset)
                fieldLen = vLen
                fieldStart = offset
            case 1: // fixed64
                fieldLen = 8
                fieldStart = offset
            case 2: // length-delimited
                let (len, lenLen) = readVarint(data, at: offset)
                guard lenLen > 0 else { return nil }
                fieldStart = data.index(offset, offsetBy: lenLen)
                fieldLen = Int(len)
            case 5: // fixed32
                fieldLen = 4
                fieldStart = offset
            default:
                return nil // unsupported wire type
            }

            guard data.distance(from: fieldStart, to: data.endIndex) >= fieldLen else { return nil }

            if fieldNum == fieldNumber && wire == wireType.rawValue {
                return data[fieldStart..<data.index(fieldStart, offsetBy: fieldLen)]
            }

            offset = data.index(fieldStart, offsetBy: fieldLen)
        }
        return nil
    }

    /// Reads a varint from data at the given offset. Returns (value, bytesRead).
    private static func readVarint(_ data: Data, at offset: Data.Index) -> (UInt64, Int) {
        var result: UInt64 = 0
        var shift = 0
        var idx = offset
        while idx < data.endIndex {
            let byte = data[idx]
            result |= UInt64(byte & 0x7F) << shift
            idx = data.index(after: idx)
            if byte & 0x80 == 0 {
                return (result, data.distance(from: offset, to: idx))
            }
            shift += 7
            if shift >= 64 { break }
        }
        return (0, 0)
    }

    /// Parses a protobuf Timestamp message (field 1 = seconds, field 2 = nanos).
    private static func parseTimestamp(_ data: Data) -> Date? {
        var seconds: Int64 = 0
        var nanos: Int32 = 0

        var offset = data.startIndex
        while offset < data.endIndex {
            let (tag, tagLen) = readVarint(data, at: offset)
            guard tagLen > 0 else { break }
            offset = data.index(offset, offsetBy: tagLen)

            let fieldNum = Int(tag >> 3)
            let wire = Int(tag & 0x7)

            if wire == 0 { // varint
                let (val, vLen) = readVarint(data, at: offset)
                guard vLen > 0 else { break }
                offset = data.index(offset, offsetBy: vLen)
                if fieldNum == 1 { seconds = Int64(bitPattern: val) }
                if fieldNum == 2 { nanos = Int32(bitPattern: UInt32(val & 0xFFFFFFFF)) }
            } else {
                break // unexpected wire type in Timestamp
            }
        }

        guard seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(seconds) + Double(nanos) / 1_000_000_000)
    }
}
