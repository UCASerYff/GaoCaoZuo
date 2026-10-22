#include <sys/types.h>
#include <dlfcn.h>
#include <string.h>

/* ABI declarations cross-checked against Apple-authored WebKit SandboxSPI.h:
 * https://github.com/WebKit/WebKit/blob/main/Source/WTF/wtf/spi/darwin/SandboxSPI.h
 * The variadic call stays in C, including on arm64. Missing SPI denies access.
 * A path-only bookmark is not proof of a sandboxed caller's authorization. */
int gao_archive_caller_access(pid_t pid, const char *operation, const char *path)
{
    if (pid <= 0 || !path || !path[0] || !operation ||
        (strcmp(operation, "file-read-data") && strcmp(operation, "file-write-data") &&
         strcmp(operation, "file-write-create"))) return 0;
    void *library = dlopen("/usr/lib/system/libsystem_sandbox.dylib", RTLD_NOW | RTLD_LOCAL);
    if (!library) return 0;
    typedef int (*check_fn)(pid_t, const char *, int, ...);
    check_fn check = (check_fn)dlsym(library, "sandbox_check");
    const int *no_report = (const int *)dlsym(library, "SANDBOX_CHECK_NO_REPORT");
    /* SANDBOX_FILTER_PATH is 1 in the checked SDK ABI. */
    int allowed = check && no_report && check(pid, operation, 1 | *no_report, path) == 0;
    dlclose(library);
    return allowed;
}
