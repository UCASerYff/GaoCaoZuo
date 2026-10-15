#!/usr/bin/env python3
"""Read-only archive adapters and a ZIP writer. Secrets arrive only on stdin.
The caller enforces an OS write-denial sandbox for list/test/stream operations.
"""
import ctypes as C
import datetime, io, json, os, pathlib, stat, struct, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import acefile

lib=C.CDLL('/usr/lib/libarchive.2.dylib')
def fn(name, result, *args):
    f=getattr(lib,name);f.restype=result;f.argtypes=list(args);return f
P=C.c_void_p;S=C.c_char_p;I=C.c_int;L=C.c_longlong;Z=C.c_size_t
new=fn('archive_read_new',P); support=fn('archive_read_support_format_all',I,P); raw=fn('archive_read_support_format_raw',I,P); filters=fn('archive_read_support_filter_all',I,P)
readopen=fn('archive_read_open_filename',I,P,S,Z);readvolumes=fn('archive_read_open_filenames',I,P,C.POINTER(S),Z);nextheader=fn('archive_read_next_header',I,P,C.POINTER(P));read=fn('archive_read_data',L,P,P,Z);readfree=fn('archive_read_free',I,P)
errorstr=fn('archive_error_string',S,P); addpass=fn('archive_read_add_passphrase',I,P,S);readopts=fn('archive_read_set_options',I,P,S)
pathname=fn('archive_entry_pathname_utf8',S,P);pathnamefallback=fn('archive_entry_pathname',S,P);size=fn('archive_entry_size',L,P);mode=fn('archive_entry_mode',I,P);mtime=fn('archive_entry_mtime',L,P);encrypted=fn('archive_entry_is_encrypted',I,P);symlink=fn('archive_entry_symlink_utf8',S,P);hardlink=fn('archive_entry_hardlink_utf8',S,P)
write_new=fn('archive_write_new',P);zipformat=fn('archive_write_set_format_zip',I,P);writeopts=fn('archive_write_set_options',I,P,S);setpass=fn('archive_write_set_passphrase',I,P,S);writeopen=fn('archive_write_open_filename',I,P,S);writeheader=fn('archive_write_header',I,P,P);writedata=fn('archive_write_data',L,P,P,Z);writeclose=fn('archive_write_close',I,P);writefree=fn('archive_write_free',I,P)
entrynew=fn('archive_entry_new',P);entryfree=fn('archive_entry_free',None,P);setpath=fn('archive_entry_set_pathname_utf8',None,P,S);setsize=fn('archive_entry_set_size',None,P,L);setmode=fn('archive_entry_set_mode',None,P,I);setmtime=fn('archive_entry_set_mtime',None,P,L,L)

def check(value,a):
    if value < 0: raise ValueError((errorstr(a) or b'archive operation failed').decode('utf-8','replace'))
    return value

def safe(s):
    if not s or any(ord(c)<32 or ord(c)==127 for c in s):raise ValueError('unsafe filename metadata')
    return s

def listing(path,n,directory=False,permissions=0o600,modified=None,enc=False,soft=None,hard=None):
    p=safe(path)
    print('Path = '+p);print('Size = '+str(n));print('Folder = '+('+' if directory else '-'));print('Encrypted = '+('+' if enc else '-'))
    print('Attributes = '+stat.filemode((stat.S_IFDIR if directory else stat.S_IFREG)|permissions))
    if modified: print('Modified = '+modified.strftime('%Y-%m-%d %H:%M:%S'))
    if soft: print('Symbolic Link = '+safe(soft))
    if hard: print('Hard Link = '+safe(hard))
    print()

def ace(command,path,member,password,encoding,limit):
    kwargs={} if encoding=='auto' else {'encoding':encoding}
    with acefile.open(path,**kwargs) as a:
        for m in a.getmembers():
            # acefile's convenience filename property sanitizes traversal. Preserve original
            # metadata for the host's rejection rules rather than silently changing unsafe names.
            if encoding=='auto':
                try:name=m.raw_filename.decode('utf-8','strict')
                except UnicodeDecodeError:name=m.raw_filename.decode('cp850','strict')
            else:name=m.raw_filename.decode(encoding,'strict')
            name=name.replace('\\','/')
            if command=='l': listing(name,m.size,m.is_dir(),modified=m.datetime,enc=m.is_enc())
            elif command=='t' or (command=='x' and name==member):
                if not m.is_dir():
                    total=0
                    for b in a.readblocks(m,pwd=password or None):
                        total+=len(b)
                        if total>limit:raise ValueError('archive byte budget exceeded')
                        if command=='x':sys.stdout.buffer.write(b)
                if command=='x':return
        if command=='x':raise ValueError('member not found')

def native(command,path,member,password,encoding,limit):
    a=new();filters(a)
    extension=pathlib.Path(path).suffix.lower()
    streams=('.gz','.gzip','.tgz','.bz2','.bzip2','.tbz','.tbz2','.xz','.txz','.lz','.lzip','.lzop','.zst','.tzst')
    if extension in streams:raw(a)
    else:support(a)
    try:
        if password:check(addpass(a,password.encode()),a)
        if encoding!='auto':check(readopts(a,('hdrcharset='+encoding).encode()),a)
        if path.endswith('.001'):
            names=[];base=path[:-3]
            for number in range(1,100001):
                volume=base+str(number).zfill(3)
                if not os.path.isfile(volume):break
                names.append(os.fsencode(volume))
            array=(S*(len(names)+1))(*names,None)
            check(readvolumes(a,array,65536),a)
        else:check(readopen(a,os.fsencode(path),65536),a)
        entry=P();buffer=C.create_string_buffer(65536)
        while True:
            code=nextheader(a,C.byref(entry))
            if code==1:break
            check(code,a)
            pathbytes=pathname(entry) or pathnamefallback(entry)
            name=pathbytes.decode('utf-8','strict') if pathbytes else 'data'
            if name=='data' and extension in streams:
                name=pathlib.Path(path).stem+('.tar' if extension in ('.tgz','.tbz','.tbz2','.txz','.tzst') else '')
            n=size(entry);m=mode(entry);soft=symlink(entry);hard=hardlink(entry)
            want=command=='t' or (command=='x' and name==member) or (command=='l' and n==0 and not stat.S_ISDIR(m) and not soft and not hard)
            total=0
            if want:
                while True:
                    length=check(read(a,buffer,len(buffer)),a)
                    if not length:break
                    total+=length
                    if total>limit:raise ValueError('archive byte budget exceeded')
                    if command=='x':sys.stdout.buffer.write(buffer.raw[:length])
                if command=='x':return
            if command=='l':
                listing(name,total if want else n,stat.S_ISDIR(m),m & 0o777,datetime.datetime.fromtimestamp(mtime(entry)),encrypted(entry)>0,soft.decode() if soft else None,hard.decode() if hard else None)
        if command=='x':raise ValueError('member not found')
    finally:readfree(a)

class SplitZIP(io.RawIOBase):
    """Seek across split .001/.002 streams without joining them on disk or in RAM."""
    def __init__(self,path):
        self.parts=[];self.offsets=[0];self.position=0
        for number in range(1,100001):
            name=path[:-3]+str(number).zfill(3)
            if not os.path.isfile(name):break
            self.parts.append(open(name,'rb'));self.offsets.append(self.offsets[-1]+os.path.getsize(name))
        if not self.parts:raise ValueError('first split volume is missing')
    def seekable(self):return True
    def readable(self):return True
    def tell(self):return self.position
    def seek(self,offset,whence=0):
        p=offset if whence==0 else self.position+offset if whence==1 else self.offsets[-1]+offset
        if p<0:raise ValueError('invalid split stream offset')
        self.position=p;return p
    def read(self,n=-1):
        import bisect
        remaining=self.offsets[-1]-self.position if n<0 else min(n,self.offsets[-1]-self.position)
        chunks=[]
        while remaining>0:
            index=bisect.bisect_right(self.offsets,self.position)-1
            part=self.parts[index];part.seek(self.position-self.offsets[index])
            b=part.read(min(remaining,self.offsets[index+1]-self.position))
            if not b:raise ValueError('split ZIP is incomplete')
            chunks.append(b);remaining-=len(b);self.position+=len(b)
        return b''.join(chunks)
    def close(self):
        for p in self.parts:p.close()
        super().close()

def zip_adapter(command,path,member,password,encoding,limit):
    import pyzipper
    source=SplitZIP(path) if path.endswith('.001') else path
    try:
        with pyzipper.AESZipFile(source,'r') as archive:
            if password:archive.setpassword(password.encode('utf-8'))
            for info in archive.infolist():
                name=info.filename
                if not info.flag_bits & 0x800 and encoding!='auto':name=name.encode('cp437').decode(encoding,'strict')
                permissions=(info.external_attr>>16)&0xffff
                soft=None
                if stat.S_ISLNK(permissions):
                    if info.file_size>4096:raise ValueError('symbolic link target too long')
                    soft=archive.read(info).decode('utf-8','strict')
                if command=='l':
                    try:modified=datetime.datetime(*info.date_time)
                    except ValueError:modified=None
                    listing(name,info.file_size,info.is_dir(),permissions&0o777 or 0o600,modified,bool(info.flag_bits&1),soft)
                elif command=='t' or (command=='x' and name==member):
                    if not info.is_dir():
                        total=0
                        with archive.open(info) as stream:
                            while b:=stream.read(65536):
                                total+=len(b)
                                if total>limit:raise ValueError('archive byte budget exceeded')
                                if command=='x':sys.stdout.buffer.write(b)
                    if command=='x':return
            if command=='x':raise ValueError('member not found')
    finally:
        if isinstance(source,SplitZIP):source.close()

def batch_request(limit):
    # The request is private stdin, following the password line. Never argv, logs,
    # a public pasteboard, or an archive-controlled output directory.
    data=sys.stdin.buffer.read(16*1024**2+1)
    if len(data)>16*1024**2:raise ValueError('batch request exceeds byte budget')
    rows=json.loads(data)
    if not isinstance(rows,list) or len(rows)>100000:raise ValueError('batch request exceeds entry budget')
    result={};total=0
    for index,row in enumerate(rows):
        if not isinstance(row,dict) or set(row)!={'path','size'}:raise ValueError('invalid batch request')
        name=row['path'];length=row['size']
        if not isinstance(name,str) or not isinstance(length,int) or isinstance(length,bool) or length<0 or name in result:raise ValueError('invalid batch member')
        safe(name);total+=length
        if total>limit:raise ValueError('archive byte budget exceeded')
        result[name]=(index,length)
    return result

def batch(path,password,encoding,limit):
    wanted=batch_request(limit);seen=set();output=sys.stdout.buffer
    def emit(name,length,blocks):
        if name not in wanted:return
        index,expected=wanted[name]
        if name in seen or length!=expected:raise ValueError('batch member identity or size changed')
        seen.add(name);output.write(struct.pack('>IQ',index,expected));total=0
        for b in blocks:
            total+=len(b)
            if total>expected:raise ValueError('batch member exceeds declared size')
            output.write(b)
        if total!=expected:raise ValueError('batch member is incomplete')
    if path.lower().endswith(('.zip','.zip.001')):
        import pyzipper
        source=SplitZIP(path) if path.endswith('.001') else path
        try:
            with pyzipper.AESZipFile(source,'r') as archive:
                if password:archive.setpassword(password.encode('utf-8'))
                for info in archive.infolist():
                    name=info.filename
                    if not info.flag_bits & 0x800 and encoding!='auto':name=name.encode('cp437').decode(encoding,'strict')
                    if name not in wanted:continue
                    if info.is_dir() or stat.S_ISLNK((info.external_attr>>16)&0xffff):raise ValueError('batch member type changed')
                    with archive.open(info) as stream:
                        emit(name,info.file_size,iter(lambda:stream.read(65536),b''))
        finally:
            if isinstance(source,SplitZIP):source.close()
    elif path.lower().endswith('.7z'):
        # The host only selects this route for checked, unencrypted Copy/LZMA2
        # archives. A single reader preserves the solid decoder's state.
        if password:raise ValueError('encrypted 7z batch is unsupported')
        a=new();filters(a);support(a)
        try:
            check(readopen(a,os.fsencode(path),65536),a)
            entry=P();buffer=C.create_string_buffer(65536)
            def blocks():
                while True:
                    length=check(read(a,buffer,len(buffer)),a)
                    if not length:return
                    yield buffer.raw[:length]
            while True:
                code=nextheader(a,C.byref(entry))
                if code==1:break
                check(code,a);rawname=pathname(entry) or pathnamefallback(entry)
                name=rawname.decode('utf-8','strict') if rawname else ''
                if name not in wanted:continue
                if not stat.S_ISREG(mode(entry)) or symlink(entry) or hardlink(entry) or encrypted(entry)>0:raise ValueError('batch member type changed')
                emit(name,size(entry),blocks())
        finally:readfree(a)
    else:raise ValueError('unsupported batch container')
    if len(seen)!=len(wanted):raise ValueError('batch member not found')
    output.write(struct.pack('>IQ',0xffffffff,0));output.flush()

def create(path,names,password,level,excludes):
    import pyzipper, fnmatch
    compression=pyzipper.ZIP_STORED if level==0 else pyzipper.ZIP_DEFLATED
    with pyzipper.AESZipFile(path,'x',compression=compression,compresslevel=level or None,allowZip64=True) as archive:
        if password:archive.setpassword(password.encode('utf-8'));archive.setencryption(pyzipper.WZ_AES,nbits=256)
        def one(p):
            name=p.as_posix();st=p.lstat()
            if any(fnmatch.fnmatchcase(name,x) or fnmatch.fnmatchcase(p.name,x) for x in excludes):return
            if not (stat.S_ISREG(st.st_mode) or stat.S_ISDIR(st.st_mode) or stat.S_ISLNK(st.st_mode)):raise ValueError('unsupported input type')
            date=datetime.datetime.fromtimestamp(st.st_mtime);date=max(datetime.datetime(1980,1,1),min(date,datetime.datetime(2107,12,31,23,59,58)))
            info=archive.zipinfo_cls(name+('/' if stat.S_ISDIR(st.st_mode) else ''),date.timetuple()[:6])
            info.external_attr=(st.st_mode&0xffff)<<16;info.create_system=3;info.compress_type=compression
            if stat.S_ISDIR(st.st_mode):
                info.external_attr|=0x10;archive.writestr(info,b'')
                for child in sorted(p.iterdir()):one(child)
            elif stat.S_ISLNK(st.st_mode):archive.writestr(info,os.readlink(p).encode('utf-8'))
            else:
                with p.open('rb') as source,archive.open(info,'w',force_zip64=st.st_size>=2**31) as output:
                    while b:=source.read(65536):output.write(b)
        for name in names:one(pathlib.Path(name))

def create_native_unused(path,names,password,level,excludes):
    import fnmatch
    a=write_new();zipformat(a)
    try:
        check(writeopts(a,('zip:compression='+('store' if level==0 else 'deflate')+',zip:compression-level='+str(level)).encode()),a)
        if password:
            check(writeopts(a,b'zip:encryption=aes256'),a);check(setpass(a,password.encode('utf-8')),a)
        check(writeopen(a,os.fsencode(path)),a)
        def one(p):
            name=p.as_posix()
            if any(fnmatch.fnmatchcase(name,x) or fnmatch.fnmatchcase(p.name,x) for x in excludes):return
            st=p.lstat()
            if not (stat.S_ISREG(st.st_mode) or stat.S_ISDIR(st.st_mode)):raise ValueError('unsupported input type')
            e=entrynew()
            try:
                setpath(e,name.encode());setsize(e,st.st_size if stat.S_ISREG(st.st_mode) else 0);setmode(e,st.st_mode & (0o777|stat.S_IFREG|stat.S_IFDIR));setmtime(e,int(st.st_mtime),0)
                check(writeheader(a,e),a)
                if stat.S_ISREG(st.st_mode):
                    with p.open('rb') as f:
                        while b:=f.read(65536):
                            if check(writedata(a,b,len(b)),a)!=len(b):raise ValueError('short archive write')
            finally:entryfree(e)
            if stat.S_ISDIR(st.st_mode):
                for child in sorted(p.iterdir()):one(child)
        for name in names:one(pathlib.Path(name))
        check(writeclose(a),a)
    finally:writefree(a)

def main():
    args=sys.argv[1:];command=args[0];sep=args.index('--');flags=args[1:sep];paths=args[sep+1:]
    password=sys.stdin.buffer.readline(4097).rstrip(b'\r\n').decode('utf-8')
    encoding=next((a[15:] for a in flags if a.startswith('--gao-encoding=')),'auto')
    limit=int(next((a[12:] for a in flags if a.startswith('--gao-limit=')),20*1024**3))
    if command=='b':
        batch(paths[0],password,encoding,limit);return
    if command=='a':
        level=int(next((a[4:] for a in flags if a.startswith('-mx=')),'5'))
        create(paths[0],paths[1:],password,level,[a[4:] for a in flags if a.startswith('-xr!')])
        split=next((a[2:-1] for a in flags if a.startswith('-v') and a.endswith('m')),None)
        if split:
            blocksize=int(split)*1024**2
            with open(paths[0],'rb') as original:
                number=1
                while True:
                    chunk=original.read(min(blocksize,65536))
                    if not chunk:break
                    with open(paths[0]+'.'+str(number).zfill(3),'xb') as out:
                        written=0
                        while chunk:
                            out.write(chunk);written+=len(chunk)
                            if written==blocksize:break
                            chunk=original.read(min(blocksize-written,65536))
                    number+=1
            os.unlink(paths[0])
        return
    handler=ace if pathlib.Path(paths[0]).suffix.lower()=='.ace' else zip_adapter if paths[0].lower().endswith(('.zip','.zip.001')) else native
    handler(command,paths[0],paths[1] if len(paths)>1 else None,password,encoding,limit)

if __name__=='__main__':
    try:main()
    except Exception as e:
        detail=str(e)
        if any(s in detail.lower() for s in ('password','passphrase','encrypted','decrypt','authenticat')):sys.stderr.write('ERROR: Wrong password or password required\n')
        else:sys.stderr.write('ERROR: '+detail+'\n')
        sys.exit(2)
