#ifndef STRATO_SANDBOX_UFFD_H
#define STRATO_SANDBOX_UFFD_H
#include <stddef.h>
#include <stdint.h>
struct strato_uffd_event { uint64_t address, end, flags; int kind; };
int strato_uffd_cancel_new(void);
int strato_uffd_cancel(int fd);
int strato_uffd_peer(int socket, int *pid, unsigned *uid, unsigned *gid);
/* One SCM_RIGHTS descriptor on the first stream fragment; all rejected FDs closed. */
int strato_uffd_receive(int socket, int cancel, void *bytes, size_t capacity, int timeout_ms, int *fd);
int strato_uffd_read_fragment(int socket, int cancel, void *bytes, size_t capacity, int timeout_ms);
int strato_uffd_descriptor_kind(int fd);
int strato_uffd_read_event(int fd, int cancel, int timeout_ms, struct strato_uffd_event *event);
int strato_uffd_copy(int fd, uint64_t address, const void *bytes, size_t count);
/* Generic Unix descriptor-send utility, also used by disposable transport fixtures. */
int strato_uffd_send(int socket, const void *bytes, size_t count, const int *fds, size_t fd_count);
#endif
