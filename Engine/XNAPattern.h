#ifndef XNAPATTERN_H
#define XNAPATTERN_H

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSUInteger, XNAAction) {
    XNAActionNone = 0,
    XNAActionStub,
    XNAActionStubData,
    XNAActionDefuse,
};

// 大小写敏感的 glob：支持 '*'、'?'，用 '|' 连接多个候选。
BOOL XNAMatchGlob(const char *name, const char *pattern);

// 类名是否可能承载广告逻辑，用于扫描时跳过绝大多数无关类。
BOOL XNAIsInterestingClassName(const char *name);

// 某个类的某个方法应执行的处理。
XNAAction XNAActionForClass(const char *className, const char *selector);

// 无参取值方法（argumentCount 为 method_getNumberOfArguments()，2 表示只有 self/_cmd）。
BOOL XNAIsDataGetter(const char *selector, NSUInteger argumentCount);

#endif
