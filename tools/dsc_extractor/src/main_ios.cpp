// dsc_extractor — on-device dyld_shared_cache extractor for WatchPair11 v8.0
//
// Calls the static dyld_shared_cache_extract_dylibs_progress() function
// from Apple's open-source dsc_extractor.cpp (APSL-licensed). Produces
// extracted dylib/binary files under <out_dir>/ following the original
// install paths from inside the cache.
//
// Usage: dsc_extractor <path-to-cache-file> <path-to-out-dir>

#include <stdio.h>
#include <string.h>
#include "dsc_extractor.h"

int main(int argc, const char* argv[])
{
    if (argc != 3) {
        fprintf(stderr,
            "Usage: %s <path-to-shared-cache> <path-to-out-dir>\n"
            "Extracts every dylib/binary embedded in an iOS dyld_shared_cache\n"
            "into <out-dir>/ preserving original install paths.\n",
            argv[0]);
        return 1;
    }

    fprintf(stderr, "[dsc] Extracting %s -> %s\n", argv[1], argv[2]);

    int result = dyld_shared_cache_extract_dylibs_progress(
        argv[1], argv[2],
        ^(unsigned current, unsigned total) {
            // Emit progress lines every ~10% so the WatchPair11 installer-app
            // log doesn't stay silent for 30+ seconds during extraction.
            static unsigned lastPct = 0;
            if (total > 0) {
                unsigned pct = (100u * current) / total;
                if (pct >= lastPct + 10 || current == total) {
                    fprintf(stderr, "[dsc] %u/%u (%u%%)\n", current, total, pct);
                    lastPct = pct;
                }
            }
        });

    fprintf(stderr, "[dsc] dyld_shared_cache_extract_dylibs_progress() => %d\n", result);
    return result;
}
