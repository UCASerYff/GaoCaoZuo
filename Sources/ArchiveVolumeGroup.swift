import Foundation
import Darwin

/// Numeric neighbors are eligible only with matching private creation evidence.
/// Successful decoding or matching filenames alone never authorize disposal.
struct ArchiveVolumeGroup {
    let first: URL
    let members: [URL]
    let fingerprints: [(URL,String)]
    private typealias Identity=ArchiveVolumeEvidenceStore.Identity
    private let identities: [String:Identity]
    func verifyUnchanged() throws {
        for member in members {try verifyUnchanged(member)}
    }
    func verifyUnchanged(_ member:URL)throws {
        let info=try EnhancedFileTools.checked(member)
        guard info.st_uid==getuid(),info.st_nlink==1,identities[member.path]==Identity(info) else {throw FileToolsError.changed(member)}
    }
    static func capture(_ archive: URL,evidence:ArchiveVolumeEvidenceStore? = nil) throws -> Self {
        let name = archive.lastPathComponent
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        let members: [URL]
        if parts.count >= 3, parts.last!.count == 3, parts.last!.allSatisfy(\.isNumber),
           ["zip", "7z"].contains(String(parts[parts.count-2]).lowercased()) {
            guard parts.last! == "001" else { throw ArchiveError.invalid("分卷后处理必须从 .001 首卷开始，未移动任何原卷。") }
            guard let evidence else {throw ArchiveError.invalid("无法证明各分卷的来源归属，已保留全部原卷。请使用保留原件的解压方式，逐卷核验后再自行处理。")}
            members=try evidence.verifiedMembers(first:archive)
        } else {
            // RAR, old ZIP/RAR multipart conventions and raw numeric splits are not
            // proven groups. Keeping them is safer than deleting only one member.
            let lower = name.lowercased()
            guard ["zip", "7z", "tar", "gz", "tgz", "xz", "txz", "bz2", "tbz2", "lz", "iso", "ar", "cpio"].contains(archive.pathExtension.lowercased()),
                  !lower.contains(".part"), archive.pathExtension != "001" else { throw ArchiveError.invalid("此格式尚未验证完整卷组后处理；请保留原卷，核验后自行处理。") }
            // ACE may itself be multi-volume without a reliable public directory identity.
            guard archive.pathExtension.lowercased() != "ace" else { throw ArchiveError.invalid("ACE 多卷归组尚未验证，自动后处理已停止。") }
            if archive.pathExtension.lowercased() == "zip" {
                let stem = archive.deletingPathExtension().lastPathComponent + ".z"
                let siblings = try FileManager.default.contentsOfDirectory(atPath: archive.deletingLastPathComponent().path)
                guard !siblings.contains(where: { $0.hasPrefix(stem) && $0.dropFirst(stem.count).count == 2 && $0.dropFirst(stem.count).allSatisfy(\.isNumber) }) else { throw ArchiveError.invalid("旧式 ZIP 多卷后处理尚未验证，原卷全部保留。") }
            }
            members = [archive]
        }
        var identities: [String:Identity] = [:]
        let fingerprints = try members.map { url -> (URL,String) in
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_nlink == 1, info.st_uid == getuid() else { throw ArchiveError.invalid("原卷不是当前用户的独立普通文件，停止后处理。") }
            _ = try EnhancedFileTools.checked(url)
            identities[url.path] = Identity(info)
            return (url, try FileTools.fingerprint(url))
        }
        return .init(first: archive, members: members, fingerprints: fingerprints, identities: identities)
    }
}
