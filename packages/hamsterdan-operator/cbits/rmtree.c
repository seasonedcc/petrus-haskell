/* shutil.rmtree(path) as CPython 3.14 runs it on POSIX
 * (_rmtree_safe_fd): lstat the top, open it O_RDONLY | O_NONBLOCK, refuse
 * it when fstat does not name the same file (a symbolic link), list it
 * through a dup of the descriptor, unlink every entry that is not a
 * directory relative to that descriptor, descend into the directories
 * (last listed first) the same way, close, and rmdir relative to the
 * parent's descriptor. Every operation below the top is relative to an open
 * directory, so no path is resolved twice and no symbolic link is followed.
 *
 * Returns 0, or the errno of the first error that rmtree raises (EMLINK
 * stands for "Cannot call rmtree on a symbolic link", which carries no
 * errno). As in CPython, an entry that vanishes while the tree is walked is
 * skipped; only the top's own disappearance reports ENOENT. */
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

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
 * is_dir is -1 when that answer raised something other than ENOENT and 0
 * when the entry vanished (skipped, as CPython does). */
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
 * is nonzero for the path given to rmtree, whose ENOENT is reported. */
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
        return EMLINK;
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

int hamsterdan_rmtree(const char *path)
{
    return remove_tree(AT_FDCWD, path, 1);
}
