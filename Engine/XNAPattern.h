#ifndef XNAPATTERN_H
#define XNAPATTERN_H

#import <Foundation/Foundation.h>
#import "XNAGlob.h"

typedef NS_ENUM(NSUInteger, XNAAction) {
    XNAActionNone = 0,
    XNAActionDefuse,
};

// 类名是否可能承载广告 UI，用于扫描时跳过绝大多数无关类。
BOOL XNAIsInterestingClassName(const char *name);

// 某个类的某个方法应执行的处理。
XNAAction XNAActionForClass(const char *className, const char *selector);

// 名字看起来是开屏/启动广告（这类广告宿主 App 会等它自己的关闭回调，不能抢先销毁）。
BOOL XNAIsSplashLikeName(const char *name);

#endif
