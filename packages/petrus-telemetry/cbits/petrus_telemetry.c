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
