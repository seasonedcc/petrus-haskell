#include <errno.h>
#include <poll.h>

/* Wait until fd is readable or timeout_ms elapses (negative: no timeout).
   Returns 1 when readable (or in error or hang-up, which the caller then
   observes through libpq), 0 on timeout, and -errno on failure (-EINTR when
   a signal, such as the RTS interrupting this call, arrived). */
int petrus_pg_wait_readable(int fd, int timeout_ms)
{
    struct pollfd p;
    p.fd = fd;
    p.events = POLLIN;
    p.revents = 0;
    int rc = poll(&p, 1, timeout_ms);
    if (rc < 0)
        return -errno;
    return rc > 0 ? 1 : 0;
}
