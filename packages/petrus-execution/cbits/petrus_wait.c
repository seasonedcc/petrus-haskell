/* Blocking wait for Petrus.Motus.Execution: the exit of a child without
 * reaping it (the process watcher). Descriptor readiness and file-system
 * primitives come from petrus-posix. */
#include <errno.h>
#include <signal.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>

#include "petrus_execution.h"

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
