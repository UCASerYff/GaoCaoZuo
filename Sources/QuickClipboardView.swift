import AppKit
import Combine
import SwiftUI

@MainActor struct QuickClipboardView: View {
    @ObservedObject private var store: OperationStore
    @ObservedObject private var clipboard: ClipboardService
    private let close: () -> Void
    private let onError: (String) -> Void
    @State private var query = ""
    @State private var selected = 0
    @State private var reportedError: String?
    @FocusState private var searchFocused: Bool

    init(store: OperationStore, close: @escaping () -> Void, onError: ((String) -> Void)? = nil) {
        self.store = store
        self.clipboard = store.clipboard
        self.close = close
        self.onError = onError ?? { [weak store] message in store?.error = message }
    }

    private var matches: [ClipboardItem] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return clipboard.items.filter { item in
            search.isEmpty || item.title.localizedCaseInsensitiveContains(search)
                || (item.text?.localizedCaseInsensitiveContains(search) ?? false)
                || (item.paths?.contains(where: { $0.localizedCaseInsensitiveContains(search) }) ?? false)
        }
    }
    private var snippets: [TextSnippet] {
        store.settings.snippets.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.text.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "doc.on.clipboard").foregroundStyle(.secondary)
                TextField("搜索剪贴板…", text: $query)
                    .textFieldStyle(.plain).font(.title3).focused($searchFocused)
                    .onSubmit(pasteSelected)
                Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.plain).help("关闭 Esc")
            }.padding(16)
            Divider()
            if !store.settings.clipboardEnabled {
                HStack(spacing: 10) {
                    Text("历史记录未开启").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("开启历史") { store.update { $0.clipboardEnabled = true } }
                        .controlSize(.small).disabled(!store.dataHealthy)
                }.padding(.horizontal, 16).padding(.vertical, 9)
                Divider()
            }
            if let error = clipboard.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 8)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(matches.enumerated()), id: \.element.id) { index, item in
                            row(item, selected: selected == index).id(item.id)
                        }
                    }.padding(8)
                    if matches.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "doc.on.clipboard").font(.title).foregroundStyle(.tertiary)
                            Text(query.isEmpty ? "暂无剪贴板历史" : "没有匹配内容").font(.headline)
                            Text(query.isEmpty ? "可直接粘贴当前剪贴板的纯文本，或复制下方常用文本。" : "试试其他关键词。")
                                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }.frame(maxWidth: .infinity).padding(26)
                    }
                }
                .onChange(of: selected) { _, value in
                    if matches.indices.contains(value) { proxy.scrollTo(matches[value].id, anchor: .center) }
                }
            }
            if !snippets.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("常用文本 · 点击复制").font(.caption).foregroundStyle(.secondary)
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(snippets) { snippet in
                                Button(snippet.name) {
                                    clipboard.copyText(snippet.text)
                                    store.message = "已复制常用文本"
                                    close()
                                }.controlSize(.small).help(snippet.text)
                            }
                        }
                    }.scrollIndicators(.hidden)
                }.padding(.horizontal, 16).padding(.vertical, 10)
            }
            Divider()
            HStack {
                Text("↑↓ 选择 · 回车粘贴").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("粘贴当前纯文本") {
                    do { try clipboard.pastePlainText(); close() }
                    catch { report(error.localizedDescription) }
                }.controlSize(.small)
                Button("管理") { close(); store.section = .clipboard; store.showMain?() }.controlSize(.small)
            }.padding(.horizontal, 14).padding(.vertical, 10)
        }
        .frame(width: 520, height: 480)
        .onAppear { selected = 0; reportedError = nil; searchFocused = true }
        .onExitCommand(perform: close)
        .onChange(of: query) { _, _ in selected = 0 }
        .onChange(of: clipboard.items) { _, _ in selected = min(selected, max(0, matches.count - 1)) }
        .onReceive(clipboard.$error.dropFirst().removeDuplicates()) { value in if let value { report(value) } }
        .onMoveCommand { direction in
            if direction == .down { selected = min(selected + 1, max(0, matches.count - 1)) }
            if direction == .up { selected = max(selected - 1, 0) }
        }
    }

    private func row(_ item: ClipboardItem, selected: Bool) -> some View {
        Button { paste(item) } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: item.kind == .image ? "photo" : item.kind == .files ? "doc.on.doc" : "text.alignleft")
                    .font(.title3).foregroundStyle(.tint).frame(width: 25).padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 6) {
                        if item.pinned { Label("已固定", systemImage: "pin.fill") }
                        Text(item.date, style: .relative)
                        if item.kind == .files { Text("\(item.paths?.count ?? 0) 个文件") }
                    }.font(.caption).foregroundStyle(.secondary)
                }
                Image(systemName: "return").font(.caption).foregroundStyle(.tertiary).padding(.top, 4)
            }.padding(10).contentShape(Rectangle())
                .background(selected ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
        .help("点击直接粘贴；右键查看更多操作")
        .contextMenu {
            Button("粘贴") { paste(item) }
            Button("复制") { copy(item) }
            if item.kind == .text {
                Button("粘贴为纯文本") { paste(item, plain: true) }
                Button("复制为纯文本") { copy(item, plain: true) }
            }
            Divider()
            Button(item.pinned ? "取消固定" : "固定") { clipboard.pin(item.id) }
            Button("删除", role: .destructive) { clipboard.delete(item.id) }
        }
    }
    private func pasteSelected() {
        guard matches.indices.contains(selected) else { return }
        paste(matches[selected])
    }
    private func paste(_ item: ClipboardItem, plain: Bool = false) {
        do { try clipboard.paste(item, plain: plain); close() }
        catch { report(error.localizedDescription) }
    }
    private func copy(_ item: ClipboardItem, plain: Bool = false) {
        do {
            try clipboard.copy(item, plain: plain)
            store.message = plain ? "已复制为纯文本" : "已复制"
            close()
        } catch { report(error.localizedDescription) }
    }
    private func report(_ message: String) {
        guard message != reportedError else { return }
        reportedError = message
        onError(message)
    }
}
