#define _GNU_SOURCE
#include "CSandboxUFFD.h"
#include <errno.h>
#ifdef __linux__
#include <fcntl.h>
#include <linux/userfaultfd.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <sys/eventfd.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

static int64_t now_ms(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC, &value) != 0) return -1;
    return (int64_t)value.tv_sec * 1000 + value.tv_nsec / 1000000;
}
static int wait_read(int fd, int cancel, int timeout_ms) {
    if (timeout_ms < 1 || timeout_ms > 60000) { errno = EINVAL; return -1; }
    int64_t start = now_ms();
    if (start < 0) return -1;
    int64_t end = start + timeout_ms;
    struct pollfd items[2] = {{fd, POLLIN, 0}, {cancel, POLLIN, 0}};
    for (;;) {
        int64_t now = now_ms();
        if (now < 0) return -1;
        if (now >= end) { errno = ETIMEDOUT; return -1; }
        int result = poll(items, 2, (int)(end - now));
        if (result < 0 && errno == EINTR) continue;
        if (result < 0) return -1;
        if (result == 0) { errno = ETIMEDOUT; return -1; }
        if (items[1].revents) { errno = ECANCELED; return -1; }
        if (items[0].revents & POLLIN) return 0;
        if (items[0].revents) { errno = ECONNRESET; return -1; }
    }
}
int strato_uffd_cancel_new(void) { return eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK); }
int strato_uffd_cancel(int fd) {
    uint64_t value = 1;
    int result;
    do { result = (int)write(fd, &value, sizeof(value)); } while (result < 0 && errno == EINTR);
    return result == sizeof(value) || (result < 0 && errno == EAGAIN) ? 0 : -1;
}
int strato_uffd_peer(int socket, int *pid, unsigned *uid, unsigned *gid) {
    struct ucred peer;
    socklen_t size = sizeof(peer);
    if (getsockopt(socket, SOL_SOCKET, SO_PEERCRED, &peer, &size) < 0) return -1;
    if (size != sizeof(peer)) { errno = EPROTO; return -1; }
    *pid = peer.pid; *uid = peer.uid; *gid = peer.gid;
    return 0;
}
int strato_uffd_receive(int socket, int cancel, void *bytes, size_t capacity, int timeout_ms, int *fd) {
    if (!capacity || capacity > 65536) { errno = EINVAL; return -1; }
    *fd = -1;
    if (wait_read(socket, cancel, timeout_ms) < 0) return -1;
    union { struct cmsghdr alignment; char bytes[CMSG_SPACE(sizeof(int) * 8)]; } control;
    struct iovec io = {bytes, capacity};
    struct msghdr msg = {0};
    msg.msg_iov = &io; msg.msg_iovlen = 1;
    msg.msg_control = control.bytes; msg.msg_controllen = sizeof(control.bytes);
    ssize_t count = recvmsg(socket, &msg, MSG_DONTWAIT | MSG_CMSG_CLOEXEC);
    if (count < 0) return -1;
    int descriptors[8], total = 0, bad = 0;
    for (struct cmsghdr *header = CMSG_FIRSTHDR(&msg); header; header = CMSG_NXTHDR(&msg, header)) {
        if (header->cmsg_level != SOL_SOCKET || header->cmsg_type != SCM_RIGHTS || header->cmsg_len < CMSG_LEN(0)) { bad = 1; continue; }
        size_t length = header->cmsg_len - CMSG_LEN(0);
        if (length % sizeof(int)) { bad = 1; continue; }
        size_t number = length / sizeof(int);
        for (size_t i = 0; i < number; ++i) {
            int value; memcpy(&value, (char *)CMSG_DATA(header) + i * sizeof(int), sizeof(value));
            if (total < 8) descriptors[total++] = value;
            else { close(value); bad = 1; }
        }
    }
    if (count <= 0 || total != 1 || bad || (msg.msg_flags & (MSG_CTRUNC | MSG_TRUNC))) {
        for (int i = 0; i < total; ++i) close(descriptors[i]);
        errno = EPROTO; return -1;
    }
    *fd = descriptors[0];
    return (int)count;
}
int strato_uffd_read_fragment(int socket, int cancel, void *bytes, size_t capacity, int timeout_ms) {
    if (!capacity || capacity > 65536) { errno = EINVAL; return -1; }
    if (wait_read(socket, cancel, timeout_ms) < 0) return -1;
    /* recvmsg even on continuations so extra descriptors cannot be silently leaked. */
    union { struct cmsghdr alignment; char bytes[CMSG_SPACE(sizeof(int) * 8)]; } control;
    struct iovec io = {bytes, capacity}; struct msghdr msg = {0};
    msg.msg_iov = &io; msg.msg_iovlen = 1; msg.msg_control = control.bytes; msg.msg_controllen = sizeof(control.bytes);
    ssize_t count = recvmsg(socket, &msg, MSG_DONTWAIT | MSG_CMSG_CLOEXEC);
    if (count < 0) return -1;
    int extra = 0;
    for (struct cmsghdr *h = CMSG_FIRSTHDR(&msg); h; h = CMSG_NXTHDR(&msg, h)) {
        extra = 1;
        if (h->cmsg_level == SOL_SOCKET && h->cmsg_type == SCM_RIGHTS && h->cmsg_len >= CMSG_LEN(0)) {
            size_t number = (h->cmsg_len - CMSG_LEN(0)) / sizeof(int);
            for (size_t i = 0; i < number; ++i) { int value; memcpy(&value, (char *)CMSG_DATA(h) + i * sizeof(int), sizeof(value)); close(value); }
        }
    }
    if (count <= 0 || extra || (msg.msg_flags & (MSG_CTRUNC | MSG_TRUNC))) { errno = EPROTO; return -1; }
    return (int)count;
}
int strato_uffd_descriptor_kind(int fd) {
    char path[64], target[128];
    snprintf(path, sizeof(path), "/proc/self/fd/%d", fd);
    ssize_t count = readlink(path, target, sizeof(target) - 1);
    if (count < 0) return -1;
    target[count] = 0;
    if (strcmp(target, "anon_inode:[userfaultfd]") != 0) { errno = ENOTTY; return -1; }
    int flags = fcntl(fd, F_GETFL), descriptor_flags = fcntl(fd, F_GETFD);
    if (flags < 0 || descriptor_flags < 0) return -1;
    if (!(flags & O_NONBLOCK) || !(descriptor_flags & FD_CLOEXEC)) { errno = EPROTO; return -1; }
    return 0;
}
int strato_uffd_read_event(int fd, int cancel, int timeout_ms, struct strato_uffd_event *event) {
    if (wait_read(fd, cancel, timeout_ms) < 0) return -1;
    struct uffd_msg msg;
    ssize_t count = read(fd, &msg, sizeof(msg));
    if (count < 0) return -1;
    if (count != sizeof(msg)) { errno = EPROTO; return -1; }
    memset(event, 0, sizeof(*event));
    if (msg.event == UFFD_EVENT_PAGEFAULT) {
        event->kind = 1; event->address = msg.arg.pagefault.address; event->flags = msg.arg.pagefault.flags;
    } else if (msg.event == UFFD_EVENT_REMOVE) {
        event->kind = 2; event->address = msg.arg.remove.start; event->end = msg.arg.remove.end;
    } else { event->kind = 3; }
    return 0;
}
int strato_uffd_copy(int fd, uint64_t address, const void *bytes, size_t count) {
    if (!bytes || count != 4096 || address % 4096) { errno = EINVAL; return -1; }
    struct uffdio_copy copy = {.dst = address, .src = (uint64_t)(uintptr_t)bytes, .len = count, .mode = 0};
    if (ioctl(fd, UFFDIO_COPY, &copy) < 0) return -1;
    if (copy.copy != (int64_t)count) { errno = EIO; return -1; }
    return 0;
}
int strato_uffd_send(int socket, const void *bytes, size_t count, const int *fds, size_t fd_count) {
    if (!bytes || !count || count > 65536 || fd_count > 16 || (fd_count && !fds)) { errno = EINVAL; return -1; }
    union { struct cmsghdr alignment; char bytes[CMSG_SPACE(sizeof(int) * 16)]; } control;
    struct iovec io = {(void *)bytes, count}; struct msghdr msg = {0};
    msg.msg_iov = &io; msg.msg_iovlen = 1;
    if (fd_count) {
        memset(&control, 0, sizeof(control)); msg.msg_control = control.bytes; msg.msg_controllen = CMSG_SPACE(sizeof(int) * fd_count);
        struct cmsghdr *h = CMSG_FIRSTHDR(&msg); h->cmsg_level = SOL_SOCKET; h->cmsg_type = SCM_RIGHTS; h->cmsg_len = CMSG_LEN(sizeof(int) * fd_count);
        memcpy(CMSG_DATA(h), fds, sizeof(int) * fd_count);
    }
    ssize_t sent = sendmsg(socket, &msg, MSG_NOSIGNAL | MSG_DONTWAIT);
    if (sent < 0) return -1;
    if ((size_t)sent != count) { errno = EIO; return -1; }
    return 0;
}
#else
int strato_uffd_cancel_new(void) { errno = ENOSYS; return -1; }
int strato_uffd_cancel(int fd) { (void)fd; errno = ENOSYS; return -1; }
int strato_uffd_peer(int s,int*p,unsigned*u,unsigned*g) { (void)s;(void)p;(void)u;(void)g;errno=ENOSYS;return -1; }
int strato_uffd_receive(int s,int c,void*b,size_t n,int t,int*f) { (void)s;(void)c;(void)b;(void)n;(void)t;(void)f;errno=ENOSYS;return -1; }
int strato_uffd_read_fragment(int s,int c,void*b,size_t n,int t) { (void)s;(void)c;(void)b;(void)n;(void)t;errno=ENOSYS;return -1; }
int strato_uffd_descriptor_kind(int fd) { (void)fd;errno=ENOSYS;return -1; }
int strato_uffd_read_event(int f,int c,int t,struct strato_uffd_event*e) { (void)f;(void)c;(void)t;(void)e;errno=ENOSYS;return -1; }
int strato_uffd_copy(int f,uint64_t a,const void*b,size_t n) { (void)f;(void)a;(void)b;(void)n;errno=ENOSYS;return -1; }
int strato_uffd_send(int s,const void*b,size_t n,const int*f,size_t c) { (void)s;(void)b;(void)n;(void)f;(void)c;errno=ENOSYS;return -1; }
#endif
