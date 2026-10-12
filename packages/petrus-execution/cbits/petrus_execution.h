#ifndef PETRUS_EXECUTION_H
#define PETRUS_EXECUTION_H

#include <sys/types.h>

int petrus_wait_readable(int fd, int timeout_ms);
int petrus_wait_exited(pid_t pid);
int petrus_spawn(const char *file, char *const argv[], char *const envp[], const char *cwd, int new_session,
                 int stdin_fd, int stdout_fd, int stderr_fd, pid_t *pid_out);
void *petrus_bz2_open(void);
void petrus_bz2_close(void *stream);
int petrus_bz2_step(void *stream, const char *in, unsigned int in_len, char *out, unsigned int out_len,
                    unsigned int *used, unsigned int *produced);

#endif
