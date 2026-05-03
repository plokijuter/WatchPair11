# WatchPair11 v8.0 — fully on-device Apple Pay pipeline

## What changed vs v7.19

In v7.19, supporting a new iOS build required the maintainer to :

1. Boot a Linux machine with the WatchPair11 source tree.
2. Extract `passd` from a copy of the target iOS dyld_shared_cache.
3. Run `scripts/build_passd_for_ios_version.sh <passd> <build>`.
4. Re-package the .deb and ship it.

That's friction — the maintainer needs the dsc, has to remember the
recipe, and users on a brand-new build are blocked until a re-release.

v8.0 removes the maintainer from the loop entirely. The same pipeline
runs on the iPhone the first time the user taps **Setup Apple Pay**
on a build for which we don't have a pre-signed binary. The result is
cached at `<jbroot>/opt/watchpair11/passd_signed_<BUILD>.bin` so all
subsequent setups are instant.

## On-device pipeline

```
[1] sw_vers -buildVersion                  → 21E236
[2] dsc_extractor /private/preboot/Cryptexes/OS/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e \
                  /tmp/wp11_extract/
[3] cp /tmp/wp11_extract/System/Library/PrivateFrameworks/PassKitCore.framework/passd \
      /tmp/wp11_passd
[4] dd : patch byte 8 (cpusubtype 0x80 → 0x00) — turns arm64e into arm64_ALL
[5] /var/jb/usr/bin/ldid -M -S/var/jb/opt/watchpair11/passd_ents.xml \
       -Icom.apple.passd /tmp/wp11_passd
[6] /var/jb/opt/watchpair11/ct_bypass_ios /tmp/wp11_passd
[7] mv /tmp/wp11_passd /var/jb/opt/watchpair11/passd_signed_${BUILD}.bin
[8] continue normal SysBins overlay + LaunchDaemon override + prefs + reload
```

Code lives in `scripts/setup-applepay.sh::build_passd_on_device()` and is
mirrored to `layout/opt/watchpair11/setup-applepay.sh` at .deb build time.

## Two new bundled binaries

### `ct_bypass_ios` (3.8 MB arm64e)

CoreTrust bypass (CVE-2023-41991), the iOS sibling of `ct_bypass_linux`
that we shipped to the maintainer's WSL host in v7.19. Same logic
(ChOma + fastPathSign coretrust_bug.c) but cross-compiled against the
iOS 16.5 SDK.

Source : `tools/ct_bypass_ios/`

- `src/main_ios.c` — CLI wrapper (no adhoc-sign step, ldid handles that).
- `src/coretrust_bug.c` + `src/coretrust_bug.h` — verbatim from
  TrollStore `Exploits/fastPathSign` at TS-pinned ChOma rev
  `964023ddac2286ef8e843f90df64d44ac6a673df`.
- `src/Templates/` — DER + signature + AppStore CodeDirectory templates,
  also from fastPathSign.
- `choma_src/` — vendored ChOma `src/` at the same TS-pinned rev (see
  `tools/fetch_external.sh` to refresh from upstream).
- `external/ios/{libcrypto.a,libssl.a}` — vendored from
  `opa334/ChOma/external/ios/` upstream (38 MB + 7.6 MB, gitignored).
  Run `bash tools/fetch_external.sh` before first build.
- `external/include/openssl/` — system OpenSSL 3 headers, staged at
  build time (host headers; the .a files are iOS arm64e binaries
  cross-built upstream).
- `tool_entitlements.xml` — `platform-application` + no-sandbox + no-container
  + skip-library-validation + get-task-allow.

Build :

```bash
bash tools/fetch_external.sh        # one time, pulls libcrypto/libssl
make -C tools/ct_bypass_ios FINALPACKAGE=1 THEOS=$HOME/theos
```

Why `arm64e` only ? `passd` itself is arm64e (PAC-signed). Anything
that touches the binary's signature blob runs in the same process,
no fat slice needed.

Why ABI warnings ? Theos clang-11 doesn't fully support arm64e ABI v2
yet — the warnings are cosmetic, the binary runs fine on iPhone 14/15.

### `dsc_extractor` (87 KB arm64e)

Extracts every dylib/binary from a dyld_shared_cache file. Source
adapted from Apple's open-source dyld project, release dyld-733.6
(APSL-2.0 — see `tools/dsc_extractor/src/APPLE_LICENSE` if/when we
add it; the file headers in dsc_extractor.cpp/h carry the license).

Why dyld-733.6 (iOS 13/14 era) and not dyld-1042 (iOS 17 era) ? The
old version is 883 lines + 255 lines of `dsc_iterator.cpp` + a handful
of headers — all self-contained in `launch-cache/`. The modern version
drags in MachOAnalyzer + Closure + a 3000-line build system. The cache
format hasn't changed in incompatible ways (the few new fields we don't
touch).

Two patches were needed :

1. **Stub the SPI digest validation** — `dsc_extractor.cpp` calls
   `CCDigest()` from `<CommonCrypto/CommonDigestSPI.h>` to verify each
   page hash against the cache code-signature. That SPI is not in the
   public iOS SDK. Since the cache lives on the user's own device,
   integrity is implied — we `#define WP11_SKIP_DIGEST_VALIDATION 1`
   and skip the per-page check. The early sanity checks (CS_SuperBlob
   layout, sizes) still run.

2. **Replace the modern `DyldSharedCache.h`** with a 12-line shim
   (`src/DyldSharedCache.h`) that exposes only the `dyld_cache_header`
   struct from `dyld_cache_format.h`. dsc_extractor.cpp only ever
   touches `cache->header.codeSignatureOffset / mappingOffset /
   localSymbolsOffset / localSymbolsSize`.

3. **Stub `<mach/shared_region.h>`** with empty `#define`s in
   `src/compat/mach/shared_region.h` — the header is included
   transitively but no constants are actually used by our subset.

Build :

```bash
make -C tools/dsc_extractor FINALPACKAGE=1 THEOS=$HOME/theos
```

## Sanity checks the script runs

Before invoking the on-device pipeline, `setup-applepay.sh` verifies :

- All four required tools exist and are executable
  (`dsc_extractor`, `ct_bypass_ios`, `ldid`, `passd_ents.xml`).
- The dyld_shared_cache exists at the expected path (modern
  `/private/preboot/Cryptexes/OS/...` first, falls back to legacy
  `/System/Library/Caches/...`).
- `/tmp` has at least 50 MB free (extraction needs ~30 MB).

If any check fails, the script bails with a one-line explanation
of what's missing and how to fix it.

## Fast paths preserved

The script tries paths in this order :

1. **`passd_signed_${BUILD}.bin` exists** — copy and go (~1 s).
2. **`passd_signed` legacy binary + we're on 20G75** — fall back, warn.
3. **On-device build** — extract + patch + sign + ct_bypass + cache.

Path 1 is the new default for users who upgrade from v7.19 on the
canonical build (`20G75`) — they see no slowdown. Path 3 fires only
when they land on a build we never built for, and it only fires once
per build (the result is cached for subsequent runs).

## Disk budget

| File                            | Size    | Notes                          |
|---------------------------------|---------|--------------------------------|
| ct_bypass_ios                   | 3.8 MB  | static libcrypto.a             |
| dsc_extractor                   | 87 KB   |                                |
| passd_signed_20G75.bin          | 6.9 MB  | already shipped in v7.19       |
| (other layout files)            | ~30 KB  | scripts + plists               |
| **Total before .deb compress**  | ~10.9 MB|                                |

The 38 MB libcrypto.a is **not** shipped in the .deb — it's a
build-time dependency only. The 3.8 MB `ct_bypass_ios` binary is what
ends up on the user's device.

## License attribution

The vendored Apple dyld sources under `tools/dsc_extractor/src/` are
APSL-2.0 (Apple Public Source License). When publishing the source
tarball or .deb, include a copy of `APPLE_LICENSE` from the
`apple-oss-distributions/dyld` project alongside the binary.

ChOma + TrollStore patches (under `tools/ct_bypass_ios/`) are MIT.

## Refreshing vendored sources

```bash
# ChOma + libcrypto/libssl iOS .a files
bash tools/fetch_external.sh

# To pin a different ChOma rev, edit the URL/branch in fetch_external.sh,
# then rerun. The TS-pinned rev (964023d) was chosen because TS' bundled
# coretrust_bug.c expects a specific ChOma API shape.
```
