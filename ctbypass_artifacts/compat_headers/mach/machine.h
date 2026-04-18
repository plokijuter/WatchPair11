/* Minimal Linux stub for mach/machine.h */
#ifndef _COMPAT_MACH_MACHINE_H
#define _COMPAT_MACH_MACHINE_H

#include <stdint.h>

typedef int32_t cpu_type_t;
typedef int32_t cpu_subtype_t;
typedef int32_t cpu_threadtype_t;
typedef int integer_t;
typedef unsigned int natural_t;

/* Common cpu_type_t values (subset) */
#define CPU_ARCH_ABI64      0x01000000
#define CPU_ARCH_ABI64_32   0x02000000
#define CPU_TYPE_ANY        ((cpu_type_t) -1)
#define CPU_TYPE_I386       ((cpu_type_t) 7)
#define CPU_TYPE_X86        CPU_TYPE_I386
#define CPU_TYPE_X86_64     (CPU_TYPE_X86 | CPU_ARCH_ABI64)
#define CPU_TYPE_ARM        ((cpu_type_t) 12)
#define CPU_TYPE_ARM64      (CPU_TYPE_ARM | CPU_ARCH_ABI64)
#define CPU_TYPE_ARM64_32   (CPU_TYPE_ARM | CPU_ARCH_ABI64_32)

#define CPU_SUBTYPE_MASK    0xff000000
#define CPU_SUBTYPE_LIB64   0x80000000

#define CPU_SUBTYPE_ARM64_ALL ((cpu_subtype_t) 0)
#define CPU_SUBTYPE_ARM64_V8  ((cpu_subtype_t) 1)
#define CPU_SUBTYPE_ARM64E    ((cpu_subtype_t) 2)

/* ARM subtypes for 32-bit */
#define CPU_SUBTYPE_ARM_ALL    ((cpu_subtype_t) 0)
#define CPU_SUBTYPE_ARM_V4T    ((cpu_subtype_t) 5)
#define CPU_SUBTYPE_ARM_V6     ((cpu_subtype_t) 6)
#define CPU_SUBTYPE_ARM_V5TEJ  ((cpu_subtype_t) 7)
#define CPU_SUBTYPE_ARM_XSCALE ((cpu_subtype_t) 8)
#define CPU_SUBTYPE_ARM_V7     ((cpu_subtype_t) 9)
#define CPU_SUBTYPE_ARM_V7F    ((cpu_subtype_t) 10)
#define CPU_SUBTYPE_ARM_V7S    ((cpu_subtype_t) 11)
#define CPU_SUBTYPE_ARM_V7K    ((cpu_subtype_t) 12)
#define CPU_SUBTYPE_ARM_V6M    ((cpu_subtype_t) 14)
#define CPU_SUBTYPE_ARM_V7M    ((cpu_subtype_t) 15)
#define CPU_SUBTYPE_ARM_V7EM   ((cpu_subtype_t) 16)

#endif
