// charger-info.c —— 读取当前充电器的「报价」与「成交」
//
// 编译:  cc -o charger-info charger-info.c -framework IOKit -framework CoreFoundation
// 运行:  ./charger-info
//
// 这 40 行就是「充电头检测 App」的核心。两条数据通路:
//   ① IOPSCopyExternalPowerAdapterDetails()  —— 公共 API，不需要 root，沙盒 App 也能用
//   ② IORegistry 的 AppleSmartBattery.AdapterDetails —— 信息更全，含完整 PDO 菜单
#include <stdio.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/ps/IOPowerSources.h>
#include <IOKit/ps/IOPSKeys.h>
#include <CoreFoundation/CoreFoundation.h>

static void dumpXML(CFTypeRef obj, const char *label) {
    printf("===== %s =====\n", label);
    if (!obj) { printf("(null) —— 当前没有接充电器\n\n"); return; }
    CFDataRef xml = CFPropertyListCreateData(kCFAllocatorDefault, obj,
                                             kCFPropertyListXMLFormat_v1_0, 0, NULL);
    if (xml) {
        fwrite(CFDataGetBytePtr(xml), 1, (size_t)CFDataGetLength(xml), stdout);
        CFRelease(xml);
    }
    printf("\n");
}

static void printMenu(CFDictionaryRef ad) {
    CFArrayRef menu = CFDictionaryGetValue(ad, CFSTR("UsbHvcMenu"));
    if (!menu || CFGetTypeID(menu) != CFArrayGetTypeID()) { printf("(没有 PDO 菜单)\n\n"); return; }

    CFIndex active = -1;
    CFNumberRef idx = CFDictionaryGetValue(ad, CFSTR("UsbHvcHvcIndex"));
    if (idx) CFNumberGetValue(idx, kCFNumberCFIndexType, &active);

    printf("===== 充电器报价单 (PDO 菜单) =====\n");
    for (CFIndex i = 0; i < CFArrayGetCount(menu); i++) {
        CFDictionaryRef e = (CFDictionaryRef)CFArrayGetValueAtIndex(menu, i);
        int mv = 0, ma = 0;
        CFNumberRef v = CFDictionaryGetValue(e, CFSTR("MaxVoltage"));
        CFNumberRef c = CFDictionaryGetValue(e, CFSTR("MaxCurrent"));
        if (v) CFNumberGetValue(v, kCFNumberIntType, &mv);
        if (c) CFNumberGetValue(c, kCFNumberIntType, &ma);
        printf("  档位%ld:  %5.1f V  x  %.3f A  =  %5.1f W%s\n",
               (long)i, mv / 1000.0, ma / 1000.0, mv * (double)ma / 1000000.0,
               (i == active) ? "   <== 当前使用" : "");
    }
    printf("\n");
}

int main(void) {
    CFDictionaryRef pub = IOPSCopyExternalPowerAdapterDetails();
    dumpXML(pub, "① 公共 API: IOPSCopyExternalPowerAdapterDetails()");

    io_service_t svc = IOServiceGetMatchingService(MACH_PORT_NULL,
                                                   IOServiceMatching("AppleSmartBattery"));
    if (svc) {
        CFMutableDictionaryRef props = NULL;
        if (IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS && props) {
            CFTypeRef ad = CFDictionaryGetValue(props, CFSTR("AdapterDetails"));
            dumpXML(ad, "② IORegistry: AppleSmartBattery -> AdapterDetails");
            if (ad && CFGetTypeID(ad) == CFDictionaryGetTypeID())
                printMenu((CFDictionaryRef)ad);

            // ③ 实测功率遥测（不是协商值，是真实测量值）
            CFTypeRef pt = CFDictionaryGetValue(props, CFSTR("PowerTelemetryData"));
            if (pt && CFGetTypeID(pt) == CFDictionaryGetTypeID()) {
                static const char *keys[] = {
                    "SystemVoltageIn", "SystemCurrentIn", "SystemPowerIn",
                    "WallEnergyEstimate", "AccumulatedWallEnergyEstimate",
                    "SystemLoad", "BatteryPower", "AdapterEfficiencyLoss"
                };
                printf("===== ③ 实测遥测 PowerTelemetryData =====\n");
                for (unsigned k = 0; k < sizeof(keys) / sizeof(keys[0]); k++) {
                    CFStringRef key = CFStringCreateWithCString(NULL, keys[k], kCFStringEncodingUTF8);
                    CFNumberRef n = (CFNumberRef)CFDictionaryGetValue((CFDictionaryRef)pt, key);
                    long long val = 0;
                    if (n && CFGetTypeID(n) == CFNumberGetTypeID() &&
                        CFNumberGetValue(n, kCFNumberLongLongType, &val))
                        printf("  %-30s %lld\n", keys[k], val);
                    CFRelease(key);
                }
                printf("\n");
            }
            CFRelease(props);
        }
        IOObjectRelease(svc);
    }
    if (pub) CFRelease(pub);
    return 0;
}
