#ifndef XNAPATTERN_H
#define XNAPATTERN_H

#import <Foundation/Foundation.h>
#import "XNAGlob.h"

typedef NS_ENUM(NSUInteger, XNAAction) {
    XNAActionNone = 0,
    XNAActionDefuse,
};

// 类名是否可能承载广告逻辑，用于扫描时跳过绝大多数无关类。
BOOL XNAIsInterestingClassName(const char *name);

// 冷启动主线程那次扫描用的判定：既命中规则表、名字又像开屏宿主。
// 它只扫一遍字符，比先跑规则再跑名字预筛省一半——冷启动卡的那一下就在这些微秒上。
BOOL XNAIsLaunchClassName(const char *name);

// 展示层方法（已含禁用名单）。类名是否要处理由调用方先判断，避免每个方法重跑一遍类名规则。
BOOL XNAIsPresentationSelector(const char *selector);

// 某个类的某个方法应执行的处理。
XNAAction XNAActionForClass(const char *className, const char *selector);

// 是否为开屏一类（决定延后离场还是直接摘掉）。
BOOL XNAIsSplashLikeName(const char *name);

// 参考实现：不查编译好的规则表，直接跑通用通配匹配。只用于测试比对快速路径是否等价。
BOOL XNAIsInterestingClassNameSlow(const char *name);
BOOL XNAIsPresentationSelectorSlow(const char *selector);

#endif
