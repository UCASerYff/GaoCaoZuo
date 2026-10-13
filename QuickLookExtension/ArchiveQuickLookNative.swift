import Foundation
import Darwin

/// Read-only metadata through the operating system's libarchive. No child tools
/// or member extraction APIs are registered in this preview provider.
enum ArchiveQuickLookNative {
    struct Limits {
        var timeoutSeconds:Double=5
        var maxReadBytes:Int64=128*1_024*1_024
        var maxEntries:Int=10_000
        var maxListingBytes:Int=4*1_024*1_024
        var maxDeclaredBytes:Int64=512*1_024*1_024
    }
    struct Failure:LocalizedError {
        let message:String
        var errorDescription:String? {L10n.text(message)}
    }
    private final class Input {
        let handle:FileHandle,limits:Limits,deadline:Double,fileSize:Int64
        let buffer=UnsafeMutableRawPointer.allocate(byteCount:65_536,alignment:16)
        var readBytes:Int64=0
        var stopped=false
        init(handle:FileHandle,fileSize:Int64,limits:Limits) {self.handle=handle;self.fileSize=fileSize;self.limits=limits;deadline=ProcessInfo.processInfo.systemUptime+limits.timeoutSeconds}
        deinit {buffer.deallocate()}
        func allowed()->Bool {
            if stopped || ProcessInfo.processInfo.systemUptime >= deadline || readBytes >= limits.maxReadBytes {stopped=true;return false}
            return true
        }
    }
    private typealias Pointer=OpaquePointer
    private typealias ReadCallback=@convention(c) (Pointer?,UnsafeMutableRawPointer?,UnsafeMutablePointer<UnsafeRawPointer?>?)->Int
    private typealias SkipCallback=@convention(c) (Pointer?,UnsafeMutableRawPointer?,Int64)->Int64
    private typealias SeekCallback=@convention(c) (Pointer?,UnsafeMutableRawPointer?,Int64,Int32)->Int64
    private static let readCallback:ReadCallback = {_,opaque,output in
        guard let opaque,let output else {return -1}
        let input=Unmanaged<Input>.fromOpaque(opaque).takeUnretainedValue()
        guard input.allowed() else {return -1}
        let size=min(65_536,Int(input.limits.maxReadBytes-input.readBytes))
        let count=Darwin.read(input.handle.fileDescriptor,input.buffer,size)
        if count>0 {input.readBytes+=Int64(count);output.pointee=UnsafeRawPointer(input.buffer)}
        return count
    }
    private static let skipCallback:SkipCallback = {_,opaque,amount in
        guard let opaque else {return -1}
        let input=Unmanaged<Input>.fromOpaque(opaque).takeUnretainedValue()
        guard input.allowed(),amount>=0 else {return -1}
        // A skip does not decompress or read bytes. Bound it to the remaining
        // input budget nevertheless, so scans cannot jump without limit.
        guard amount<=input.limits.maxReadBytes-input.readBytes else {input.stopped=true;return -1}
        let before=lseek(input.handle.fileDescriptor,0,SEEK_CUR)
        guard before>=0,amount<=input.fileSize-before else {return -1}
        let after=lseek(input.handle.fileDescriptor,amount,SEEK_CUR)
        guard after>=before else {return -1}
        input.readBytes+=after-before
        return after-before
    }
    private static let seekCallback:SeekCallback = {_,opaque,offset,whence in
        guard let opaque else {return -1}
        let input=Unmanaged<Input>.fromOpaque(opaque).takeUnretainedValue()
        guard input.allowed() else {return -1}
        let base:Int64
        switch whence {
        case SEEK_SET:base=0
        case SEEK_CUR:base=lseek(input.handle.fileDescriptor,0,SEEK_CUR)
        case SEEK_END:base=input.fileSize
        default:return -1
        }
        let (target,overflow)=base.addingReportingOverflow(offset)
        guard !overflow,base>=0,target>=0,target<=input.fileSize else {return -1}
        return lseek(input.handle.fileDescriptor,target,SEEK_SET)
    }
    private final class Library {
        let image:UnsafeMutableRawPointer
        let create:@convention(c) ()->Pointer?
        let free:@convention(c) (Pointer?)->Int32
        let formatAll:@convention(c) (Pointer?)->Int32
        let formatRaw:@convention(c) (Pointer?)->Int32
        let format:@convention(c) (Pointer?)->Int32
        let setData:@convention(c) (Pointer?,UnsafeMutableRawPointer?)->Int32
        let setRead:@convention(c) (Pointer?,ReadCallback?)->Int32
        let setSkip:@convention(c) (Pointer?,SkipCallback?)->Int32
        let setSeek:@convention(c) (Pointer?,SeekCallback?)->Int32
        let open:@convention(c) (Pointer?)->Int32
        let next:@convention(c) (Pointer?,UnsafeMutablePointer<Pointer?>?)->Int32
        let pathname:@convention(c) (Pointer?)->UnsafePointer<CChar>?
        let size:@convention(c) (Pointer?)->Int64
        let sizeIsSet:@convention(c) (Pointer?)->Int32
        let mode:@convention(c) (Pointer?)->UInt16
        let encrypted:@convention(c) (Pointer?)->Int32
        init() throws {
            guard let image=dlopen("/usr/lib/libarchive.2.dylib",RTLD_NOW|RTLD_LOCAL) else {throw Failure(message:"系统压缩预览组件不可用，请在搞操作中打开。")}
            self.image=image
            var complete=false
            defer {if !complete {dlclose(image)}}
            func symbol<T>(_ name:String,_ type:T.Type)throws->T {
                guard let address=dlsym(image,name) else {throw Failure(message:"系统压缩预览组件不完整，请在搞操作中打开。")}
                return unsafeBitCast(address,to:type)
            }
            create=try symbol("archive_read_new",type(of:create));free=try symbol("archive_read_free",type(of:free))
            formatAll=try symbol("archive_read_support_format_all",type(of:formatAll));formatRaw=try symbol("archive_read_support_format_raw",type(of:formatRaw))
            format=try symbol("archive_format",type(of:format))
            setData=try symbol("archive_read_set_callback_data",type(of:setData));setRead=try symbol("archive_read_set_read_callback",type(of:setRead))
            setSkip=try symbol("archive_read_set_skip_callback",type(of:setSkip));setSeek=try symbol("archive_read_set_seek_callback",type(of:setSeek))
            open=try symbol("archive_read_open1",type(of:open));next=try symbol("archive_read_next_header",type(of:next))
            pathname=try symbol("archive_entry_pathname_utf8",type(of:pathname));size=try symbol("archive_entry_size",type(of:size))
            sizeIsSet=try symbol("archive_entry_size_is_set",type(of:sizeIsSet));mode=try symbol("archive_entry_mode",type(of:mode))
            encrypted=try symbol("archive_entry_is_encrypted",type(of:encrypted))
            complete=true
        }
        deinit {dlclose(image)}
        // Do not use support_filter_all: some system builds register fallback
        // command-line programs. A warning means this filter is not native.
        func filter(_ name:String,reader:Pointer)throws {
            guard let address=dlsym(image,"archive_read_support_filter_"+name) else {throw Failure(message:"此格式的系统预览暂不可用，请在搞操作中打开。")}
            let setup=unsafeBitCast(address,to:(@convention(c) (Pointer?)->Int32).self)
            guard setup(reader)==0 else {throw Failure(message:"此格式需要完整压缩引擎，请在搞操作中打开。")}
        }
    }
    static func list(url:URL,limits:Limits=Limits()) throws->String {
        let deadline=ProcessInfo.processInfo.systemUptime+max(0,limits.timeoutSeconds)
        let suffix=url.pathExtension.lowercased()
        if suffix=="ace" {throw Failure(message:"ACE 目录暂不能在系统空格预览中读取，请在搞操作中打开。")}
        let handle=try FileHandle(forReadingFrom:url)
        defer {try? handle.close()}
        var info=stat()
        guard fstat(handle.fileDescriptor,&info)==0,(info.st_mode & UInt16(S_IFMT))==UInt16(S_IFREG) else {throw Failure(message:"只能预览普通压缩文件，请在搞操作中打开。")}
        try ArchiveQuickLookPreflight.validate(handle:handle,maxMetadataBytes:min(4*1_024*1_024,max(0,limits.maxListingBytes)),maxEntries:max(0,limits.maxEntries),maxDataBytes:UInt64(max(0,min(limits.maxReadBytes,limits.maxDeclaredBytes))),timeoutSeconds:max(0,deadline-ProcessInfo.processInfo.systemUptime))
        let library=try Library()
        guard let reader=library.create() else {throw Failure(message:"无法创建压缩预览，请在搞操作中打开。")}
        defer {_=library.free(reader)}
        var remainingLimits=limits
        remainingLimits.timeoutSeconds=max(0,deadline-ProcessInfo.processInfo.systemUptime)
        let input=Input(handle:handle,fileSize:info.st_size,limits:remainingLimits)
        let context=Unmanaged.passUnretained(input).toOpaque()
        _=library.setData(reader,context);_=library.setRead(reader,readCallback);_=library.setSkip(reader,skipCallback);_=library.setSeek(reader,seekCallback)
        let streamFilters:[String:String] = ["gz":"gzip","gzip":"gzip","tgz":"gzip","bz2":"bzip2","bzip2":"bzip2","tbz":"bzip2","tbz2":"bzip2","xz":"xz","txz":"xz","lz":"lzip","lzip":"lzip","lzop":"lzop","zst":"zstd","tzst":"zstd"]
        let stream=streamFilters[suffix]
        try library.filter(stream ?? "none",reader:reader)
        guard library.formatAll(reader)==0,(stream == nil || library.formatRaw(reader)==0) else {throw Failure(message:"此格式的目录预览暂不可用，请在搞操作中打开。")}
        guard library.open(reader)>=0 else {throw Failure(message:input.stopped ? "压缩包超出预览时间或读取预算，请在搞操作中打开。" : "无法读取压缩包目录，请在搞操作中打开。")}
        var listing="",count=0,total:Int64=0,listingBytes=0
        while input.allowed() {
            var entry:Pointer?
            let code=library.next(reader,&entry)
            if code==1 {return listing}
            guard code>=0,let entry else {throw Failure(message:input.stopped ? "压缩包超出预览时间或读取预算，请在搞操作中打开。" : "压缩包目录无法完整读取，可能已加密或损坏，请在搞操作中打开。")}
            count+=1
            guard count<=limits.maxEntries else {return listing+"PreviewWarning = 目录超过预览数量上限，已截断；完整目录请在搞操作中打开。\n"}
            guard let bytes=library.pathname(entry) else {throw Failure(message:"压缩包文件名无法解码，请在搞操作中打开。")}
            guard strnlen(bytes,16_385)<=16_384 else {throw Failure(message:"压缩包文件名超出预览上限，请在搞操作中打开。")}
            var name=String(cString:bytes)
            guard !name.isEmpty,!name.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains),name.utf8.count<=16_384 else {throw Failure(message:"压缩包包含无法安全显示的文件名，请在搞操作中打开。")}
            let rawStream=library.format(reader)&0xff0000 == 0x90000
            if rawStream,name=="data" {name=url.deletingPathExtension().lastPathComponent+(["tgz","tbz","tbz2","txz","tzst"].contains(suffix) ? ".tar" : "")}
            let size=max(0,library.size(entry)),known=library.sizeIsSet(entry) != 0
            let isDirectory=(library.mode(entry) & UInt16(S_IFMT))==UInt16(S_IFDIR)
            do {
                let row="Path = \(name)\nSize = \(size)\nSizeUnknown = \(known ? "-" : "+")\nFolder = \(isDirectory ? "+" : "-")\nEncrypted = \(library.encrypted(entry)>0 ? "+" : "-")\n\n"
                guard listingBytes+row.utf8.count<=limits.maxListingBytes else {return listing+"PreviewWarning = 目录超过预览大小上限，已截断；完整目录请在搞操作中打开。\n"}
                listingBytes+=row.utf8.count
                listing+=row
            }
            guard size<=limits.maxDeclaredBytes,total<=limits.maxDeclaredBytes-size else {return listing+"PreviewWarning = 内容超过预览展开预算，已截断；完整目录请在搞操作中打开。\n"}
            total+=size
            // Raw compressed streams have one member. Its size may be absent;
            // do not decompress its payload merely to calculate a byte count.
            if rawStream {return listing}
        }
        throw Failure(message:"压缩包超出预览时间或读取预算，请在搞操作中打开。")
    }
}
