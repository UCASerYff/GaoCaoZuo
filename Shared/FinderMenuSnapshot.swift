import AppKit
import Foundation

struct FinderMenuItemDefinition: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var icon: String
    var enabled = true
    var group: String
}
struct FinderMenuFolder: Codable, Identifiable {
    var id: String
    var name: String
    var path: String
}
struct FinderMenuTemplate: Codable, Identifiable {
    var id: String
    var name: String
    var binary: Bool
}
struct FinderMenuApplication:Codable,Identifiable {var id:String;var name:String}
struct FinderMenuPreferences: Codable {
    var schema = 1
    var items = Self.defaults
    var showIcons = true
    var mergeInSubmenu = true
    var includeExternalVolumes = true
    var showToolbar = true
    var excludedPaths: [String] = []
    var excludedApps: [String] = []
    static var defaults: [FinderMenuItemDefinition] {
        let groups: [(String,[(String,String,String)])] = [
            ("压缩",[("archive.create","压缩为 ZIP","archivebox"),("archive.7z","压缩为 7Z","archivebox.fill"),("archive.extract","直接解压","shippingbox"),("archive.list","预览压缩包…","list.bullet.rectangle"),("archive.custom","自定义压缩…","slider.horizontal.3"),("archive.extract.custom","解压到其他目录…","folder")]),
            ("新建",[("new.text","新建文本","doc.badge.plus"),("new.markdown","新建 Markdown","doc.badge.plus"),("new.folder","新建文件夹","folder.badge.plus"),("file.new.office","新建文档…","doc"),("file.new.docx","新建 Word","doc"),("file.new.xlsx","新建 Excel","tablecells"),("file.new.pptx","新建 PowerPoint","rectangle.on.rectangle"),("file.new.pages","新建 Pages","doc"),("file.new.numbers","新建 Numbers","tablecells"),("file.new.key","新建 Keynote","rectangle.on.rectangle"),("new.custom","自定义新建…","square.and.pencil")]),
            ("目录",[("folder.open","常用目录","heart"),("folder.copy","复制到","doc.on.doc"),("folder.move","移动到","folder"),("file.template.create","文件模板","doc.on.doc")]),
            ("文件",[("path.copy","复制路径","link"),("file.path.real","复制真实路径","link"),("file.path.custom","复制自定义路径","link"),("name.copy","复制文件名","textformat"),("folder.favorite.add","添加到常用目录","heart"),("file.cut","剪切","scissors"),("file.paste","粘贴剪切文件","doc.on.clipboard"),("files.rename","批量重命名…","pencil"),("file.folderNames","根据文件名新建文件夹","folder.badge.plus"),("file.dissolve","解散文件夹…","folder.badge.minus"),("file.alias","发送替身到桌面","arrowshape.turn.up.right")]),
            ("属性",[("file.hide","隐藏所选文件","eye.slash"),("file.unhide","取消隐藏所选文件","eye"),("file.hideAll","隐藏当前目录全部文件","eye.slash"),("file.unhideAll","取消隐藏当前目录全部文件","eye"),("file.extension.hide","隐藏扩展名","textformat"),("file.extension.show","显示扩展名","textformat"),("file.write","授予写权限","lock.open"),("file.permissions","设置文件权限…","lock"),("file.icon","设置图标…","photo"),("file.icon.clear","移除自定义图标","photo"),("file.info","文件信息与校验值","info.circle")]),
            ("图片",[("images.png","转为 PNG","photo"),("images.jpeg","转为 JPEG","photo"),("images.heic","转为 HEIC","photo"),("images.tiff","转为 TIFF","photo"),("images.webp","转为 WebP","photo"),("images.icns","转为 ICNS","app"),("images.macicons","macOS 图标集","app"),("images.iosicons","iOS 图标集","app"),("images.convert","自定义格式与尺寸…","slider.horizontal.3"),("file.wallpaper","设为桌面墙纸","photo")]),
            ("分享与应用",[("file.openApp","用指定应用打开…","app"),("file.terminal","在终端打开…","terminal"),("file.airdrop","隔空投送","airplayaudio"),("file.mail","邮件发送","envelope"),("file.ishot","打开 iShot","camera"),("file.ishot.markup","用 iShot 打开图片","photo"),("file.diskmap","DiskMap 分析","chart.pie"),("file.delete","彻底删除…","trash")])]
        return groups.flatMap { group, values in values.map { id,title,icon in
            FinderMenuItemDefinition(id:id,title:title,icon:icon,enabled:["archive.create","archive.7z","archive.extract","archive.list","archive.custom","new.text","new.markdown","new.folder","file.new.office","folder.open","folder.copy","folder.move","file.template.create","path.copy","name.copy","folder.favorite.add","file.cut","file.paste","files.rename","file.info","file.hide","file.unhide","file.terminal"].contains(id),group:group)
        } }
    }
}
struct FinderMenuSnapshot: Codable {
    var schema = 1
    var preferences = FinderMenuPreferences()
    var folders: [FinderMenuFolder] = []
    var templates: [FinderMenuTemplate] = []
    var applications:[FinderMenuApplication]=[]
    static let pasteboardName = NSPasteboard.Name("com.gaoseries.GaoCaoZuo.finder-menu")
    static let type = NSPasteboard.PasteboardType("com.gaoseries.GaoCaoZuo.finder-menu-json")
    static let changedNotification = NSNotification.Name("com.gaoseries.GaoCaoZuo.finder-menu-changed")
    @MainActor static func read() -> Self? {
        guard let bytes=NSPasteboard(name:pasteboardName).data(forType:type),bytes.count <= 2_000_000,
              let value=try? JSONDecoder().decode(Self.self,from:bytes),value.schema == 1,
              value.preferences.schema == 1,value.folders.count <= 1000,value.templates.count <= 1000,
              value.preferences.items.count <= 300,value.applications.count<=1000,
              value.preferences.items.allSatisfy({$0.title.utf8.count <= 512 && FinderActionRequest.isAllowed($0.id) || ["folder.open","folder.copy","folder.move"].contains($0.id)}) else {return nil}
        return value
    }
    @MainActor func publish() {
        guard let bytes=try? JSONEncoder().encode(self),bytes.count <= 2_000_000 else {return}
        let board=NSPasteboard(name:Self.pasteboardName);board.clearContents();board.setData(bytes,forType:Self.type)
        DistributedNotificationCenter.default().postNotificationName(Self.changedNotification,object:nil,userInfo:nil,deliverImmediately:true)
    }
}
