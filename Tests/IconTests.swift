import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count == 2, let data = try? Data(contentsOf:URL(fileURLWithPath:args[1])),
      let image = NSBitmapImageRep(data:data) else { fatalError("IconTests.swift AppIcon.png") }
precondition(image.pixelsWide == 1024 && image.pixelsHigh == 1024)
func rgba(_ x: Int, _ y: Int) -> NSColor { image.colorAt(x:x,y:y)! }
for (x,y) in [(0,0),(1023,0),(0,1023),(1023,1023),(81,512),(942,512)] {
    precondition(rgba(x,y).alphaComponent == 0,"Outer margin is not transparent")
}
// Side strips avoid the lettermark and round corners; every pixel must be #777777.
for x in [100,120,200,800,900,923] {
    for y in 330..<690 {
        let c=rgba(x,y)
        precondition(abs(c.redComponent-119.0/255)<0.002 && abs(c.greenComponent-119.0/255)<0.002 && abs(c.blueComponent-119.0/255)<0.002 && c.alphaComponent==1,"Background must be a single uniform #777777 fill")
    }
}
var edgeLow=1024, edgeHigh=0, whiteLeft=1024, whiteRight=0, whiteLow=1024, whiteHigh=0, whiteCount=0
for y in 82..<942 { for x in 82..<942 {
    let c=rgba(x,y)
    if c.alphaComponent > 0.9 && c.redComponent > 0.6 && c.greenComponent > 0.6 && c.blueComponent > 0.6 {
        edgeLow=min(edgeLow,y); edgeHigh=max(edgeHigh,y)
    }
    if c.alphaComponent > 0.9 && c.redComponent > 0.9 && c.greenComponent > 0.9 && c.blueComponent > 0.9 {
        whiteLeft=min(whiteLeft,x); whiteRight=max(whiteRight,x)
        whiteLow=min(whiteLow,y); whiteHigh=max(whiteHigh,y); whiteCount+=1
    }
} }
// The dense 操作 strokes are scaled to 85% of the original 602px composition.
// Pure-white area is close to 搞文件's 49,460 pixels without changing stroke weight.
precondition((508...514).contains(edgeHigh-edgeLow+1),"Lettermark including antialiasing should be about 512px high")
precondition((502...508).contains(whiteHigh-whiteLow+1) && (289...297).contains(whiteRight-whiteLeft+1),"Pure-white lettermark should remain approximately 293×505px")
precondition((47_000...50_000).contains(whiteCount),"White stroke density must match the reviewed family size")
precondition(abs((whiteLeft+whiteRight)/2-512)<4 && abs((edgeLow+edgeHigh)/2-512)<4,"Lettermark must be centered")
print("Icon tests passed: 1024 canvas, transparent margin, uniform #777777 tile, 512px composition, pure-white bbox \(whiteRight-whiteLeft+1)×\(whiteHigh-whiteLow+1), area \(whiteCount)px.")
