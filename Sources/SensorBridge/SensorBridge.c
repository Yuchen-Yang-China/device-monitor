#include "SensorBridge.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <math.h>
#include <stdbool.h>
#include <string.h>

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;

#ifdef __LP64__
typedef double IOHIDFloat;
#else
typedef float IOHIDFloat;
#endif

#define MM_IOHID_EVENT_TYPE_TEMPERATURE 15
#define MM_IOHID_EVENT_FIELD_BASE(type) (type << 16)

extern IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type, int32_t options, int64_t timestamp);
extern CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef service, CFStringRef key);
extern IOHIDFloat IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);
extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef matching);
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef client);

static void initialize_snapshot(MMTemperatureSnapshot *snapshot) {
    snapshot->soc_average_celsius = NAN;
    snapshot->soc_maximum_celsius = NAN;
    snapshot->ssd_average_celsius = NAN;
    snapshot->soc_sensor_count = 0;
    snapshot->ssd_sensor_count = 0;
}

static bool valid_temperature(double value) {
    return isfinite(value) && value >= 0.0 && value < 120.0;
}

int MMReadTemperatures(MMTemperatureSnapshot *snapshot) {
    if (snapshot == NULL) {
        return 0;
    }
    initialize_snapshot(snapshot);

    int32_t usage_page = 0xff00;
    int32_t usage = 0x0005;
    CFNumberRef page_number = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &usage_page);
    CFNumberRef usage_number = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &usage);
    CFMutableDictionaryRef matching = CFDictionaryCreateMutable(kCFAllocatorDefault, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(matching, CFSTR("PrimaryUsagePage"), page_number);
    CFDictionarySetValue(matching, CFSTR("PrimaryUsage"), usage_number);
    CFRelease(page_number);
    CFRelease(usage_number);

    IOHIDEventSystemClientRef client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (client == NULL) {
        CFRelease(matching);
        return 0;
    }
    IOHIDEventSystemClientSetMatching(client, matching);
    CFRelease(matching);

    CFArrayRef services = IOHIDEventSystemClientCopyServices(client);
    if (services == NULL) {
        CFRelease(client);
        return 0;
    }

    double soc_total = 0.0;
    double ssd_total = 0.0;
    double soc_maximum = -INFINITY;

    for (CFIndex index = 0; index < CFArrayGetCount(services); index++) {
        IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, index);
        CFTypeRef product = IOHIDServiceClientCopyProperty(service, CFSTR("Product"));
        if (product == NULL || CFGetTypeID(product) != CFStringGetTypeID()) {
            if (product != NULL) {
                CFRelease(product);
            }
            continue;
        }

        char name[256] = {0};
        bool has_name = CFStringGetCString((CFStringRef)product, name, sizeof(name), kCFStringEncodingUTF8);
        CFRelease(product);
        if (!has_name) {
            continue;
        }

        IOHIDEventRef event = IOHIDServiceClientCopyEvent(service, MM_IOHID_EVENT_TYPE_TEMPERATURE, 0, 0);
        if (event == NULL) {
            continue;
        }
        double value = IOHIDEventGetFloatValue(event, MM_IOHID_EVENT_FIELD_BASE(MM_IOHID_EVENT_TYPE_TEMPERATURE));
        CFRelease(event);
        if (!valid_temperature(value)) {
            continue;
        }

        if (
            strncmp(name, "SOC MTR Temp", 12) == 0 ||
            strncmp(name, "PMGR SOC Die Temp", 17) == 0 ||
            strncmp(name, "PMU tdie", 8) == 0 ||
            strncmp(name, "PMU2 tdie", 9) == 0
        ) {
            soc_total += value;
            snapshot->soc_sensor_count += 1;
            if (value > soc_maximum) {
                soc_maximum = value;
            }
        } else if (strncmp(name, "NAND CH", 7) == 0) {
            ssd_total += value;
            snapshot->ssd_sensor_count += 1;
        }
    }

    CFRelease(services);
    CFRelease(client);

    if (snapshot->soc_sensor_count > 0) {
        snapshot->soc_average_celsius = soc_total / snapshot->soc_sensor_count;
        snapshot->soc_maximum_celsius = soc_maximum;
    }
    if (snapshot->ssd_sensor_count > 0) {
        snapshot->ssd_average_celsius = ssd_total / snapshot->ssd_sensor_count;
    }
    return 1;
}
