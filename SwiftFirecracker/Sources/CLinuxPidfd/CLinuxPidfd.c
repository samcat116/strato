#define _GNU_SOURCE

#include "CLinuxPidfd.h"

#include <errno.h>

#ifdef __linux__
#include <signal.h>
#include <sys/syscall.h>
#include <unistd.h>
#endif

int swift_firecracker_pidfd_open(pid_t pid) {
#ifdef __linux__
    return (int)syscall(SYS_pidfd_open, pid, 0);
#else
    (void)pid;
    errno = ENOSYS;
    return -1;
#endif
}

int swift_firecracker_pidfd_send_signal(int pidfd, int signal_number) {
#ifdef __linux__
    return (int)syscall(SYS_pidfd_send_signal, pidfd, signal_number, NULL, 0);
#else
    (void)pidfd;
    (void)signal_number;
    errno = ENOSYS;
    return -1;
#endif
}
