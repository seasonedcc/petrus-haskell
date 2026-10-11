/* Blocking waits for Petrus.Motus.Execution: readiness of a descriptor
 * (the Gondolin control socket) and the exit of a child without reaping it
 * (the process watcher). File-system primitives come from petrus-posix. */
#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>

#include "petrus_execution.h"

/* Block the calling OS thread until fd is readable (1), the timeout
 * elapses (0) or poll fails (-1, errno set; EINTR when the RTS interrupts
 * an `interruptible` call to deliver an asynchronous exception).  This is
 * what CPython's socket timeouts do, and it avoids an IO-manager wakeup on
 * every control-socket round trip. */
int petrus_wait_readable(int fd, int timeout_ms)
{
    struct pollfd entry;
    entry.fd = fd;
    entry.events = POLLIN;
    entry.revents = 0;
    int ready = poll(&entry, 1, timeout_ms);
    if (ready > 0) {
        return 1;
    }
    return ready;
}

/* Block until child `pid` has exited, without reaping it: waitid(2) with
 * WNOWAIT leaves the zombie for the caller's own waitpid, so a reaped pid is
 * never signalled.  Call it only from a safe foreign call on the threaded
 * RTS.  Returns 0 once the child has exited, or errno (ECHILD when it has
 * already been reaped). */
int petrus_wait_exited(pid_t pid)
{
    siginfo_t info;
    for (;;) {
        memset(&info, 0, sizeof info);
        if (waitid(P_PID, (id_t)pid, &info, WEXITED | WNOWAIT) == 0)
            return 0;
        if (errno != EINTR)
            return errno;
    }
}
