#include "XNAGlob.h"
#include <stdio.h>
#include <string.h>

static int failures = 0;

#define CHECK(cond) do { if (!(cond)) { failures++; printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); } } while (0)

int main(void) {
    CHECK(XNAMatchGlob("ATSplashAd", "*SplashAd"));
    CHECK(XNAMatchGlob("ATAdManager", "ATAdManager|ATInitModule"));
    CHECK(XNAMatchGlob("ATInitModule", "ATAdManager|ATInitModule"));
    CHECK(XNAMatchGlob("WMADManager", "AT*|BU*|WM*"));
    CHECK(XNAMatchGlob("BUSplashAd", "AT*Ad*|BU*|CSJ*"));
    CHECK(XNAMatchGlob("DeviceADTableViewCell", "*AD*|*Ad"));
    CHECK(XNAMatchGlob("ADRule", "ADInfo*|ADRule|*AdManager"));

    CHECK(!XNAMatchGlob("DownloadViewController", "AD*"));
    CHECK(!XNAMatchGlob("AddressBookViewController", "*Ad"));
    CHECK(!XNAMatchGlob("oad", "*AD"));
    CHECK(!XNAMatchGlob("ATAdManager", "ATInitModule|BU*"));
    CHECK(!XNAMatchGlob("HistoryADView", "AD*|*AD"));
    CHECK(!XNAMatchGlob("BU", "AT*|"));
    CHECK(XNAMatchGlob("AT", "AT*"));
    CHECK(XNAMatchGlob("AT", "AT|BU*"));
    CHECK(XNAMatchGlob("AXB", "A?B"));
    CHECK(!XNAMatchGlob("AB", "A?B"));

    printf(failures ? "%d glob checks failed\n" : "glob matcher ok\n", failures);
    return failures ? 1 : 0;
}
