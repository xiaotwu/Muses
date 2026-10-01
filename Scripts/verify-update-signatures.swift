#!/usr/bin/env swift
import Foundation
import CryptoKit

// Verify against the key embedded in the app, not merely the publisher's private key.
func reject(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let args = CommandLine.arguments
guard args.count == 4 else { reject("Usage: verify-update-signatures.swift APP FEED ARCHIVE") }
let app = URL(fileURLWithPath: args[1])
let feed = try Data(contentsOf: URL(fileURLWithPath: args[2]))
let archive = try Data(contentsOf: URL(fileURLWithPath: args[3]), options: .mappedIfSafe)
let plist = try PropertyListSerialization.propertyList(
    from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), format: nil) as! [String: Any]
guard let encoded = plist["SUPublicEDKey"] as? String,
      let raw = Data(base64Encoded: encoded), raw.count == 32 else { reject("Missing app public key") }
let key = try Curve25519.Signing.PublicKey(rawRepresentation: raw)
let marker = Data("<!-- sparkle-signatures:\n".utf8)
guard let range = feed.range(of: marker, options: .backwards),
      let block = String(data: feed.suffix(from: range.upperBound), encoding: .utf8) else {
    reject("Missing feed signature")
}
let lines = block.split(separator: "\n").map(String.init)
guard lines.count == 3, lines[2] == "-->",
      lines[0].hasPrefix("edSignature: "), lines[1].hasPrefix("length: "),
      let signature = Data(base64Encoded: String(lines[0].dropFirst("edSignature: ".count))),
      Int(lines[1].dropFirst("length: ".count)) == range.lowerBound,
      key.isValidSignature(signature, for: feed.prefix(range.lowerBound)) else {
    reject("Feed signature does not match the app public key")
}
let document = try XMLDocument(data: feed, options: .nodeLoadExternalEntitiesNever)
let enclosures = try document.nodes(forXPath: "/rss/channel/item/enclosure")
guard enclosures.count == 1, let element = enclosures.first as? XMLElement,
      let value = element.attribute(forName: "sparkle:edSignature")?.stringValue,
      let archiveSignature = Data(base64Encoded: value),
      key.isValidSignature(archiveSignature, for: archive) else {
    reject("Archive signature does not match the app public key")
}
print("Feed and archive signatures match the application's embedded public key.")
