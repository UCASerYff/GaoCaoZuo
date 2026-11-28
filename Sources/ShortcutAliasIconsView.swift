import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ShortcutAliasIconsView: View {
    @ObservedObject var store: OperationStore
    @State private var rows: [ShortcutAliasPreview] = []
    @State private var selected = Set<String>()
    @State private var palette: [ShortcutMascot: NSImage] = [:]
    @State private var role: ShortcutMascot = .chatgpt
    @State private var custom: LocalIcon?
    @State private var suggestions: [String: ShortcutMascot] = [:]
    @State private var decision: Decision?
    @State private var message: String?
    @State private var problems: [String] = []

    private struct LocalIcon {
        let name: String
        let image: NSImage
    }

    private struct Decision: Identifiable {
        let id = UUID()
        let rows: [ShortcutAliasPreview]
        let icons: [String: LocalIcon]
        var title: String { icons.isEmpty ? "恢复默认图标" : "应用图标" }
    }

    private var service: ShortcutAliasIcons { store.shortcutAliasIcons }
    private var canWrite: Bool { store.dataHealthy && service.healthy }
    private var targetRows: [ShortcutAliasPreview] { rows.filter { selected.contains($0.id) } }
    private var editable: [ShortcutAliasPreview] { targetRows.filter { $0.state == .available || $0.state == .managed } }
    private var managed: [ShortcutAliasPreview] { targetRows.filter { $0.state == .managed } }
    private func chosenIcon(for row: ShortcutAliasPreview) -> LocalIcon? {
        let selectedRole = suggestions[row.id] ?? role
        return custom ?? palette[selectedRole].map { LocalIcon(name: selectedRole.title, image: $0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                controls
                paletteView
                aliasList
                footer
            }
            .padding(26)
            .frame(maxWidth: 1_240, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear(perform: loadPalette)
        .alert("图标换装", isPresented: Binding(get: { decision != nil }, set: { if !$0 { decision = nil } }), presenting: decision) { pending in
            Button(pending.title) { apply(pending) }
            Button("取消", role: .cancel) {}
        } message: { pending in
            let names = pending.rows.prefix(6).map { $0.url.lastPathComponent }.joined(separator: "、")
            let remainder = pending.rows.count > 6 ? "等 \(pending.rows.count) 个替身" : ""
            let icons = Set(pending.icons.values.map(\.name)).sorted()
            Text("\(names)\(remainder)\n\(icons.isEmpty ? "恢复默认图标" : "图标：" + icons.joined(separator: "、"))")
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button { scanDesktop() } label: { Label("扫描桌面", systemImage: "desktopcomputer") }
            Button { chooseAliases() } label: { Label("添加替身…", systemImage: "plus") }
            Button { createAlias() } label: { Label("新建应用替身…", systemImage: "arrowshape.turn.up.right") }
                .disabled(!canWrite)
            Spacer(minLength: 4)
            Button("匹配常见 AI") { matchNames() }.disabled(rows.isEmpty)
            Button { chooseImage() } label: { Label("本地图标…", systemImage: "photo.badge.plus") }
        }
    }

    private var paletteView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("角色图标").font(.headline)
                if let custom {
                    Image(nsImage: custom.image).resizable().scaledToFit().frame(width: 23, height: 23).accessibilityHidden(true)
                    Text(custom.name).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    Button("返回角色图标") { self.custom = nil }.buttonStyle(.plain).foregroundStyle(OperationStyle.accent)
                }
                Spacer()
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 10)], spacing: 10) {
                ForEach(ShortcutMascot.allCases) { value in
                    let isChosen = custom == nil && suggestions.isEmpty && role == value
                    Button {
                        role = value
                        custom = nil
                        suggestions.removeAll()
                    } label: {
                        VStack(spacing: 7) {
                            if let image = palette[value] {
                                Image(nsImage: image).resizable().scaledToFit().frame(width: 60, height: 60).accessibilityHidden(true)
                            } else {
                                Image(systemName: "photo").foregroundStyle(.secondary).frame(width: 60, height: 60)
                            }
                            Text(value.title).font(.callout.weight(isChosen ? .semibold : .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(isChosen ? OperationStyle.accent.opacity(0.12) : OperationStyle.surface,
                                    in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(isChosen ? OperationStyle.accent : Color.secondary.opacity(0.16)))
                        .contentShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isChosen ? .isSelected : [])
                    .disabled(palette[value] == nil)
                }
            }
        }
    }

    private var aliasList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Finder 替身").font(.headline)
                Spacer()
                if !rows.isEmpty {
                    Text("已选 \(selected.count) / \(rows.count)").font(.caption).foregroundStyle(.secondary)
                    Button("全选可换装项") {
                        selected = Set(rows.filter { $0.state == .available || $0.state == .managed }.map(\.id))
                    }.buttonStyle(.plain).foregroundStyle(OperationStyle.accent)
                }
            }
            if rows.isEmpty {
                ContentUnavailableView("还没有替身", systemImage: "arrowshape.turn.up.right",
                    description: Text("扫描桌面，或添加你想换装的 Finder 替身。"))
                    .frame(maxWidth: .infinity, minHeight: 190)
            } else {
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        aliasRow(row)
                        if row.id != rows.last?.id { Divider().padding(.horizontal, 12) }
                    }
                }
            }
        }
        .padding(15)
        .background(OperationStyle.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private func aliasRow(_ row: ShortcutAliasPreview) -> some View {
        let canSelect = row.state == .available || row.state == .managed
        return HStack(spacing: 11) {
            Toggle(isOn: Binding(get: { selected.contains(row.id) }, set: { checked in
                if checked { selected.insert(row.id) } else { selected.remove(row.id) }
            })) {
                Text(row.url.lastPathComponent)
            }.labelsHidden().toggleStyle(.checkbox).disabled(!canSelect)
            Image(nsImage: row.currentImage).resizable().scaledToFit().frame(width: 36, height: 36).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.url.lastPathComponent).font(.callout.weight(.medium)).lineLimit(1)
                Text(row.url.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 5)
            if selected.contains(row.id), let preview = chosenIcon(for: row) {
                Image(nsImage: preview.image).resizable().scaledToFit().frame(width: 26, height: 26).accessibilityLabel("换装预览")
            }
            Text(status(row)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }.padding(.horizontal, 11).padding(.vertical, 9)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
                Spacer()
                Button("恢复已选") { decision = Decision(rows: managed, icons: [:]) }
                    .disabled(managed.isEmpty || managed.count > 80 || !canWrite)
                Button("应用到已选") {
                    let icons = editable.compactMap { row in chosenIcon(for: row).map { (row.id, $0) } }
                    if icons.count == editable.count { decision = Decision(rows: editable, icons: Dictionary(uniqueKeysWithValues: icons)) }
                }.buttonStyle(.borderedProminent)
                    .disabled(editable.isEmpty || editable.count > 80 || editable.contains(where: { chosenIcon(for: $0) == nil }) || !canWrite)
            }
            ForEach(Array(problems.prefix(8).enumerated()), id: \.offset) { item in
                Text(item.element).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func status(_ row: ShortcutAliasPreview) -> String {
        switch row.state {
        case .available: return "默认图标"
        case .managed: return row.appliedName ?? "已换装"
        case .custom: return "已有自定义图标"
        case .changed: return "已在外部修改"
        case .interrupted: return "上次操作待核对"
        }
    }

    private func loadPalette() {
        guard palette.isEmpty else { return }
        for value in ShortcutMascot.allCases {
            if let url = value.imageURL, let image = try? ShortcutAliasIcons.loadLocalImage(url) { palette[value] = image }
        }
        if palette.count != ShortcutMascot.allCases.count { message = "部分角色图标无法加载。" }
    }

    private func collect(_ urls: [URL], addSelection: Bool) {
        var known = Set(rows.map(\.id))
        problems = []
        for url in urls.prefix(300) where known.insert(url.standardizedFileURL.path).inserted {
            do {
                if let preview = try service.previews(for: [url]).first {
                    rows.append(preview)
                    if addSelection && (preview.state == .available || preview.state == .managed) { selected.insert(preview.id) }
                }
            } catch { problems.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
        }
        if urls.count > 300 { problems.append("桌面替身较多，已显示前 300 项。") }
        if rows.isEmpty && problems.isEmpty { message = "没有找到 Finder 替身。" }
        else { message = "已列出 \(rows.count) 个替身。" }
    }

    private func scanDesktop() {
        do {
            let desktop = try service.desktopAliases()
            let paths = rows.map(\.url) + desktop
            let oldSelection = selected
            rows = []
            collect(paths, addSelection: false)
            selected = oldSelection.intersection(rows.map(\.id))
        } catch { message = error.localizedDescription }
    }

    private func matchNames() {
        let suggestions = rows.compactMap { row -> (String, ShortcutMascot)? in
            guard row.state == .available || row.state == .managed,
                  let role = ShortcutMascot.suggestion(for: row.url.lastPathComponent), palette[role] != nil else { return nil }
            return (row.id, role)
        }
        guard !suggestions.isEmpty else { message = "没有按名称匹配到常见 AI 替身。"; return }
        self.suggestions = Dictionary(uniqueKeysWithValues: suggestions)
        selected = Set(self.suggestions.keys)
        custom = nil
        message = "已为 \(suggestions.count) 项建议图标。"
    }

    private func chooseAliases() {
        let panel = NSOpenPanel()
        panel.title = "选择 Finder 替身"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = false
        panel.directoryURL = service.desktop
        if panel.runModal() == .OK { collect(panel.urls, addSelection: true) }
    }

    private func createAlias() {
        let panel = NSOpenPanel()
        panel.title = "选择应用程序"
        panel.allowedContentTypes = [.application]
        panel.directoryURL = FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask).first
        guard panel.runModal() == .OK, let app = panel.url else { return }
        do { collect([try service.createAlias(for: app)], addSelection: true) }
        catch { message = error.localizedDescription }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.title = "选择本地图标"
        panel.allowedContentTypes = ["ico", "icns", "png"].compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            custom = LocalIcon(name: url.lastPathComponent, image: try ShortcutAliasIcons.loadLocalImage(url))
            suggestions.removeAll()
        }
        catch { message = error.localizedDescription }
    }

    private func apply(_ pending: Decision) {
        guard canWrite else { message = "资料暂时不可写入。"; return }
        do {
            let groups = Dictionary(grouping: pending.rows) { pending.icons[$0.id]?.name ?? "" }
            var changed = 0
            var failures: [String] = []
            for key in groups.keys.sorted() {
                guard let group = groups[key], let first = group.first else { continue }
                let result = try service.change(group, to: pending.icons[first.id]?.image, name: key)
                changed += result.completed
                failures += result.failures
                if !canWrite { break }
            }
            for index in rows.indices where pending.rows.contains(where: { $0.id == rows[index].id }) {
                if let updated = (try? service.previews(for: [rows[index].url]))?.first { rows[index] = updated }
            }
            problems = failures
            let unfinished = pending.rows.count - changed
            message = "\(pending.title) \(changed) 项。" + (unfinished == 0 ? "" : " 有 \(unfinished) 项未完成。")
            store.message = message ?? ""
        } catch { message = error.localizedDescription }
    }
}
