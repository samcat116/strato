#ifndef SWIFT_FIRECRACKER_LINUX_PIDFD_H
#define SWIFT_FIRECRACKER_LINUX_PIDFD_H

#include <sys/types.h>

int swift_firecracker_pidfd_open(pid_t pid);
int swift_firecracker_pidfd_send_signal(int pidfd, int signal_number);

#endif
