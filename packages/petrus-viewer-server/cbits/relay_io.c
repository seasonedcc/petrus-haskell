/*
 * Socket readiness and non-blocking I/O for the event loops
 * (Petrus.Viewer.EventLoop: the relays, the HTTP front, petrus-mcp):
 * kqueue on macOS and the BSDs, epoll on Linux.
 *
 * Every relay socket stays registered for reading for as long as it is
 * served (level triggered), and for writing only while output is pending,
 * so serving a message costs one readiness wait shared by every socket
 * that is ready, one recv, and one send: the shape of Node's event loop.
 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <unistd.h>

#if defined(__linux__)
#include <sys/epoll.h>
#define PRELAY_EPOLL 1
#else
#include <sys/event.h>
#include <sys/time.h>
#endif

#define PRELAY_READABLE 1
#define PRELAY_WRITABLE 2
#define PRELAY_HANGUP 4

int prelay_poll_create(void)
{
#ifdef PRELAY_EPOLL
    return epoll_create1(EPOLL_CLOEXEC);
#else
    int kq = kqueue();
    if (kq >= 0) fcntl(kq, F_SETFD, FD_CLOEXEC);
    return kq;
#endif
}

/* Start watching fd for reading. */
int prelay_poll_add(int pfd, int fd)
{
#ifdef PRELAY_EPOLL
    struct epoll_event ev;
    memset(&ev, 0, sizeof ev);
    ev.events = EPOLLIN | EPOLLRDHUP;
    ev.data.fd = fd;
    return epoll_ctl(pfd, EPOLL_CTL_ADD, fd, &ev);
#else
    struct kevent ch;
    EV_SET(&ch, fd, EVFILT_READ, EV_ADD, 0, 0, NULL);
    return kevent(pfd, &ch, 1, NULL, 0, NULL);
#endif
}

/* Watch fd for writing too (on) or stop (off); reading stays on. */
int prelay_poll_write(int pfd, int fd, int on)
{
#ifdef PRELAY_EPOLL
    struct epoll_event ev;
    memset(&ev, 0, sizeof ev);
    ev.events = EPOLLIN | EPOLLRDHUP | (on ? EPOLLOUT : 0);
    ev.data.fd = fd;
    return epoll_ctl(pfd, EPOLL_CTL_MOD, fd, &ev);
#else
    struct kevent ch;
    EV_SET(&ch, fd, EVFILT_WRITE, on ? EV_ADD : EV_DELETE, 0, 0, NULL);
    int r = kevent(pfd, &ch, 1, NULL, 0, NULL);
    if (r < 0 && !on && errno == ENOENT) return 0;
    return r;
#endif
}

int prelay_poll_remove(int pfd, int fd)
{
#ifdef PRELAY_EPOLL
    struct epoll_event ev;
    memset(&ev, 0, sizeof ev);
    return epoll_ctl(pfd, EPOLL_CTL_DEL, fd, &ev);
#else
    struct kevent ch[2];
    EV_SET(&ch[0], fd, EVFILT_READ, EV_DELETE, 0, 0, NULL);
    EV_SET(&ch[1], fd, EVFILT_WRITE, EV_DELETE, 0, 0, NULL);
    /* one change at a time: a missing write filter must not stop the read
     * filter's removal */
    kevent(pfd, &ch[1], 1, NULL, 0, NULL);
    return kevent(pfd, &ch[0], 1, NULL, 0, NULL);
#endif
}

/* Wait for readiness (timeout_ms < 0 waits forever, 0 polls). Fills fds and
 * flags (PRELAY_*), one entry per ready fd and readiness kind; returns the
 * count, or -1. */
int prelay_poll_wait(int pfd, int *fds, int *flags, int max, int timeout_ms)
{
#ifdef PRELAY_EPOLL
    struct epoll_event evs[256];
    if (max > 256) max = 256;
    int n = epoll_wait(pfd, evs, max, timeout_ms);
    if (n < 0) return errno == EINTR ? 0 : -1;
    for (int i = 0; i < n; i++) {
        int f = 0;
        if (evs[i].events & (EPOLLIN | EPOLLRDHUP)) f |= PRELAY_READABLE;
        if (evs[i].events & EPOLLOUT) f |= PRELAY_WRITABLE;
        if (evs[i].events & (EPOLLHUP | EPOLLERR)) f |= PRELAY_HANGUP | PRELAY_READABLE;
        fds[i] = evs[i].data.fd;
        flags[i] = f;
    }
    return n;
#else
    struct kevent evs[256];
    struct timespec ts, *tsp = NULL;
    if (max > 256) max = 256;
    if (timeout_ms >= 0) {
        ts.tv_sec = timeout_ms / 1000;
        ts.tv_nsec = (long)(timeout_ms % 1000) * 1000000L;
        tsp = &ts;
    }
    int n = kevent(pfd, NULL, 0, evs, max, tsp);
    if (n < 0) return errno == EINTR ? 0 : -1;
    for (int i = 0; i < n; i++) {
        int f = 0;
        if (evs[i].filter == EVFILT_READ) f |= PRELAY_READABLE;
        if (evs[i].filter == EVFILT_WRITE) f |= PRELAY_WRITABLE;
        if (evs[i].flags & EV_ERROR) f |= PRELAY_HANGUP | PRELAY_READABLE;
        fds[i] = (int)evs[i].ident;
        flags[i] = f;
    }
    return n;
#endif
}

/* recv without blocking: bytes read, 0 at end of stream, -2 when nothing is
 * available, -1 on error. */
long prelay_recv(int fd, uint8_t *buf, long len)
{
    for (;;) {
        ssize_t r = recv(fd, buf, (size_t)len, MSG_DONTWAIT);
        if (r >= 0) return (long)r;
        if (errno == EINTR) continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK) return -2;
        return -1;
    }
}

/* read from a descriptor in non-blocking mode (a pipe): as prelay_recv. */
long prelay_read(int fd, uint8_t *buf, long len)
{
    for (;;) {
        ssize_t r = read(fd, buf, (size_t)len);
        if (r >= 0) return (long)r;
        if (errno == EINTR) continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK) return -2;
        return -1;
    }
}

/* Put a descriptor in non-blocking mode; negative on failure. */
int prelay_set_nonblocking(int fd)
{
    int flags = fcntl(fd, F_GETFL);
    if (flags < 0) return -1;
    return fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

/* writev without blocking (SIGPIPE is ignored by the GHC runtime): bytes
 * written, -2 when the socket buffer is full, -1 on error. */
long prelay_sendv(int fd, uint8_t **bufs, long *lens, int n)
{
    struct iovec iov[64];
    if (n > 64) n = 64;
    for (int i = 0; i < n; i++) {
        iov[i].iov_base = bufs[i];
        iov[i].iov_len = (size_t)lens[i];
    }
    for (;;) {
        ssize_t r = writev(fd, iov, n);
        if (r >= 0) return (long)r;
        if (errno == EINTR) continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK) return -2;
        return -1;
    }
}

/* Wake-up pipe: both ends non-blocking and close-on-exec. */
int prelay_pipe(int *fds)
{
    if (pipe(fds) < 0) return -1;
    for (int i = 0; i < 2; i++) {
        fcntl(fds[i], F_SETFL, fcntl(fds[i], F_GETFL) | O_NONBLOCK);
        fcntl(fds[i], F_SETFD, FD_CLOEXEC);
    }
    return 0;
}

void prelay_wake(int fd)
{
    uint8_t b = 1;
    ssize_t r = write(fd, &b, 1);
    (void)r; /* a full pipe is already a pending wake-up */
}

void prelay_drain(int fd)
{
    uint8_t buf[256];
    while (read(fd, buf, sizeof buf) > 0) {
    }
}

int prelay_close(int fd)
{
    return close(fd);
}

/* dst[i] = src[i] ^ key[(i + offset) % 4]; dst may equal src. */
void prelay_unmask(uint8_t *dst, const uint8_t *src, long len, const uint8_t *key, long offset)
{
    uint8_t k[4];
    for (int i = 0; i < 4; i++) k[i] = key[(i + offset) & 3];
    long i = 0;
    uint32_t k32;
    memcpy(&k32, k, 4);
    uint64_t k64 = ((uint64_t)k32 << 32) | k32;
    for (; i + 8 <= len; i += 8) {
        uint64_t w;
        memcpy(&w, src + i, 8);
        w ^= k64;
        memcpy(dst + i, &w, 8);
    }
    for (; i < len; i++) dst[i] = src[i] ^ k[i & 3];
}
