import Foundation
import CryptoKit

struct WireState: Codable, Equatable {
    var stamps: [Int]
    var lastSeenWallClock: Int
    var lastSeenUptimeMillis: Int
    var lastSeenIDFV: String?
    var strictModeUntil: Int?
    var lastSeenPro: Bool?
}

enum StateCodec {
    /// Encodes the given `WireState` into bytes as: HMAC(32 bytes) || JSON
    /// HMAC = HMAC-SHA256(secretKey, jsonPayload)
    static func encode(_ state: WireState, secretKey: Data) throws -> Data {
        let json = try JSONEncoder().encode(state)
        let mac = Self.hmacSHA256(key: secretKey, data: json)
        var result = Data()
        result.append(mac)
        result.append(json)
        return result
    }

    /// Attempts to decode and verify bytes. Returns the `WireState` if valid.
    static func decodeIfValid(_ data: Data, secretKey: Data) -> WireState? {
        guard data.count > 32 else { return nil }
        let mac = data.prefix(32)
        let json = data.suffix(from: 32)
        let expected = Self.hmacSHA256(key: secretKey, data: json)
        guard mac == expected else { return nil }
        return try? JSONDecoder().decode(WireState.self, from: json)
    }

    private static func hmacSHA256(key: Data, data: Data) -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: symmetricKey)
        return Data(mac)
    }
}


