# Mac Monitor

A lightweight native macOS menu bar monitor for CPU utilization, memory pressure, Apple Silicon SoC temperature, and primary physical-network throughput.

## Run

```sh
swift run
```

To build a double-clickable app bundle, run:

```sh
./Scripts/build-app.sh
```

The menu bar item shows CPU, memory, and thermal pressure as three vertical indicators. Upload and download rates are stacked to reduce horizontal menu bar usage.

## Resource policy

- One utility-priority sampling timer.
- Network is sampled every second from the primary physical interface; CPU and memory every five seconds; SoC temperature and thermal pressure every fifteen seconds.
- Five minutes of trends are retained only in memory.
- No disk history, animation loop, privileged helper, or third-party runtime.
