import AppKit

@MainActor enum ClipboardExplicitCopy {
    @MainActor final class Recovery {
        let snapshot:ClipboardPasteboardSnapshot,board:NSPasteboard
        var expectedCount:Int
        init(snapshot:ClipboardPasteboardSnapshot,board:NSPasteboard,expectedCount:Int) {self.snapshot=snapshot;self.board=board;self.expectedCount=expectedCount}
        func restore()throws {
            guard try snapshot.restore(board,ifUnchanged:expectedCount,onCleared:{self.expectedCount=$0}) else {
                throw DataFailure.message("剪贴板在提示后又发生变化，未覆盖新内容；可选择保留当前内容。")
            }
        }
    }
    struct Failure:LocalizedError {
        let recovery:Recovery?
        let message:String
        var errorDescription:String? {L10n.text(message)}
    }
    /// Explicit copy keeps the replacement on success. Only a failed write may
    /// restore automatically, and only while the clearing generation is ours.
    static func publish(_ prepared:NSPasteboardItem,to board:NSPasteboard,expectedCount:Int,
                        shouldProceed:()->Bool={true},write:(([NSPasteboardItem])->Bool)?=nil)throws {
        guard board.changeCount==expectedCount,shouldProceed() else {throw DataFailure.message("剪贴板或来源已变化，未执行复制。")}
        let snapshot=try ClipboardPasteboardSnapshot.capture(board)
        guard board.changeCount==expectedCount,shouldProceed() else {throw DataFailure.message("剪贴板或来源已变化，未执行复制。")}
        let cleared=board.clearContents()
        guard board.changeCount==cleared else {
            throw Failure(recovery:Recovery(snapshot:snapshot,board:board,expectedCount:board.changeCount),message:"复制期间剪贴板已变化，未覆盖新内容；复制前内容仍在内存中。")
        }
        if (write ?? {board.writeObjects($0)})([prepared]) {return}
        let recovery=Recovery(snapshot:snapshot,board:board,expectedCount:board.changeCount)
        if board.changeCount==cleared {
            do {try recovery.restore();throw Failure(recovery:nil,message:"无法写入系统剪贴板，已恢复复制前内容，堆栈已保留。")}
            catch let failure as Failure {throw failure}
            catch {throw Failure(recovery:recovery,message:"复制与自动恢复未完成，复制前内容仍在内存中，请选择恢复或保留当前剪贴板。")}
        }
        throw Failure(recovery:recovery,message:"复制未完成，剪贴板已有新内容；复制前内容仍在内存中，堆栈已保留。")
    }
}
