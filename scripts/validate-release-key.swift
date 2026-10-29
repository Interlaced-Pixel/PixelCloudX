import CryptoKit
import Foundation

guard CommandLine.arguments.count == 3 else { fatalError("Expected a local key file and an application Info.plist") }
let keyURL = URL(fileURLWithPath: CommandLine.arguments[1])
let infoURL = URL(fileURLWithPath: CommandLine.arguments[2])
let encoded = try Data(contentsOf: keyURL)
guard let seed = Data(base64Encoded: encoded), seed.count == 32 else { fatalError("Expected a base64-encoded 32-byte Ed25519 seed") }
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as! [String: Any]
guard info["SUPublicEDKey"] as? String == key.publicKey.rawRepresentation.base64EncodedString() else {
    fatalError("The local release key does not match the app's embedded public key")
}
print("Release signing key matches the embedded public key.")
