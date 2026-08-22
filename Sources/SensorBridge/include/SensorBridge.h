#ifndef SENSOR_BRIDGE_H
#define SENSOR_BRIDGE_H

#include <stdint.h>

typedef struct {
    double soc_average_celsius;
    double soc_maximum_celsius;
    double ssd_average_celsius;
    uint32_t soc_sensor_count;
    uint32_t ssd_sensor_count;
} MMTemperatureSnapshot;

// Returns 1 when the HID temperature service was queried. Individual values are NaN when unavailable.
int MMReadTemperatures(MMTemperatureSnapshot *snapshot);

#endif
