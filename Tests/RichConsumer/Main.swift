import Foundation
import AppKit
import CryptoKit
import Darwin

@main enum RichConsumerFixture {
    static let fileBytes=Data("Public synthetic file attachment; exact bytes.\n".utf8)
    static let binaryBytes=Data([0,1,2,255,128,10])
    static let hiddenBytes=Data("Public synthetic hidden child.\n".utf8)
    static let expectedText="Styled\nImage\u{fffc}\nFile\u{fffc}\nFolder\u{fffc}"
    static func hash(_ bytes:Data)->String {SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()}
    static func fail(_ message:String)throws->Never {throw NSError(domain:"RichConsumerFixture",code:1,userInfo:[NSLocalizedDescriptionKey:message])}
    static func privateAlias(_ path:String)->String {path=="/tmp" || path.hasPrefix("/tmp/") ? "/private"+path:path}
    static func emit(_ value:[String:Any]) {
        let bytes=(try? JSONSerialization.data(withJSONObject:value,options:[.sortedKeys])) ?? Data("{\"ok\":false}".utf8)
        FileHandle.standardOutput.write(bytes+Data("\n".utf8))
    }
    static func root()throws->URL {
        let executable=URL(fileURLWithPath:privateAlias(URL(fileURLWithPath:CommandLine.arguments[0]).standardizedFileURL.path))
        var root=executable
        for _ in 0..<5 {root=root.deletingLastPathComponent()}
        var info=stat()
        guard executable.path==root.appendingPathComponent("Helper.noindex/RichConsumer.app/Contents/MacOS/rich-consumer").path,
              privateAlias(root.deletingLastPathComponent().path)=="/private/tmp",root.lastPathComponent.hasPrefix("gaocaozuo-acceptance-"),root.pathExtension=="noindex",
              lstat(root.path,&info)==0,info.st_mode&S_IFMT==S_IFDIR,info.st_uid==getuid(),info.st_mode&0o777==0o700,
              privateAlias(root.resolvingSymlinksInPath().path)==privateAlias(root.path) else {try fail("Fixture root is not the expected private owned directory")}
        return root
    }
    @MainActor static func prepare(_ root:URL)throws->[String:Any] {
        let fm=FileManager.default,data=root.appendingPathComponent("data",isDirectory:true),inputs=root.appendingPathComponent("Inputs",isDirectory:true),outputs=root.appendingPathComponent("Outputs",isDirectory:true)
        for url in [data,inputs,outputs] {try fm.createDirectory(at:url,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])}
        let styled=NSAttributedString(string:"Styled",attributes:[.font:NSFont.boldSystemFont(ofSize:19),.foregroundColor:NSColor.red])
        let rtf=try styled.data(from:NSRange(location:0,length:styled.length),documentAttributes:[.documentType:NSAttributedString.DocumentType.rtf])
        guard let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:2,pixelsHigh:2,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0) else {try fail("Unable to build public PNG")}
        for y in 0..<2 {for x in 0..<2 {bitmap.setColor(.blue,atX:x,y:y)}}
        guard let png=bitmap.representation(using:.png,properties:[:]) else {try fail("Unable to encode public PNG")}
        try rtf.write(to:inputs.appendingPathComponent("Styled.rtf"),options:.withoutOverwriting)
        try png.write(to:inputs.appendingPathComponent("Public-2x2.png"),options:.withoutOverwriting)
        let file=inputs.appendingPathComponent("Public attachment [a] $ ;.txt"),folder=inputs.appendingPathComponent("Public Folder",isDirectory:true)
        try fileBytes.write(to:file,options:.withoutOverwriting)
        try fm.createDirectory(at:folder.appendingPathComponent("nested",isDirectory:true),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try fm.createDirectory(at:folder.appendingPathComponent("empty",isDirectory:true),withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        try binaryBytes.write(to:folder.appendingPathComponent("nested/Public binary.dat"),options:.withoutOverwriting)
        try hiddenBytes.write(to:folder.appendingPathComponent(".hidden"),options:.withoutOverwriting)
        let stack=PasteStack();try stack.configurePersistence(dataDirectory:data)
        try stack.pushContent(text:"Styled",rtf:rtf)
        try stack.pushContent(text:"Image",png:png)
        // These references contain only our new public fixture paths, without
        // requesting a security-scoped bookmark or consulting any pasteboard.
        try stack.pushSnippet(AdvancedSnippet(name:"File",text:"File",format:.fileReference,fileReferences:[SnippetFileReference(path:file.path,bookmark:nil)]))
        try stack.pushSnippet(AdvancedSnippet(name:"Folder",text:"Folder",format:.fileReference,fileReferences:[SnippetFileReference(path:folder.path,bookmark:nil)]))
        let reopened=PasteStack();try reopened.configurePersistence(dataDirectory:data)
        guard reopened.entries.count==4,reopened.entries.map(\.text)==["Styled","Image","File","Folder"] else {try fail("Persistent fixture stack failed to reopen in order")}
        let manifest:[String:Any]=["schema":1,"root":root.path,"data":data.path,"binary":CommandLine.arguments[0],"inputs":[inputs.appendingPathComponent("Styled.rtf").path,inputs.appendingPathComponent("Public-2x2.png").path,file.path,folder.path],"output":outputs.appendingPathComponent("Consumed.rtfd").path,"entries":4,"separator":"\\n","expectedText":expectedText,"pngSHA256":hash(png),"fileSHA256":hash(fileBytes),"binarySHA256":hash(binaryBytes),"hiddenSHA256":hash(hiddenBytes),"systemGeneralPasteboardAccessed":false,"guiOpened":false]
        try JSONSerialization.data(withJSONObject:manifest,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("fixture.json"),options:.withoutOverwriting)
        return manifest.merging(["ok":true,"phase":"prepared","consumerVerified":false]){_,new in new}
    }
    @MainActor static func verify(_ root:URL,path:String)throws->[String:Any] {
        let url=URL(fileURLWithPath:privateAlias(URL(fileURLWithPath:path).standardizedFileURL.path))
        guard path.hasPrefix("/"),url.path.hasPrefix(root.path+"/"),url.pathExtension.lowercased()=="rtfd",privateAlias(url.resolvingSymlinksInPath().path)==url.path else {try fail("Only an RTFD package inside this fixture root may be verified")}
        var info=stat()
        guard lstat(url.path,&info)==0,info.st_mode&S_IFMT==S_IFDIR,info.st_uid==getuid() else {try fail("Consumer output is not an owned RTFD package")}
        // Capture only bounded regular files/directories through the production
        // no-follow FD walker. The RTF reader receives an in-memory wrapper.
        let captured=try SnippetDirectoryAttachment.capture(url,maximumBytes:64*1_024*1_024,maximumEntries:1000)
        guard let text=NSAttributedString(rtfdFileWrapper:captured.wrapper,documentAttributes:nil) else {try fail("TextEdit RTFD output could not be decoded")}
        guard text.string==expectedText || text.string==expectedText+"\n" else {try fail("Consumer text or attachment order differs from the four-item fixture")}
        for index in 0..<6 {
            guard let font=text.attribute(.font,at:index,effectiveRange:nil) as? NSFont,
                  NSFontManager.shared.traits(of:font).contains(.boldFontMask),abs(font.pointSize-19)<0.1,
                  let color=(text.attribute(.foregroundColor,at:index,effectiveRange:nil) as? NSColor)?.usingColorSpace(.deviceRGB),
                  abs(color.redComponent-1)<0.02,abs(color.greenComponent)<0.02,abs(color.blueComponent)<0.02,abs(color.alphaComponent-1)<0.02 else {try fail("Styled text did not retain 19-point bold red formatting")}
        }
        var attachments:[FileWrapper]=[],positions:[Int]=[]
        text.enumerateAttribute(.attachment,in:NSRange(location:0,length:text.length)){value,range,_ in
            if let attachment=value as? NSTextAttachment,let wrapper=attachment.fileWrapper {attachments.append(wrapper);positions.append(range.location)}
        }
        guard attachments.count==3,positions==[12,18,26],attachments[0].isRegularFile,attachments[1].isRegularFile,attachments[2].isDirectory else {try fail("Consumer attachment type or order changed")}
        let png=try Data(contentsOf:root.appendingPathComponent("Inputs/Public-2x2.png"))
        guard attachments[0].regularFileContents==png,let image=NSBitmapImageRep(data:png),image.pixelsWide==2,image.pixelsHigh==2 else {try fail("Consumer PNG bytes or dimensions changed")}
        guard attachments[1].regularFileContents==fileBytes else {try fail("Consumer ordinary file bytes changed")}
        guard let children=attachments[2].fileWrappers,Set(children.keys)==Set(["nested","empty",".hidden"]),
              children["nested"]?.isDirectory==true,Set(children["nested"]?.fileWrappers?.keys.map{$0} ?? [])==Set(["Public binary.dat"]),
              children["nested"]?.fileWrappers?["Public binary.dat"]?.regularFileContents==binaryBytes,
              children["empty"]?.isDirectory==true,children["empty"]?.fileWrappers?.isEmpty==true,
              children[".hidden"]?.isRegularFile==true,children[".hidden"]?.regularFileContents==hiddenBytes else {try fail("Consumer folder structure, empty directory, hidden child or binary bytes changed")}
        return ["ok":true,"phase":"verified","output":url.path,"styled19PointBoldRed":true,"attachmentOrder":["PNG","file","folder"],"pngExactBytes":true,"fileExactBytes":true,"folderBinaryExactBytes":true,"emptyDirectoryPreserved":true,"hiddenChildExactBytes":true,"trailingConsumerNewline":text.string.hasSuffix("\n"),"systemGeneralPasteboardAccessed":false,"guiOpened":false]
    }
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        do {
            let root=try root(),args=CommandLine.arguments
            let result:[String:Any]
            if args.count==2,args[1]=="prepare" {result=try prepare(root)}
            else if args.count==3,args[1]=="verify" {result=try verify(root,path:args[2])}
            else {try fail("Use prepare or verify <consumer-output.rtfd>")}
            emit(result)
        }catch {emit(["ok":false,"error":error.localizedDescription,"systemGeneralPasteboardAccessed":false,"guiOpened":false]);exit(1)}
    }
}
