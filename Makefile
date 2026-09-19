TARGET := iphone:clang:latest:15.0
ARCHS = arm64
THEOS_PACKAGE_SCHEME = roothide
INSTALL_TARGET_PROCESSES = controlclient

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = XrkNoAd
XrkNoAd_FILES = Engine/XNAGlob.c Engine/XNAPattern.m Engine/XNAHooks.m
XrkNoAd_CFLAGS = -fobjc-arc -Wall -Wextra -Wno-unused-parameter
XrkNoAd_FRAMEWORKS = Foundation UIKit

include $(THEOS_MAKE_PATH)/tweak.mk
