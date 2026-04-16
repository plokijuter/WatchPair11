# WatchPair26 v2 - Adapté pour nathanlr
export THEOS ?= $(HOME)/theos

THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = SpringBoard
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = WatchPair26

$(TWEAK_NAME)_FILES = Tweak.xm
$(TWEAK_NAME)_CFLAGS = -fobjc-arc
$(TWEAK_NAME)_FRAMEWORKS = Foundation CoreFoundation
WatchPair26_LIBRARIES = substrate
$(TWEAK_NAME)_LDFLAGS = -ldl

include $(THEOS_MAKE_PATH)/tweak.mk
