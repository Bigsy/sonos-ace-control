import Foundation
import CryptoKit
import Security

// ASP device challenge, inferred from the installed Android client. This probe
// verifies message hashes and possession of the certificate's private key. It
// does not yet validate the manufacturer's certificate chain.
final class SonosAttestation {
    enum Step { case waiting, send(Data), complete }
    struct Failure: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }
    private var certificate = Data()
    private var signature = Data()
    private var nonce = Data()
    private var key: SecKey?
    private var phase = 0

    private static func element(_ tag: UInt8, _ value: Data) -> Data {
        Data([tag, UInt8(value.count >> 8), UInt8(value.count & 255)]) + value
    }

    static func hello() -> Data {
        let version = Data([1, 0, 0, 0])
        return Data([0, 0]) + element(1, version) + element(2, version)
            + element(3, Data([0, 0, 0, 0]))
            + element(4, Data(UUID().uuidString.lowercased().utf8))
    }

    func receive(_ data: Data) throws -> Step {
        guard let message = SonosAuthentication.parse(data, protocolID: 0) else {
            throw Failure(reason: "Malformed device-verification message.")
        }
        let fields = message.elements
        if message.type == 8 {
            throw Failure(reason: "Device verification returned status \(message.status.map(String.init) ?? "unknown").")
        }
        switch message.type {
        case 1, 2:
            guard phase == 0, let part = fields[6], let marker = fields[5], marker.count == 1,
                  (message.type == 1 ? [0, 1] : [2]).contains(marker[0]),
                  certificate.count + part.count <= 32_768 else {
                throw Failure(reason: "Invalid certificate fragment sequence.")
            }
            if message.type == 1 {
                guard certificate.isEmpty, fields[1] == [1, 0, 0, 0] else {
                    throw Failure(reason: "Unsupported verification protocol version.")
                }
            }
            certificate.append(contentsOf: part)
            return .waiting
        case 3:
            guard phase == 0, !certificate.isEmpty, fields[5] == [3],
                  fields[7] == Array(SHA256.hash(data: certificate)) else {
                throw Failure(reason: "Device certificate hash did not match.")
            }
            var der = certificate
            if let pem = String(data: certificate, encoding: .utf8), pem.contains("-----BEGIN CERTIFICATE-----") {
                let body = pem.components(separatedBy: "-----BEGIN CERTIFICATE-----")[1]
                    .components(separatedBy: "-----END CERTIFICATE-----")[0]
                guard let decoded = Data(base64Encoded: body, options: .ignoreUnknownCharacters) else {
                    throw Failure(reason: "Invalid certificate encoding.")
                }
                der = decoded
            }
            guard let cert = SecCertificateCreateWithData(nil, der as CFData),
                  let publicKey = SecCertificateCopyKey(cert) else {
                throw Failure(reason: "Cannot read the device certificate's public key.")
            }
            key = publicKey
            var random = [UInt8](repeating: 0, count: 8)
            guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else {
                throw Failure(reason: "Could not generate a device challenge.")
            }
            nonce = Data(random)
            phase = 1
            return .send(Data([0, 4]) + Self.element(13, nonce))
        case 5, 6:
            guard phase == 1, let part = fields[14], let marker = fields[5], marker.count == 1,
                  (message.type == 5 ? [0, 1] : [2]).contains(marker[0]),
                  signature.count + part.count <= 2048 else {
                throw Failure(reason: "Invalid challenge-response fragment sequence.")
            }
            signature.append(contentsOf: part)
            return .waiting
        case 7:
            guard phase == 1, let key, !signature.isEmpty, fields[5] == [3],
                  fields[7] == Array(SHA256.hash(data: signature)) else {
                throw Failure(reason: "Device challenge-response hash did not match.")
            }
            var error: Unmanaged<CFError>?
            guard SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256,
                                        nonce as CFData, signature as CFData, &error) else {
                throw Failure(reason: "Device challenge signature verification failed.")
            }
            phase = 2
            return .complete
        default:
            throw Failure(reason: "Unexpected device-verification message \(message.type).")
        }
    }
}
