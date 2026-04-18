/* Minimal Linux stub for sys/sysctl.h — ChOma's Host.c uses sysctlbyname 
 * which we replace with hardcoded values since we're on Linux and don't
 * care about the host CPU (we're targeting arm64). */
#ifndef _COMPAT_SYS_SYSCTL_H
#define _COMPAT_SYS_SYSCTL_H
#include <stddef.h>
static inline int sysctlbyname(const char *name, void *oldp, size_t *oldlenp,
                                 const void *newp, size_t newlen) {
    /* Return error to force ChOma to assume arm64 defaults or whatever */
    return -1;
}
#endif
