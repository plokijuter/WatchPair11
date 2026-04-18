// Linux port of fastPathSign — only the CT bypass portion, no adhoc sign
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
        macho = fat_find_slice(fat, CPU_TYPE_ARM64, CPU_SUBTYPE_ARM64_ALL);
        if (!macho) macho = fat_find_slice(fat, CPU_TYPE_ARM64, CPU_SUBTYPE_ARM64_V8);
        if (!macho) macho = fat_find_slice(fat, CPU_TYPE_ARM64, CPU_SUBTYPE_ARM64E);
        if (!macho) {
            fat_free(fat);
            return NULL;
        }
    }

    char *temp = strdup("/tmp/fpsXXXXXX");
    int fd = mkstemp(temp);
    if (fd < 0) {
        perror("mkstemp");
        free(temp);
        fat_free(fat);
        return NULL;
    }
    close(fd);

    MemoryStream *outStream = file_stream_init_from_path(temp, 0, 0, FILE_STREAM_FLAG_WRITABLE | FILE_STREAM_FLAG_AUTO_EXPAND);
    MemoryStream *machoStream = macho_get_stream(macho);
    memory_stream_copy_data(machoStream, 0, outStream, 0, memory_stream_get_size(machoStream));

    fat_free(fat);
    memory_stream_free(outStream);
    return temp;
}

int main(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <macho_path>\n", argv[0]);
        fprintf(stderr, "Applies CoreTrust bypass (CVE-2023-41991) to an iOS arm64 Mach-O binary.\n");
        fprintf(stderr, "Binary should already be ldid-signed with desired entitlements.\n");
        return 1;
    }

    const char *input = argv[1];
    printf("Input: %s\n", input);

    // Extract preferred slice (handles fat binaries)
    char *machoPath = extract_preferred_slice(input);
    if (!machoPath) {
        fprintf(stderr, "Failed extracting preferred slice (not a valid Mach-O/FAT?)\n");
        return 1;
    }
    printf("Extracted slice to %s\n", machoPath);

    printf("Applying CoreTrust bypass...\n");
    int r = apply_coretrust_bypass(machoPath);
    if (r != 0) {
        fprintf(stderr, "Failed applying CoreTrust bypass (%d)\n", r);
        unlink(machoPath);
        free(machoPath);
        return r;
    }

    // Copy the patched slice back over the input (in-place)
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
    printf("Applied CoreTrust Bypass to %s\n", input);
    return 0;
}
