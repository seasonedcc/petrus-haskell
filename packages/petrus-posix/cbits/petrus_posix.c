/*
 * Small POSIX shims for petrus-posix: the calls whose argument or result
 * structures differ between Linux and macOS (struct stat, struct rusage,
 * struct dirent, struct pollfd, the EAI_* set), flattened into plain
 * integers for the Haskell FFI; and shutil.rmtree's walk (petrus_rmtree).
 */
#define _GNU_SOURCE 1
#ifdef __APPLE__
#define _DARWIN_C_SOURCE 1
#endif

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <poll.h>
#include <stdint.h>
#include <stdlib.h>
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

/* The next entry name, or NULL at the end (errno 0) or on error (errno set). */
const char *petrus_readdir(void *dir)
{
    errno = 0;
    struct dirent *entry = readdir((DIR *)dir);
    return entry == NULL ? NULL : entry->d_name;
}

int petrus_closedir(void *dir) { return closedir((DIR *)dir); }

/*
 * Wait until fd is readable, in error or hung up (1), or timeout_ms elapses
 * (0); -errno when poll fails (-EINTR when a signal, such as the RTS
 * interrupting this call, arrived).
 */
int petrus_wait_readable(int fd, int timeout_ms)
{
    struct pollfd entry;
    entry.fd = fd;
    entry.events = POLLIN;
    entry.revents = 0;
    int ready = poll(&entry, 1, timeout_ms);
    if (ready < 0)
        return -errno;
    return ready > 0 ? 1 : 0;
}

/*
 * The getaddrinfo error codes <netdb.h> defines on this system, ending with
 * 0 (which no EAI_* code is).
 */
static const int gai_codes[] = {
    EAI_AGAIN, EAI_BADFLAGS, EAI_FAIL, EAI_FAMILY, EAI_MEMORY, EAI_NONAME,
    EAI_SERVICE, EAI_SOCKTYPE, EAI_SYSTEM, EAI_OVERFLOW,
#ifdef EAI_ADDRFAMILY
    EAI_ADDRFAMILY,
#endif
#if defined(EAI_NODATA) && (!defined(EAI_NONAME) || EAI_NODATA != EAI_NONAME)
    EAI_NODATA,
#endif
#ifdef EAI_BADHINTS
    EAI_BADHINTS,
#endif
#ifdef EAI_PROTOCOL
    EAI_PROTOCOL,
#endif
#ifdef EAI_INPROGRESS
    EAI_INPROGRESS,
#endif
#ifdef EAI_CANCELED
    EAI_CANCELED,
#endif
#ifdef EAI_NOTCANCELED
    EAI_NOTCANCELED,
#endif
#ifdef EAI_ALLDONE
    EAI_ALLDONE,
#endif
#ifdef EAI_INTR
    EAI_INTR,
#endif
#ifdef EAI_IDN_ENCODE
    EAI_IDN_ENCODE,
#endif
    0};

const int *petrus_gai_codes(void) { return gai_codes; }

/*
 * shutil.rmtree(path) as CPython 3.14 runs it on POSIX (_rmtree_safe_fd):
 * lstat the top, open it O_RDONLY | O_NONBLOCK, refuse it when fstat does
 * not name the same file (a symbolic link), list it through a dup of the
 * descriptor, unlink every entry that is not a directory relative to that
 * descriptor, descend into the directories (last listed first) the same
 * way, close, and rmdir relative to the parent's descriptor. Every operation
 * below the top is relative to an open directory, so no path is resolved
 * twice and no symbolic link is followed.
 *
 * Returns 0, the errno of the first error that rmtree raises, or -1 for
 * "Cannot call rmtree on a symbolic link" (which carries no errno). As in
 * CPython, an entry that vanishes while the tree is walked is skipped; only
 * the top's own disappearance reports ENOENT.
 *
 * The walk is C, one foreign call in all, because the same walk over this
 * package's openat primitives (a foreign call per system call) left
 * hamsterdan-operator's qualification-setup row level with the reference
 * (1.00x in four interleaved full runs on the Apple M4, 2026-10-12) where
 * this one keeps it ahead (1.02-1.05x); see that package's bench/RESULTS.md.
 */

struct entry {
    char *name;
    int is_dir;
};

static void free_entries(struct entry *entries, size_t count)
{
    for (size_t i = 0; i < count; i++) free(entries[i].name);
    free(entries);
}

/* list(os.scandir(fd)) with each entry's is_dir(follow_symlinks=False);
 * is_dir is 1 for a directory, 0 otherwise, -1 when that answer raised
 * something other than ENOENT, and 2 when the entry vanished (skipped, as
 * CPython does). */
static int scan(int fd, struct entry **out, size_t *count)
{
    int copy = dup(fd);
    if (copy < 0) return errno;
    DIR *dir = fdopendir(copy);
    if (dir == NULL) {
        int err = errno;
        close(copy);
        return err;
    }
    size_t capacity = 16, used = 0;
    struct entry *entries = malloc(capacity * sizeof *entries);
    if (entries == NULL) {
        closedir(dir);
        return ENOMEM;
    }
    for (;;) {
        errno = 0;
        struct dirent *item = readdir(dir);
        if (item == NULL) {
            int err = errno;
            if (err != 0) {
                closedir(dir);
                free_entries(entries, used);
                return err;
            }
            break;
        }
        if (strcmp(item->d_name, ".") == 0 || strcmp(item->d_name, "..") == 0) continue;
        if (used == capacity) {
            struct entry *grown = realloc(entries, 2 * capacity * sizeof *entries);
            if (grown == NULL) {
                closedir(dir);
                free_entries(entries, used);
                return ENOMEM;
            }
            entries = grown;
            capacity *= 2;
        }
        char *name = strdup(item->d_name);
        if (name == NULL) {
            closedir(dir);
            free_entries(entries, used);
            return ENOMEM;
        }
        int is_dir;
        if (item->d_type == DT_UNKNOWN) {
            struct stat st;
            if (fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0)
                is_dir = S_ISDIR(st.st_mode) ? 1 : 0;
            else
                is_dir = errno == ENOENT ? 2 : -1;
        } else {
            is_dir = item->d_type == DT_DIR ? 1 : 0;
        }
        entries[used].name = name;
        entries[used].is_dir = is_dir;
        used++;
    }
    closedir(dir);
    *out = entries;
    *count = used;
    return 0;
}

/* One stack item of _rmtree_safe_fd_step plus everything it pushes. `top`
 * is nonzero for the path given to rmtree, whose ENOENT is reported.
 * Returns 0, an errno, or -1 for a directory that is a symbolic link. */
static int remove_tree(int dirfd, const char *name, int top)
{
    struct stat orig, now;
    if (fstatat(dirfd, name, &orig, AT_SYMLINK_NOFOLLOW) != 0)
        return (errno == ENOENT && !top) ? 0 : errno;
    int fd = openat(dirfd, name, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return (errno == ENOENT && !top) ? 0 : errno;
    if (fstat(fd, &now) != 0) {
        int err = errno;
        close(fd);
        return (err == ENOENT && !top) ? 0 : err;
    }
    if (orig.st_dev != now.st_dev || orig.st_ino != now.st_ino) {
        close(fd);
        return -1;
    }
    struct entry *entries = NULL;
    size_t count = 0;
    int err = scan(fd, &entries, &count);
    if (err != 0) {
        close(fd);
        return (err == ENOENT && !top) ? 0 : err;
    }
    for (size_t i = 0; i < count; i++) {
        if (entries[i].is_dir == 1 || entries[i].is_dir == 2) continue;
        if (unlinkat(fd, entries[i].name, 0) != 0 && errno != ENOENT) {
            err = errno;
            free_entries(entries, count);
            close(fd);
            return err;
        }
    }
    for (size_t i = count; i > 0; i--) {
        if (entries[i - 1].is_dir != 1) continue;
        err = remove_tree(fd, entries[i - 1].name, 0);
        if (err != 0) {
            free_entries(entries, count);
            close(fd);
            return err;
        }
    }
    free_entries(entries, count);
    if (close(fd) != 0) return errno;
    if (unlinkat(dirfd, name, AT_REMOVEDIR) != 0) return (errno == ENOENT && !top) ? 0 : errno;
    return 0;
}

int petrus_rmtree(const char *path)
{
    return remove_tree(AT_FDCWD, path, 1);
}
