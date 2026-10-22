import AppKit
import ImageIO
import UniformTypeIdentifiers

enum FileEnhancementImages {
    static let builtinSymbols = ["folder", "doc.text", "star", "heart", "book", "photo", "music.note", "calendar", "archivebox", "terminal", "globe"]
    static func builtinIcon(_ name: String) throws -> NSImage {
        guard builtinSymbols.contains(name), let symbol=NSImage(systemSymbolName:name,accessibilityDescription:nil) else { throw FileToolsError.invalid("内置图标不可用。") }
        return NSImage(size:NSSize(width:128,height:128),flipped:false) { rect in
            NSColor.systemBlue.setFill();NSBezierPath(roundedRect:rect.insetBy(dx:5,dy:5),xRadius:24,yRadius:24).fill()
            let white=symbol.withSymbolConfiguration(.init(paletteColors:[.white])) ?? symbol
            white.draw(in:rect.insetBy(dx:28,dy:28));return true
        }
    }
    static func source(_ url:URL) throws -> CGImage {
        _ = try EnhancedFileTools.checked(url)
        guard let source=CGImageSourceCreateWithURL(url as CFURL,nil),CGImageSourceGetCount(source)==1,
              let info=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let w=info[kCGImagePropertyPixelWidth] as? Int,let h=info[kCGImagePropertyPixelHeight] as? Int,
              w>0,h>0,Double(w)*Double(h)<=100_000_000 else {throw FileToolsError.invalid("请选择不超过一亿像素的单张图片。")}
        guard let image=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:max(w,h)] as CFDictionary) else {throw FileToolsError.invalid("图片无法解码。")}
        return image
    }
    static func png(_ image:CGImage,size:Int,opaque:Bool=false) throws -> Data {
        guard let context=CGContext(data:nil,width:size,height:size,bitsPerComponent:8,bytesPerRow:size*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:(opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue) else {throw FileToolsError.invalid("图像内存不足。")}
        context.interpolationQuality = .high
        if opaque {context.setFillColor(CGColor(gray:1,alpha:1));context.fill(CGRect(x:0,y:0,width:size,height:size))}
        let ratio=min(Double(size)/Double(image.width),Double(size)/Double(image.height))
        let w=Double(image.width)*ratio,h=Double(image.height)*ratio
        context.draw(image,in:CGRect(x:(Double(size)-w)/2,y:(Double(size)-h)/2,width:w,height:h))
        guard let output=context.makeImage() else {throw FileToolsError.invalid("图像渲染失败。")}
        return try encode(output,type:UTType.png.identifier)
    }
    static func encode(_ image:CGImage,type:String) throws -> Data {
        let bytes=NSMutableData()
        guard let dest=CGImageDestinationCreateWithData(bytes,type as CFString,1,nil) else {throw FileToolsError.invalid(L10n.format("系统没有 %@ 编码器。", String(describing: (type))))}
        CGImageDestinationAddImage(dest,image,[kCGImageDestinationLossyCompressionQuality:0.9] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {throw FileToolsError.invalid("图片编码失败。")};return bytes as Data
    }
    static var webPAvailable:Bool { (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains("org.webmproject.webp") || Bundle.main.url(forResource:"cwebp",withExtension:nil,subdirectory:"Tools") != nil }
    static func webP(_ source:URL,to output:URL,engineOverride:URL?=nil) throws {
        let image=try self.source(source)
        if (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains("org.webmproject.webp") {
            try encode(image,type:"org.webmproject.webp").write(to:output,options:.withoutOverwriting);return
        }
        guard let engine=engineOverride ?? Bundle.main.url(forResource:"cwebp",withExtension:nil,subdirectory:"Tools") else {throw FileToolsError.invalid("此版本尚未包含 WebP 编码器，未生成文件。")}
        let temp=output.deletingLastPathComponent().appendingPathComponent(".gaocaozuo-webp-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);defer{try? FileManager.default.removeItem(at:temp)}
        let input=temp.appendingPathComponent("input.png"),result=temp.appendingPathComponent("output.webp")
        try encode(image,type:UTType.png.identifier).write(to:input,options:.withoutOverwriting)
        let process=Process();process.executableURL=engine;process.arguments=["-quiet","-q","90",input.path,"-o",result.path]
        process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
        try process.run()
        let deadline=Date().addingTimeInterval(120)
        while process.isRunning && Date()<deadline {Thread.sleep(forTimeInterval:0.02)}
        if process.isRunning {process.terminate();throw FileToolsError.invalid("WebP 编码超时。")}
        guard process.terminationStatus==0,let decode=CGImageSourceCreateWithURL(result as CFURL,nil),CGImageSourceGetCount(decode)==1 else {throw FileToolsError.invalid("WebP 编码结果无法验证。")}
        guard renamex_np(result.path,output.path,UInt32(RENAME_EXCL))==0 else {throw FileToolsError.conflict(output)}
    }
    static func create(_ urls:[URL],kind:String) throws -> [FileOperationReceipt] {
        guard ["webp","icns","macicons","iosicons"].contains(kind),!urls.isEmpty else { throw FileToolsError.invalid("请选择图片及有效输出格式。") }
        var receipts:[FileOperationReceipt]=[]
        do {
            for source in urls {
                let image=try self.source(source),directory=source.deletingLastPathComponent(),stem=source.deletingPathExtension().lastPathComponent
                let suffix=kind == "icns" ? ".icns" : kind == "webp" ? ".webp" : kind == "macicons" ? ".iconset" : ".xcassets"
                let output=try QuickFileActions.uniqueURL(in:directory,preferredName:stem+suffix,isDirectory:kind.hasSuffix("icons"))
                if kind=="webp" {try webP(source,to:output)}
                else if kind=="icns" {
                    var body=Data()
                    for (tag,size) in [("icp4",16),("icp5",32),("icp6",64),("ic07",128),("ic08",256),("ic09",512),("ic10",1024)] {
                        let bytes=try png(image,size:size);body.append(Data(tag.utf8));var length=UInt32(bytes.count+8).bigEndian;withUnsafeBytes(of:&length){body.append(contentsOf:$0)};body.append(bytes)
                    }
                    var result=Data("icns".utf8),length=UInt32(body.count+8).bigEndian;withUnsafeBytes(of:&length){result.append(contentsOf:$0)};result.append(body)
                    try result.write(to:output,options:.withoutOverwriting)
                } else {
                    let stage=directory.appendingPathComponent(".gaocaozuo-icons-"+UUID().uuidString,isDirectory:true)
                    try FileManager.default.createDirectory(at:stage,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);defer{try? FileManager.default.removeItem(at:stage)}
                    if kind=="macicons" {
                        for size in [16,32,128,256,512] {for scale in [1,2] {try png(image,size:size*scale).write(to:stage.appendingPathComponent("icon_\(size)x\(size)\(scale==2 ? "@2x" : "").png"),options:.withoutOverwriting)}}
                    } else {
                        let appIcons=stage.appendingPathComponent("AppIcon.appiconset",isDirectory:true)
                        let watchIcons=stage.appendingPathComponent("WatchAppIcon.appiconset",isDirectory:true)
                        try FileManager.default.createDirectory(at:appIcons,withIntermediateDirectories:false)
                        try FileManager.default.createDirectory(at:watchIcons,withIntermediateDirectories:false)
                        var items:[[String:String]]=[]
                        let specs:[(String,String,[Int])]=[("iphone","20",[2,3]),("iphone","29",[1,2,3]),("iphone","40",[2,3]),("iphone","57",[1,2]),("iphone","60",[2,3]),("ipad","20",[1,2]),("ipad","29",[1,2]),("ipad","40",[1,2]),("ipad","50",[1,2]),("ipad","72",[1,2]),("ipad","76",[1,2]),("ipad","83.5",[2]),("ios-marketing","1024",[1])]
                        for (idiom,size,scales) in specs {for scale in scales {
                            let name="\(idiom)-\(size)-\(scale)x.png";try png(image,size:Int((Double(size) ?? 1)*Double(scale)),opaque:true).write(to:appIcons.appendingPathComponent(name),options:.withoutOverwriting)
                            items.append(["idiom":idiom,"size":"\(size)x\(size)","scale":"\(scale)x","filename":name])
                        }}
                        let info:[String:Any]=["version":1,"author":"com.gaoseries.GaoCaoZuo"]
                        try JSONSerialization.data(withJSONObject:["images":items,"info":info],options:[.prettyPrinted,.sortedKeys]).write(to:appIcons.appendingPathComponent("Contents.json"),options:.withoutOverwriting)
                        // Apple documents the classic watchOS role/subtype slots. Keep the Watch set
                        // separate so Xcode can assign the appropriate app icon to each target.
                        var watchItems:[[String:String]]=[]
                        let watchSpecs:[(String,String,String,Int)]=[("notificationCenter","38mm","24",2),("notificationCenter","42mm","27.5",2),("companionSettings","","29",2),("companionSettings","","29",3),("appLauncher","38mm","40",2),("longLook","42mm","44",2),("quickLook","38mm","86",2),("quickLook","42mm","98",2)]
                        for (role,subtype,size,scale) in watchSpecs {
                            let name="watch-\(role)-\(subtype)-\(scale)x.png"
                            try png(image,size:Int((Double(size) ?? 1)*Double(scale)),opaque:true).write(to:watchIcons.appendingPathComponent(name),options:.withoutOverwriting)
                            var slot=["idiom":"watch","role":role,"size":"\(size)x\(size)","scale":"\(scale)x","filename":name]
                            if !subtype.isEmpty {slot["subtype"]=subtype};watchItems.append(slot)
                        }
                        let marketingName="watch-marketing-1024.png"
                        try png(image,size:1024,opaque:true).write(to:watchIcons.appendingPathComponent(marketingName),options:.withoutOverwriting)
                        watchItems.append(["idiom":"watch-marketing","size":"1024x1024","scale":"1x","filename":marketingName])
                        try JSONSerialization.data(withJSONObject:["images":watchItems,"info":info],options:[.prettyPrinted,.sortedKeys]).write(to:watchIcons.appendingPathComponent("Contents.json"),options:.withoutOverwriting)
                        try JSONSerialization.data(withJSONObject:["info":info],options:[.prettyPrinted,.sortedKeys]).write(to:stage.appendingPathComponent("Contents.json"),options:.withoutOverwriting)
                    }
                    guard renamex_np(stage.path,output.path,UInt32(RENAME_EXCL))==0 else {throw FileToolsError.conflict(output)}
                }
                receipts.append(.init(kind:.convert,destination:output,fingerprint:try FileTools.fingerprint(output)))
            }
            return receipts
        } catch {try FileTools.undo(receipts,trashCreated:false);throw error}
    }
}
