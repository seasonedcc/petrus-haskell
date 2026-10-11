#ifndef PETRUS_POSIX_H
#define PETRUS_POSIX_H

#include <stdint.h>
#include <sys/types.h>

int petrus_stat_at(int dirfd, const char *name, int nofollow, int64_t *out);
int petrus_dir_entry_count(int fd);
int petrus_wait_readable(int fd, int timeout_ms);
int petrus_wait_exited(pid_t pid);
int petrus_spawn(const char *file, char *const argv[], char *const envp[], const char *cwd, int new_session,
                 int stdin_fd, int stdout_fd, int stderr_fd, pid_t *pid_out);

#endif
