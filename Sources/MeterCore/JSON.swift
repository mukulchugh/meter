import Foundation

/// A small JSON value that keeps number tokens as their original text, so money is never routed
/// through `Double`. (`JSONSerialization` would parse `0.06` to a binary double first.)
enum JSON: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(String)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    struct ParseError: Error, Equatable { let message: String }

    static func parse(_ data: Data) throws -> JSON {
        var p = Parser(bytes: Array(data))
        p.skipWS()
        let v = try p.value()
        p.skipWS()
        guard p.i == p.bytes.count else { throw ParseError(message: "trailing characters") }
        return v
    }

    subscript(key: String) -> JSON {
        if case .object(let o) = self { return o[key] ?? .null }
        return .null
    }

    var string: String? { if case .string(let s) = self { return s }; return nil }
    var array: [JSON] { if case .array(let a) = self { return a }; return [] }
    var isNull: Bool { if case .null = self { return true }; return false }
    var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    var isObject: Bool { if case .object = self { return true }; return false }

    var int: Int? {
        switch self {
        case .number(let s): return Int(s) ?? Decimal(string: s).map { NSDecimalNumber(decimal: $0).intValue }
        case .string(let s): return Int(s)
        default: return nil
        }
    }

    /// Exact decimal from a JSON string ("123.45") or a JSON number token (0.06).
    var decimal: Decimal? {
        switch self {
        case .number(let s), .string(let s): return Money.decimal(from: s)
        default: return nil
        }
    }

    private struct Parser {
        let bytes: [UInt8]
        var i = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func skipWS() {
            while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
        }

        mutating func value() throws -> JSON {
            guard i < bytes.count else { throw ParseError(message: "unexpected end") }
            switch bytes[i] {
            case UInt8(ascii: "{"): return try object()
            case UInt8(ascii: "["): return try arr()
            case UInt8(ascii: "\""): return .string(try str())
            case UInt8(ascii: "t"): try lit("true"); return .bool(true)
            case UInt8(ascii: "f"): try lit("false"); return .bool(false)
            case UInt8(ascii: "n"): try lit("null"); return .null
            default: return try num()
            }
        }

        mutating func lit(_ s: String) throws {
            let u = Array(s.utf8)
            guard i + u.count <= bytes.count, Array(bytes[i..<i + u.count]) == u else { throw ParseError(message: "bad literal") }
            i += u.count
        }

        mutating func num() throws -> JSON {
            let start = i
            while i < bytes.count, "+-0123456789.eE".utf8.contains(bytes[i]) { i += 1 }
            guard i > start, let s = String(bytes: bytes[start..<i], encoding: .utf8) else { throw ParseError(message: "bad number") }
            return .number(s)
        }

        mutating func str() throws -> String {
            i += 1
            var out = [UInt8]()
            while i < bytes.count {
                let c = bytes[i]
                if c == UInt8(ascii: "\"") { i += 1; return String(decoding: out, as: UTF8.self) }
                if c == UInt8(ascii: "\\") {
                    i += 1
                    guard i < bytes.count else { break }
                    let e = bytes[i]
                    switch e {
                    case UInt8(ascii: "n"): out.append(0x0A)
                    case UInt8(ascii: "t"): out.append(0x09)
                    case UInt8(ascii: "r"): out.append(0x0D)
                    case UInt8(ascii: "b"): out.append(0x08)
                    case UInt8(ascii: "f"): out.append(0x0C)
                    case UInt8(ascii: "u"):
                        var scalar = try hex4()
                        if (0xD800..<0xDC00).contains(scalar), i + 2 < bytes.count, bytes[i + 1] == UInt8(ascii: "\\"), bytes[i + 2] == UInt8(ascii: "u") {
                            i += 2
                            let low = try hex4()
                            scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                        }
                        out.append(contentsOf: Array(String(Character(Unicode.Scalar(scalar) ?? "\u{FFFD}")).utf8))
                    default: out.append(e)
                    }
                    i += 1
                } else {
                    out.append(c); i += 1
                }
            }
            throw ParseError(message: "unterminated string")
        }

        /// Reads the four hex digits after `\u`; leaves `i` on the last digit.
        mutating func hex4() throws -> UInt32 {
            guard i + 4 < bytes.count,
                  let s = String(bytes: bytes[(i + 1)...(i + 4)], encoding: .utf8),
                  let v = UInt32(s, radix: 16) else { throw ParseError(message: "bad escape") }
            i += 4
            return v
        }

        mutating func arr() throws -> JSON {
            i += 1
            var items = [JSON]()
            skipWS()
            if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
            while true {
                skipWS()
                items.append(try value())
                skipWS()
                guard i < bytes.count else { throw ParseError(message: "unterminated array") }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                throw ParseError(message: "bad array")
            }
        }

        mutating func object() throws -> JSON {
            i += 1
            var o = [String: JSON]()
            skipWS()
            if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(o) }
            while true {
                skipWS()
                guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw ParseError(message: "bad key") }
                let k = try str()
                skipWS()
                guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw ParseError(message: "missing colon") }
                i += 1
                skipWS()
                o[k] = try value()
                skipWS()
                guard i < bytes.count else { throw ParseError(message: "unterminated object") }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(o) }
                throw ParseError(message: "bad object")
            }
        }
    }
}
