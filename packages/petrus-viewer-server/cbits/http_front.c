/*
 * The system calls of the HTTP front loop (Petrus.Viewer.HttpFront) that
 * relay_io.c does not already provide: accepting without blocking, moving
 * a socket between read and write readiness, and Node's Date header.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#if defined(__linux__)
#include <sys/epoll.h>
#define PFRONT_EPOLL 1
#else
#include <sys/event.h>
#include <sys/time.h>
#endif

/* Accept one connection from a non-blocking listening socket. The new
 * socket is non-blocking, close-on-exec, and has Nagle off (Node's http
 * server sets noDelay). Returns the descriptor, -2 when no connection is
 * waiting (or it went away before accept), -1 on any other error. */
int pfront_accept(int lfd)
{
    for (;;) {
        int fd = accept(lfd, NULL, NULL);
        if (fd >= 0) {
            fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
            fcntl(fd, F_SETFD, FD_CLOEXEC);
            int one = 1;
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
            return fd;
        }
        if (errno == EINTR) continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK || errno == ECONNABORTED) return -2;
        return -1;
    }
}

int pfront_set_nonblocking(int fd)
{
    int fl = fcntl(fd, F_GETFL);
    if (fl < 0) return -1;
    return fcntl(fd, F_SETFL, fl | O_NONBLOCK);
}

/* Switch a registered socket between waiting to read (writing = 0) and
 * waiting to write (writing = 1): a connection whose response did not fit
 * in the socket buffer reads nothing more until that response is out. */
int pfront_watch(int pfd, int fd, int writing)
{
#ifdef PFRONT_EPOLL
    struct epoll_event ev;
    memset(&ev, 0, sizeof ev);
    ev.events = writing ? EPOLLOUT : (EPOLLIN | EPOLLRDHUP);
    ev.data.fd = fd;
    return epoll_ctl(pfd, EPOLL_CTL_MOD, fd, &ev);
#else
    struct kevent ch[2];
    if (writing) {
        EV_SET(&ch[0], fd, EVFILT_READ, EV_DISABLE, 0, 0, NULL);
        EV_SET(&ch[1], fd, EVFILT_WRITE, EV_ADD | EV_ENABLE, 0, 0, NULL);
    } else {
        EV_SET(&ch[0], fd, EVFILT_WRITE, EV_DELETE, 0, 0, NULL);
        EV_SET(&ch[1], fd, EVFILT_READ, EV_ENABLE, 0, 0, NULL);
    }
    return kevent(pfd, ch, 2, NULL, 0, NULL);
#endif
}

/* The IMF-fixdate of now ("Sun, 06 Nov 1994 08:49:37 GMT", 29 bytes),
 * formatted once per second like Node's utcDate(). Called from the front
 * loop's thread only. */
void pfront_http_date(char *out)
{
    static const char days[7][4] = {"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"};
    static const char months[12][4] = {"Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                       "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"};
    static time_t cached_at = (time_t)-1;
    static char cached[30];
    time_t now = time(NULL);
    if (now != cached_at) {
        struct tm tm;
        gmtime_r(&now, &tm);
        cached[0] = days[tm.tm_wday][0];
        cached[1] = days[tm.tm_wday][1];
        cached[2] = days[tm.tm_wday][2];
        cached[3] = ',';
        cached[4] = ' ';
        cached[5] = (char)('0' + tm.tm_mday / 10);
        cached[6] = (char)('0' + tm.tm_mday % 10);
        cached[7] = ' ';
        memcpy(cached + 8, months[tm.tm_mon], 3);
        cached[11] = ' ';
        int y = tm.tm_year + 1900;
        cached[12] = (char)('0' + (y / 1000) % 10);
        cached[13] = (char)('0' + (y / 100) % 10);
        cached[14] = (char)('0' + (y / 10) % 10);
        cached[15] = (char)('0' + y % 10);
        cached[16] = ' ';
        cached[17] = (char)('0' + tm.tm_hour / 10);
        cached[18] = (char)('0' + tm.tm_hour % 10);
        cached[19] = ':';
        cached[20] = (char)('0' + tm.tm_min / 10);
        cached[21] = (char)('0' + tm.tm_min % 10);
        cached[22] = ':';
        cached[23] = (char)('0' + tm.tm_sec / 10);
        cached[24] = (char)('0' + tm.tm_sec % 10);
        memcpy(cached + 25, " GMT", 4);
        cached_at = now;
    }
    memcpy(out, cached, 29);
}
