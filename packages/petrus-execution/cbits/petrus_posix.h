#ifndef PETRUS_POSIX_H
#define PETRUS_POSIX_H

#include <stdint.h>

int petrus_stat_at(int dirfd, const char *name, int nofollow, int64_t *out);
int petrus_dir_entry_count(int fd);

#endif
