import AppKit

enum InputOpenTargets {
    /// Validate the whole list before handing any target to Launch Services.
    /// This parses only stored selectors; it never reads file or document contents.
    static func urls(_ values:[String])throws->[URL] {
        guard !values.isEmpty,values.count<=32 else {throw SystemControlError.message("打开目标必须为1–32个明确路径或网址。")}
        return try values.map {value in
            guard !value.isEmpty,value.utf8.count<=8192,!value.contains("\0"),!value.contains("\n"),!value.contains("\r") else {
                throw SystemControlError.message("打开目标包含无效字符或超过预算。")
            }
            if value.hasPrefix("/") {return URL(fileURLWithPath:value)}
            guard let u=URL(string:value),let scheme=u.scheme?.lowercased(),["http","https","file"].contains(scheme),u.user==nil,u.password==nil else {
                throw SystemControlError.message("只支持明确文件路径和HTTP(S)网址；未知协议未执行。")
            }
            if u.isFileURL {guard u.host==nil || u.host=="" || u.host=="localhost",u.path.hasPrefix("/") else {throw SystemControlError.message("文件目标不是本机绝对路径。")}}
            else {guard let host=u.host,!host.isEmpty else {throw SystemControlError.message("网址缺少主机。")}}
            return u
        }
    }
    @MainActor static func perform(_ values:[String],exists:(URL)->Bool={FileManager.default.fileExists(atPath:$0.path)},
                                  open:(URL)->Bool={NSWorkspace.shared.open($0)})throws {
        let destinations=try urls(values)
        guard destinations.filter(\.isFileURL).allSatisfy(exists) else {throw SystemControlError.message("某个原打开目标不存在或无法访问，未递交任何打开请求。")}
        for destination in destinations {guard open(destination) else {throw SystemControlError.message("系统拒绝打开目标；已递交项目可能已被目标应用接收。")}}
    }
}
