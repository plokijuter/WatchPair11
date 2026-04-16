export THEOS ?= $(HOME)/theos
THEOS_PACKAGE_SCHEME = rootless
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TOOL_NAME = wp11bridge
wp11bridge_FILES = main.m
wp11bridge_CFLAGS = -fobjc-arc
wp11bridge_FRAMEWORKS = Foundation
wp11bridge_LDFLAGS = -ldl
wp11bridge_INSTALL_PATH = /var/jb/usr/bin

include $(THEOS_MAKE_PATH)/tool.mk
