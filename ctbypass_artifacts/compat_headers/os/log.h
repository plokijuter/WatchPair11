/* Linux no-op stub for os/log.h */
#ifndef _COMPAT_OS_LOG_H
#define _COMPAT_OS_LOG_H
#include <stdio.h>
#define OS_LOG_DEFAULT NULL
#define os_log_t void*
#define os_log_create(subsys, cat) NULL
#define os_log(log, fmt, ...) do { fprintf(stderr, fmt "\n", ##__VA_ARGS__); } while(0)
#define os_log_info(log, fmt, ...) do { fprintf(stderr, fmt "\n", ##__VA_ARGS__); } while(0)
#define os_log_debug(log, fmt, ...) do {} while(0)
#define os_log_error(log, fmt, ...) do { fprintf(stderr, fmt "\n", ##__VA_ARGS__); } while(0)
#define os_log_fault(log, fmt, ...) do { fprintf(stderr, fmt "\n", ##__VA_ARGS__); } while(0)
#endif
