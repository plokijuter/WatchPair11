// Minimal shim for the modern dyld DyldSharedCache.h.
//
// dsc_extractor.cpp only touches `dyldSharedCache->header.<field>`. The
// modern wrapper class drags MachOAnalyzer + Closure + 100+ extra files
// — way too heavy for an on-device tool. The dyld_cache_header struct
// from dyld_cache_format.h is the only thing we actually need.
//
// This shim is a single-translation-unit drop-in for ports that don't
// need the closure/analyzer machinery.

#ifndef DyldSharedCache_h_SHIM
#define DyldSharedCache_h_SHIM

#include "dyld_cache_format.h"

class DyldSharedCache {
public:
    dyld_cache_header header;
};

#endif // DyldSharedCache_h_SHIM
