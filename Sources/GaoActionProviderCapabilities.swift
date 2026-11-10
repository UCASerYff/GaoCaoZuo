import Foundation
import CoreFoundation
import Darwin

struct GaoActionProviderCapabilities: Decodable {
    struct Action: Decodable {
        var action:String
        var parametersSchema:[String:GaoActionAnyCodable]
        var supportsReferences:Bool?
        var supportsItems:Bool?
        var referencesSchema:[String:GaoActionAnyCodable]?
        var requiresUserConfirmation:Bool?
        var reviewOnly:Bool?
        private enum CodingKeys:String,CodingKey {
            case action,parametersSchema,parameters,supportsReferences,supportsItems,referencesSchema,requiresUserConfirmation,reviewOnly,items,references
        }
        init(from decoder:Decoder) throws {
            let c=try decoder.container(keyedBy:CodingKeys.self)
            action=try c.decode(String.self,forKey:.action)
            supportsReferences=try c.decodeIfPresent(Bool.self,forKey:.supportsReferences)
            supportsItems=try c.decodeIfPresent(Bool.self,forKey:.supportsItems)
            referencesSchema=try c.decodeIfPresent([String:GaoActionAnyCodable].self,forKey:.referencesSchema)
            requiresUserConfirmation=try c.decodeIfPresent(Bool.self,forKey:.requiresUserConfirmation)
            reviewOnly=try c.decodeIfPresent(Bool.self,forKey:.reviewOnly)
            guard c.contains(.parametersSchema) != c.contains(.parameters) else {
                throw GaoActionError.providerNotReady("参数能力必须使用一种明确的 schema 形状")
            }
            if c.contains(.parametersSchema) {
                guard !c.contains(.items),!c.contains(.references) else {throw GaoActionError.providerNotReady("不接受混合的能力约束形状")}
                parametersSchema=try c.decode([String:GaoActionAnyCodable].self,forKey:.parametersSchema)
            } else {
                // Portal V1 declares all six zero-payload actions with `parameters`.
                // Decode its complete table, retaining the owner/schema checks in load().
                let portalActions:Set<String> = ["portal.openSite","portal.openWorkspace","portal.focusSearch","portal.proposeSite","portal.prepareDownload","downloads.prepare"]
                guard portalActions.contains(action),supportsItems != true,supportsReferences != true,referencesSchema == nil else {
                    throw GaoActionError.providerNotReady("尚不支持此动作的 parameters 能力形状")
                }
                for key in [CodingKeys.items,.references] {
                    let limit=try c.decode([String:GaoActionAnyCodable].self,forKey:key)
                    guard Set(limit.keys)==["maxCount"],let n=limit["maxCount"]?.value as? NSNumber,
                          CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue==0 else {
                        throw GaoActionError.providerNotReady("门户能力必须明确禁止文件与引用")
                    }
                }
                parametersSchema=try c.decode([String:GaoActionAnyCodable].self,forKey:.parameters)
                supportsItems=false;supportsReferences=false
            }
        }
    }
    var schemaVersion:Int
    var bundleID:String
    var appVersion:String
    var actions:[Action]
    static func load(appURL:URL,bundleID:String) throws -> Self {
        let infoFD=try GaoActionFiles.openRegular(appURL.appendingPathComponent("Contents/Info.plist"),owned:false);defer{close(infoFD)}
        let infoData=try GaoActionFiles.read(fd:infoFD,maximum:1_048_576,owned:false)
        guard let info=try PropertyListSerialization.propertyList(from:infoData,format:nil) as? [String:Any],
              info["CFBundleIdentifier"] as? String == bundleID,
              let version=info["CFBundleShortVersionString"] as? String,!version.isEmpty else {throw GaoActionError.providerNotReady("安装应用的标识或版本无效")}
        let url=appURL.appendingPathComponent("Contents/Resources/GaoCapabilities.json")
        let fd=try GaoActionFiles.openRegular(url,owned:false);defer{close(fd)}
        let data=try GaoActionFiles.read(fd:fd,maximum:GaoActionV1.maximumManifestBytes,owned:false)
        let capabilities=try JSONDecoder().decode(Self.self,from:data)
        guard capabilities.schemaVersion==1,capabilities.bundleID==bundleID,capabilities.appVersion==version,
              capabilities.actions.count<=GaoActionV1.knownActions.count,
              Set(capabilities.actions.map(\.action)).count==capabilities.actions.count else {throw GaoActionError.providerNotReady("能力表 schema、应用标识或版本不匹配")}
        for a in capabilities.actions {
            guard GaoActionV1.knownActions.contains(a.action),GaoActionV1.owners[a.action]==nil || GaoActionV1.owners[a.action]==bundleID,
                  a.parametersSchema["type"]?.value as? String == "object",
                  a.parametersSchema["additionalProperties"]?.value as? Bool == false,
                  let props=a.parametersSchema["properties"]?.value as? [String:Any],
                  Set(props.keys).isSubset(of:GaoActionV1.parameterKeys[a.action] ?? []) else {throw GaoActionError.providerNotReady("提供方声明了不兼容动作或参数 schema")}
            try GaoActionParameterSchema.validateDefinition(a.parametersSchema.mapValues(\.value))
            if let references=a.referencesSchema {try GaoActionParameterSchema.validateDefinition(references.mapValues(\.value))}
        }
        return capabilities
    }
    func require(action:String,parameters:[String:Any],items:Bool,references:Bool) throws {
        guard let capability=actions.first(where:{$0.action==action}) else {throw GaoActionError.providerNotReady(L10n.format("目标应用尚未声明实现 %@", String(describing: (action))))}
        guard (!items || capability.supportsItems != false),(!references || capability.supportsReferences != false),
              let properties=capability.parametersSchema["properties"]?.value as? [String:Any],Set(parameters.keys).isSubset(of:Set(properties.keys)) else {throw GaoActionError.providerNotReady("提供方未声明本次附件、引用或可选参数")}
        try GaoActionParameterSchema.validate(parameters,schema:capability.parametersSchema.mapValues(\.value))
        if action == "downloads.prepare" {
            guard !items,!references,let urls=parameters["urls"] as? [String],(1...32).contains(urls.count),urls.allSatisfy(GaoActionV1.safeHTTP) else {
                throw GaoActionError.providerNotReady("下载准备只接受固定契约允许的 http/https URL，不接受文件或引用")
            }
        }
    }
    func requireInputs(action:String,parameters:[String:Any],items:Bool,references:[GaoActionReference]) throws {
        try require(action:action,parameters:parameters,items:items,references:!references.isEmpty)
        guard let capability=actions.first(where:{$0.action==action}),let schema=capability.referencesSchema else {return}
        let values=try references.map { reference -> [String:Any] in
            guard let value=try JSONSerialization.jsonObject(with:JSONEncoder().encode(reference)) as? [String:Any] else {
                throw GaoActionError.providerNotReady("无法核验提供方引用约束")
            }
            return value
        }
        try GaoActionParameterSchema.validate(values,schema:schema.mapValues(\.value))
    }
}

private enum GaoActionParameterSchema {
    private static let metadata:Set<String>=["type","const","enum","description","title","default"]
    static func validateDefinition(_ schema:[String:Any],depth:Int=0) throws {
        func invalid() -> GaoActionError {.providerNotReady("提供方能力 schema 的约束无效或不受支持")}
        guard depth<=8 else {throw invalid()}
        for key in ["description","title"] where schema[key] != nil {guard schema[key] is String else {throw invalid()}}
        guard let type=schema["type"] as? String else {
            guard schema["const"] != nil,Set(schema.keys).isSubset(of:["const","description","title"]) else {throw invalid()};return
        }
        let extra:[String:Set<String>]=[
            "object":["properties","required","additionalProperties"],"array":["items","minItems","maxItems"],
            "string":["minLength","maxLength","pattern","format"],"number":["minimum","maximum"],"integer":["minimum","maximum"],"boolean":[]]
        guard let keys=extra[type],Set(schema.keys).isSubset(of:metadata.union(keys)) else {throw invalid()}
        func bound(_ key:String,integer:Bool)->Double? {
            guard let n=schema[key] as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue.isFinite else {return nil}
            if integer {guard let count=n as? Int,count>=0,Double(count)==n.doubleValue else {return nil}}
            return n.doubleValue
        }
        for pair in [("minLength","maxLength"),("minItems","maxItems"),("minimum","maximum")] {
            let integer=pair.0 != "minimum"
            for key in [pair.0,pair.1] where schema[key] != nil {guard bound(key,integer:integer) != nil else {throw invalid()}}
            if let min=bound(pair.0,integer:integer),let max=bound(pair.1,integer:integer),min>max {throw invalid()}
        }
        if let values=schema["enum"] {guard let array=values as? [Any],!array.isEmpty,array.count<=256 else {throw invalid()}}
        if type == "object" {
            guard let props=schema["properties"] as? [String:Any],props.count<=256 else {throw invalid()}
            if let required=schema["required"] {
                guard let names=required as? [String],Set(names).count==names.count,Set(names).isSubset(of:Set(props.keys)) else {throw invalid()}
            }
            if let additional=schema["additionalProperties"] {guard let n=additional as? NSNumber,CFGetTypeID(n)==CFBooleanGetTypeID() else {throw invalid()}}
            for child in props.values {guard let child=child as? [String:Any] else {throw invalid()};try validateDefinition(child,depth:depth+1)}
        } else if type == "array" {
            if let n=schema["items"] as? NSNumber,CFGetTypeID(n)==CFBooleanGetTypeID() {}
            else {guard let child=schema["items"] as? [String:Any] else {throw invalid()};try validateDefinition(child,depth:depth+1)}
        } else if type == "string" {
            if let format=schema["format"] {guard format as? String == "uri" else {throw invalid()}}
            if let pattern=schema["pattern"] {
                guard let pattern=pattern as? String,pattern.utf8.count<=1024,(try? NSRegularExpression(pattern:pattern)) != nil else {throw invalid()}
            }
        }
    }
    static func validate(_ value:Any,schema:[String:Any],depth:Int=0) throws {
        func invalid() -> GaoActionError {.providerNotReady("本次参数不符合提供方能力 schema")}
        guard depth<=8 else {throw invalid()}
        if depth==0 {try validateDefinition(schema)}
        if let constant=schema["const"],GaoActionAnyCodable(value) != GaoActionAnyCodable(constant) {throw invalid()}
        if let values=schema["enum"] as? [Any],!values.contains(where:{GaoActionAnyCodable(value)==GaoActionAnyCodable($0)}) {throw invalid()}
        // V1 supports this explicit subset, rather than silently ignoring a
        // provider's new validation vocabulary and dispatching incompatible data.
        let supported:Set<String>=["type","const","enum","minimum","maximum","minLength","maxLength","pattern","format","minItems","maxItems","items","properties","required","additionalProperties","description","title","default"]
        guard Set(schema.keys).isSubset(of:supported) else {throw GaoActionError.providerNotReady("提供方使用了尚未支持的能力约束")}
        guard let type=schema["type"] as? String else {
            guard schema["const"] != nil,Set(schema.keys).isSubset(of:["const","description","title"]) else {throw GaoActionError.providerNotReady("提供方参数 schema 缺少类型")}
            return
        }
        switch type {
        case "string":
            guard let s=value as? String else {throw invalid()}
            if let max=schema["maxLength"] as? Int,s.count>max {throw invalid()}
            if let min=schema["minLength"] as? Int,s.count<min {throw invalid()}
            if let values=schema["enum"] as? [String],!values.contains(s) {throw invalid()}
            if let pattern=schema["pattern"] as? String {guard pattern.utf8.count<=1024,s.range(of:pattern,options:.regularExpression) != nil else {throw invalid()}}
            if schema["format"] as? String == "uri" {
                guard !s.isEmpty,!s.unicodeScalars.contains(where:{CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0)}),
                      let components=URLComponents(string:s),components.scheme?.isEmpty==false,components.url != nil else {throw invalid()}
            }
        case "number","integer":
            guard let n=value as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue.isFinite,type != "integer" || floor(n.doubleValue)==n.doubleValue else {throw invalid()}
            if let max=schema["maximum"] as? Double,n.doubleValue>max {throw invalid()}
            if let min=schema["minimum"] as? Double,n.doubleValue<min {throw invalid()}
        case "boolean":guard let n=value as? NSNumber,CFGetTypeID(n)==CFBooleanGetTypeID() else {throw invalid()}
        case "array":
            guard let a=value as? [Any] else {throw invalid()}
            if let max=schema["maxItems"] as? Int,a.count>max {throw invalid()}
            if let min=schema["minItems"] as? Int,a.count<min {throw invalid()}
            if let boolean=schema["items"] as? Bool {
                guard boolean || a.isEmpty else {throw invalid()};return
            }
            guard let item=schema["items"] as? [String:Any] else {throw invalid()}
            for value in a {try validate(value,schema:item,depth:depth+1)}
        case "object":
            guard let object=value as? [String:Any],let properties=schema["properties"] as? [String:Any] else {throw invalid()}
            if let required=schema["required"] as? [String],!Set(required).isSubset(of:Set(object.keys)) {throw invalid()}
            if schema["additionalProperties"] as? Bool == false,!Set(object.keys).isSubset(of:Set(properties.keys)) {throw invalid()}
            for (key,value) in object where properties[key] != nil {
                guard let child=properties[key] as? [String:Any] else {throw invalid()}
                try validate(value,schema:child,depth:depth+1)
            }
        default:throw GaoActionError.providerNotReady("提供方使用了不支持的参数 schema 类型")
        }
    }
}
