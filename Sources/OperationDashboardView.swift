import SwiftUI
import AppKit

/// A launch surface built from the user's real actions and files. Opening the
/// dashboard never reads the pasteboard, captures the screen or asks for access.
struct OperationDashboardView: View {
    @ObservedObject var store: OperationStore

    private var favorites: [OperationAction] {
        let available = store.actionChoices
        return store.settings.favorites.compactMap { id in available.first { $0.id == id } }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                welcome
                destinations
                favoritesSection
                HStack(alignment: .top, spacing: 18) {
                    filesSection.frame(maxWidth: .infinity, alignment: .topLeading)
                    personalSection.frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .padding(28)
            .frame(maxWidth: 1240)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var welcome: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 14) {
                Label("你的 Mac 操作工作台", systemImage: "sparkle")
                    .font(.callout.weight(.medium)).foregroundStyle(.white.opacity(0.78))
                Text("把常用操作，放到手边。")
                    .font(.system(size: 27, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
                Text("处理文件、整理窗口、记录灵感。\n从这里开始，少点几下。")
                    .font(.callout).foregroundStyle(.white.opacity(0.8)).lineSpacing(4)
                Button { store.prepare("panel.show") } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "command")
                        Text("打开操作面板").fontWeight(.semibold)
                        Image(systemName: "arrow.right").font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(DashboardPalette.deepGreen)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.white, in: RoundedRectangle(cornerRadius: 10))
                    .contentShape(RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain).padding(.top, 3)
                .help("搜索全部动作，也可拖入文件后执行")
            }.frame(maxWidth: .infinity, alignment: .leading)
            DashboardWindowIllustration().frame(width: 138, height: 150)
                .accessibilityHidden(true)
        }
        .padding(26)
        .background {
            RoundedRectangle(cornerRadius: 20)
                .fill(LinearGradient(colors: [DashboardPalette.deepGreen, Color(red: 0.16, green: 0.43, blue: 0.39)], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
    }

    private var destinations: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 12)], spacing: 12) {
            DashboardDestinationCard(title: "截图与录制", detail: "截图 · 标注 · 文字识别", icon: "viewfinder", color: DashboardPalette.green) {
                store.section = .screenshots
            }
            DashboardDestinationCard(title: "剪贴板", detail: "历史内容与常用短语", icon: "doc.on.clipboard", color: Color(red: 0.40, green: 0.39, blue: 0.70)) {
                store.section = .clipboard
            }
            DashboardDestinationCard(title: "桌面总览", detail: "查找窗口，快速切换", icon: "rectangle.3.group", color: Color(red: 0.28, green: 0.46, blue: 0.68)) {
                store.section = .overview
            }
            DashboardDestinationCard(title: "文件处理", detail: "新建 · 转换 · 压缩", icon: "folder", color: Color(red: 0.65, green: 0.44, blue: 0.23)) {
                store.section = .files
            }
        }
    }

    private var favoritesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("常用动作").font(.title3.weight(.semibold))
                Spacer()
                Text("在动作旁点星标，即可收藏")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if favorites.isEmpty {
                HStack(spacing: 14) {
                    Image(systemName: "star").font(.title2).foregroundStyle(DashboardPalette.green)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("把顺手的动作收藏在这里").font(.headline)
                        Text("到文件、窗口或小工具中点亮星标，下次直接使用。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button("浏览动作") { store.section = .tools }
                }.padding(20).dashboardSurface()
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 12)], spacing: 12) {
                    ForEach(favorites) { action in
                        DashboardFavoriteRow(store: store, action: action)
                    }
                }
            }
        }
    }

    private var filesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("文件快处理", systemImage: "doc.badge.gearshape")
                    .font(.headline)
                Spacer()
                Button { store.chooseFiles() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless).help("选择文件或文件夹")
                    .accessibilityLabel("选择文件或文件夹")
            }
            if store.selection.isEmpty {
                Text("文件拖进窗口，就能接着处理。")
                    .font(.callout).foregroundStyle(.secondary)
                Button(action: store.chooseFiles) {
                    Label("选择文件…", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity).padding(.vertical, 18)
                        .background(DashboardPalette.green.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DashboardPalette.green.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                }.buttonStyle(.plain).foregroundStyle(DashboardPalette.green)
            } else {
                Text(L10n.format("已选择 %@ 项", String(store.selection.count)))
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(Array(store.selection.prefix(2).enumerated()), id: \.offset) { _, url in
                    Label(url.lastPathComponent, systemImage: "doc")
                        .font(.callout).lineLimit(1).help(url.path)
                }
                HStack(spacing: 8) {
                    Button("压缩 ZIP") { store.prepare("archive.create") }
                    Button("批量改名") { store.prepare("files.rename") }
                    Spacer(minLength: 0)
                }.controlSize(.small).disabled(!store.dataHealthy)
            }
            if !store.lastOutputs.isEmpty {
                Divider()
                Button { NSWorkspace.shared.activateFileViewerSelecting(store.lastOutputs) } label: {
                    Label("在 Finder 查看上次结果", systemImage: "arrow.up.forward.square")
                        .font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).foregroundStyle(DashboardPalette.green)
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).dashboardSurface()
    }

    private var personalSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("我的工作方式", systemImage: "slider.horizontal.3")
                    .font(.headline)
                Spacer()
            }
            DashboardTextLink(title: "快捷键与手势", detail: "让熟悉的操作一触即达", icon: "keyboard") { store.section = .input }
            Divider()
            DashboardTextLink(title: "组合操作", detail: "把多个步骤串成一次动作", icon: "square.stack.3d.up") { store.section = .workflows }
            if let folder = store.settings.folders.first(where: \.isCommon) {
                Divider()
                DashboardTextLink(title: folder.name, detail: "常用目录", icon: "folder") { store.openFolder(folder) }
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).dashboardSurface()
    }
}

private enum DashboardPalette {
    static let green = Color(red: 0.12, green: 0.48, blue: 0.42)
    static let deepGreen = Color(red: 0.08, green: 0.28, blue: 0.25)
}

private struct DashboardSurface: ViewModifier {
    func body(content: Content) -> some View {
        content.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.06)))
    }
}

private extension View {
    func dashboardSurface() -> some View { modifier(DashboardSurface()) }
}

private struct DashboardDestinationCard: View {
    let title: String
    let detail: String
    let icon: String
    let color: Color
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: icon).font(.system(size: 21, weight: .medium))
                        .foregroundStyle(color).frame(width: 42, height: 42)
                        .background(color.opacity(0.11), in: RoundedRectangle(cornerRadius: 12))
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right").font(.caption.weight(.medium))
                        .foregroundStyle(hovered ? color : Color.secondary.opacity(0.6))
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.padding(16).frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                .dashboardSurface()
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(color.opacity(hovered ? 0.4 : 0), lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(.plain).onHover { hovered = $0 }
        .accessibilityLabel(title + "，" + detail)
    }
}

private struct DashboardFavoriteRow: View {
    @ObservedObject var store: OperationStore
    let action: OperationAction
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 12) {
            Button { store.prepare(action.id) } label: {
                HStack(spacing: 12) {
                    Image(systemName: action.icon).font(.system(size: 18, weight: .medium))
                        .foregroundStyle(DashboardPalette.green).frame(width: 36, height: 38)
                        .background(DashboardPalette.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(action.title).font(.callout.weight(.semibold)).foregroundStyle(.primary)
                        Text(action.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(action.unavailableReason != nil)
                .help(action.unavailableReason ?? action.detail)
            Button { store.toggleFavorite(action.id) } label: {
                Image(systemName: "star.fill").font(.caption)
                    .foregroundStyle(Color(red: 0.68, green: 0.49, blue: 0.20))
                    .padding(4)
            }.buttonStyle(.plain).help("取消收藏")
                .accessibilityLabel("取消收藏：" + action.title)
                .disabled(!store.dataHealthy)
        }.padding(13).dashboardSurface()
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(DashboardPalette.green.opacity(hovered ? 0.22 : 0)))
            .onHover { hovered = $0 }
    }
}

private struct DashboardTextLink: View {
    let title: String
    let detail: String
    let icon: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: icon).font(.body).foregroundStyle(DashboardPalette.green).frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.callout.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).help(title)
    }
}

private struct DashboardWindowIllustration: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16).fill(.white.opacity(0.07))
                .frame(width: 112, height: 104).rotationEffect(.degrees(12)).offset(x: 10, y: -8)
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 4) {
                    ForEach(0..<3) { _ in Circle().fill(.white.opacity(0.65)).frame(width: 5, height: 5) }
                    Spacer()
                }
                HStack(alignment: .top, spacing: 8) {
                    RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.14)).frame(width: 22)
                    VStack(alignment: .leading, spacing: 7) {
                        Image(systemName: "command").font(.system(size: 25, weight: .medium)).foregroundStyle(.white)
                        RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.5)).frame(height: 4)
                        RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.2)).frame(width: 30, height: 4)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(15).frame(width: 120, height: 112)
                .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.24)))
                .rotationEffect(.degrees(-6))
            Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundStyle(DashboardPalette.deepGreen)
                .frame(width: 32, height: 32).background(Color(red: 0.76, green: 0.90, blue: 0.76), in: RoundedRectangle(cornerRadius: 10))
                .rotationEffect(.degrees(8)).offset(x: 49, y: 50)
        }
    }
}
