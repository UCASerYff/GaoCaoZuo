import Foundation
import AppKit

@MainActor func runRightMouseMigrationTests() throws {
    let fm=FileManager.default, root=URL(fileURLWithPath:"/private/tmp/GaoRightMigration-"+UUID().uuidString,isDirectory:true)
    try fm.createDirectory(at:root,withIntermediateDirectories:false);defer{try? fm.removeItem(at:root)}
    var checks=0
    func expect(_ value:@autoclosure () throws -> Bool,_ description:String) throws {checks += 1;guard try value() else {throw DataFailure.message(description)}}
    func rejects(_ description:String,_ body:() throws -> Void) throws {do{try body()}catch{checks += 1;return};throw DataFailure.message(description)}
    let project=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
    let resources=root.appendingPathComponent("DocumentTemplates")
    try fm.copyItem(at:project.appendingPathComponent("Resources/DocumentTemplates"),to:resources)
    let value=try Data(contentsOf:resources.appendingPathComponent("Blank.rtf"))
    let suffixes=["rtf","txt","md",""]+FileEnhancements.documentFormats.filter{$0 != "rtf"}+["wps","et","dps","ai"]
    let templates:[[String:Any]]=suffixes.enumerated().map {index,suffix in
        ["name":index == 0 ? "User's original title" : "User title \(index)","suffix":suffix,"enable":index != 0,"mainMenu":index == 0,"icon":"metadata-only"]
    }
    let iconDigest=String(repeating:"a",count:64)
    let config:[String:Any]=[
        "newFileList":templates,
        "fileIconList":[["name":"Stock icon title","enable":false,"iconSHA256":iconDigest,"iconByteCount":123,"assetRetainedInBackup":true]],
        "toolboxList":[["name":"My terminal title","enable":true,"type":2,"bundleId":"com.apple.Terminal","appName":"Terminal","selectOptionIndex":1],
                       ["name":"Future action title","enable":true,"type":99,"future":["unknown":"preserve"]]]]
    let plan=try RightMouseMigration.prepare(config:config,resources:resources,existing:.init(),sourceVersion:"test-only",resolveApplication:{_ in nil})
    try expect(plan.report.templateCount == 12 && plan.settings.templates.count == 16 && plan.attachments.count == 11,"configuration maps only to nine original formats plus empty text, markdown and folder")
    try expect(!plan.settings.templates[0].isEnabled && plan.settings.templates[0].mainMenu == true && plan.menuEntries[0].name == "User's original title","original disabled state, main-menu choice and user title survive")
    try expect(plan.report.resourceBundleID == "com.gaoseries.GaoCaoZuo" && plan.report.resources.first?.relativePath == "Blank.rtf" && plan.report.resources.first?.sha256 == RightMouseMigration.sha(value),"resource evidence names this app's original bytes")
    try expect(plan.report.unavailableTemplates == ["wps","et","dps","ai"] && plan.settings.templates.suffix(4).allSatisfy{!$0.isEnabled && $0.entries.isEmpty && $0.unavailableReason != nil},"WPS and AI remain unavailable, without counterfeit or competitor content")
    try expect(plan.report.iconCount == 0 && plan.report.iconReferences.first?.sha256 == iconDigest && plan.attachments.values.allSatisfy{$0.count != 123},"stock icon backup references never become reusable private attachments")
    try expect(plan.settings.apps.count == 1 && !plan.settings.apps[0].isEnabled && plan.report.unavailableApps == ["com.apple.Terminal"],"missing application is retained and unknown Terminal option remains paused")
    try expect(plan.menuEntries.last?.mappedActionID == nil && plan.report.unmappedKeys.contains("right/toolbox/1/future"),"future action fields are reported and left in source backup, never silently mapped")
    try expect(!fm.fileExists(atPath:root.appendingPathComponent("FileEnhancements").path),"prepare is read-only")
    let controller=FileEnhancementController(directory:root.appendingPathComponent("private-data"))
    try controller.installMigrationAttachments(plan);try controller.update{$0=plan.settings}
    let output=root.appendingPathComponent("output");try fm.createDirectory(at:output,withIntermediateDirectories:false)
    try rejects("disabled mapped template cannot execute through its UUID") {_ = try controller.createTemplate(plan.settings.templates[0].id,directory:output)}
    try rejects("unavailable WPS cannot execute even if its source switch was enabled") {_ = try controller.createTemplate(plan.settings.templates.last!.id,directory:output)}
    try controller.update{$0.templates[0].enabled=true}
    let receipt=try controller.createTemplate(controller.settings.templates[0],in:output)
    try expect(try Data(contentsOf:receipt.destination) == value,"new output matches this app's original template, not competitor bytes")
    let reopened=FileEnhancementController(directory:root.appendingPathComponent("private-data"))
    try expect(reopened.healthy && reopened.settings.templates.count == 16 && reopened.settings.templates.last?.unavailableReason != nil,"restart retains verified original attachments and unavailable configuration")
    let repeated=try RightMouseMigration.prepare(config:config,resources:resources,existing:plan.settings,sourceVersion:"test-only",resolveApplication:{_ in nil})
    try expect(repeated.attachments.isEmpty && repeated.settings.templates[0].id == plan.settings.templates[0].id,"same source mapping is idempotent and keeps stable menu IDs")
    try Data("changed".utf8).write(to:resources.appendingPathComponent("Blank.rtf"))
    try rejects("changed original resource cannot reuse old provenance") {_ = try RightMouseMigration.prepare(config:config,resources:resources,existing:plan.settings,resolveApplication:{_ in nil})}
    try fm.removeItem(at:resources.appendingPathComponent("Blank.rtf"))
    try rejects("missing original resource cannot turn into an empty document") {_ = try RightMouseMigration.prepare(config:config,resources:resources,existing:.init(),resolveApplication:{_ in nil})}
    let elsewhere=root.appendingPathComponent("elsewhere.rtf");try value.write(to:elsewhere)
    try fm.createSymbolicLink(at:resources.appendingPathComponent("Blank.rtf"),withDestinationURL:elsewhere)
    try rejects("symlink resource cannot escape this app's original resources") {_ = try RightMouseMigration.prepare(config:config,resources:resources,existing:.init(),resolveApplication:{_ in nil})}
    var rawIcons=config;rawIcons["newFileList"]=[];rawIcons["fileIconList"]=[["name":"stock","enable":true,"icon":Data("must stay in backup".utf8)]]
    try rejects("raw competitor icon bytes are refused") {_ = try RightMouseMigration.prepare(config:rawIcons,resources:resources,existing:.init(),resolveApplication:{_ in nil})}
    var future=config;future["newFileList"]=[["name":"Custom","suffix":"unknown","enable":true,"mainMenu":false,"path":"/not-read/private-document"]]
    let unknown=try RightMouseMigration.prepare(config:future,resources:resources,existing:.init(),resolveApplication:{_ in nil})
    try expect(unknown.settings.templates.isEmpty && unknown.menuEntries.first?.unknownReason != nil,"unknown custom template paths are never read or replaced by built-ins")
    let editor=root.appendingPathComponent("FixtureEditor.app"),contents=editor.appendingPathComponent("Contents")
    try fm.createDirectory(at:contents,withIntermediateDirectories:true)
    let editorID="com.gaoseries.fixture.Editor"
    try PropertyListSerialization.data(fromPropertyList:["CFBundleIdentifier":editorID,"CFBundleDisplayName":"Verified fixture label","CFBundlePackageType":"APPL"],format:.xml,options:0).write(to:contents.appendingPathComponent("Info.plist"))
    var emptyNames=config;emptyNames["newFileList"]=[]
    emptyNames["toolboxList"]=[
        ["name":"","appName":"Original product label","bundleId":editorID,"enable":true,"type":2],
        ["name":"","appName":"","bundleId":editorID,"enable":true,"type":2],
        ["name":"","appName":"Label is not identity","bundleId":"","enable":true,"type":2],
        ["name":"","appName":"","bundleId":"com.gaoseries.fixture.Missing","enable":true,"type":2]]
    let labeled=try RightMouseMigration.prepare(config:emptyNames,resources:resources,existing:.init(),resolveApplication:{$0 == editorID ? editor : nil})
    try expect(labeled.settings.apps.count == 2 && labeled.settings.apps[0].name == "Original product label" && labeled.settings.apps[1].name == "Verified fixture label","empty source name uses appName or a verified bundle label, never an invented empty display")
    let labeledTools=labeled.menuEntries.filter{$0.kind == "toolbox"}
    try expect(labeledTools[0].name.isEmpty && labeledTools[0].displayName == "Original product label" && labeledTools[1].name.isEmpty,"raw empty names remain in the source report separately from display labels")
    try expect(labeledTools[2].mappedActionID == nil && labeledTools[2].unknownReason != nil && labeledTools[3].mappedActionID == nil && labeledTools[3].unknownReason != nil,"missing identity or label is retained as unresolved, never guessed from the product name")
    try expect(labeled.attachments.isEmpty,"application label migration neither launches apps nor writes attachments")
    let forbidden=root.appendingPathComponent("iRightMouse Pro.app/DocumentTemplates")
    try fm.createDirectory(at:forbidden,withIntermediateDirectories:true)
    try rejects("competitor resource roots are refused before reading templates") {_ = try RightMouseMigration.prepare(config:future,resources:forbidden,existing:.init(),resolveApplication:{_ in nil})}
    print("PASS: \(checks) right-mouse configuration mapping tests; original-resource fixtures auto-cleaned; WPS/AI unavailable")
}
