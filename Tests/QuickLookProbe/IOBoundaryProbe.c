#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

/* Public synthetic fixtures only. A denied write-open never truncates a file. */
static int check_open(const char *path,int flags) {
    int fd=open(path,flags,0600),error=fd<0 ? errno:0;
    if(fd>=0) close(fd);
    return error;
}
int main(int argc,char **argv) {
    if(argc!=4) return 2;
    int selected=check_open(argv[1],O_RDONLY|O_NOFOLLOW);
    int outside=check_open(argv[2],O_RDONLY|O_NOFOLLOW);
    int original_write=check_open(argv[1],O_WRONLY|O_NOFOLLOW);
    int scratch_create=check_open(argv[3],O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW);
    printf("{\"selectedRead\":%d,\"outsideRead\":%d,\"originalWrite\":%d,\"scratchCreate\":%d}",selected,outside,original_write,scratch_create);
    return 0;
}
