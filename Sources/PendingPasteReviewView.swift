import SwiftUI

@MainActor struct PendingPasteReviewView:View {
    @ObservedObject var clipboard:ClipboardService
    var close:()->Void
    @State private var failure:String?
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            Text("确认粘贴结果").font(.title3.bold())
            if let pending=clipboard.pendingPaste {
                Text(L10n.text(pending.message)).fixedSize(horizontal:false,vertical:true)
                Text("请先核对原目标内容，再选择是否恢复原剪贴板。处理这笔粘贴后，才可继续下一笔。").font(.caption).foregroundStyle(.secondary)
                if let failure {Text(L10n.text(failure)).foregroundStyle(.red)}
                VStack(alignment:.leading,spacing:8) {
                    if pending.eventWasSubmitted {
                    Button("内容已插入，恢复原剪贴板") {perform {try clipboard.confirmPendingPaste(restoreOriginal:true)}}
                    Button("内容已插入，保留当前剪贴板") {perform {try clipboard.confirmPendingPaste(restoreOriginal:false)}}
                    if pending.sendEnterRequested {
                        Button("内容已插入，发送回车") {perform {try clipboard.confirmPendingPaste(restoreOriginal:true,sendEnter:true)}}
                    }
                    }
                    Button("取消本次粘贴") {perform {try clipboard.cancelPendingPaste()}}
                    Button("取消并保留当前剪贴板") {perform {try clipboard.cancelPendingPaste(restoreOriginal:false)}}
                }
                HStack {Spacer();Button("稍后处理",action:close)}
            } else if clipboard.hasActivePasteTransaction {
                Text("正在等待原目标，尚未确认发送。");Button("取消本次粘贴") {perform {try clipboard.cancelPendingPaste()}}
            } else {Text("没有待确认的粘贴。");Button("关闭",action:close)}
        }.padding(20).frame(width:520).onExitCommand(perform:close)
    }
    private func perform(_ action:() throws -> Void) {
        do {try action();failure=nil;if clipboard.pendingPaste == nil {close()}}
        catch {failure=error.localizedDescription}
    }
}
