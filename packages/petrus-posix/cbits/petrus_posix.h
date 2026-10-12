#ifndef PETRUS_POSIX_H
#define PETRUS_POSIX_H

#include <stdint.h>
#include <sys/types.h>

int petrus_fstatat(int dirfd, const char *path, int nofollow, int64_t *out);
int petrus_fstat(int fd, int64_t *out);
int petrus_lstat_kind(const char *path);
int petrus_open(const char *path, int flags, mode_t mode);
int petrus_at_fdcwd(void);
int petrus_at_removedir(void);
int petrus_maxrss(int64_t *out);
long petrus_page_size(void);
void *petrus_fdopendir(int fd);
const char *petrus_readdir(void *dir, int *kind);
int petrus_closedir(void *dir);

#endif
