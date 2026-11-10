import AppKit
import SwiftUI

/// The page owns a short-lived catalog session. Rendering rows never starts a screenshot request.
struct DesktopOverviewView: View {
    @ObservedObject var controller: DesktopOverviewController
    @State private var query = ""
    @State private var appFilter = ""
    @State private var pendingClose: DesktopOverviewEntry?
    @FocusState private var searchFocused: Bool

    private var filtered: [DesktopOverviewEntry] {
        controller.entries.filter {
            (appFilter.isEmpty || $0.bundleID == appFilter) &&
            DesktopOverviewPolicy.containsQuery(appName: $0.appName, title: $0.title, bundleID: $0.bundleID, query: query)
        }
    }

    private var groups: [DesktopOverviewGroup] {
        let rows = filtered
        guard controller.preferences.groupByApplication else { return [DesktopOverviewGroup(id: "all", title: "", rows: rows)] }
        let grouped = Dictionary(grouping: rows) { "\($0.pid):\($0.bundleID)" }
        return grouped.map { key, rows in DesktopOverviewGroup(id: key, title: rows.first?.appName ?? "应用", rows: rows) }
            .sorted { $0.title == $1.title ? $0.id < $1.id : $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private var applicationFilters: [DesktopOverviewApplicationFilter] {
        Dictionary(grouping: controller.entries.filter { !$0.bundleID.isEmpty }, by: \.bundleID)
            .map { DesktopOverviewApplicationFilter(id: $0.key, title: $0.value.first?.appName ?? $0.key) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索应用、窗口标题或 Bundle ID", text: $query)
                    .textFieldStyle(.plain).focused($searchFocused)
                    .onSubmit { activateSelection() }
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).help("清除搜索") }
                Button { controller.refresh() } label: { Label("刷新", systemImage: "arrow.clockwise") }
                    .disabled(controller.isLoading || controller.isBusy)
            }.padding(14)
            Divider()
            permissionRow
            HStack(spacing: 12) {
                Text("\(filtered.count) 项").foregroundStyle(.secondary)
                Picker("应用", selection: $appFilter) {
                    Text("全部应用").tag("")
                    ForEach(applicationFilters) { app in Text(app.title).tag(app.id) }
                }.frame(maxWidth: 230)
                Spacer()
                Toggle("按应用分组", isOn: preferenceBinding(\.groupByApplication)).toggleStyle(.checkbox)
                Toggle("紧凑列表", isOn: preferenceBinding(\.compactChooser)).toggleStyle(.checkbox)
                exclusionMenu
            }.font(.callout).padding(.horizontal, 14).padding(.vertical, 10)
            Toggle("菜单栏下方状态条", isOn: preferenceBinding(\.statusStripEnabled))
                .toggleStyle(.checkbox).font(.caption).padding(.horizontal, 14).padding(.bottom, 10)
                .help("显示搞操作自有提示条，不接收鼠标输入，不改动系统菜单或其他应用图标。")
            Divider()
            if controller.isLoading { ProgressView("正在读取窗口目录…").controlSize(.small).padding(10) }
            if filtered.isEmpty && !controller.isLoading {
                ContentUnavailableView("没有匹配的窗口或应用", systemImage: "macwindow.on.rectangle", description: Text("尝试清除搜索、恢复排除应用或刷新目录。辅助功能未授权时仅显示应用入口。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(groups) { group in
                                if !group.title.isEmpty {
                                    HStack {
                                        Text(group.title).font(.headline)
                                        Text("\(group.rows.count) 项").font(.caption).foregroundStyle(.secondary)
                                    }.padding(.top, 8).padding(.leading, 8)
                                }
                                ForEach(group.rows) { entry in
                                    row(entry).id(entry.id)
                                }
                            }
                        }.padding(12)
                    }
                    .onChange(of: controller.selectedID) { _, id in
                        if let id { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
            Divider()
            selectionActions
            Divider()
            previewControls
            Text(controller.status).font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
        .onAppear { controller.beginSession() }
        .onDisappear { controller.endSession() }
        .onChange(of: controller.entries.map(\.id)) { _, _ in
            if !applicationFilters.contains(where: { $0.id == appFilter }) { appFilter = "" }
        }
        .onChange(of: query) { _, _ in normalizeSelection() }
        .onChange(of: appFilter) { _, _ in normalizeSelection() }
        .onKeyPress(.downArrow) { moveSelection(1); return .handled }
        .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
        .confirmationDialog("关闭所选窗口？", isPresented: Binding(get: { pendingClose != nil }, set: { if !$0 { pendingClose = nil } }), titleVisibility: .visible) {
            if let entry = pendingClose {
                Button("关闭窗口", role: .destructive) { controller.close(entry); pendingClose = nil }
            }
            Button("取消", role: .cancel) { pendingClose = nil }
        } message: {
            if let entry = pendingClose { Text(entry.appName + " · " + entry.displayTitle + "\n若有未保存内容，请在目标应用中处理其保存提示。") }
        }
    }

    private var permissionRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: controller.accessibilityGranted ? "checkmark.shield" : "hand.raised").foregroundStyle(.secondary)
            Text(controller.accessibilityGranted ? "已获辅助功能权限，可选择标准窗口、聚焦、关闭及应用现有窗口动作。" : "窗口操作需要辅助功能权限；当前仍可搜索并激活应用。")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            if !controller.accessibilityGranted { Button("辅助功能设置") { controller.openAccessibilitySettings() } }
            Button("刷新权限") { controller.refreshPermissions(); controller.refresh() }
                .disabled(controller.isBusy || controller.isLoading)
        }.padding(.horizontal, 14).padding(.top, 12)
    }

    private func row(_ entry: DesktopOverviewEntry) -> some View {
        let selected = controller.selectedID == entry.id
        return Button {
            controller.selectedID = entry.id
        } label: {
            HStack(spacing: 12) {
                if controller.preferences.thumbnailsEnabled {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08))
                        if let image = controller.cachedPreview(for: entry) {
                            Image(nsImage: image).resizable().scaledToFit().padding(2)
                        } else { Image(nsImage: entry.icon).resizable().scaledToFit().padding(8) }
                    }.frame(width: controller.preferences.compactChooser ? 64 : 96, height: controller.preferences.compactChooser ? 38 : 58)
                } else {
                    Image(nsImage: entry.icon).resizable().frame(width: controller.preferences.compactChooser ? 26 : 34, height: controller.preferences.compactChooser ? 26 : 34)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.displayTitle).font(.body).lineLimit(controller.preferences.compactChooser ? 1 : 2)
                    Text(entry.appName + " · " + entry.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                if entry.isMinimized { Image(systemName: "minus.square").foregroundStyle(.secondary).help("已最小化") }
                if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
            }.padding(controller.preferences.compactChooser ? 8 : 11).frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.accentColor : Color.secondary.opacity(0.12), lineWidth: selected ? 1.5 : 1))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(controller.isBusy || controller.isLoading)
        .accessibilityLabel(entry.appName + "，" + entry.displayTitle + "，" + entry.detail)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            Button(entry.canFocus ? "聚焦此窗口" : "激活此应用") { controller.selectedID = entry.id; controller.activate(entry) }
            Button("关闭此窗口…", role: .destructive) { pendingClose = entry }.disabled(!entry.canClose)
            Divider()
            Button("从总览排除此应用") { controller.excludeApplication(entry) }.disabled(entry.bundleID.isEmpty)
            Button("不预览此应用") { controller.excludePreview(entry) }.disabled(entry.bundleID.isEmpty || controller.preferences.excludedThumbnailBundleIDs.contains(entry.bundleID))
        }
    }

    private var selectionActions: some View {
        HStack(spacing: 10) {
            if let entry = controller.selectedEntry {
                Text(entry.appName + " · " + entry.displayTitle).font(.caption).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Button(entry.canFocus ? "聚焦窗口" : "激活应用") { controller.activate(entry) }
                    .disabled(controller.isBusy || controller.isLoading)
                if controller.supportsWindowActions {
                    Menu("窗口动作") {
                        ForEach(commonActions) { action in
                            Button { controller.perform(action, on: entry) } label: { Label(action.title, systemImage: action.icon) }
                        }
                    }.disabled(!entry.canFocus || !controller.accessibilityGranted || controller.isBusy || controller.isLoading)
                }
                Button("关闭…", role: .destructive) { pendingClose = entry }
                    .disabled(!entry.canClose || !controller.accessibilityGranted || controller.isBusy || controller.isLoading)
            } else {
                Text("选择一项后聚焦或执行窗口动作；搜索后可用 ↑↓ 选择、回车切换。").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            if controller.isBusy { ProgressView().controlSize(.small) }
        }.padding(12)
    }

    private var previewControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Toggle("窗口静态预览", isOn: preferenceBinding(\.thumbnailsEnabled)).toggleStyle(.checkbox)
                Spacer()
                if controller.preferences.thumbnailsEnabled {
                    if !controller.screenCaptureGranted {
                        Button("授权屏幕录制") { controller.requestPreviewPermission() }
                        Button("屏幕录制设置") { controller.openScreenCaptureSettings() }
                    }
                    Button("生成一次预览") { controller.capturePreviews() }
                        .disabled(!controller.screenCaptureGranted || !controller.accessibilityGranted || controller.isLoading || controller.isBusy || controller.isCapturingPreviews)
                    Button("清除预览") { controller.releasePreviews() }
                }
                if controller.isCapturingPreviews { ProgressView().controlSize(.small) }
            }
            Text(controller.preferences.thumbnailsEnabled ? "屏幕录制只用于读取窗口缩略图；授权后也需点击生成。列表、搜索与窗口操作使用辅助功能，无预览时显示应用图标。" : "静态预览已关闭；窗口列表、搜索与窗口操作仍可使用。")
                .font(.caption).foregroundStyle(.secondary)
            if controller.preferences.thumbnailsEnabled { Text(controller.previewStatus).font(.caption2).foregroundStyle(.secondary) }
        }.padding(12)
    }

    private var exclusionMenu: some View {
        Menu("排除设置") {
            if controller.preferences.excludedApplicationBundleIDs.isEmpty && controller.preferences.excludedThumbnailBundleIDs.isEmpty {
                Text("未设置排除应用")
            }
            if !controller.preferences.excludedApplicationBundleIDs.isEmpty {
                Section("从总览排除") {
                    ForEach(controller.preferences.excludedApplicationBundleIDs, id: \.self) { id in
                        Button("恢复 " + id) { controller.updatePreferences { $0.excludedApplicationBundleIDs.removeAll { $0 == id } } }
                    }
                }
            }
            if !controller.preferences.excludedThumbnailBundleIDs.isEmpty {
                Section("不读取预览") {
                    ForEach(controller.preferences.excludedThumbnailBundleIDs, id: \.self) { id in
                        Button("允许预览 " + id) { controller.updatePreferences { $0.excludedThumbnailBundleIDs.removeAll { $0 == id } } }
                    }
                }
            }
        }.disabled(controller.isBusy)
    }

    private let commonActions: [WindowAction] = [.leftHalf, .rightHalf, .topHalf, .bottomHalf, .topLeft, .topRight, .bottomLeft, .bottomRight, .maximize, .nearMaximize, .center, .centerHalf, .maximizeHeight, .maximizeWidth, .smaller, .larger, .restore, .minimize, .toggleFullScreen]

    private func preferenceBinding(_ keyPath: WritableKeyPath<DesktopOverviewPreferences, Bool>) -> Binding<Bool> {
        Binding(get: { controller.preferences[keyPath: keyPath] }, set: { value in controller.updatePreferences { $0[keyPath: keyPath] = value } })
    }

    private func normalizeSelection() {
        if !filtered.contains(where: { $0.id == controller.selectedID }) { controller.selectedID = filtered.first?.id }
    }

    private func moveSelection(_ delta: Int) {
        let rows = groups.flatMap(\.rows)
        guard !rows.isEmpty else { return }
        let index = rows.firstIndex { $0.id == controller.selectedID }
        let next = index.map { min(max($0 + delta, 0), rows.count - 1) } ?? (delta >= 0 ? 0 : rows.count - 1)
        controller.selectedID = rows[next].id
    }

    private func activateSelection() {
        if let entry = filtered.first(where: { $0.id == controller.selectedID }) ?? filtered.first { controller.selectedID = entry.id; controller.activate(entry) }
    }
}

private struct DesktopOverviewGroup: Identifiable {
    let id: String
    let title: String
    let rows: [DesktopOverviewEntry]
}

private struct DesktopOverviewApplicationFilter: Identifiable {
    let id: String
    let title: String
}
