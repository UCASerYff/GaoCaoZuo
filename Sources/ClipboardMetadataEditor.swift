import SwiftUI

struct ClipboardMetadataEditor: View {
    let item:ClipboardItem
    let save:(String,[String]) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var group=""
    @State private var tags=""
    @State private var failure:String?
    var body:some View {
        Form {
            Text("剪贴板分组与标签").font(.headline)
            TextField("分组",text:$group)
            TextField("标签（逗号分隔）",text:$tags)
            if let failure {Text(L10n.text(failure)).foregroundStyle(.red)}
            HStack {Button("取消") {dismiss()};Spacer();Button("保存") {do {try save(group.trimmingCharacters(in:.whitespacesAndNewlines),tags.split(whereSeparator:{$0 == "," || $0 == "，"}).map{String($0).trimmingCharacters(in:.whitespacesAndNewlines)}.filter{!$0.isEmpty});dismiss()} catch {failure=error.localizedDescription}}.keyboardShortcut(.defaultAction)}
        }.padding(20).frame(width:440).onAppear {group=item.group ?? "";tags=(item.tags ?? []).joined(separator:", ")}
    }
}
