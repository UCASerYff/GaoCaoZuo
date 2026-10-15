import AppKit

/// All representations are retained, including RTF, file URLs and images.
/// The caller must check changeCount immediately before restoration.
struct ClipboardPasteboardSnapshot {
    let representations:[[(type:String,data:Data)]]
    let changeCount:Int
    @MainActor static func capture(_ board:NSPasteboard) throws -> Self {
        let initialCount=board.changeCount
        let items=board.pasteboardItems ?? []
        guard items.count <= 256 else {throw DataFailure.message("原剪贴板项目过多，未执行临时替换；可先复制后手动粘贴。")}
        var total=0
        var representations:[[(type:String,data:Data)]]=[]
        for item in items {
            guard item.types.count <= 64 else {throw DataFailure.message("原剪贴板格式过多，已停止临时替换。")}
            var row:[(type:String,data:Data)]=[]
            for type in item.types {
                guard let bytes=item.data(forType:type),bytes.count <= 64_000_000-total else {throw DataFailure.message("无法完整保留原剪贴板，或超过64MB预算；未执行自动粘贴。")}
                total += bytes.count;row.append((type.rawValue,bytes))
            }
            representations.append(row)
        }
        guard board.changeCount == initialCount else {throw DataFailure.message("读取期间剪贴板已改变，未执行自动粘贴。")}
        return try captureRepresentations(representations.map { $0.map { (type:$0.type,data:Optional($0.data)) } },changeCount:initialCount,currentCount:board.changeCount)
    }
    static func captureRepresentations(_ values:[[(type:String,data:Data?)]],changeCount:Int,currentCount:Int,maximumBytes:Int=64_000_000) throws -> Self {
        guard changeCount == currentCount,values.count <= 256 else {throw DataFailure.message("读取期间剪贴板已变化或项目过多。")}
        var total=0
        var result:[[(type:String,data:Data)]]=[]
        for row in values {
            guard row.count <= 64,Set(row.map(\.type)).count == row.count else {throw DataFailure.message("剪贴板类型过多或重复。")}
            var retained:[(type:String,data:Data)]=[]
            for value in row {
                guard let bytes=value.data,bytes.count <= maximumBytes-total else {throw DataFailure.message("无法完整保留原剪贴板，未执行临时替换。")}
                total += bytes.count;retained.append((value.type,bytes))
            }
            result.append(retained)
        }
        return Self(representations:result,changeCount:changeCount)
    }
    @discardableResult func restore(ifUnchanged expected:Int,currentCount:()->Int,write:([[(type:String,data:Data)]])->Bool) throws -> Bool {
        guard currentCount() == expected else {return false}
        guard write(representations) else {throw DataFailure.message("原剪贴板的完整格式恢复失败。")}
        return true
    }
    @discardableResult @MainActor func restore(_ board:NSPasteboard,ifUnchanged expected:Int,onCleared:((Int)->Void)?=nil) throws -> Bool {
        var objects:[NSPasteboardItem]=[]
        for row in representations {
            let item=NSPasteboardItem()
            for value in row {
                guard item.setData(value.data,forType:NSPasteboard.PasteboardType(value.type)) else {
                    throw DataFailure.message("无法准备原剪贴板的完整格式，当前剪贴板未改动。")
                }
            }
            objects.append(item)
        }
        // Building representations can take time; compare immediately before
        // replacing. NSPasteboard has no public cross-process compare-and-swap.
        guard board.changeCount == expected else {return false}
        let cleared=board.clearContents()
        onCleared?(cleared)
        guard board.changeCount == cleared else {return false}
        guard objects.isEmpty || board.writeObjects(objects) else {
            throw DataFailure.message("原剪贴板的完整格式恢复失败；原内容仍仅保留在本次确认内存中。")
        }
        return true
    }
}
