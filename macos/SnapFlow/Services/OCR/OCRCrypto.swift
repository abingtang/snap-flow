import CryptoKit
import Foundation

enum OCRCrypto {
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(_ string: String) -> String {
        sha256Hex(Data(string.utf8))
    }

    static func hmacSHA256(key: Data, message: Data) -> Data {
        let symmetric = SymmetricKey(data: key)
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: symmetric)
        return Data(mac)
    }

    static func hmacSHA256(key: Data, message: String) -> Data {
        hmacSHA256(key: key, message: Data(message.utf8))
    }

    static func hmacSHA256(key: String, message: String) -> Data {
        hmacSHA256(key: Data(key.utf8), message: Data(message.utf8))
    }

    static func hmacSHA256Hex(key: Data, message: String) -> String {
        hmacSHA256(key: key, message: message).map { String(format: "%02x", $0) }.joined()
    }
}
