import AppKit
import Foundation

// Match the Gao family canvas/tile, with a 512 px mark for the denser 操作 strokes.
// 2026-10-08 visual review: preserve the original lettering and reduce its scale to 85%.
// Generated lettering alpha is preserved; the background is a single vector fill.
let args = CommandLine.arguments
guard args.count == 3, let data = try? Data(contentsOf: URL(fileURLWithPath: args[1])),
      let source = NSBitmapImageRep(data: data),
      let cg = source.cgImage else { fatalError("ComposeIcon.swift Lettering.png AppIcon.png") }
var minX = source.pixelsWide, minY = source.pixelsHigh, maxX = 0, maxY = 0
for y in 0..<source.pixelsHigh {
    for x in 0..<source.pixelsWide where (source.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
        minX = min(minX,x); minY = min(minY,y); maxX = max(maxX,x); maxY = max(maxY,y)
    }
}
guard maxX > minX, maxY > minY,
      let cropped = cg.cropping(to: CGRect(x:minX,y:minY,width:maxX-minX+1,height:maxY-minY+1)) else { fatalError("Empty lettering") }
let lettering = NSImage(cgImage:cropped,size:NSSize(width:cropped.width,height:cropped.height))
let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:1024,pixelsHigh:1024,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:4096,bitsPerPixel:32)!
bitmap.size = NSSize(width:1024,height:1024)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
NSColor(srgbRed:119.0/255,green:119.0/255,blue:119.0/255,alpha:1).setFill()
NSBezierPath(roundedRect:NSRect(x:82,y:82,width:860,height:860),xRadius:189,yRadius:189).fill()
NSGraphicsContext.current?.imageInterpolation = .high
let height = CGFloat(512)
let width = CGFloat(cropped.width) / CGFloat(cropped.height) * height
lettering.draw(in:NSRect(x:(1024-width)/2,y:(1024-height)/2,width:width,height:height),from:.zero,operation:.sourceOver,fraction:1)
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:args[2]),options:.atomic)
