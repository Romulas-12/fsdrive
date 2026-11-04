import Crypto
import Foundation
import NIOSSL
import FSDriveCore
import SwiftASN1
import X509

/// The server's own TLS key and self-signed certificate, made on first start. Clients
/// do not check it against certificate authorities: they pin its public key (see
/// ServerTrust), so the name or address it is reached by does not matter.
struct TLSIdentity {
    let key: P256.Signing.PrivateKey
    let certificateDER: [UInt8]

    static func dir(root: String) -> String { root + "/.system/tls" }

    /// Loads the key and certificate, or makes them the first time.
    static func loadOrCreate(root: String) throws -> TLSIdentity {
        let dir = dir(root: root)
        let keyPath = dir + "/key.pem", certPath = dir + "/cert.pem"
        if let keyPEM = try? String(contentsOfFile: keyPath, encoding: .utf8),
           let certPEM = try? String(contentsOfFile: certPath, encoding: .utf8) {
            let identity = TLSIdentity(key: try P256.Signing.PrivateKey(pemRepresentation: keyPEM),
                                       certificateDER: try PEMDocument(pemString: certPEM).derBytes)
            try identity.writePin(dir: dir)
            return identity
        }
        let key = P256.Signing.PrivateKey()
        let name = try DistinguishedName { CommonName("FSDrive") }
        let now = Date()
        let cert = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: .init(key.publicKey),
            notValidBefore: now.addingTimeInterval(-3600),
            // Pinned clients ignore expiry; a far date keeps tools that do check it quiet.
            notValidAfter: now.addingTimeInterval(100 * 365 * 24 * 3600),
            issuer: name,
            subject: name,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                KeyUsage(digitalSignature: true)
                try ExtendedKeyUsage([.serverAuth])
            },
            issuerPrivateKey: .init(key))
        var serializer = DER.Serializer()
        try serializer.serialize(cert)
        let identity = TLSIdentity(key: key, certificateDER: serializer.serializedBytes)

        try FileIO.mkdirs(dir)
        chmod(dir, 0o700)
        FileManager.default.createFile(atPath: keyPath, contents: nil, attributes: [.posixPermissions: 0o600])
        try key.pemRepresentation.write(toFile: keyPath, atomically: false, encoding: .utf8)
        try PEMDocument(type: "CERTIFICATE", derBytes: identity.certificateDER).pemString
            .write(toFile: certPath, atomically: true, encoding: .utf8)
        try identity.writePin(dir: dir)
        logLine("TLS: new server key, fingerprint \(ServerPin.code(identity.pin))")
        return identity
    }

    /// "sha256/<base64>" of the public key (SubjectPublicKeyInfo), the form clients pin.
    var pin: String { ServerPin.pin(spki: key.publicKey.derRepresentation) }

    /// The pin as curl takes it (--pinnedpubkey) and its short code, for the settings page
    /// and the gateway setup script.
    private func writePin(dir: String) throws {
        try ("sha256//" + pin.dropFirst("sha256/".count) + "\n").write(toFile: dir + "/pin", atomically: true, encoding: .utf8)
        try (ServerPin.code(pin) + "\n").write(toFile: dir + "/code", atomically: true, encoding: .utf8)
    }

    func serverConfiguration() throws -> TLSConfiguration {
        var tls = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(try NIOSSLCertificate(bytes: certificateDER, format: .der))],
            privateKey: .privateKey(try NIOSSLPrivateKey(bytes: Array(key.derRepresentation), format: .der)))
        // Every client (URLSession, curl on QTS and on the gateway) speaks TLS 1.3.
        tls.minimumTLSVersion = .tlsv13
        return tls
    }
}
