import Foundation
import Darwin

/// Only the trusted Quick Look broker constructs this scope. Archive engines
/// receive the staged job tree and bundled runtime, never the broker's file
/// access. Read-only commands cannot write; rebuilds can write only the job tree.
struct ArchiveExecutionScope {
    private struct Directory {
        let url:URL,device:dev_t,inode:ino_t
        let privateWorkspace:Bool
        init(_ url:URL,privateWorkspace:Bool)throws {
            let fd=open(url.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
            guard fd>=0 else {throw Failure(message:"无法打开受保护的归档工作目录。")}
            defer {close(fd)}
            var info=stat()
            guard fstat(fd,&info)==0,info.st_mode&S_IFMT==S_IFDIR,
                  !privateWorkspace || (info.st_uid==getuid() && info.st_mode&0o077==0),
                  let path=realpath(url.path,nil) else {throw Failure(message:"归档工作目录的身份或权限不安全，未启动引擎。")}
            defer {free(path)}
            self.url=URL(fileURLWithPath:String(cString:path),isDirectory:true);device=info.st_dev;inode=info.st_ino;self.privateWorkspace=privateWorkspace
        }
        func verify()throws {
            var info=stat()
            guard lstat(url.path,&info)==0,info.st_mode&S_IFMT==S_IFDIR,info.st_dev==device,info.st_ino==inode,
                  !privateWorkspace || (info.st_uid==getuid() && info.st_mode&0o077==0) else {throw Failure(message:"归档工作目录发生变化，已停止引擎。")}
        }
    }
    struct Failure:LocalizedError {let message:String;var errorDescription:String? {L10n.text(message)}}
    private let workspace:Directory,runtime:Directory,readOnlyFiles:[String]
    var workspaceURL:URL {workspace.url}
    init(workspace:URL,runtime:URL,readOnlyFiles:[URL]=[])throws {
        self.workspace=try Directory(workspace,privateWorkspace:true)
        self.runtime=try Directory(runtime,privateWorkspace:false)
        guard readOnlyFiles.count<=16 else {throw Failure(message:"归档引擎的读取授权超过预算。")}
        self.readOnlyFiles=try readOnlyFiles.map {url in
            var info=stat()
            guard url.isFileURL,lstat(url.path,&info)==0,info.st_mode&S_IFMT==S_IFREG,info.st_nlink==1,
                  let path=realpath(url.path,nil) else {throw Failure(message:"归档引擎只能读取已核验的普通文件。")}
            defer {free(path)};return String(cString:path)
        }
    }
    func profile(writing:Bool)throws->String {
        try workspace.verify();try runtime.verify()
        func quoted(_ value:String)throws->String {
            guard !value.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) else {throw Failure(message:"归档工作路径包含不支持的控制字符。")}
            let encoder=JSONEncoder();encoder.outputFormatting=[.withoutEscapingSlashes]
            return String(data:try encoder.encode(value),encoding:.utf8)!
        }
        // libignition opens the literal root directory to bootstrap dyld using
        // openat. This does not allow reading descendants such as user files.
        let system=["/System","/usr/lib","/usr/share","/private/var/db/timezone"]
        let directories=try (system+[runtime.url.path,workspace.url.path]).map{"(subpath "+(try quoted($0))+")"}
        let files=try (["/","/dev/null","/dev/random","/dev/urandom"]+readOnlyFiles).map{"(literal "+(try quoted($0))+")"}
        var value="(version 1)(allow default)(deny network*)(deny file-write*)(deny file-read-data)(allow file-read-data "+(directories+files).joined(separator:" ")+")"
        if writing {value += "(allow file-write* (subpath "+(try quoted(workspace.url.path))+"))"}
        return value
    }
    var environment:[String:String] {
        // Do not copy unrelated parent environment credentials into a decoder.
        ["PATH":"/usr/bin:/bin","LC_ALL":"en_US.UTF-8","LANG":"en_US.UTF-8","HOME":workspace.url.path,"TMPDIR":workspace.url.path+"/"]
    }
}
