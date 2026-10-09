# IMBluetoothKit ExampleApp

Minimal iOS 15+ demo that binds a user, reconnects the last device, lists cached devices with connection / reconnecting badges, scans C100, connects with `firstConnect: true`, shows battery from `C100DeviceState`, and unbinds.

## Requirements

- Xcode 15+
- CocoaPods
- iOS 15.0+ Simulator or device (Bluetooth features need a physical device)

## Run

```bash
cd ExampleApp
pod install
open IMBluetoothKitExample.xcworkspace
```

Select scheme **IMBluetoothKitExample**, pick a Simulator or device, then Run.

Or build from CLI:

```bash
cd ExampleApp
pod install
xcodebuild -workspace IMBluetoothKitExample.xcworkspace \
  -scheme IMBluetoothKitExample \
  -destination 'generic/platform=iOS Simulator' \
  build
```

## Flow

1. Launch registers `C100Factory` in `AppDelegate`.
2. Enter a `userID` → **bindUser + reconnectLast**.
3. Device list shows `service.devices` with `connectionState` / `reconnecting` badges and C100 battery.
4. **Scan** → `startScan(for: C100Factory())` → tap a row → `connect(firstConnect: true)`.
5. **Unbind** → `unbindUser()` and return to login.

The Podfile pulls **IMBluetoothKit** from the public binary GitHub repo (`:git` + `:tag`), with `RxSwift` / `RxRelay` pinned `~> 6.9`. Match the tag to the SDK version you integrate in your app.
