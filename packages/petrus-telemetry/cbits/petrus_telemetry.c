/*
 * The two libc facts the memory gauges need. The `unix` package exposes
 * neither `ru_maxrss` nor a portable `_SC_PAGESIZE`, and both differ in layout
 * or value across platforms, so the C compiler resolves them here.
 */
#include <sys/resource.h>
#include <unistd.h>

/* getrusage(RUSAGE_SELF).ru_maxrss: bytes on Darwin, kilobytes elsewhere; -1 on error. */
long petrus_telemetry_max_rss(void)
{
    struct rusage usage;
    if (getrusage(RUSAGE_SELF, &usage) != 0) {
        return -1;
    }
    return (long)usage.ru_maxrss;
}

/* sysconf(_SC_PAGESIZE); -1 on error. */
long petrus_telemetry_page_size(void)
{
    return sysconf(_SC_PAGESIZE);
}

#include <errno.h>

/* ENOTCAPABLE where the platform defines it (CPython maps it to
 * PermissionError since 3.13); -1 elsewhere. */
int petrus_telemetry_enotcapable(void)
{
#ifdef ENOTCAPABLE
    return ENOTCAPABLE;
#else
    return -1;
#endif
}
