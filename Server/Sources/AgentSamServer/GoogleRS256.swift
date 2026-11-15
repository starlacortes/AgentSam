import Foundation
import _CryptoExtras

/// RS256 signer for Google service-account JWTs (RSA PKCS#1 v1.5 over SHA-256).
enum GoogleRS256 {
    @Sendable static func sign(pemPrivateKey: String, message: Data) throws -> Data {
        let key = try _RSA.Signing.PrivateKey(pemRepresentation: pemPrivateKey)
        return try key.signature(for: message, padding: .insecurePKCS1v1_5).rawRepresentation
    }
}
