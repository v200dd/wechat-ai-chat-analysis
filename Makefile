export THEOS ?= $(HOME)/theos
export TARGET = iphone:clang:14.5:14.0
export ARCHS = arm64
export DEBUG = 0
export FINALPACKAGE = 1

# 默认装到 /Library/MobileSubstrate（rootful）。
# Dopamine / palera1n rootless 越狱：make package ROOTLESS=1
ROOTLESS ?= 0
ifeq ($(ROOTLESS),1)
export THEOS_PACKAGE_SCHEME = rootless
endif

INSTALL_TARGET_PROCESSES = WeChat

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = WeChatAIAnalysis

WeChatAIAnalysis_FILES = \
	Sources/JGPTCommon.m \
	Sources/JGPTConfig.m \
	Sources/JGPTModels.m \
	Sources/JGPTPrompts.m \
	Sources/JGPTClient.m \
	Sources/JGPTStream.m \
	Sources/JGPTMemoryStore.m \
	Sources/JGPTWeChat.m \
	Sources/JGPTEngine.m \
	Sources/JGPTAssistantPanel.m \
	Sources/JGPTChatCard.m \
	Sources/JGPTInlineCard.m \
	Sources/JGPTMessageMenu.m \
	Sources/JGPTSettingsVC.m \
	Sources/JGPTAboutVC.m \
	Sources/JGPTMediaLog.m \
	Sources/JGPTMediaLogVC.m \
	Sources/JGPTMemoryVC.m \
	Sources/JGPTEntry.m

WeChatAIAnalysis_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore Photos AVFoundation
WeChatAIAnalysis_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
WeChatAIAnalysis_LDFLAGS = -undefined dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 WeChat || true"
