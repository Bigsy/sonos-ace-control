import Foundation

enum SonosProtocol {
    static let service = "FE07"
    static let controlWrite = "C44F42B1-F5CF-479B-B515-9F1BB0099C9A"
    static let controlNotify = "C44F42B1-F5CF-479B-B515-9F1BB0099C9B"
    static let setupWrite = "C44F42B1-F5CF-479B-B515-9F1BB0099C9E"
    static let setupNotify = "C44F42B1-F5CF-479B-B515-9F1BB0099C9F"
    static let settings: UInt8 = 2
    static let getSidetone: UInt8 = 53
    static let setSidetone: UInt8 = 54
    static let getEQ: UInt8 = 63
    static let setEQType: UInt8 = 64
    static let setEQBand: UInt8 = 65
    static let getANC: UInt8 = 14
    static let setANC: UInt8 = 15
    static let getLoudness: UInt8 = 67
    static let setLoudness: UInt8 = 32

    struct Response {
        let namespace: UInt8
        let command: UInt8
        let status: UInt8
        let payload: [UInt8]
    }

    static func command(_ id: UInt8, payload: [UInt8] = []) -> Data {
        Data([0, settings, id] + payload)
    }

    static func response(_ data: Data) -> Response? {
        let bytes = Array(data)
        guard bytes.count >= 4, bytes[0] == 2 else { return nil }
        return Response(namespace: bytes[1], command: bytes[2], status: bytes[3], payload: Array(bytes.dropFirst(4)))
    }

    struct EQSettings {
        let active: UInt8
        let bands: [UInt8: [Int]]
    }

    static func parseEQ(_ payload: [UInt8]) -> EQSettings? {
        guard payload.count >= 2 else { return nil }
        let active = payload[0]
        var offset = 2
        var bands: [UInt8: [Int]] = [:]
        for _ in 0..<Int(payload[1]) {
            guard offset + 2 <= payload.count else { return nil }
            let type = payload[offset]
            let count = Int(payload[offset + 1])
            offset += 2
            guard offset + count <= payload.count, bands[type] == nil else { return nil }
            bands[type] = payload[offset..<(offset + count)].map { Int(Int8(bitPattern: $0)) }
            offset += count
        }
        guard offset == payload.count, bands[active] != nil else { return nil }
        return EQSettings(active: active, bands: bands)
    }

    static func describeEQ(_ payload: [UInt8]) -> String? {
        guard let eq = parseEQ(payload) else { return nil }
        var lines = ["Active EQ: \(eq.active == 0 ? "3-band" : eq.active == 1 ? "8-band" : "unknown (\(eq.active))")"]
        for type in eq.bands.keys.sorted() {
            let values = eq.bands[type]!.map(String.init)
            lines.append("\(type == 0 ? "3-band" : type == 1 ? "8-band" : "EQ \(type)"): \(values.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }
}

enum SonosAuthentication {
    static let hello = Data([1, 0, 1, 0, 4, 1, 0, 0, 0, 2, 0, 4, 0, 0, 0, 1])
    static let selectPairwise = Data([1, 2, 3, 0, 1, 0])
    static let requestCommonToken = Data([1, 4, 3, 0, 1, 0])

    struct Message {
        let type: UInt8
        let elements: [UInt8: [UInt8]]
        var status: UInt16? {
            guard let bytes = elements[0], bytes.count == 2 else { return nil }
            return UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        }
    }

    static func parse(_ data: Data, protocolID: UInt8 = 1) -> Message? {
        let bytes = Array(data)
        guard bytes.count >= 2, bytes[0] == protocolID else { return nil }
        var offset = 2
        var elements: [UInt8: [UInt8]] = [:]
        while offset < bytes.count {
            guard offset + 3 <= bytes.count else { return nil }
            let tag = bytes[offset]
            let count = Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2])
            offset += 3
            guard offset + count <= bytes.count, elements[tag] == nil else { return nil }
            elements[tag] = Array(bytes[offset..<(offset + count)])
            offset += count
        }
        return Message(type: bytes[1], elements: elements)
    }

    static func authenticate(token: [UInt8]) -> Data? {
        guard token.count == 20 else { return nil }
        return Data([1, 6, 4, 0, 20] + token)
    }
}

extension Data {
    var hex: String { map { String(format: "%02X", $0) }.joined(separator: " ") }
}
