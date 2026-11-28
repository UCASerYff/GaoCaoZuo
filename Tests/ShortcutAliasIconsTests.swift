import AppKit
import CoreGraphics
import Foundation

@MainActor func runShortcutAliasIconsTests(in directory: URL) throws {
    let root = directory.appendingPathComponent("shortcut-alias-icons", isDirectory: true)
    let manager = FileManager.default
    try manager.createDirectory(at: root, withIntermediateDirectories: false)
    let target = root.appendingPathComponent("Synthetic.app", isDirectory: true)
    try manager.createDirectory(at: target, withIntermediateDirectories: false)
    let untouched = target.appendingPathComponent("identity.txt")
    let original = Data("synthetic target content".utf8)
    try original.write(to: untouched, options: .withoutOverwriting)
    let storeDirectory = root.appendingPathComponent("profile", isDirectory: true)
    let service = ShortcutAliasIcons(data: LocalData(directory: storeDirectory))

    func require(_ condition: @autoclosure () throws -> Bool, _ failure: String) throws {
        guard try condition() else { throw DataFailure.message("Shortcut aliases: " + failure) }
    }
    func first(_ url: URL, service from: ShortcutAliasIcons? = nil) throws -> ShortcutAliasPreview {
        guard let value = try (from ?? service).previews(for: [url]).first else { throw DataFailure.message("Missing synthetic alias") }
        return value
    }
    func fixture(_ red: CGFloat, _ blue: CGFloat) throws -> NSImage {
        guard let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw DataFailure.message("Missing synthetic color context")
        }
        context.setFillColor(red: red, green: 0.2, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        guard let output = context.makeImage() else { throw DataFailure.message("Missing synthetic color icon") }
        return NSImage(cgImage: output, size: NSSize(width: 64, height: 64))
    }

    let alias = try service.createAlias(for: target, in: root)
    let initial = try first(alias)
    try require(initial.state == .available, "new alias did not have its default icon")
    var duplicateRejected = false
    do { _ = try service.createAlias(for: target, in: root) } catch { duplicateRejected = true }
    let afterDuplicate = try first(alias).stamp
    try require(duplicateRejected && afterDuplicate == initial.stamp, "duplicate alias overwrote an existing shortcut")
    let excluded = root.appendingPathComponent("symbolic-link")
    try manager.createSymbolicLink(at: excluded, withDestinationURL: alias)
    let insideBundle = target.appendingPathComponent("inside target alias")
    let targetBookmark = try root.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
    try URL.writeBookmarkData(targetBookmark, to: insideBundle)
    for invalid in [target, excluded, insideBundle] {
        var rejected = false
        do { _ = try service.previews(for: [invalid]) } catch { rejected = true }
        try require(rejected, "application directory or symlink entered the alias editor")
    }

    let red = try fixture(0.9, 0.1)
    let blue = try fixture(0.1, 0.9)
    let applied = try service.change([initial], to: red, name: "Synthetic red")
    try require(applied.completed == 1 && applied.failures.isEmpty, "icon application failed: \(applied.failures)")
    let loaded = ShortcutAliasIcons(data: LocalData(directory: storeDirectory, createIfMissing: false))
    let managed = try first(alias, service: loaded)
    try require(managed.state == .managed && managed.appliedName == "Synthetic red", "applied icon was not tracked across instances")
    try require(managed.stamp.isSameAlias(as: initial.stamp), "applying an icon changed the alias target or replacement identity")
    let restore = try loaded.change([managed], to: nil)
    try require(restore.completed == 1 && restore.failures.isEmpty, "restore did not complete: \(restore.failures)")
    let again = try first(alias, service: loaded)
    try require(again.state == .available && again.stamp == initial.stamp, "default icon was not restored")

    try require(try loaded.change([again], to: red, name: "Synthetic red").completed == 1, "could not reapply the red fixture")
    let stalePlan = try first(alias, service: loaded)
    try require(NSWorkspace.shared.setIcon(blue, forFile: alias.path), "external-change fixture could not be applied")
    let foreign = try first(alias, service: loaded)
    try require(foreign.state == .changed, "external icon change was not reported")
    let skipped = try loaded.change([stalePlan], to: nil)
    try require(skipped.completed == 0 && skipped.failures.count == 1, "stale restore changed an external icon")
    try require(try first(alias, service: loaded).stamp == foreign.stamp, "external icon no longer matched its fingerprint")

    let second = root.appendingPathComponent("already-custom")
    let bookmark = try target.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
    try URL.writeBookmarkData(bookmark, to: second)
    try require(NSWorkspace.shared.setIcon(blue, forFile: second.path), "existing-custom fixture could not be applied")
    let before = try first(second, service: loaded)
    try require(before.state == .custom, "an unmanaged custom icon was not marked as protected")
    let refused = try loaded.change([before], to: red, name: "Synthetic red")
    let unchanged = try first(second, service: loaded).stamp
    try require(refused.completed == 0 && unchanged == before.stamp, "unmanaged custom icon was replaced")
    try require(try Data(contentsOf: untouched) == original, "alias actions changed the application target")

    try require(ShortcutMascot.allCases.count == 8, "eight shared roles were not registered")
    for role in ShortcutMascot.allCases {
        guard let image = role.imageURL else { throw DataFailure.message("Missing role resource \(role.rawValue)") }
        _ = try ShortcutAliasIcons.loadLocalImage(image)
    }
    for (name, role) in [("Codex", ShortcutMascot.chatgpt), ("Antigravity", .gemini), ("ZCode", .glm), ("智谱", .glm), ("通义千问", .qwen)] {
        try require(ShortcutMascot.suggestion(for: name) == role, "name matching failed for \(name)")
    }
    print("Shortcut alias icons passed: staged assets, creation conflict, apply and restore, target identity, external edits, symlink and custom-icon protection.")
}
