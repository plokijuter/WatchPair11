# WatchPair11 — single rootless .deb (works on nathanlr AND roothide)
#
#   make package
#
# v8.0-2 architecture: a single rootless build covers both jailbreaks.
# Roothide exposes /var/jb/ as a symlink to its randomized jbroot, and the
# `setup-applepay.sh` script auto-detects the JB flavor at install time
# (skipping the SysBins overlay step on roothide). ElleKit (roothide's
# Substrate-compatible hooking framework) loads MobileSubstrate-style
# tweaks unmodified — see the `Depends:` line in `control`.

export THEOS ?= $(HOME)/theos

INSTALL_TARGET_PROCESSES = SpringBoard
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = WatchPair11

$(TWEAK_NAME)_FILES = Tweak.xm
$(TWEAK_NAME)_CFLAGS = -fobjc-arc -Wno-error=unused-function
$(TWEAK_NAME)_FRAMEWORKS = Foundation CoreFoundation
WatchPair11_LIBRARIES = substrate
$(TWEAK_NAME)_LDFLAGS = -ldl

include $(THEOS_MAKE_PATH)/tweak.mk

# Build the home-screen app and bundle it into the same .deb
SUBPROJECTS = installer-app
include $(THEOS_MAKE_PATH)/aggregate.mk

# ----------------------------------------------------------------------------
# v8.0 — make sure the on-device tools are built and staged into layout/
# before packaging. Build them via their own Theos sub-makefiles since they
# need different ARCHS (arm64e only) and FRAMEWORKS than the tweak.
#
# We require the user to have run `tools/fetch_external.sh` once first to
# pull libcrypto.a/libssl.a from ChOma upstream (gitignored, ~47 MB).
# ----------------------------------------------------------------------------
TOOLS_LAYOUT_DIR := layout/opt/watchpair11
CTBP_IOS_BIN := $(TOOLS_LAYOUT_DIR)/ct_bypass_ios
DSC_EXTRACTOR_BIN := $(TOOLS_LAYOUT_DIR)/dsc_extractor

before-package::
	@$(MAKE) -C tools/ct_bypass_ios build-and-stage THEOS=$(THEOS)
	@$(MAKE) -C tools/dsc_extractor build-and-stage THEOS=$(THEOS)
