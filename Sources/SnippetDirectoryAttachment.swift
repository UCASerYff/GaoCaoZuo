import Foundation
import Darwin

/// Capture a selected folder as one real RTFD attachment. Every child is opened
/// relative to an anchored directory, never through a symbolic link or FIFO.
enum SnippetDirectoryAttachment {
    struct Result {let wrapper:FileWrapper;let byteCount:Int}
    private struct Identity:Equatable {
        let device:Int32,inode:UInt64,size:Int64,mode:UInt16,links:UInt16
        let modified:Int64,modifiedNS:Int64,changed:Int64,changedNS:Int64
        init(_ s:stat) {device=s.st_dev;inode=s.st_ino;size=s.st_size;mode=s.st_mode;links=s.st_nlink;modified=Int64(s.st_mtimespec.tv_sec);modifiedNS=Int64(s.st_mtimespec.tv_nsec);changed=Int64(s.st_ctimespec.tv_sec);changedNS=Int64(s.st_ctimespec.tv_nsec)}
    }
    static func capture(_ url:URL,maximumBytes:Int,maximumEntries:Int=1000)throws->Result {
        let root=open(url.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK)
        guard root>=0 else {throw DataFailure.message("无法读取所选附件文件夹，堆栈已保留。")}
        defer {close(root)}
        var bytes=0,entries=0,identities:[String:Identity]=[:]
        func checked(_ fd:Int32)throws->stat {var s=stat();guard fstat(fd,&s)==0 else {throw DataFailure.message("附件读取期间已变化，未导入。")};return s}
        func names(_ fd:Int32)throws->[String] {
            let scan=openat(fd,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
            guard scan>=0,let directory=fdopendir(scan) else {if scan>=0{close(scan)};throw DataFailure.message("无法读取所选附件文件夹，堆栈已保留。")}
            defer {closedir(directory)}
            var values:[String]=[];errno=0
            while let entry=readdir(directory) {
                let name=withUnsafePointer(to:&entry.pointee.d_name) {pointer in pointer.withMemoryRebound(to:CChar.self,capacity:Int(MAXNAMLEN)+1){String(validatingUTF8:$0)}}
                guard let name else {throw DataFailure.message("附件文件夹包含不支持的文件名，堆栈已保留。")}
                if name != ".",name != ".." {
                    guard values.count<maximumEntries else {throw DataFailure.message("附件文件夹超过项目预算，堆栈已保留。")}
                    values.append(name)
                }
                errno=0
            }
            guard errno==0,values.count<=maximumEntries else {throw DataFailure.message("附件文件夹超过项目预算，堆栈已保留。")}
            return values.sorted()
        }
        func walk(_ fd:Int32,path:String,depth:Int,verify:Bool)throws->FileWrapper? {
            guard depth<=32 else {throw DataFailure.message("附件文件夹层级过深，堆栈已保留。")}
            let before=try checked(fd),identity=Identity(before)
            if verify {guard identities[path]==identity else {throw DataFailure.message("附件读取期间已变化，未导入。")}}
            else {identities[path]=identity}
            if before.st_mode&S_IFMT==S_IFREG {
                guard before.st_nlink==1,before.st_size>=0,before.st_size<=SnippetLibraryStore.maximumAttachmentBytes else {throw DataFailure.message("附件不是普通文件或超过读取预算。")}
                if verify {return nil}
                guard before.st_size<=maximumBytes-bytes else {throw DataFailure.message("合并附件超过64MB，堆栈已保留。")}
                var data=Data(),buffer=[UInt8](repeating:0,count:65536)
                while true {
                    let count=Darwin.read(fd,&buffer,buffer.count)
                    if count<0,errno==EINTR {continue}
                    guard count>=0,count<=Int(before.st_size)-data.count else {throw DataFailure.message("附件读取期间已变化，未导入。")}
                    if count==0 {break};data.append(contentsOf:buffer.prefix(count))
                }
                guard data.count==before.st_size,Identity(try checked(fd))==identity else {throw DataFailure.message("附件读取期间已变化，未导入。")}
                bytes += data.count
                return FileWrapper(regularFileWithContents:data)
            }
            guard before.st_mode&S_IFMT==S_IFDIR else {throw DataFailure.message("附件文件夹包含链接或特殊文件，堆栈已保留。")}
            let children=try names(fd)
            var wrappers:[String:FileWrapper]=[:]
            for name in children {
                if !verify {entries += 1;guard entries<=maximumEntries else {throw DataFailure.message("附件文件夹超过项目预算，堆栈已保留。")}}
                let child=openat(fd,name,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK)
                guard child>=0 else {throw DataFailure.message("附件文件夹包含链接或不可读项目，堆栈已保留。")}
                defer {close(child)}
                let key=path.isEmpty ? name:path+"/"+name
                if let wrapper=try walk(child,path:key,depth:depth+1,verify:verify) {wrapper.preferredFilename=name;wrappers[name]=wrapper}
                var named=stat()
                guard fstatat(fd,name,&named,AT_SYMLINK_NOFOLLOW)==0,Identity(named)==Identity(try checked(child)) else {throw DataFailure.message("附件读取期间已变化，未导入。")}
            }
            guard Identity(try checked(fd))==identity,try names(fd)==children else {throw DataFailure.message("附件读取期间已变化，未导入。")}
            if verify {return nil}
            return FileWrapper(directoryWithFileWrappers:wrappers)
        }
        guard let wrapper=try walk(root,path:"",depth:0,verify:false) else {throw DataFailure.message("无法读取所选附件文件夹，堆栈已保留。")}
        _ = try walk(root,path:"",depth:0,verify:true)
        var named=stat()
        guard lstat(url.path,&named)==0,Identity(named)==identities[""] else {throw DataFailure.message("附件读取期间已变化，未导入。")}
        wrapper.preferredFilename=url.lastPathComponent
        return Result(wrapper:wrapper,byteCount:bytes)
    }
}
