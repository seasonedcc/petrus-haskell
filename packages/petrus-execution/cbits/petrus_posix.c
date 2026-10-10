/* Small POSIX helpers for Petrus.Motus.Execution.Internal.Posix.
 *
 * Seam: these belong to petrus-posix; see the Haskell module header. */
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdint.h>
#include <sys/stat.h>
#include <unistd.h>

#if defined(__APPLE__)
#define PETRUS_MTIME_NS(s) ((int64_t)(s).st_mtimespec.tv_sec * 1000000000 + (s).st_mtimespec.tv_nsec)
#define PETRUS_CTIME_NS(s) ((int64_t)(s).st_ctimespec.tv_sec * 1000000000 + (s).st_ctimespec.tv_nsec)
#else
#define PETRUS_MTIME_NS(s) ((int64_t)(s).st_mtim.tv_sec * 1000000000 + (s).st_mtim.tv_nsec)
#define PETRUS_CTIME_NS(s) ((int64_t)(s).st_ctim.tv_sec * 1000000000 + (s).st_ctim.tv_nsec)
#endif

/* out[0..7] = dev, ino, mode, uid, nlink, size, mtime_ns, ctime_ns.
 * name == NULL means fstat(dirfd). Returns 0 or -1 (errno set). */
int petrus_stat_at(int dirfd, const char *name, int nofollow, int64_t *out)
{
    struct stat st;
    int rc = name == NULL ? fstat(dirfd, &st)
                          : fstatat(dirfd, name, &st, nofollow ? AT_SYMLINK_NOFOLLOW : 0);
    if (rc != 0)
        return -1;
    out[0] = (int64_t)st.st_dev;
    out[1] = (int64_t)st.st_ino;
    out[2] = (int64_t)st.st_mode;
    out[3] = (int64_t)st.st_uid;
    out[4] = (int64_t)st.st_nlink;
    out[5] = (int64_t)st.st_size;
    out[6] = PETRUS_MTIME_NS(st);
    out[7] = PETRUS_CTIME_NS(st);
    return 0;
}

/* Number of entries other than "." and ".." in the directory open as fd
 * (the descriptor itself is left open). -1 on error (errno set). */
int petrus_dir_entry_count(int fd)
{
    int copy = dup(fd);
    if (copy < 0)
        return -1;
    DIR *dir = fdopendir(copy);
    if (dir == NULL) {
        int saved = errno;
        close(copy);
        errno = saved;
        return -1;
    }
    rewinddir(dir);
    int count = 0;
    struct dirent *entry;
    errno = 0;
    while ((entry = readdir(dir)) != NULL) {
        const char *n = entry->d_name;
        if (n[0] == '.' && (n[1] == '\0' || (n[1] == '.' && n[2] == '\0')))
            continue;
        count++;
    }
    int saved = errno;
    closedir(dir);
    if (saved != 0) {
        errno = saved;
        return -1;
    }
    return count;
}

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
