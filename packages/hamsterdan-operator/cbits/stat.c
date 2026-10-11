/* The struct stat fields the qualification fences inspect, for fstat,
 * lstat and fstatat(AT_SYMLINK_NOFOLLOW), and confstr(_CS_PATH). The unix
 * package has neither fstatat nor confstr. */
#include <fcntl.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/stat.h>
#include <unistd.h>

static void hamsterdan_fill(const struct stat *st, uint64_t *out)
{
    out[0] = (uint64_t)st->st_mode;
    out[1] = (uint64_t)st->st_uid;
    out[2] = (uint64_t)st->st_dev;
    out[3] = (uint64_t)st->st_ino;
    out[4] = (uint64_t)st->st_nlink;
    out[5] = (uint64_t)st->st_size;
}

int hamsterdan_fstat(int fd, uint64_t *out)
{
    struct stat st;
    int rc = fstat(fd, &st);
    if (rc == 0) hamsterdan_fill(&st, out);
    return rc;
}

int hamsterdan_lstat(const char *path, uint64_t *out)
{
    struct stat st;
    int rc = lstat(path, &st);
    if (rc == 0) hamsterdan_fill(&st, out);
    return rc;
}

int hamsterdan_fstatat_nofollow(int dirfd, const char *name, uint64_t *out)
{
    struct stat st;
    int rc = fstatat(dirfd, name, &st, AT_SYMLINK_NOFOLLOW);
    if (rc == 0) hamsterdan_fill(&st, out);
    return rc;
}

/* os.confstr("CS_PATH"): the buffer size the value needs (with its NUL),
 * or 0 when the system has none. */
size_t hamsterdan_cs_path(char *buf, size_t len)
{
    return confstr(_CS_PATH, buf, len);
}
