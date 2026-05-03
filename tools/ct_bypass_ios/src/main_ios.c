// ct_bypass_ios — on-device CoreTrust bypass for WatchPair11 v8.0
//
// Standalone tool that runs on the iPhone itself. Takes an ldid-signed
// arm64 Mach-O binary and patches the embedded CMS signature blob so that
// CoreTrust (CVE-2023-41991) accepts it as legitimately Apple-signed.
//
// This is the iOS sibling of ct_bypass_linux. The CT bypass logic is
// identical (ChOma + fastPathSign coretrust_bug.c). The only difference
// is platform : iOS uses CoreFoundation directly (no libplist patch),
// links against the system libcrypto from the SDK, and runs on arm64e.
//
// Usage:
//   ct_bypass_ios <macho_path>
//
// The binary is patched in-place. Caller must back up beforehand if
// needed (the WatchPair11 setup script does).

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include "FAT.h"
#include "MachO.h"
#include "FileStream.h"

#define CPU_TYPE_ARM64 0x0100000c
#define CPU_SUBTYPE_ARM64_ALL 0
#define CPU_SUBTYPE_ARM64E 2
#define CPU_SUBTYPE_ARM64_V8 1

int apply_coretrust_bypass(const char *machoPath);

static char *extract_preferred_slice(const char *fatPath)
{
    FAT *fat = fat_init_from_path(fatPath);
    if (!fat) return NULL;
    MachO *macho = fat_find_preferred_slice(fat);
    if (!macho) {
        // Fall back to any arm64 variant
        macho = fat_find_slice(fat, CPU_TYPE_ARM64, CPU_SUBTYPE_ARM64_ALL);
        if (!macho) macho = fat_find_slice(fat, CPU_TYPE_ARM64, CPU_SUBTYPE_ARM64_V8);
        if (!macho) macho = fat_find_slice(fat, CPU_TYPE_ARM64, CPU_SUBTYPE_ARM64E);
        if (!macho) {
            fat_free(fat);
            return NULL;
        }
    }

    char *temp = strdup("/tmp/ctbpiosXXXXXX");
    int fd = mkstemp(temp);
    if (fd < 0) {
        perror("mkstemp");
        free(temp);
        fat_free(fat);
        return NULL;
    }
    close(fd);

    MemoryStream *outStream = file_stream_init_from_path(temp, 0, 0,
        FILE_STREAM_FLAG_WRITABLE | FILE_STREAM_FLAG_AUTO_EXPAND);
    MemoryStream *machoStream = macho_get_stream(macho);
    memory_stream_copy_data(machoStream, 0, outStream, 0,
        memory_stream_get_size(machoStream));

    fat_free(fat);
    memory_stream_free(outStream);
    return temp;
}

int main(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr,
            "Usage: %s <macho_path>\n"
            "Applies CoreTrust bypass (CVE-2023-41991) to an iOS arm64 Mach-O.\n"
            "The binary must already be ldid-signed with the desired entitlements.\n",
            argv[0]);
        return 1;
    }

    const char *input = argv[1];
    printf("[ctb-ios] Input: %s\n", input);

    char *machoPath = extract_preferred_slice(input);
    if (!machoPath) {
        fprintf(stderr, "[ctb-ios] Failed extracting preferred slice (not arm64?)\n");
        return 1;
    }
    printf("[ctb-ios] Extracted slice to %s\n", machoPath);

    printf("[ctb-ios] Applying CoreTrust bypass...\n");
    int r = apply_coretrust_bypass(machoPath);
    if (r != 0) {
        fprintf(stderr, "[ctb-ios] Failed CoreTrust bypass (rc=%d)\n", r);
        unlink(machoPath);
        free(machoPath);
        return r;
    }

    // Copy patched slice back over the input in-place
    FILE *src = fopen(machoPath, "rb");
    FILE *dst = fopen(input, "wb");
    if (!src || !dst) {
        perror("fopen");
        if (src) fclose(src);
        if (dst) fclose(dst);
        unlink(machoPath);
        free(machoPath);
        return 1;
    }
    char buf[65536];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), src)) > 0) {
        if (fwrite(buf, 1, n, dst) != n) {
            perror("fwrite");
            break;
        }
    }
    fclose(src);
    fclose(dst);
    unlink(machoPath);
    free(machoPath);

    chmod(input, 0755);
    printf("[ctb-ios] CoreTrust bypass applied to %s\n", input);
    return 0;
}
