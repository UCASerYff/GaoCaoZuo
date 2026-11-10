import AppKit
import SwiftUI
import CoreImage

enum ScreenshotAnnotationTool: String, CaseIterable, Codable { case arrow="箭头", line="直线", rectangle="矩形", ellipse="椭圆", pen="画笔", text="文字", number="编号", highlight="高亮", crop="裁剪", mosaic="马赛克", blur="模糊", redact="实心遮盖" }
struct ScreenshotAnnotationLayer: Codable, Identifiable, Equatable {
    var id = UUID(); var tool: ScreenshotAnnotationTool; var points: [CGPoint]; var text = ""
    var red: Double = 1; var green: Double = 0.2; var blue: Double = 0.15; var width: Double = 4
    var rect: CGRect { guard let p = points.first, let q = points.last else { return .zero }; return CGRect(x:min(p.x,q.x),y:min(p.y,q.y),width:abs(p.x-q.x),height:abs(p.y-q.y)) }
}
struct ScreenshotAnnotationState: Codable, Equatable { var layers: [ScreenshotAnnotationLayer] = []; var quarterTurns = 0 }
@MainActor final class ScreenshotAnnotationDocument: ObservableObject {
    let original: CGImage; let originalSHA256: String
    @Published var state = ScreenshotAnnotationState(); private var undoStack: [ScreenshotAnnotationState] = []; private var redoStack: [ScreenshotAnnotationState] = []
    init(image: CGImage) { original = image; originalSHA256 = (try? ScreenshotPngData(image)).map(ScreenshotFileSafety.digest) ?? "" }
    var canUndo: Bool { !undoStack.isEmpty }; var canRedo: Bool { !redoStack.isEmpty }
    func add(_ layer: ScreenshotAnnotationLayer) { mutate { $0.layers.append(layer) } }
    func rotate() { mutate { $0.quarterTurns = ($0.quarterTurns+1)%4 } }
    private func mutate(_ edit: (inout ScreenshotAnnotationState)->Void) { undoStack.append(state); if undoStack.count > 100 { undoStack.removeFirst() }; redoStack=[]; edit(&state) }
    func undo() { guard let old = undoStack.popLast() else { return }; redoStack.append(state); state=old }
    func redo() { guard let next = redoStack.popLast() else { return }; undoStack.append(state); state=next }
    func flatten() throws -> CGImage { try ScreenshotAnnotationRenderer.render(original:original,state:state) }
    func saveEditable(to url: URL) throws {
        guard !FileManager.default.fileExists(atPath:url.path) else { throw ScreenshotAppIssue.message("编辑文档已存在，请使用新文件名。") }
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        struct Metadata: Codable { var schemaVersion=1; var originalSHA256: String; var state: ScreenshotAnnotationState }
        do {
            let data=try ScreenshotPngData(original); try data.write(to:url.appendingPathComponent("original.png"),options:.withoutOverwriting)
            try JSONEncoder().encode(Metadata(originalSHA256:originalSHA256,state:state)).write(to:url.appendingPathComponent("document.json"),options:.atomic)
        } catch { try? FileManager.default.removeItem(at:url); throw error }
    }
    static func loadEditable(_ url: URL) throws -> ScreenshotAnnotationDocument {
        struct Metadata: Codable { var schemaVersion:Int; var originalSHA256:String; var state:ScreenshotAnnotationState }
        let metadata=try JSONDecoder().decode(Metadata.self,from:ScreenshotGaoPrivateIO.read(ScreenshotGaoPrivateIO.regularURL(url.appendingPathComponent("document.json")),maximum:16_777_216))
        guard metadata.schemaVersion==1, metadata.state.layers.count<=10000 else { throw ScreenshotAppIssue.message("标注格式过新或图层过多，原件未修改。") }
        let image=try ScreenshotReadImage(url.appendingPathComponent("original.png")); let doc=ScreenshotAnnotationDocument(image:image)
        guard doc.originalSHA256==metadata.originalSHA256 else { throw ScreenshotAppIssue.message("标注原件摘要不符。") }
        doc.state=metadata.state; return doc
    }
    func export(to url: URL, jpeg: Bool = false, quality: Double = 0.9) throws {
        let image=try flatten(); let rep=NSBitmapImageRep(cgImage:image)
        guard let bytes=rep.representation(using:jpeg ? .jpeg:.png,properties:jpeg ? [.compressionFactor:max(0,min(1,quality))]:[:]) else { throw ScreenshotAppIssue.message("图像导出失败。") }
        guard !FileManager.default.fileExists(atPath:url.path) else { throw ScreenshotAppIssue.message("目标已存在，请另选文件名。") }
        try bytes.write(to:url,options:.withoutOverwriting)
        let checked=try ScreenshotReadImage(url); guard checked.width==image.width, checked.height==image.height else { throw ScreenshotAppIssue.message("导出回读尺寸校验失败。") }
    }
}
enum ScreenshotAnnotationRenderer {
    static func render(original: CGImage, state: ScreenshotAnnotationState) throws -> CGImage {
        guard Int64(original.width)*Int64(original.height)<=100_000_000 else { throw ScreenshotAppIssue.message("标注图像超过像素预算。") }
        let cs=CGColorSpace(name:CGColorSpace.sRGB)!
        guard let ctx=CGContext(data:nil,width:original.width,height:original.height,bitsPerComponent:8,bytesPerRow:0,space:cs,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ScreenshotAppIssue.message("内存不足，无法栅格导出。") }
        ctx.draw(original,in:CGRect(x:0,y:0,width:original.width,height:original.height))
        // Layer coordinates use image pixels, top-left origin.
        ctx.translateBy(x:0,y:CGFloat(original.height)); ctx.scaleBy(x:1,y:-1)
        var cropRect: CGRect?
        for l in state.layers {
            guard l.points.allSatisfy({$0.x.isFinite && $0.y.isFinite}), l.width.isFinite, l.width>0 else { throw ScreenshotAppIssue.message("图层坐标或样式无效。") }
            let r=l.rect; let color=CGColor(srgbRed:l.red,green:l.green,blue:l.blue,alpha:l.tool == .highlight ? 0.3:1)
            ctx.saveGState(); ctx.setStrokeColor(color); ctx.setFillColor(color); ctx.setLineWidth(CGFloat(l.width)); ctx.setLineCap(.round); ctx.setLineJoin(.round)
            switch l.tool {
            case .crop: if r.width>1 && r.height>1 { cropRect=r }
            case .rectangle: ctx.stroke(r)
            case .ellipse: ctx.strokeEllipse(in:r)
            case .highlight,.redact: ctx.fill(r)
            case .mosaic,.blur:
                if let current=ctx.makeImage(), r.width>0, r.height>0 {
                    // CI bottom-left coordinate conversion. Blur is cosmetic; redaction is the irreversible option.
                    let ci=CIImage(cgImage:current); let ciRect=CGRect(x:r.minX,y:CGFloat(original.height)-r.maxY,width:r.width,height:r.height)
                    let filter=l.tool == .mosaic ? "CIPixellate":"CIGaussianBlur"
                    let filtered=ci.applyingFilter(filter,parameters:l.tool == .mosaic ? [kCIInputScaleKey:max(10,l.width*3)]:[kCIInputRadiusKey:max(6,l.width*2)])
                    if let block=CIContext().createCGImage(filtered,from:ciRect) { ctx.translateBy(x:r.minX,y:r.maxY); ctx.scaleBy(x:1,y:-1); ctx.draw(block,in:CGRect(origin:.zero,size:r.size)) }
                }
            case .text,.number:
                let text=l.tool == .number ? (l.text.isEmpty ? "1":l.text):l.text
                let font=NSFont.systemFont(ofSize:CGFloat(max(12,l.width*5)),weight:.semibold)
                let attr=NSAttributedString(string:text,attributes:[.font:font,.foregroundColor:NSColor(cgColor:color) ?? .red])
                NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current=NSGraphicsContext(cgContext:ctx,flipped:true)
                attr.draw(at:l.points.first ?? .zero); NSGraphicsContext.restoreGraphicsState()
            case .line,.arrow,.pen:
                if let first=l.points.first { ctx.move(to:first); for p in l.points.dropFirst(){ctx.addLine(to:p)}; ctx.strokePath() }
                if l.tool == .arrow, l.points.count>=2, let p=l.points.first, let q=l.points.last { let a=atan2(q.y-p.y,q.x-p.x), n=CGFloat(max(12,l.width*4)); ctx.move(to:CGPoint(x:q.x-n*cos(a-0.45),y:q.y-n*sin(a-0.45))); ctx.addLine(to:q); ctx.addLine(to:CGPoint(x:q.x-n*cos(a+0.45),y:q.y-n*sin(a+0.45))); ctx.strokePath() }
            }
            ctx.restoreGState()
        }
        guard var image=ctx.makeImage() else { throw ScreenshotAppIssue.message("标注渲染失败。") }
        if let r=cropRect { let bounded=r.intersection(CGRect(x:0,y:0,width:image.width,height:image.height)).integral; guard let cropped=image.cropping(to:bounded) else { throw ScreenshotAppIssue.message("裁剪区域无效。") }; image=cropped }
        let turns=((state.quarterTurns%4)+4)%4
        if turns != 0 {
            let w=turns%2==0 ? image.width:image.height, h=turns%2==0 ? image.height:image.width
            guard let rotated=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:0,space:cs,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ScreenshotAppIssue.message("旋转内存不足。") }
            rotated.translateBy(x:CGFloat(w)/2,y:CGFloat(h)/2); rotated.rotate(by: -CGFloat(turns) * .pi / 2)
            rotated.draw(image,in:CGRect(x: -CGFloat(image.width)/2,y: -CGFloat(image.height)/2,width:CGFloat(image.width),height:CGFloat(image.height))); guard let result=rotated.makeImage() else { throw ScreenshotAppIssue.message("旋转失败。") }; image=result
        }
        return image
    }
}
struct ScreenshotAnnotationCanvas: NSViewRepresentable {
    @ObservedObject var document: ScreenshotAnnotationDocument; var tool:ScreenshotAnnotationTool; var text:String; var color:NSColor; var width:Double
    func makeNSView(context:Context)->ScreenshotAnnotationNSView { let v=ScreenshotAnnotationNSView(); v.document=document; return v }
    func updateNSView(_ v:ScreenshotAnnotationNSView,context:Context){v.document=document;v.renderedImage=try? document.flatten();v.tool=tool;v.label=text;v.color=color;v.lineWidth=width;v.needsDisplay=true}
}
final class ScreenshotAnnotationNSView:NSView {
    weak var document:ScreenshotAnnotationDocument?;var renderedImage:CGImage?; var tool=ScreenshotAnnotationTool.arrow; var label=""; var color=NSColor.systemRed;var lineWidth=4.0;var points:[CGPoint]=[]
    override var isFlipped:Bool{true}
    var imageRect:CGRect { guard let image=renderedImage else{return .zero};let s=min(bounds.width/CGFloat(image.width),bounds.height/CGFloat(image.height));return CGRect(x:(bounds.width-CGFloat(image.width)*s)/2,y:(bounds.height-CGFloat(image.height)*s)/2,width:CGFloat(image.width)*s,height:CGFloat(image.height)*s) }
    var cropBounds:CGRect{guard let d=document else{return .zero};let full=CGRect(x:0,y:0,width:d.original.width,height:d.original.height);return d.state.layers.last(where:{$0.tool == .crop && $0.rect.width>1 && $0.rect.height>1}).map{$0.rect.intersection(full).integral} ?? full}
    override func draw(_ dirtyRect:NSRect){super.draw(dirtyRect);NSColor.windowBackgroundColor.setFill();bounds.fill();guard let image=renderedImage else{return}; NSImage(cgImage:image,size:.zero).draw(in:imageRect,from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil);if points.count>1{NSColor.systemBlue.setStroke();let path=NSBezierPath();path.move(to:viewPoint(points[0]));for p in points.dropFirst(){path.line(to:viewPoint(p))};path.lineWidth=2;path.stroke()}}
    func point(_ e:NSEvent)->CGPoint{let p=convert(e.locationInWindow,from:nil),r=imageRect;guard let d=document,let image=renderedImage,r.width>0 else{return .zero};let x=max(0,min(CGFloat(image.width),(p.x-r.minX)*CGFloat(image.width)/r.width)),y=max(0,min(CGFloat(image.height),(p.y-r.minY)*CGFloat(image.height)/r.height));let c=cropBounds;let q:CGPoint;switch d.state.quarterTurns%4{case 1:q=CGPoint(x:y,y:c.height-x);case 2:q=CGPoint(x:c.width-x,y:c.height-y);case 3:q=CGPoint(x:c.width-y,y:x);default:q=CGPoint(x:x,y:y)};return CGPoint(x:q.x+c.minX,y:q.y+c.minY)}
    func viewPoint(_ p:CGPoint)->CGPoint{guard let d=document,let image=renderedImage else{return .zero};let r=imageRect,c=cropBounds,x=p.x-c.minX,y=p.y-c.minY;let q:CGPoint;switch d.state.quarterTurns%4{case 1:q=CGPoint(x:c.height-y,y:x);case 2:q=CGPoint(x:c.width-x,y:c.height-y);case 3:q=CGPoint(x:y,y:c.width-x);default:q=CGPoint(x:x,y:y)};return CGPoint(x:r.minX+q.x*r.width/CGFloat(image.width),y:r.minY+q.y*r.height/CGFloat(image.height))}
    override func mouseDown(with e:NSEvent){points=[point(e)];needsDisplay=true}
    override func mouseDragged(with e:NSEvent){if tool == .pen{points.append(point(e))}else{points=Array(points.prefix(1))+[point(e)]};needsDisplay=true}
    override func mouseUp(with e:NSEvent){guard let d=document,!points.isEmpty else{return};if tool != .pen {points=Array(points.prefix(1))+[point(e)]};let rgb=color.usingColorSpace(.sRGB) ?? .red;d.add(ScreenshotAnnotationLayer(tool:tool,points:points,text:label,red:rgb.redComponent,green:rgb.greenComponent,blue:rgb.blueComponent,width:lineWidth));points=[];needsDisplay=true}
}
