import Foundation

/// Receives Quartz/AX global coordinates (top-down), after AppKit screen conversion.
enum InputScreenEdgeGeometry {
    static func matches(_ name:String,point:CGPoint,frames:[CGRect],start:Double=0,end:Double=1,width:Double=8)->Bool {
        guard point.x.isFinite,point.y.isFinite,start.isFinite,end.isFinite,width.isFinite,
              start>=0,end<=1,end-start>=0.01,(2...80).contains(width) else{return false}
        return frames.contains {f in
            guard !f.isNull,f.width>0,f.height>0,f.minX.isFinite,f.minY.isFinite,
                  f.width.isFinite,f.height.isFinite,f.insetBy(dx:-1,dy:-1).contains(point) else{return false}
            let left=point.x<f.minX+width,right=point.x>f.maxX-width
            let top=point.y<f.minY+width,bottom=point.y>f.maxY-width
            func inSegment(_ fraction:Double)->Bool {
                // Last segment includes the outer endpoint; all other ends are exclusive.
                fraction>=start && (fraction<end || end==1 && fraction<=1)
            }
            switch name {
            case "topLeft":return left && top
            case "topRight":return right && top
            case "bottomLeft":return left && bottom
            case "bottomRight":return right && bottom
            case "left":return left && inSegment((point.y-f.minY)/f.height)
            case "right":return right && inSegment((point.y-f.minY)/f.height)
            case "top":return top && inSegment((point.x-f.minX)/f.width)
            case "bottom":return bottom && inSegment((point.x-f.minX)/f.width)
            default:return false
            }
        }
    }
}
