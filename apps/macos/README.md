# Device Monitor for macOS

Product behavior, Windows parity, and the cross-device protocol are documented in:

- [Device Monitor product specification (Chinese)](../../docs/PRODUCT_SPEC.zh-CN.md)
- [Peer Status Protocol v1 (Chinese)](../../docs/PEER_SYNC_PROTOCOL_V1.zh-CN.md)
- [Peer Status v1 JSON Schema](../../docs/status-v1.schema.json)
- [Windows Codex handoff prompt (Chinese)](../../docs/WINDOWS_CODEX_HANDOFF.zh-CN.md)

Device Monitor is a native macOS menu bar monitor for the metrics that are useful
at a glance: CPU utilization and load, memory pressure and swap, thermal state,
and traffic on the primary physical network interface. Details are collected
on demand so the menu bar path stays quiet when the popover is closed.

## Requirements and support

- macOS 14 or newer.
- Apple Silicon (`arm64`) is the primary supported runtime. The HID sensor
  bridge reports Apple Silicon SoC/SSD temperatures when the matching services
  are present.
- Intel (`x86_64`) builds are supported for CPU, memory, and network metrics;
  the Apple Silicon temperature bridge may report `Unavailable`. A universal
  binary can therefore run on both architectures, but temperature parity is
  not promised on Intel.

The project has no network dependencies, privileged helper, third-party
runtime, or required environment variables for local development.

## Run from SwiftPM

```sh
swift run
```

The first temperature query may be unavailable on a machine without the
matching HID service. CPU, memory, and network readings continue independently.

## Build an app bundle

The build script asks SwiftPM for its actual binary directory, so it works with
native and multi-architecture build layouts:

```sh
./Scripts/build-app.sh                         # native release, DeviceMonitor.app
./Scripts/build-app.sh --arch arm64            # Apple Silicon
./Scripts/build-app.sh --arch x86_64           # Intel
./Scripts/build-app.sh --arch universal        # arm64 + x86_64
./Scripts/build-app.sh --configuration debug --output /tmp/DeviceMonitor.app
```

Every bundle is signed and checked with `codesign --verify --deep --strict`.
Without a signing identity the script uses a timestamp-free ad-hoc signature,
which is verifiable locally but is not a distribution signature. For a release
build, provide a Developer ID identity either as an option or an environment
variable:

```sh
DEVICEMONITOR_SIGNING_IDENTITY="Developer ID Application: Example (TEAMID)" \
  ./Scripts/build-app.sh --arch universal
```

Developer ID signing, hardened runtime, notarization, and stapling require an
Apple Developer account and credentials outside this repository. When an
identity is supplied, the script also runs `spctl --assess`; ad-hoc builds do
not claim Gatekeeper approval.

## Sampling profiles

The default `Balanced` profile samples network traffic every 1 second, CPU and
memory every 5 seconds, and thermal data every 15 seconds. `Low power` changes
those intervals to 2, 10, and 30 seconds. `Responsive` uses 1, 2, and 10
seconds. The profile controls polling cadence, not the accuracy of the
underlying operating-system counters.

Five minutes of trend points are retained in memory. Process lists and Wi-Fi
metadata are sampled only while their corresponding detail view is open; Wi-Fi
metadata refreshes at a slower cadence than traffic counters. No history is
written to disk.

## Peer monitoring

Peer monitoring is disabled by default. Open Settings, choose a language, then
enable peer monitoring. Give both devices the same 32-byte Base64URL pairing
secret and set the peer address to the other computer's private `host:port`;
the default port is `48621`. Each app exposes `GET /v1/status` and polls the
other device every five seconds. A peer becomes offline after 15 seconds
without a valid signed response.

Use the feature only on a trusted LAN or through an encrypted overlay such as
Tailscale/WireGuard. The v1 service uses HMAC authentication and integrity but
does not encrypt the JSON body itself, so never forward port 48621 directly to
the public internet. The exact wire contract and cross-platform signature test
vector are in [Peer Status Protocol v1](../../docs/PEER_SYNC_PROTOCOL_V1.zh-CN.md).

## Permissions and privacy

Network counters use local interface statistics. Network details show signal
strength and channel when CoreWLAN exposes them, without reading the SSID or
requesting Location Services. Peer monitoring is disabled by default. When the
user enables and configures it, Device Monitor exchanges only the read-only metric
fields defined by Peer Status Protocol v1; process names, SSIDs, usernames,
addresses, and files are never included.

## Validation

The repository's read-only checks can be run with:

```sh
./Scripts/verify.sh
swift build -c debug -Xswiftc -warnings-as-errors
swift test
zsh -n Scripts/build-app.sh
plutil -lint App/Info.plist
```

`Scripts/verify.sh` is the local static gate and does not require a signing
identity. Set `DEVICEMONITOR_VERIFY_APP=1` when an existing `DeviceMonitor.app`
bundle should also be checked. `swift test` exercises pure formatting, sampling-profile, thermal-state, and
trend calculations without requiring a GUI session or physical sensor. Build
and signing checks should be run on the target macOS architecture; notarization
cannot be validated without a real Developer ID identity.
