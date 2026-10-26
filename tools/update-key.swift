// Ed25519 key that signs update zips; the app checks them against SquintUpdatePublicKey in App/Info.plist.
//   swift tools/update-key.swift generate    – new key into the login Keychain, prints the public key
//   swift tools/update-key.swift sign FILE   – prints FILE's base64 signature
// The private key comes from $SQUINT_UPDATE_KEY (base64) or the Keychain item "Squint Update Key".
import CryptoKit
import Foundation

let service = "Squint Update Key"

func security(_ args: [String]) -> (status: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    try! p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

func privateKey() -> Curve25519.Signing.PrivateKey {
    var encoded = ProcessInfo.processInfo.environment["SQUINT_UPDATE_KEY"] ?? ""
    if encoded.isEmpty {
        let r = security(["find-generic-password", "-s", service, "-w"])
        guard r.status == 0 else { fail("No update key: set SQUINT_UPDATE_KEY or run `swift tools/update-key.swift generate`.") }
        encoded = r.out
    }
    guard let raw = Data(base64Encoded: encoded), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        fail("The update key isn't a base64 Ed25519 private key.")
    }
    return key
}

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "generate":
    if security(["find-generic-password", "-s", service]).status == 0 { fail("The Keychain already has \"\(service)\"; delete it first to replace it.") }
    let key = Curve25519.Signing.PrivateKey()
    let r = security(["add-generic-password", "-s", service, "-a", NSUserName(), "-w", key.rawRepresentation.base64EncodedString()])
    guard r.status == 0 else { fail("Couldn't add the key to the Keychain.") }
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "sign" where args.count == 2:
    guard let data = FileManager.default.contents(atPath: args[args.startIndex + 1]) else { fail("Can't read \(args[args.startIndex + 1]).") }
    print(try! privateKey().signature(for: data).base64EncodedString())
default:
    fail("usage: swift tools/update-key.swift generate | sign FILE")
}
