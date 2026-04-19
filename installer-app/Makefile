export THEOS ?= $(HOME)/theos
THEOS_PACKAGE_SCHEME = rootless
TARGET = iphone:clang:16.5:14.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = WatchPair11Installer

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = WatchPair11Installer

WatchPair11Installer_FILES = main.m AppDelegate.m ViewController.m Installer.m
WatchPair11Installer_FRAMEWORKS = UIKit CoreGraphics Foundation
WatchPair11Installer_CFLAGS = -fobjc-arc
WatchPair11Installer_CODESIGN_FLAGS = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/application.mk
