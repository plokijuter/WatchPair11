# WatchPair11 — single source tree, two .deb variants
#
#   make package                 → rootless / nathanlr (default)
#   make package SCHEME=roothide → roothide variant
#                                  requires $(THEOS_ROOTHIDE) (defaults to
#                                  $HOME/theos-roothide). Clone roothide/theos
#                                  there manually first; we don't auto-fetch.
#
# Theos picks layout + control automatically based on THEOS_LAYOUT_DIR_NAME:
#   rootless → layout/    + control            → com.watchpair11.deb
#   roothide → layout-roothide/ + layout-roothide/DEBIAN/control
#                                              → com.watchpair11.roothide.deb

SCHEME ?= rootless

ifeq ($(SCHEME),roothide)
    THEOS_ROOTHIDE ?= $(HOME)/theos-roothide
    export THEOS := $(THEOS_ROOTHIDE)
    THEOS_PACKAGE_SCHEME = roothide
    THEOS_LAYOUT_DIR_NAME = layout-roothide
    # Force theos to pick layout-roothide/DEBIAN/control (not the root-level
    # rootless control) — to do that we MOVE the root control aside at stage
    # time via the sync-roothide-layout target below, then put it back.
else
    export THEOS ?= $(HOME)/theos
    THEOS_PACKAGE_SCHEME = rootless
endif

INSTALL_TARGET_PROCESSES = SpringBoard
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = WatchPair11

$(TWEAK_NAME)_FILES = Tweak.xm
$(TWEAK_NAME)_CFLAGS = -fobjc-arc -Wno-error=unused-function
$(TWEAK_NAME)_FRAMEWORKS = Foundation CoreFoundation
WatchPair11_LIBRARIES = substrate
$(TWEAK_NAME)_LDFLAGS = -ldl

ifeq ($(SCHEME),roothide)
    $(TWEAK_NAME)_CFLAGS += -DROOTHIDE=1
    # libroothide is part of the roothide theos SDK. The header
    # <roothide.h> is auto-discovered via the SDK isysroot.
    $(TWEAK_NAME)_LIBRARIES += roothide
endif

include $(THEOS_MAKE_PATH)/tweak.mk

# Build the home-screen app and bundle it into the same .deb
SUBPROJECTS = installer-app
include $(THEOS_MAKE_PATH)/aggregate.mk

# ----------------------------------------------------------------------------
# Roothide variant: keep layout-roothide/opt/ in sync with layout/opt/
# (we don't want to maintain two copies of setup/rollback scripts +
# the passd plist template).
# Also temporarily hides the root-level control file so theos picks the
# roothide one inside layout-roothide/DEBIAN/.
# ----------------------------------------------------------------------------
ifeq ($(SCHEME),roothide)
before-stage::
	@echo "==> Syncing layout/opt -> layout-roothide/opt"
	@mkdir -p layout-roothide/opt
	@rm -rf layout-roothide/opt/watchpair11
	@cp -R layout/opt/watchpair11 layout-roothide/opt/watchpair11
	@echo "==> Hiding root-level rootless control during roothide build"
	@if [ -f control ] && [ ! -f control.rootless.bak ]; then \
	  mv control control.rootless.bak; \
	fi

after-stage::
	@if [ -f control.rootless.bak ]; then \
	  mv control.rootless.bak control; \
	fi
endif
