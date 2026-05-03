# dsc_extractor — Theos tool, cross-compiled from Linux for iOS arm64e
#
# Builds the on-device dyld_shared_cache extractor used by WatchPair11 v8.0+
# `setup-applepay.sh` to pull `passd` (and any other binary) out of the
# system's shared cache, ready to be ldid-signed and CT-bypassed.
#
# Source : Apple's open-source dyld project (dyld-733.6, APSL-2.0).
# Specifically `launch-cache/dsc_extractor.cpp` + `dsc_iterator.cpp` and
# their *.hpp dependencies. The modern DyldSharedCache.h is replaced by a
# minimal shim (src/DyldSharedCache.h) that exposes only the cache_header
# fields the extractor actually touches.
#
# Output: layout/opt/watchpair11/dsc_extractor (signed with ldid -M)
#
# Build :
#   make -C tools/dsc_extractor THEOS=$HOME/theos
#
# To clean :
#   make -C tools/dsc_extractor clean THEOS=$HOME/theos

TARGET := iphone:clang:16.5:14.0
ARCHS := arm64e
PACKAGE_VERSION := 8.0
THEOS_PACKAGE_SCHEME ?= rootless

include $(THEOS)/makefiles/common.mk

TOOL_NAME = dsc_extractor

dsc_extractor_FILES = \
  src/main_ios.cpp \
  src/dsc_extractor.cpp \
  src/dsc_iterator.cpp

# Notes :
# - We override `dyld_shared_cache_extract_dylibs_progress` from
#   dsc_extractor.cpp (it's a free function, not in a class) — main_ios.cpp
#   declares it via dsc_extractor.h.
# - Use C++14 for std::unordered_map et al.
# - `-fblocks` enables the ^{} progress-callback syntax.
dsc_extractor_CFLAGS = \
  -Isrc \
  -Isrc/compat \
  -std=c++14 \
  -fblocks \
  -Wno-pointer-to-int-cast \
  -Wno-unused-command-line-argument \
  -Wno-deprecated-declarations \
  -Wno-format \
  -Wno-format-security \
  -Wno-unused-variable \
  -Wno-unused-function \
  -Wno-implicit-function-declaration \
  -Wno-int-conversion \
  -Wno-incompatible-pointer-types \
  -Wno-narrowing \
  -Wno-c++11-narrowing \
  -Wno-macro-redefined \
  -Wno-error \
  -DEXTRACT_USING_BLOCKS=1 \
  -D__APPLE__=1

dsc_extractor_FRAMEWORKS = Foundation
dsc_extractor_LDFLAGS = -lc++

dsc_extractor_INSTALL_PATH = /opt/watchpair11
dsc_extractor_CODESIGN_FLAGS = -Stool_entitlements.xml

include $(THEOS_MAKE_PATH)/tool.mk

# Convenience target — same shape as tools/ct_bypass_ios/Makefile.
.PHONY: build-and-stage
build-and-stage:
	@$(MAKE) FINALPACKAGE=1 THEOS=$(THEOS)
	@cp -f .theos/obj/dsc_extractor ../../layout/opt/watchpair11/dsc_extractor
	@$(THEOS)/toolchain/linux/iphone/bin/ldid -M -Stool_entitlements.xml ../../layout/opt/watchpair11/dsc_extractor
	@chmod 755 ../../layout/opt/watchpair11/dsc_extractor
	@echo "[dsc_extractor] staged $$(stat -c%s ../../layout/opt/watchpair11/dsc_extractor) bytes -> layout/opt/watchpair11/"
