/* Child spawning for Petrus.Motus.Execution.Internal.Process.
 *
 * subprocess.Popen(close_fds=True) closes only the descriptors that are
 * actually open.  The `process` package falls back to fork/exec for
 * close_fds and then closes every descriptor up to sysconf(_SC_OPEN_MAX),
 * which costs ~0.1 s per spawn when RLIMIT_NOFILE is 1 048 576 (the macOS
 * default under launchd).  Here posix_spawn closes descriptors the way each
 * platform intends:
 *
 *   - Darwin: POSIX_SPAWN_CLOEXEC_DEFAULT (only stdio survives, via dup2 or
 *     posix_spawn_file_actions_addinherit_np);
 *   - glibc >= 2.34: posix_spawn_file_actions_addclosefrom_np(3).
 *
 * Like CPython's restore_signals=True, SIGPIPE and SIGXFSZ (ignored by the
 * GHC RTS) are reset to their defaults and the child starts with an empty
 * signal mask.
 *
 * Seam: this belongs to petrus-posix; see the Haskell module header. */
#if defined(__linux__)
#define _GNU_SOURCE
#endif

#include <errno.h>
#include <signal.h>
#include <spawn.h>
#include <stddef.h>
#include <string.h>
#include <sys/types.h>

#include "petrus_posix.h"

extern char **environ;

#if !defined(__APPLE__)
#if !(defined(__GLIBC__) && (__GLIBC__ > 2 || (__GLIBC__ == 2 && __GLIBC_MINOR__ >= 34)))
#error "petrus_spawn needs POSIX_SPAWN_CLOEXEC_DEFAULT (Darwin) or posix_spawn_file_actions_addclosefrom_np (glibc >= 2.34)"
#endif
#endif

/* Spawn `file`.  A path containing a slash is executed as given with no
 * /bin/sh fallback on ENOEXEC (CPython's execve semantics); a bare name is
 * searched on PATH by posix_spawnp.  `envp` NULL
 * inherits the environment, `cwd` NULL inherits the directory, and each
 * stdio descriptor < 0 is inherited.  Returns 0 and stores the pid, or an
 * errno value. */
int petrus_spawn(const char *file, char *const argv[], char *const envp[], const char *cwd, int new_session,
                 int stdin_fd, int stdout_fd, int stderr_fd, pid_t *pid_out)
{
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    int status = posix_spawn_file_actions_init(&actions);
    if (status != 0) {
        return status;
    }
    status = posix_spawnattr_init(&attributes);
    if (status != 0) {
        posix_spawn_file_actions_destroy(&actions);
        return status;
    }

    const int sources[3] = {stdin_fd, stdout_fd, stderr_fd};
    for (int target = 0; target < 3 && status == 0; target++) {
        if (sources[target] >= 0) {
            status = posix_spawn_file_actions_adddup2(&actions, sources[target], target);
        }
#if defined(__APPLE__)
        else {
            status = posix_spawn_file_actions_addinherit_np(&actions, target);
        }
#endif
    }
#if !defined(__APPLE__)
    if (status == 0) {
        status = posix_spawn_file_actions_addclosefrom_np(&actions, 3);
    }
#endif
    if (status == 0 && cwd != NULL) {
        /* macOS 26 renamed it posix_spawn_file_actions_addchdir; the _np
         * spelling works on every supported macOS and glibc >= 2.29. */
#if defined(__clang__)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#endif
        status = posix_spawn_file_actions_addchdir_np(&actions, cwd);
#if defined(__clang__)
#pragma clang diagnostic pop
#endif
    }

    short flags = POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF;
#if defined(__APPLE__)
    flags |= POSIX_SPAWN_CLOEXEC_DEFAULT;
#endif
    if (new_session) {
        flags |= POSIX_SPAWN_SETSID;
    }
    sigset_t empty;
    sigset_t defaults;
    sigemptyset(&empty);
    sigemptyset(&defaults);
    sigaddset(&defaults, SIGPIPE);
    sigaddset(&defaults, SIGXFSZ);
    if (status == 0) {
        status = posix_spawnattr_setflags(&attributes, flags);
    }
    if (status == 0) {
        status = posix_spawnattr_setsigmask(&attributes, &empty);
    }
    if (status == 0) {
        status = posix_spawnattr_setsigdefault(&attributes, &defaults);
    }
    if (status == 0) {
        char *const *environment = envp != NULL ? envp : environ;
        status = strchr(file, '/') != NULL ? posix_spawn(pid_out, file, &actions, &attributes, argv, environment)
                                           : posix_spawnp(pid_out, file, &actions, &attributes, argv, environment);
    }
    posix_spawnattr_destroy(&attributes);
    posix_spawn_file_actions_destroy(&actions);
    return status;
}
