// Stub for <mach/shared_region.h> — not in public iOS SDK.
// dyld_cache_format.h includes it but the constants are not actually used
// by dsc_extractor.cpp/dsc_iterator.cpp; we expose just enough symbols
// that everything still compiles.

#ifndef _WP11_MACH_SHARED_REGION_STUB_H_
#define _WP11_MACH_SHARED_REGION_STUB_H_

// Common values from real <mach/shared_region.h> — provided for
// completeness; nothing in our subset of the dyld code path actually
// references them.
#ifndef SHARED_REGION_BASE_ARM64
#define SHARED_REGION_BASE_ARM64        0x180000000ULL
#define SHARED_REGION_SIZE_ARM64        0x100000000ULL
#endif

#ifndef SHARED_REGION_BASE
#define SHARED_REGION_BASE              SHARED_REGION_BASE_ARM64
#define SHARED_REGION_SIZE              SHARED_REGION_SIZE_ARM64
#endif

#endif
