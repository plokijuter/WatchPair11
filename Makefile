# WatchPair11 v2 - Adapté pour nathanlr
export THEOS ?= $(HOME)/theos

THEOS_PACKAGE_SCHEME = rootless
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
