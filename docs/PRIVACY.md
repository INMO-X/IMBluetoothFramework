# Privacy (IMBluetoothKit)

This document describes what the framework’s Apple privacy manifest declares and what the **host app** must configure separately.

## Privacy manifest (`PrivacyInfo.xcprivacy`)

The framework ships a privacy manifest that declares:

| Key | Value |
|-----|--------|
| `NSPrivacyTracking` | `false` — the framework does not track users across apps or websites. |
| `NSPrivacyTrackingDomains` | Empty — no tracking domains. |
| `NSPrivacyCollectedDataTypes` | Empty — the framework does not declare collection of data types for App Store privacy labeling via this manifest. |
| `NSPrivacyAccessedAPITypes` | **UserDefaults** (`NSPrivacyAccessedAPICategoryUserDefaults`) with reason **`CA92.1`** — access to app-scoped preferences and device state stored on behalf of the host app (bound devices and last-connected peripheral under keys prefixed with **`IMBluetoothKit.boundDevices.`** in `UserDefaultsBluetoothPersistence`, plus C100 classic-link state in `C100ClassicLinkDetector`), not for cross-app tracking. |

The manifest file lives at `IMBluetoothKit/PrivacyInfo.xcprivacy` in the source tree.

**Binary (CocoaPods) consumers receive it in two places:**

1. **Inside each XCFramework slice** — `IMBluetoothKit.framework/PrivacyInfo.xcprivacy` (Xcode / App Store privacy aggregation reads this). Expand the `.xcframework` → `ios-arm64` → `IMBluetoothKit.framework` in Finder if you need to inspect it; CocoaPods Project Navigator often does **not** list files inside vendored frameworks.
2. **As a CocoaPods resource bundle** — `IMBluetoothKit_PrivacyInfo` (file `PrivacyInfo.xcprivacy` at the pod root), so it also appears under Pods after `pod install`.

## Host app requirements (Info.plist & capabilities)

These items are **not** satisfied by the framework manifest alone; the integrating app is responsible for them.

### Bluetooth

Add **`NSBluetoothAlwaysUsageDescription`** to the host app’s Info.plist with a user-facing string explaining why Bluetooth is needed (scanning, connecting, and communicating with INMO glasses and related peripherals).

### C100 / C110 Wi‑Fi and hotspot

C100 and C110 device flows may join the glasses’ Wi‑Fi hotspot for file sync, OTA, or similar features. Depending on your integration and iOS version, the host app may need:

- Appropriate **Network Extension** or related entitlements if you use extension-based networking APIs.
- User-facing usage descriptions for local network or hotspot access where Apple requires them for your chosen APIs.

Consult Apple’s current documentation and your app’s networking architecture when enabling these code paths.

## Tracking

IMBluetoothKit does **not** perform user tracking as defined by Apple’s privacy manifest (`NSPrivacyTracking` is `false`). Host apps remain responsible for their own analytics, advertising, and any additional privacy declarations beyond this framework.
