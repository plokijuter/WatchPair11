export THEOS ?= $(HOME)/theos
THEOS_PACKAGE_SCHEME = rootless
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TOOL_NAME = wp26bridge
wp26bridge_FILES = main.m
wp26bridge_CFLAGS = -fobjc-arc
wp26bridge_FRAMEWORKS = Foundation
wp26bridge_LDFLAGS = -ldl
wp26bridge_INSTALL_PATH = /var/jb/usr/bin

include $(THEOS_MAKE_PATH)/tool.mk
