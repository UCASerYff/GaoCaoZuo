import Foundation

enum InputActionDelivery {
    static func perform(_ actionID:String,mode:InputWindowTargetMode,legacy:((String)->Void)?,
                        invocation:((String,InputWindowTargetMode)->Void)?)throws {
        if let invocation {invocation(actionID,mode);return}
        guard mode == .inheritSettings else {throw SystemControlError.message("此输入规则的窗口目标方式尚未连接，未回退到其他窗口。")}
        guard let legacy else {throw SystemControlError.message("输入动作尚未连接，未执行。")}
        legacy(actionID)
    }
}
