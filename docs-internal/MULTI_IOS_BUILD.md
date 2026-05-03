# Multi-iOS Apple Pay build pipeline (v7.19+)

How to add Apple Pay support for a new iOS build (16.x, 17.x, 18.x, …) to
WatchPair11.

## Why we need a per-build binary

See `docs-internal/passd-patches-audit.md` for the deep analysis.

**TL;DR**: WatchPair11's Apple Pay flow needs a single byte patch on Apple's
`passd` binary (Mach-O cpusubtype field at offset +8 — `arm64e` → `arm64`)
so it satisfies CoreTrust CPU subtype validation after our CT bypass is
applied. Every other Apple Pay bypass (7 hooks + 3 CFPreferences keys) is a
runtime hook in `Tweak.xm` that works unchanged across iOS versions.

That means: **one `Tweak.xm` for all iOS builds, but one signed `passd`
binary per iOS build**. The pipeline below is fully mechanical.

## Naming convention

Per-build binaries live in `layout/opt/watchpair11/` and follow:

    passd_signed_<APPLE_BUILD_ID>.bin

Examples:
- `passd_signed_20G75.bin`  → iOS 16.6 (20G75)
- `passd_signed_21E236.bin` → iOS 17.4.1 (21E236)
- `passd_signed_22A3354.bin` → iOS 18.0 (22A3354)

The on-device `setup-applepay.sh` reads `sw_vers -buildVersion` and picks
the matching `.bin`. If none matches, it prints the list of supported
builds and aborts.

## Step 1 — Extract `passd` from the target iOS dyld_shared_cache

You need a copy of the iOS firmware (.ipsw) for the target build.

```bash
# Install ipsw (https://github.com/blacktop/ipsw)
brew install blacktop/tap/ipsw   # macOS
# or download a binary release for Linux

# Download the .ipsw (or use ipsw download)
ipsw download ipsw --device iPhone15,2 --build 21E236

# Extract dyld_shared_cache from the .ipsw
ipsw extract --dyld iPhone15,2_17.4.1_21E236_Restore.ipsw

# This drops dyld_shared_cache_arm64e (and friends) in the current dir.
# Pull the passd binary out of the cache:
ipsw dyld extract \
    dyld_shared_cache_arm64e \
    /System/Library/PrivateFrameworks/PassKitCore.framework/passd \
    --output /tmp/passd_21E236
```

You now have an unmodified `passd` Mach-O at `/tmp/passd_21E236` (typically
~7 MB, thin arm64e).

> Note: if your extraction tool produces a fat binary, run
> `lipo -thin arm64e <fat> -output passd_thin` first — the build script
> only accepts thin Mach-Os.

## Step 2 — Build `ct_bypass_linux` (one-time)

If you haven't already:

```bash
cd ctbypass_artifacts
bash build_linux_ctbp.sh
# Output: /tmp/ts_build/out/ct_bypass_linux
# Or copy it to ctbypass_artifacts/ct_bypass_linux for the build script to find it
cp /tmp/ts_build/out/ct_bypass_linux ./ct_bypass_linux
```

Tooling required (Linux WSL):
- `clang` (with `libBlocksRuntime` headers)
- `libcrypto-dev` (OpenSSL)
- `libplist-2.0-dev`
- `ldid` (`$HOME/theos/toolchain/linux/iphone/bin/ldid`)

## Step 3 — Run the pipeline

```bash
bash scripts/build_passd_for_ios_version.sh \
    /tmp/passd_21E236 \
    21E236
```

This will:
1. Validate the input is a thin arm64/arm64e Mach-O
2. Patch `cpusubtype` (offset +8) `arm64e` → `arm64_ALL`
3. `ldid -S<passd_ents.xml> -Icom.apple.passd` (preserves restricted ents)
4. `ct_bypass_linux` (CVE-2023-41991 trust-bypass code signature)
5. Verify (size, magic, ldid identifier, strings)
6. Write `layout/opt/watchpair11/passd_signed_21E236.bin`

The script is **idempotent** — re-running on an already-patched binary
prints a warning and proceeds (the `cpusubtype` patch becomes a no-op).

Override paths via env vars if needed:

```bash
CT_BYPASS=/path/to/ct_bypass_linux \
LDID=/path/to/ldid \
ENTS_XML=/path/to/custom_ents.xml \
    bash scripts/build_passd_for_ios_version.sh /tmp/passd 21E236
```

## Step 4 — Add the binary to the .deb

The `.deb` packaging picks up everything under `layout/opt/watchpair11/`
automatically. Just rebuild:

```bash
make package FINALPACKAGE=1 THEOS=$HOME/theos
ls -la packages/com.watchpair11_*.deb
```

Verify the binary is bundled:

```bash
dpkg -c packages/com.watchpair11_7.19-*.deb | grep passd_signed
```

## Step 5 — Release a new version

1. Bump `Version:` in `control` (e.g. `7.19-1` → `7.19-2`)
2. Add a one-liner to the `## Changelog` section of `README.md` mentioning
   the new supported builds
3. Rebuild the .deb
4. Copy the new .deb into `docs/debs/`
5. Run `bash scripts/regen-apt-repo.sh` to refresh the APT metadata
6. `git add` everything (including the new `passd_signed_*.bin`), commit
   and push

The on-device installer (home-screen app) requires no changes — it shells
out to `setup-applepay.sh`, which now does build detection.

## Troubleshooting

### "No matching passd binary for build XXXX" on device

The user's iOS build doesn't have a bundled binary. Either ship one
(steps above) or have them open an issue with their `sw_vers
-buildVersion` output.

### `ct_bypass_linux` returns "ERROR: no cputype" but still completes

This is benign — it's an early diagnostic from ChOma's FAT parser when fed
a thin Mach-O. The bypass continues correctly. Verify with the final
"Applied CoreTrust Bypass to ..." message.

### Device hits safe mode after install

Run rollback:

```bash
sudo bash /var/jb/opt/watchpair11/rollback-applepay.sh
```

Common causes :
- Wrong build binary used (check `sw_vers -buildVersion`)
- `passd_ents.xml` missing a per-build entitlement Apple added in 17/18
- ct_bypass produced an invalid signature (re-extract `passd` and re-run)

### Adding builds where `passd` symbols changed

The audit assumes the 7 NPK\* C symbols and the
`canAddSecureElementPassWithConfiguration:completion:` ObjC selector are
stable across iOS 16/17/18. If Apple renames or removes any of them,
`Tweak.xm` will need a per-version conditional. Check
`/var/tmp/wp11.log` after install — the witness file
`/var/tmp/wp11_passd.txt` confirms hook load.

## Files

- Pipeline script : `scripts/build_passd_for_ios_version.sh`
- ct_bypass tool source : `ctbypass_artifacts/main_linux.c`
- Entitlements XML : `layout/opt/watchpair11/passd_ents.xml`
- Per-build binaries : `layout/opt/watchpair11/passd_signed_<BUILD>.bin`
- On-device setup : `layout/opt/watchpair11/setup-applepay.sh` (also
  mirrored at `scripts/setup-applepay.sh` for repo-level reference)
- Audit (rationale)  : `docs-internal/passd-patches-audit.md`
