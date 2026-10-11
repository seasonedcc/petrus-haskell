/*
 * fs.readFileSync's system calls for Petrus.Viewer.FileIO: open the file
 * and learn its size in one foreign call.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

/* open(path, O_RDONLY | O_CLOEXEC); *size is the size of a regular file and
 * -1 for anything else. Returns the descriptor, or -1 with errno set. */
int petrus_open_read(const char *path, long *size)
{
    int fd;
    do {
        fd = open(path, O_RDONLY | O_CLOEXEC);
    } while (fd < 0 && errno == EINTR);
    if (fd < 0)
        return -1;
    struct stat st;
    *size = (fstat(fd, &st) == 0 && S_ISREG(st.st_mode)) ? (long)st.st_size : -1;
    return fd;
}
