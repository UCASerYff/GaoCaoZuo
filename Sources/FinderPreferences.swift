import AppKit
import SwiftUI

@MainActor final class FinderPreferenceController: ObservableObject {
    @Published private(set) var preferences=FinderMenuPreferences()
    @Published var error:String?
    let data:LocalData
    var changed:(()->Void)?
    init(directory:URL) {
        data=LocalData(directory:directory)
        do {
            if var value=try data.load("finder-menu.json",as:FinderMenuPreferences.self) {
                guard value.schema == 1 else {throw DataFailure.message("右键配置来自更新版本，原配置已保留。")}
                let legacyTitles=["file.ishot":"打开 iShot","file.ishot.markup":"用 iShot 打开图片","file.diskmap":"DiskMap 分析"]
                let defaults=Dictionary(uniqueKeysWithValues:FinderMenuPreferences.defaults.map{($0.id,$0.title)})
                for index in value.items.indices {
                    let item=value.items[index]
                    if legacyTitles[item.id] == item.title,let replacement=defaults[item.id] {value.items[index].title=replacement}
                }
                let ids=Set(value.items.map(\.id));value.items += FinderMenuPreferences.defaults.filter{!ids.contains($0.id)}
                preferences=value
            }
        } catch {data.block(error.localizedDescription);self.error=error.localizedDescription}
    }
    func update(_ body:(inout FinderMenuPreferences)->Void) {
        do {var next=preferences;body(&next);try data.save(next,name:"finder-menu.json");preferences=next;error=nil;changed?()}
        catch {self.error=error.localizedDescription}
    }
    func addExcludedPath(_ raw:String) {
        // Spaces are legal filename characters, including at the end of a path.
        // Do not trim them into a different exclusion target.
        let path=raw
        guard path.hasPrefix("/"),!path.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) else {error=L10n.text("请输入有效的绝对目录路径。");return}
        let normalized=URL(fileURLWithPath:path).standardizedFileURL.path
        update {value in if !value.excludedPaths.contains(where:{URL(fileURLWithPath:$0).standardizedFileURL.path == normalized}) {value.excludedPaths.append(normalized)}}
    }
    func addExcludedApplication(_ raw:String) {
        let id=raw.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !id.isEmpty,id.utf8.count <= 512,!id.unicodeScalars.contains(where:CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains) else {error=L10n.text("请输入不含空白或控制字符的应用 Bundle ID。");return}
        update {value in if !value.excludedApps.contains(id) {value.excludedApps.append(id)}}
    }
    func replaceForMigration(_ value:FinderMenuPreferences) throws {
        guard value.schema == 1 else {throw DataFailure.message("菜单配置版本无效。")};try data.save(value,name:"finder-menu.json");preferences=value;changed?()
    }
    func move(_ id:String,by distance:Int) {
        update {value in guard let index=value.items.firstIndex(where:{$0.id == id}) else{return};let to=max(0,min(value.items.count-1,index+distance));let item=value.items.remove(at:index);value.items.insert(item,at:to)}
    }
    func publish(store:OperationStore) {
        let folders=store.settings.folders.map{FinderMenuFolder(id:$0.id.uuidString,name:$0.name,path:$0.path,sourceRoles:$0.sourceRoles)}
        let templates=store.settings.templates.map{FinderMenuTemplate(id:$0.id.uuidString,name:$0.name,binary:false)} + store.fileEnhancements.settings.templates.filter(\.isEnabled).map{FinderMenuTemplate(id:$0.id.uuidString,name:$0.name,binary:true)}
        let apps=store.fileEnhancements.settings.apps.filter(\.isEnabled).map{FinderMenuApplication(id:$0.id.uuidString,name:$0.name)}
        FinderMenuSnapshot(preferences:preferences,folders:folders,templates:templates,applications:apps,language:store.settings.language).publish()
    }
}
struct FinderPreferenceView:View {
    @ObservedObject var controller:FinderPreferenceController
    @State private var excluded=""
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Toggle("显示图标",isOn:flag(\.showIcons));Toggle("收纳到搞操作子菜单",isOn:flag(\.mergeInSubmenu))
            }
            HStack {
                Toggle("包括系统盘与外接磁盘",isOn:flag(\.includeExternalVolumes));Toggle("访达工具栏菜单",isOn:flag(\.showToolbar))
            }
            Text("拖动条目调整顺序，也可用上下箭头；关闭不常用的功能可以保持右键菜单简洁。").font(.caption).foregroundStyle(.secondary)
            List {
                ForEach(controller.preferences.items) {item in
                    HStack {
                        Toggle("",isOn:Binding(get:{controller.preferences.items.first(where:{$0.id==item.id})?.enabled ?? false},set:{enabled in controller.update{value in if let i=value.items.firstIndex(where:{$0.id==item.id}){value.items[i].enabled=enabled}}})).labelsHidden()
                        Image(systemName:item.icon).frame(width:22)
                        TextField("菜单名称",text:Binding(get:{FinderMenuPreferences.displayTitle(controller.preferences.items.first(where:{$0.id==item.id}) ?? item)},set:{title in controller.update{value in if let i=value.items.firstIndex(where:{$0.id==item.id}){value.items[i].title=FinderMenuPreferences.storedTitle(String(title.prefix(120)),for:item.id)}}}))
                        Text(L10n.text(item.group)).font(.caption).foregroundStyle(.secondary)
                        Button{controller.move(item.id,by:-1)}label:{Image(systemName:"arrow.up")}.buttonStyle(.borderless)
                        Button{controller.move(item.id,by:1)}label:{Image(systemName:"arrow.down")}.buttonStyle(.borderless)
                    }.draggable(item.id).dropDestination(for:String.self){ids,_ in
                        guard let source=ids.first,let from=controller.preferences.items.firstIndex(where:{$0.id==source}),let to=controller.preferences.items.firstIndex(where:{$0.id==item.id}) else{return false}
                        controller.move(source,by:to-from);return true
                    }
                }
            }.frame(minHeight:260)
            HStack {TextField("排除目录的绝对路径",text:$excluded).textFieldStyle(.roundedBorder);Button("添加目录排除"){controller.addExcludedPath(excluded);if controller.error == nil {excluded=""}}}
            ForEach(controller.preferences.excludedPaths,id:\.self){path in HStack{Text("📁 "+path).font(.caption).lineLimit(1);Spacer();Button("移除"){controller.update{$0.excludedPaths.removeAll{$0==path}}}}}
            HStack {
                TextField("排除应用的 Bundle ID (如 com.apple.finder)",text:$excludedApp).textFieldStyle(.roundedBorder)
                Button("添加应用排除"){controller.addExcludedApplication(excludedApp);if controller.error == nil {excludedApp=""}}
                Button("选择应用…"){chooseApp()}
            }
            ForEach(controller.preferences.excludedApps,id:\.self){app in HStack{Text("🚫 "+app).font(.caption).lineLimit(1);Spacer();Button("移除"){controller.update{$0.excludedApps.removeAll{$0==app}}}}}
            if let error=controller.error {Text(L10n.text(error)).foregroundStyle(.red).font(.caption)}
            Text("访达工具栏按钮由系统的“自定工具栏”管理；此开关控制按钮内的菜单。").font(.caption).foregroundStyle(.secondary)
        }.padding().disabled(controller.data.failure != nil)
    }
    @State private var excludedApp = ""
    private func chooseApp() {
        let p=NSOpenPanel();p.allowedContentTypes=[.application];p.message=L10n.text("选择要排除右键菜单的应用程序")
        if p.runModal() == .OK,let url=p.url,let bundle=Bundle(url:url),let id=bundle.bundleIdentifier {
            controller.addExcludedApplication(id)
        }
    }
    private func flag(_ key:WritableKeyPath<FinderMenuPreferences,Bool>)->Binding<Bool>{Binding(get:{controller.preferences[keyPath:key]},set:{value in controller.update{$0[keyPath:key]=value}})}
}
