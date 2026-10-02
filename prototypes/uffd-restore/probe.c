/* Read-only availability probe; never advertises a Firecracker capability. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/userfaultfd.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/syscall.h>
#include <unistd.h>
int main(void) {
#ifdef SYS_userfaultfd
    int flags[] = {O_CLOEXEC | O_NONBLOCK, O_CLOEXEC | O_NONBLOCK | UFFD_USER_MODE_ONLY};
    for (unsigned i = 0; i < 2; ++i) {
        int fd = syscall(SYS_userfaultfd, flags[i]);
        if (fd < 0) { printf("syscall flags=%#x errno=%d (%s)\n", flags[i], errno, strerror(errno)); continue; }
        struct uffdio_api api = {.api = UFFD_API, .features = 0};
        if (ioctl(fd, UFFDIO_API, &api) < 0) printf("UFFDIO_API errno=%d (%s)\n", errno, strerror(errno));
        else printf("UFFDIO_API features=%#llx ioctls=%#llx; restore NOT tested\n", (unsigned long long)api.features, (unsigned long long)api.ioctls);
        close(fd);
    }
#else
    puts("SYS_userfaultfd absent in build headers");
#endif
    puts("lazy_restore_healthy=false (no end-to-end restore proof)");
    return 0;
}
