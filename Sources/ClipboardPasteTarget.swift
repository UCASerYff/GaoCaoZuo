import AppKit
import ApplicationServices
import Carbon

/// Captured before this application's panels take focus. No field contents are read.
struct ClipboardPasteTarget {
    let pid: pid_t
    let identity: String
    let element: AXUIElement
    let window: AXUIElement?
    let range: CFRange?
    let document: String?
    let role: String
    let editableText: Bool
    let capturedAt: Date

    @MainActor static func capture() -> Self? {
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
              let app=NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let identity=WindowProcessIdentity.auditTokenString(for:app.processIdentifier) else {return nil}
        let application=AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application,0.15)
        guard let element=asElement(attribute(application,kAXFocusedUIElementAttribute)),
              let window=asElement(attribute(application,kAXFocusedWindowAttribute)) else {return nil}
        AXUIElementSetMessagingTimeout(element,0.15);AXUIElementSetMessagingTimeout(window,0.15)
        guard !isSecure(element), let role=attribute(element,kAXRoleAttribute) as? String else {return nil}
        let editable=isEditableText(element,role:role)
        let documentEvidence=readDocument(window)
        let rangeEvidence=readSelectedRange(element)
        guard documentEvidence.known,rangeEvidence.known,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              WindowProcessIdentity.auditTokenString(for:app.processIdentifier) == identity else {return nil}
        let candidate=Self(pid:app.processIdentifier,identity:identity,element:element,
                    window:window,range:rangeEvidence.value,document:documentEvidence.value,
                    role:role,editableText:editable,capturedAt:Date())
        return candidate.isValid(requireFrontmost:true) ? candidate : nil
    }
    @MainActor func isValid(requireFrontmost: Bool, checkRange: Bool = true, requireEditableText: Bool = false) -> Bool {
        let age=Date().timeIntervalSince(capturedAt)
        guard age >= 0, age <= 60,AXIsProcessTrusted(),!IsSecureEventInputEnabled(),
              WindowProcessIdentity.auditTokenString(for:pid) == identity,
              let app=NSRunningApplication(processIdentifier:pid), !app.isTerminated,
              !requireFrontmost || NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {return false}
        let application=AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application,0.15)
        guard let current=Self.asElement(Self.attribute(application,kAXFocusedUIElementAttribute)),
              CFEqual(current,element),!Self.isSecure(current) else {return false}
        guard let window,let currentWindow=Self.asElement(Self.attribute(application,kAXFocusedWindowAttribute)),
              CFEqual(currentWindow,window) else {return false}
        let documentEvidence=Self.readDocument(currentWindow)
        guard documentEvidence.known,ClipboardPasteTargetPolicy.documentsMatch(document,documentEvidence.value) else {return false}
        let currentRole=Self.attribute(current,kAXRoleAttribute) as? String
        guard currentRole == role else {return false}
        if requireEditableText,
           !ClipboardPasteTargetPolicy.permitsEnter(capturedRole:role,currentRole:currentRole,
               capturedEditable:editableText,currentEditable:Self.isEditableText(current,role:currentRole)) {return false}
        if checkRange {
            let evidence=Self.readSelectedRange(current)
            guard evidence.known else {return false}
            switch (range,evidence.value) {
            case (nil,nil): break
            case let (old?,new?): guard old.location == new.location,old.length == new.length else {return false}
            default: return false
            }
        }
        // AX calls can block briefly. Recheck process and foreground after the
        // complete element/window/document evidence, immediately before return.
        return !IsSecureEventInputEnabled()
            && WindowProcessIdentity.auditTokenString(for:pid) == identity
            && (!requireFrontmost || NSWorkspace.shared.frontmostApplication?.processIdentifier == pid)
    }
    private static func attribute(_ element:AXUIElement,_ name:String)->CFTypeRef? {
        AXUIElementSetMessagingTimeout(element,0.15)
        var value:CFTypeRef?
        guard AXUIElementCopyAttributeValue(element,name as CFString,&value) == .success else {return nil}
        return value
    }
    private static func asElement(_ value:CFTypeRef?)->AXUIElement? {
        guard let value,CFGetTypeID(value) == AXUIElementGetTypeID() else {return nil}
        return (value as! AXUIElement)
    }
    private static func isSecure(_ element:AXUIElement)->Bool {
        let role=attribute(element,kAXRoleAttribute) as? String
        let subrole=attribute(element,kAXSubroleAttribute) as? String
        return role == nil || role == "AXSecureTextField" || subrole == "AXSecureTextField"
    }
    private static func readDocument(_ element:AXUIElement)->(known:Bool,value:String?) {
        var value:CFTypeRef?
        AXUIElementSetMessagingTimeout(element,0.15)
        switch AXUIElementCopyAttributeValue(element,kAXDocumentAttribute as CFString,&value) {
        case .attributeUnsupported,.noValue: return (true,nil)
        case .success:
            if value == nil {return (true,nil)}
            guard let document=value as? String else {return (false,nil)}
            return (true,document)
        default: return (false,nil)
        }
    }
    private static func readSelectedRange(_ element:AXUIElement)->(known:Bool,value:CFRange?) {
        var value:CFTypeRef?
        AXUIElementSetMessagingTimeout(element,0.15)
        switch AXUIElementCopyAttributeValue(element,kAXSelectedTextRangeAttribute as CFString,&value) {
        case .attributeUnsupported,.noValue: return (true,nil)
        case .success:
            guard let value,CFGetTypeID(value) == AXValueGetTypeID() else {return (false,nil)}
            var range=CFRange()
            guard AXValueGetValue(value as! AXValue,.cfRange,&range),range.location >= 0,range.length >= 0 else {return (false,nil)}
            return (true,range)
        default:return (false,nil)
        }
    }
    private static func isEditableText(_ element:AXUIElement,role:String?)->Bool {
        guard let role,["AXTextField","AXTextArea","AXComboBox"].contains(role),!isSecure(element) else {return false}
        for key in [kAXValueAttribute,kAXSelectedTextAttribute] {
            var settable:DarwinBoolean=false
            if AXUIElementIsAttributeSettable(element,key as CFString,&settable) == .success,settable.boolValue {return true}
        }
        return false
    }
}
