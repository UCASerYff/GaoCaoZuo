#!/usr/bin/env python3
"""Fixed broker checks use the actual sandboxed caller's file scope, not a path claim."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

PROJECT = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='GaoCallerAccess-',suffix='.noindex',dir='/private/tmp') as temporary:
    root=Path(temporary)
    allowed=root/'public-selected.txt';denied=root/'public-not-selected.txt'
    allowed.write_text('Public selected canary\n');denied.write_text('Public unselected canary\n')
    main=root/'Main.c';main.write_text('''#include <sys/types.h>
#include <stdlib.h>
#include <stdio.h>
int gao_archive_caller_access(pid_t,const char*,const char*);
int main(int argc,char **argv) {
 if(argc!=5)return 2;
 pid_t pid=(pid_t)atoi(argv[1]);
 printf("[%d,%d,%d,%d,%d,%d]\\n",
  gao_archive_caller_access(pid,"file-read-data",argv[2]),
  gao_archive_caller_access(pid,"file-read-data",argv[3]),
  gao_archive_caller_access(pid,"file-write-data",argv[2]),
  gao_archive_caller_access(pid,"file-write-create",argv[4]),
  gao_archive_caller_access(0,"file-read-data",argv[2]),
  gao_archive_caller_access(pid,"mach-lookup",argv[2]));
 return 0;
}''')
    binary=root/'checker'
    subprocess.run(['xcrun','clang','-O2',str(PROJECT/'Scripts/QuickLookCallerAccess.c'),str(main),'-o',str(binary)],check=True,timeout=60)
    def check(pid):
        return json.loads(subprocess.check_output([str(binary),str(pid),str(allowed),str(denied),str(root)],text=True,timeout=5))
    baseline=check(os.getpid())
    assert baseline==[1,1,1,1,0,0],('public baseline',baseline)
    profile='(version 1)(allow default)(deny file-read-data (literal '+json.dumps(str(denied))+'))(deny file-write* (subpath '+json.dumps(str(root))+'))'
    child=subprocess.Popen(['/usr/bin/sandbox-exec','-p',profile,'/bin/sleep','30'],stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
    try:
        deadline=time.monotonic()+3
        result=None
        while time.monotonic()<deadline:
            assert child.poll() is None,'sandboxed caller exited before checks'
            result=check(child.pid)
            if result==[1,0,0,0,0,0]:break
            time.sleep(.02)
        assert result==[1,0,0,0,0,0],('sandboxed caller scope',result)
        print(json.dumps({'status':'passed','actualSandboxedCallerPID':child.pid,'normalUIDBaseline':baseline,'sandboxedCallerChecks':result,'selectedReadAllowed':True,'unselectedReadDenied':True,'originalWriteDenied':True,'parentCreateDenied':True,'invalidPIDAndNonFileOperationsDenied':True,'appOrWindowOpened':False,'fixtureData':'public synthetic only'},sort_keys=True))
    finally:
        if child.poll() is None:child.terminate()
        try:child.wait(timeout=3)
        except subprocess.TimeoutExpired:child.kill();child.wait(timeout=3)
