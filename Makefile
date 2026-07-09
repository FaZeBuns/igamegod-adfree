TARGET := iphone:clang:16.5:14.0
ARCHS = arm64
INSTALL_TARGET_PROCESSES = iGameGod

ifeq ($(THEOS_PACKAGE_SCHEME),)
THEOS_PACKAGE_SCHEME = rootless
endif

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = iGameGodAdFree

iGameGodAdFree_FILES = iGameGodAdFree.m
iGameGodAdFree_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
iGameGodAdFree_FRAMEWORKS = UIKit WebKit
iGameGodAdFree_LIBRARIES = substrate

include $(THEOS)/makefiles/tweak.mk
