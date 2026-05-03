# ct_bypass_ios — Theos tool, cross-compiled from Linux for iOS arm64e
#
# Builds the on-device CoreTrust bypass binary used by WatchPair11 v8.0+
# `setup-applepay.sh` to sign passd extracted from the dyld_shared_cache.
#
# Output: layout/opt/watchpair11/ct_bypass_ios (signed with ldid -M)
#
# Build :
#   make -C tools/ct_bypass_ios THEOS=$HOME/theos
#
# To clean :
#   make -C tools/ct_bypass_ios clean THEOS=$HOME/theos

TARGET := iphone:clang:16.5:14.0
ARCHS := arm64e
PACKAGE_VERSION := 8.0

# We do NOT install this into /var/jb when packaging — the parent project
# pulls our compiled binary from .theos/_/opt/watchpair11/ct_bypass_ios via
# the BEFORE_PACKAGE step in the parent Makefile. We just need a thin
# `tool` build that ldid-signs the binary and drops it somewhere predictable.
THEOS_PACKAGE_SCHEME ?= rootless

include $(THEOS)/makefiles/common.mk

TOOL_NAME = ct_bypass_ios

ct_bypass_ios_FILES = \
  src/main_ios.c \
  src/coretrust_bug.c \
  choma_src/Base64.c \
  choma_src/BufferedStream.c \
  choma_src/CSBlob.c \
  choma_src/CodeDirectory.c \
  choma_src/FAT.c \
  choma_src/FileStream.c \
  choma_src/Host.c \
  choma_src/MachO.c \
  choma_src/MachOLoadCommand.c \
  choma_src/MemoryStream.c \
  choma_src/PatchFinder.c \
  choma_src/PatchFinder_arm64.c \
  choma_src/Util.c \
  choma_src/arm64.c

# Local headers for ChOma + Templates + coretrust_bug
ct_bypass_ios_CFLAGS = \
  -Ichoma_src \
  -Isrc \
  -Iexternal/include \
  -fblocks \
  -Wno-pointer-to-int-cast \
  -Wno-unused-command-line-argument \
  -Wno-deprecated-declarations \
  -Wno-format \
  -Wno-implicit-function-declaration \
  -Wno-int-conversion \
  -Wno-incompatible-pointer-types \
  -Wno-macro-redefined \
  -Wno-error

# Frameworks + libs : CoreFoundation for plist work, libcrypto/libssl for CMS,
# CommonCrypto via Security framework. libcrypto/libssl static archives are
# pulled in from external/ios/ (vendored from ChOma upstream).
ct_bypass_ios_FRAMEWORKS = CoreFoundation Foundation Security
ct_bypass_ios_LDFLAGS = \
  external/ios/libcrypto.a \
  external/ios/libssl.a \
  -lcompression

ct_bypass_ios_INSTALL_PATH = /opt/watchpair11
ct_bypass_ios_CODESIGN_FLAGS = -Stool_entitlements.xml

include $(THEOS_MAKE_PATH)/tool.mk

# Custom convenience target used by the parent project's `before-package` hook.
# Builds with FINALPACKAGE=1 (stripped) and re-signs the output with `ldid -M`
# so Apple-restricted entitlements are MERGED (not replaced — `-S` strips
# anything ldid doesn't recognise as standard).
.PHONY: build-and-stage
build-and-stage:
	@if [ ! -f external/ios/libcrypto.a ] || [ ! -f external/ios/libssl.a ]; then \
	  echo "[ct_bypass_ios] external/ios/libcrypto.a missing — run tools/fetch_external.sh first"; \
	  exit 1; \
	fi
	@$(MAKE) FINALPACKAGE=1 THEOS=$(THEOS)
	@cp -f .theos/obj/ct_bypass_ios ../../layout/opt/watchpair11/ct_bypass_ios
	@$(THEOS)/toolchain/linux/iphone/bin/ldid -M -Stool_entitlements.xml ../../layout/opt/watchpair11/ct_bypass_ios
	@chmod 755 ../../layout/opt/watchpair11/ct_bypass_ios
	@echo "[ct_bypass_ios] staged $$(stat -c%s ../../layout/opt/watchpair11/ct_bypass_ios) bytes -> layout/opt/watchpair11/"
