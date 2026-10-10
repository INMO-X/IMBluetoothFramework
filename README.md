# BluetoothKit

INMO X 蓝牙 SDK：CoreBluetooth 封装、设备状态机与 `BluetoothService` 调度层。通过 CocoaPods 引入**预编译 XCFramework**（Swift module 统一为 `BluetoothKit`），按子规格选择全量或单产品线组合包。

- **iOS** 15.0+
- **集成方式**：CocoaPods（`:git` + `:tag`）
- **二进制形态**：**static XCFramework**（第三方 RxSwift / RxRelay / SSZipArchive 由 CocoaPods 拉取，不打进包内；宿主 static / dynamic 均可）

公开仓：<https://github.com/INMO-X/BluetoothKit>

---

## 安装（CocoaPods）

在 `Podfile` 中指向公开二进制仓库与版本 tag：

```ruby
platform :ios, '15.0'
# static 或 dynamic 均可；与 INMOX 一致时可用：
# use_frameworks! :linkage => :static
use_frameworks!

target 'YourApp' do
  pod 'BluetoothKit',
    :git => 'https://github.com/INMO-X/BluetoothKit.git',
    :tag => '0.1.0'
end
```

默认子规格为 **`Full`**（全量官方设备）。可按需改为下列子规格之一（**只选一种组合方式**，见下方「禁止混用」）。

```ruby
GIT = 'https://github.com/INMO-X/BluetoothKit.git'

# 仅基础层（自行实现 Device）
pod 'BluetoothKit/Base', :git => GIT, :tag => '0.1.0'

# 单产品线组合包（已含 Base 能力，无需再写 Base）—— 每次只选一行
pod 'BluetoothKit/Devices/C100', :git => GIT, :tag => '0.1.0'
# pod 'BluetoothKit/Devices/C110', :git => GIT, :tag => '0.1.0'
# pod 'BluetoothKit/Devices/XA01', :git => GIT, :tag => '0.1.0'
```

执行 `pod install` 后 `import BluetoothKit` 即可。

隐私清单：`PrivacyInfo.xcprivacy` 嵌在 XCFramework 内，并额外以 CocoaPods resource bundle `BluetoothKit_PrivacyInfo` 提供（详见 [docs/PRIVACY.md](docs/PRIVACY.md)）。

Xcode 16+/27 SDK 下，若传递依赖仍声明过低的 `IPHONEOS_DEPLOYMENT_TARGET`，可在宿主 `Podfile` 增加与 ExampleApp 相同的 `post_install`（仅此一项，**无需**再改 RxSwift 的 `BUILD_LIBRARY_FOR_DISTRIBUTION`）：

```ruby
post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      if config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'].to_f < 15.0
        config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
      end
    end
  end
end
```

---

## 子规格 / 组合包对照

| 子规格 | XCFramework 路径 | 包含内容 |
|--------|-------------------|----------|
| **Full** | `XCFrameworks/BluetoothKit.xcframework` | Base + C100 + C110 + XA01 |
| **Base** | `XCFrameworks/variants/Base/…` | Core / Device / Protocol / Service / Logger |
| **Devices/C100** | `XCFrameworks/variants/C100/…` | Base + C100 |
| **Devices/C110** | `XCFrameworks/variants/C110/…` | Base + C110 |
| **Devices/XA01** | `XCFrameworks/variants/XA01/…` | Base + XA01 |

> **二进制客户必读（Devices 父规格陷阱）：**
> - 请使用 **`Full`**，或**恰好一行** `Devices/<型号>`（如 `Devices/C100`）。
> - **禁止**写 `pod 'BluetoothKit/Devices'`：CocoaPods 会嵌套带上 C100+C110+XA01 三份 XCFramework，同名 module 必冲突。
> - **禁止**同时写两行及以上 `Devices/*`（例如 C100 + C110）。
> - **禁止**同时依赖 **`Full`** 与任意 `Devices/*`。
> 各变体均为同名 Swift module `BluetoothKit`，重复链接会导致重复符号 / 模块冲突。
---

## 依赖

CocoaPods 会拉取下列第三方库（版本以 podspec 为准）：

| 依赖 | 版本 | 子规格 |
|------|------|--------|
| RxSwift | `~> 6.9.0` | 全部 |
| RxRelay | `~> 6.9.0` | 全部 |
| SSZipArchive | `~> 2.4` | **Full**、**Devices/C100** |

系统框架（由 podspec 声明，无需单独 pod）：

| 子规格 | `s.frameworks` |
|--------|----------------|
| Full | CoreBluetooth, AVFoundation, NetworkExtension, Network |
| Base | CoreBluetooth, AVFoundation |
| Devices/C100 | CoreBluetooth, AVFoundation, NetworkExtension, Network |
| Devices/C110 | CoreBluetooth, AVFoundation, NetworkExtension |
| Devices/XA01 | CoreBluetooth, AVFoundation |

---

## 最小接入示例

```swift
import BluetoothKit

// 1. 启动期：注册所支持的产品工厂（在 connect / bindUser / startScan 之前）
DeviceRegistry.shared.register(C100Factory())

// 2. 登录后绑定用户并尝试回连上次设备
BluetoothService.shared.bindUser(userID)
if !BluetoothService.shared.reconnectLast() {
    BluetoothService.shared.startScan(for: C100Factory())
}

// 3. 订阅状态 / 下发指令（示例）
device.stateStream
    .compactMap { $0 as? C100DeviceState }
    .observe(on: MainScheduler.instance)
    .subscribe(onNext: { state in /* battery, sync state, … */ })

device.send(command: C100DeviceCommand.takePhoto)
```

绑定列表与「上次连接设备」默认写入 `UserDefaults`，key 前缀为 **`BluetoothKit.boundDevices.`**（按 userID 分区）。若曾使用旧前缀 `IMBluetoothKit.boundDevices.*` 或 `IMBluetoothFramework.boundDevices.*`，SDK 会在首次读写时按该顺序自动迁移到 `BluetoothKit.boundDevices.*`。自定义 `keyPrefix` 不触发迁移。

---

## 更多文档

| 文档 | 说明 |
|------|------|
| [docs/USAGE.md](docs/USAGE.md) | 业务场景与公开 API 参考 |
| [docs/PRIVACY.md](docs/PRIVACY.md) | Privacy manifest 与宿主 App Info.plist 要求 |
| 公开仓 [ExampleApp/](https://github.com/INMO-X/BluetoothKit/tree/master/ExampleApp) | 可运行 Demo（CocoaPods 二进制 tag + 示例 UI） |

宿主 App 须在 Info.plist 配置 **`NSBluetoothAlwaysUsageDescription`**；C100/C110 Wi‑Fi 同步相关能力见 [docs/PRIVACY.md](docs/PRIVACY.md)。
