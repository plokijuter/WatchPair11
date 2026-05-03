export THEOS ?= $(HOME)/theos

THEOS_PACKAGE_SCHEME = rootless

TARGET = iphone:clang:16.5:14.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = WatchPair11

WatchPair11_FILES = main.m AppDelegate.m ViewController.m Installer.m
WatchPair11_FRAMEWORKS = UIKit CoreGraphics Foundation
WatchPair11_CFLAGS = -fobjc-arc
WatchPair11_CODESIGN_FLAGS = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/application.mk
