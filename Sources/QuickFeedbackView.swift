import AppKit
import SwiftUI

struct QuickFeedbackView: View {
    @ObservedObject var store:OperationStore
    @ObservedObject var archive:ArchiveService
    let close:()->Void
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            HStack(alignment:.top,spacing:10) {
                if store.feedback.kind == .running {ProgressView().controlSize(.small)}
                else {Image(systemName:store.feedback.kind == .failure ? "exclamationmark.circle.fill" : "checkmark.circle.fill").foregroundStyle(store.feedback.kind == .failure ? .orange : .green)}
                Text(store.feedback.title).font(.callout.weight(.medium)).lineLimit(3).frame(maxWidth:.infinity,alignment:.leading)
                Button(action:close){Image(systemName:"xmark")}.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            if archive.isRunning,let progress=archive.progress {ProgressView(value:progress)}
            HStack(spacing:12) {
                if store.queuedCount > 0 {Text("等待 \(store.queuedCount) 项").font(.caption).foregroundStyle(.secondary)}
                if !store.feedback.outputs.isEmpty {
                    Text(store.feedback.outputs.count == 1 ? store.feedback.outputs[0].lastPathComponent : "\(store.feedback.outputs.count) 个结果").font(.caption).lineLimit(1).foregroundStyle(.secondary)
                    Spacer(minLength:0)
                    Button("显示结果"){NSWorkspace.shared.activateFileViewerSelecting(store.feedback.outputs);close()}.controlSize(.small)
                } else {Spacer(minLength:0)}
                if archive.isRunning || store.awaitingArchivePassword {Button("取消任务"){store.cancelQuickArchive()}.controlSize(.small)}
                else if store.queuedCount > 0 {Button("取消等待"){store.cancelWaitingJobs()}.controlSize(.small)}
                if store.feedback.kind == .failure {Button("打开搞操作"){close();store.showMain?()}.controlSize(.small)}
            }
        }.padding(16).frame(width:360).background(.regularMaterial,in:RoundedRectangle(cornerRadius:14))
    }
}

struct ArchivePasswordPrompt:View {
    let filename:String
    let incorrect:Bool
    let finish:(String?)->Void
    @State private var password=""
    @FocusState private var focused:Bool
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            Label("这个压缩包需要密码",systemImage:"lock.fill").font(.headline)
            Text(filename).font(.callout).lineLimit(2)
            if incorrect {Text("密码不正确，请重试。").font(.callout).foregroundStyle(.red)}
            SecureField("压缩包密码",text:$password).textFieldStyle(.roundedBorder).focused($focused).onSubmit{if !password.isEmpty{finish(password)}}
            HStack {Text("仅用于这次解压").font(.caption).foregroundStyle(.secondary);Spacer();Button("取消"){finish(nil)}.keyboardShortcut(.cancelAction);Button("继续解压"){finish(password)}.keyboardShortcut(.defaultAction).disabled(password.isEmpty)}
        }.padding(22).frame(width:410).onAppear{focused=true}
    }
}
