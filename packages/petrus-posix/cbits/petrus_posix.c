/*
 * Small POSIX shims for petrus-posix: the calls whose argument or result
 * structures differ between Linux and macOS (struct stat, struct rusage,
 * struct dirent), flattened into plain integers for the Haskell FFI.
 */
#define _GNU_SOURCE 1
#ifdef __APPLE__
#define _DARWIN_C_SOURCE 1
#endif

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <unistd.h>

#include "petrus_posix.h"

static void petrus_fill_stat(const struct stat *st, int64_t *out)
{
    out[0] = (int64_t)st->st_dev;
    out[1] = (int64_t)st->st_ino;
    out[2] = (int64_t)st->st_mode;
    out[3] = (int64_t)st->st_nlink;
    out[4] = (int64_t)st->st_uid;
    out[5] = (int64_t)st->st_gid;
    out[6] = (int64_t)st->st_size;
#ifdef __APPLE__
    out[7] = (int64_t)st->st_atimespec.tv_sec;
    out[8] = (int64_t)st->st_atimespec.tv_nsec;
    out[9] = (int64_t)st->st_mtimespec.tv_sec;
    out[10] = (int64_t)st->st_mtimespec.tv_nsec;
    out[11] = (int64_t)st->st_ctimespec.tv_sec;
    out[12] = (int64_t)st->st_ctimespec.tv_nsec;
#else
    out[7] = (int64_t)st->st_atim.tv_sec;
    out[8] = (int64_t)st->st_atim.tv_nsec;
    out[9] = (int64_t)st->st_mtim.tv_sec;
    out[10] = (int64_t)st->st_mtim.tv_nsec;
    out[11] = (int64_t)st->st_ctim.tv_sec;
    out[12] = (int64_t)st->st_ctim.tv_nsec;
#endif
}

int petrus_fstatat(int dirfd, const char *path, int nofollow, int64_t *out)
{
    struct stat st;
    int flags = nofollow ? AT_SYMLINK_NOFOLLOW : 0;
    if (fstatat(dirfd, path, &st, flags) != 0)
        return -1;
    petrus_fill_stat(&st, out);
    return 0;
}

int petrus_fstat(int fd, int64_t *out)
{
    struct stat st;
    if (fstat(fd, &st) != 0)
        return -1;
    petrus_fill_stat(&st, out);
    return 0;
}

/* lstat classification for realpath: 1 symlink, 0 anything else, -1 error. */
int petrus_lstat_kind(const char *path)
{
    struct stat st;
    if (lstat(path, &st) != 0)
        return -1;
    return S_ISLNK(st.st_mode) ? 1 : 0;
}

/* open(2) with O_CLOEXEC added, as every Python descriptor is non-inheritable. */
int petrus_open(const char *path, int flags, mode_t mode)
{
    return open(path, flags | O_CLOEXEC, mode);
}

int petrus_at_fdcwd(void) { return AT_FDCWD; }
int petrus_at_removedir(void) { return AT_REMOVEDIR; }

/* ru_maxrss of RUSAGE_SELF: bytes on Darwin, kibibytes on Linux. */
int petrus_maxrss(int64_t *out)
{
    struct rusage usage;
    if (getrusage(RUSAGE_SELF, &usage) != 0)
        return -1;
    *out = (int64_t)usage.ru_maxrss;
    return 0;
}

long petrus_page_size(void) { return sysconf(_SC_PAGESIZE); }

/*
 * Directory listing from a descriptor. The descriptor is duplicated so the
 * caller keeps ownership of its own; the stream is closed by petrus_closedir.
 */
void *petrus_fdopendir(int fd)
{
    int copy = fcntl(fd, F_DUPFD_CLOEXEC, 0);
    if (copy < 0)
        return NULL;
    DIR *dir = fdopendir(copy);
    if (dir == NULL) {
        int saved = errno;
        close(copy);
        errno = saved;
        return NULL;
    }
    rewinddir(dir);
    return dir;
}

/*
 * The next entry name, or NULL at the end (errno 0) or on error (errno set).
 * *kind is what d_type says of the entry without following a link: 1 a
 * directory, 0 anything else, -1 not known (DT_UNKNOWN).
 */
const char *petrus_readdir(void *dir, int *kind)
{
    errno = 0;
    struct dirent *entry = readdir((DIR *)dir);
    if (entry == NULL)
        return NULL;
    *kind = entry->d_type == DT_UNKNOWN ? -1 : entry->d_type == DT_DIR ? 1 : 0;
    return entry->d_name;
}

int petrus_closedir(void *dir) { return closedir((DIR *)dir); }
