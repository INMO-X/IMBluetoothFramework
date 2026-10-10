# BluetoothKit 使用指南

本文档面向 **业务 / UI 层开发者**。通过 CocoaPods 引入（`import BluetoothKit`）；默认拿全量设备，也可按子规格只要 `Devices/C100` / `C110` / `XA01` 等组合包（安装细节见仓库 README）。

- **Part A**：场景化用法（启动注册 → 扫描连接 → 指令 / 状态 → 重连 → Mock / 扩展）
- **Part B**：[公开 API 参考](#公开-api-参考)（符号一览，与源码 `///` 对齐）

本文档不包含私有帧布局 / 魔数协议细节；编解码实现以各设备源码为准。

---

## 目录

### Part A — 场景

1. [整体架构](#1-整体架构)
2. [快速开始](#2-快速开始)
   - 2.A [新手教程：跟着场景走一遍](#2a-新手教程跟着场景走一遍)
3. [启动期注册设备工厂](#3-启动期注册设备工厂)
4. [扫描](#4-扫描)
   - 4.1 普通扫描（不限类型）
   - 4.2 **按设备类型搜索**（新方法）
   - 4.3 按任意过滤器搜索
5. [连接 / 断开 / 多设备切换](#5-连接--断开--多设备切换)
   - 5.1 连接
   - 5.2 主动断开
   - 5.3 取消自动重连但保持当前连接
   - 5.4 多设备切换
   - 5.5 **设备缓存管理（addDevice / removeDevice / clearDevices）**
   - 5.6 **用户身份与持久化（bindUser / unbindUser / persistence）**
   - 5.7 **获取与回连上一次设备（lastConnected* / reconnectLast）**
6. [订阅设备状态与事件](#6-订阅设备状态与事件)
7. [下发业务指令](#7-下发业务指令)
8. [自动重连策略](#8-自动重连策略)
9. [系统蓝牙状态联动](#9-系统蓝牙状态联动)
10. [Mock / 单测](#10-mock--单测)（**源码 pod 专用**）
11. [扩展一种新设备类型](#11-扩展一种新设备类型)
12. [日志](#12-日志)
13. [常见问题](#13-常见问题)

### Part B — [公开 API 参考](#公开-api-参考)

- [Service](#service) · [Core](#core) · [Device / Registry](#device--registry) · [Protocol / Filters](#protocol--filters) · [C100 / C110 / XA01](#c100--c110--xa01) · [Logger / Persistence](#logger--persistence)

---

## 1. 整体架构

```
┌──────────────────────────────────────────────┐
│                 UI / ViewModel               │  只依赖 BluetoothServiceProtocol
└──────────────┬───────────────────────────────┘
               │  Rx 订阅 / 调用
               ▼
┌──────────────────────────────────────────────┐
│       BluetoothService（.shared 单例）        │  业务中间层：
│  - 设备缓存（add / remove / clear）            │  - 缓存即 devices 流
│  - 多设备管理 / 焦点切换                       │  - SwitchPolicy
│  - 自动重连（指数退避）                        │  - AutoReconnectPolicy
│  - 字节按 UUID 派发到 BluetoothDevice          │  - DeviceRegistry 查表
└──────────────┬───────────────────────────────┘
               │  仅暴露响应式接口
               ▼
┌──────────────────────────────────────────────┐
│             BluetoothManager                 │  纯 CoreBluetooth 封装
│  扫描 / 连接 / 服务发现 / Notify / Write       │  禁止业务分支
└──────────────────────────────────────────────┘
```

每个具体设备由 4 块小协议构成：

| 角色                        | 职责                                |
|-----------------------------|------------------------------------|
| `DeviceFilter`              | 判断扫描结果是否属于本设备类型       |
| `DeviceFactory`             | 持有 filter，并构造 Device 实例      |
| `BluetoothProtocolParser`   | 字节 → 事件                         |
| `BluetoothCommandBuilder`   | 业务指令 → 字节，并选择写入特征值    |
| `BluetoothDevice`           | 状态机（继承 `BaseReducerDevice`）  |

---

## 2. 快速开始

最少 5 步即可跑通一台设备：

```swift
import BluetoothKit
import RxSwift

let bag = DisposeBag()

// 1) 启动期注册支持的设备类型
DeviceRegistry.shared.register(C100Factory())

// 2) 拿到全局 Service 实例（单例，整个 App 共用同一份扫描 / 重连 / 设备缓存状态）
let service: BluetoothServiceProtocol = BluetoothService.shared

// 3) 订阅扫描结果
service.discoveredPeripherals
    .subscribe(onNext: { list in print("发现 \(list.count) 台外设") })
    .disposed(by: bag)

// 4) 开始扫描
service.startScan()

// 5) 找到目标设备后连接
service.discoveredPeripherals
    .compactMap { $0.first(where: { $0.name.hasPrefix("INMO") }) }
    .take(1)
    .subscribe(onNext: { peripheral in
        service.stopScan()
        service.connect(peripheral: peripheral)
    })
    .disposed(by: bag)
```

> Mock / 单测需要替换底层 manager 时，使用 `BluetoothService(manager: mock, registry: .shared)` 自行构造一份新的实例；不要去动 `.shared`。

---

## 2.A 新手教程：跟着场景走一遍

> 这一节按"App 真实生命周期"把所有 API 串起来，每一步都告诉你**什么时候调用、调用谁、为什么**。
> 第一次接入 BluetoothKit 的同学只看这一节就能跑通主流程。

App 完整时间线：

```
App 启动
  └─ ① 注册设备工厂
用户登录
  ├─ ② bindUser(userID)
  └─ ②.5 reconnectLast() —— 一行 API 自动连上"上次的眼镜"
首页 / 设备页
  ├─ ③ 订阅 devices / currentDevice / connectionState
  └─ ④ 已绑定设备需要联网时：connect(peripheral:)
绑定新设备
  ├─ ⑤ startScan(for: 工厂)
  ├─ ⑥ 用户从扫描结果里挑一台 → connect(peripheral:)
  └─ ⑦ stopScan()
日常使用
  ├─ ⑧ send(command:) 下发指令
  └─ ⑨ 掉线？SDK 自动重连，你什么都不用做
解绑某台设备
  └─ ⑩ removeDevice(device)
退出登录
  └─ ⑪ unbindUser()
注销账号 / 解绑全部
  └─ ⑫ clearDevices()
```

下面分步细讲。

---

### ① App 启动 —— 注册设备工厂（仅一次）

**时机**：`AppDelegate.didFinishLaunching` 或 `SceneDelegate.willConnectTo` 等"App 进程启动后只会跑一次"的位置。

**目的**：告诉 SDK"我这个 App 支持哪几种设备"。注册之后 SDK 才知道扫描到一台 C100 时该构造哪种 `BluetoothDevice`。

```swift
// AppDelegate.swift
import BluetoothKit

func application(_ application: UIApplication,
                 didFinishLaunchingWithOptions launchOptions: [...]?) -> Bool {
    DeviceRegistry.shared.register(C100Factory())
    // 如果还支持其它设备：
    // DeviceRegistry.shared.register(C110Factory())
    return true
}
```

⚠️ 不要在 ViewController 里注册 —— 多次进入会重复注册，造成同一台外设被多次匹配。

---

### ② 用户登录成功 —— `bindUser(userID:)`

**时机**：登录回调里、拿到 `userID` 的那一刻。**必须早于"显示设备列表"或"扫描"**。

**做了什么**：
1. 把当前用户身份记下来（之后所有持久化都按这个 ID 分区）；
2. 自动从 `UserDefaults` 把这位用户上次绑过的设备列表读回来，构造成 `BluetoothDevice` 占位塞入缓存；
3. UI 立刻就能在 `service.devices` 流里看到"已绑定 N 台"。

```swift
// 登录成功后
AuthService.shared.signIn { result in
    guard case .success(let user) = result else { return }
    BluetoothService.shared.bindUser(user.id)
    //     ↑ user.id 是 String：业务侧自定义，SDK 不解释
    coordinator.showHome()
}
```

**App 冷启动时也要调一次吗？** 是的——只要用户登录态还在，App 启动后第一件事就是 `bindUser`，
否则 SDK 不知道现在是哪个用户、不会自动恢复列表。建议封装到统一的"启动后引导"逻辑里：

```swift
// SceneDelegate.swift
func sceneDidBecomeActive(_ scene: UIScene) {
    if let userID = AuthService.shared.cachedUserID {
        BluetoothService.shared.bindUser(userID)
    }
}
```

---

### ②.5 紧跟 `bindUser` —— `reconnectLast()` 自动回连上次的眼镜

**时机**：在 `bindUser(userID)` 成功之后的下一行。可以放在登录回调里，也可以放在冷启动的"恢复登录态"逻辑里。

**做了什么**：根据当前用户的"最后一次成功连接"记录，自动定位 CBPeripheral 句柄并连上。**整个流程不需要扫描**，对用户来说"打开 App 就连好了"。

```swift
AuthService.shared.signIn { result in
    guard case .success(let user) = result else { return }
    BluetoothService.shared.bindUser(user.id)

    if !BluetoothService.shared.reconnectLast() {
        // 上次设备的句柄被系统遗忘，或本账号从未连过任何设备
        // → 提示用户去搜索一台
        coordinator.showBindGuide()
    }
}
```

**返回 `false` 的几种情况**：

| 原因                                                          | 处理建议                                  |
|---------------------------------------------------------------|-------------------------------------------|
| `currentUserID == nil`（忘了 `bindUser`）                     | 检查调用顺序，必须先 bindUser              |
| 当前用户从未连过任何设备                                      | 跳到"添加设备"流程                         |
| 缓存里没有占位、且持久化里也没有该 UUID 的快照（脏数据）       | 跳到"添加设备"流程                         |
| 持久化快照存在但 DeviceRegistry 找不到对应工厂（产品已下架）  | 跳到"添加设备"流程                         |
| CBPeripheral 句柄已被系统侧释放（很久没连、清缓存等）         | 走扫描兜底（见下方完整示例）                |

**完整示例：先无扫描回连，失败时降级到扫描**：

```swift
let svc = BluetoothService.shared
svc.bindUser(user.id)

if svc.reconnectLast() {
    // 已成功调度一次连接尝试，UI 上显示"连接中…"即可
    return
}

// 兜底：用上次设备的 UUID 做定向扫描，扫到后再 connect
guard let targetID = svc.lastConnectedIdentifier else {
    coordinator.showBindGuide()
    return
}

let hint = svc.lastConnectedPeripheral?.name ?? "设备"
toast("正在搜索 \(hint)…")

svc.discoveredPeripherals
    .compactMap { list in list.first { $0.identifier == targetID } }
    .take(1)
    .timeout(.seconds(15), scheduler: MainScheduler.instance)
    .subscribe(
        onNext: { hit in
            svc.stopScan()
            svc.connect(peripheral: hit)
        },
        onError: { _ in
            svc.stopScan()
            self.toast("找不到上次连接的眼镜，请确认设备已开机")
        }
    )
    .disposed(by: bag)
svc.startScan()
```

**关键事实**：

- `reconnectLast()` 内部会**自动给"上次设备"补一个 Device 占位**（通过持久化快照 + DeviceRegistry 工厂），所以即便缓存里此刻只有别的设备、甚至空缓存，也能正确发起回连；
- 句柄优先用 `BluetoothService` 内部的 `peripheralsByID` 表；找不到时通过 CoreBluetooth 标准 API `retrievePeripherals(withIdentifiers:)` 反查（这个 API 不需要扫描，是 BLE "回连"的标准入口）；
- 拿到句柄后内部直接走 `connect(peripheral:)` 公开路径，意图位 / 自动重连 / 心跳一并跑起来。

⚠️ **不要**在没有 `bindUser` 的状态下调用 `reconnectLast()` —— 会 no-op 返回 `false`，并打 info 日志 `reconnectLast skip: no lastConnected`。

---

### ③ 首页 / 设备页 —— 订阅响应式流

**时机**：`viewDidLoad` 里建立订阅；ViewController 销毁时由 `DisposeBag` 自动断订。

**订阅哪几条**：

| 流                          | 用途                                                         |
|-----------------------------|--------------------------------------------------------------|
| `service.devices`           | 已绑定 / 已加入缓存的设备列表，做表格 / 卡片                  |
| `service.currentDevice`     | 当前焦点设备，用来驱动"详情页 / 大卡片 / 当前电量"等组件       |
| `service.connectionState`   | 连接状态机事件，做 toast 提示（连接中 / 失败 / 蓝牙未开启）     |
| `service.reconnecting`      | 正在重连的 UUID 集合，给设备卡片打"重连中"角标                  |

```swift
final class HomeVC: UIViewController {
    private let bag = DisposeBag()
    private let service = BluetoothService.shared

    override func viewDidLoad() {
        super.viewDidLoad()

        // 列表
        service.devices
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] devices in
                self?.tableView.reload(with: devices)
            })
            .disposed(by: bag)

        // 焦点设备 → 大卡片
        service.currentDevice
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] device in
                self?.heroCard.bind(device)
            })
            .disposed(by: bag)

        // 连接状态 toast
        service.connectionState
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] state in
                switch state {
                case .connecting:    self?.toast("连接中…")
                case .connected:     self?.toast("已连接")
                case .failed:        self?.toast("连接失败")
                case .poweredOff:    self?.toast("请打开蓝牙")
                default: break
                }
            })
            .disposed(by: bag)
    }
}
```

⚠️ 不要在 `bindService` 之前调 `service.startScan()`——订阅没建立就开扫，第一帧扫到的设备会被丢掉。
顺序：**先订阅，再触发动作**。

---

### ④ 已绑定设备需要联网 —— `connect(peripheral:)`

**时机**：用户进入"我的眼镜"页 / 点击设备卡片"立即连接"时。

**前置条件**：
- 该设备已经在缓存里（`bindUser` 恢复出来的，或者上次绑定后还没退出过登录）；
- 拿得到 `BluetoothPeripheral`：扫描期间能拿到带 `CBPeripheral` 句柄的版本；从持久化恢复出来的版本没有句柄，
  下次扫到同一 UUID 时句柄会自动回填。

```swift
deviceCardTap
    .withLatestFrom(service.currentDevice)
    .compactMap { $0 }
    .subscribe(onNext: { device in
        // 用扫到的 peripheral 触发 connect；只有 device 占位时需要先扫一次
        BluetoothService.shared.startScan(for: C100Factory())
            .compactMap { $0.first(where: { $0.identifier == device.peripheralIdentifier }) }
            .take(1)
            .subscribe(onNext: { peripheral in
                BluetoothService.shared.stopScan()
                BluetoothService.shared.connect(peripheral: peripheral)
            })
            .disposed(by: bag)
    })
    .disposed(by: bag)
```

如果系统蓝牙还没打开，`connect` 不会报错——`BluetoothManager` 会把请求挂起，蓝牙就绪后自动重发。

---

### ⑤ 绑定新设备：开始扫描 —— `startScan(for: 工厂)`

**时机**：用户点击"添加新眼镜"按钮 → 跳转到搜索页 → `viewDidLoad` 里调。

**用 `startScan(for:)` 而不是 `startScan()` 的好处**：返回的 Observable 已经按设备类型 filter 过滤，
搜索页只会看到 C100，不会被路由器 / 耳机等其它蓝牙设备污染。

```swift
final class BindSearchVC: UIViewController {
    private let bag = DisposeBag()
    override func viewDidLoad() {
        super.viewDidLoad()
        BluetoothService.shared.startScan(for: C100Factory())
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] list in
                self?.show(devices: list)
            })
            .disposed(by: bag)
    }
}
```

---

### ⑥ 用户挑了一台 —— `connect(peripheral:)` 触发首次连接

**时机**：用户点击搜索结果里的某一行。

**SDK 自动做的事**：
1. 标记"用户希望保持连接"意图位（之后掉线会自动重连）；
2. 通过 `DeviceRegistry` 找到 C100Factory，构造 `BluetoothDevice` 占位塞入缓存；
3. **如果已 `bindUser`**：自动把这台外设的快照写进当前用户的持久化 → 下次启动 `bindUser` 时还能恢复；
4. 触发底层 `central.connect`。

```swift
tableView.rx.modelSelected(BluetoothPeripheral.self)
    .subscribe(onNext: { peripheral in
        BluetoothService.shared.connect(peripheral: peripheral)
    })
    .disposed(by: bag)
```

---

### ⑦ 连接成功后 —— `stopScan()`

**时机**：`connectionState` 收到 `.connected` 时；或用户离开搜索页时。

**为什么要停**：iOS 后台扫描有耗电与策略限制；连上之后没必要继续广播扫描。

```swift
service.connectionState
    .filter { if case .connected = $0 { return true }; return false }
    .take(1)
    .subscribe(onNext: { _ in
        BluetoothService.shared.stopScan()
        coordinator.dismissBindSearch()
    })
    .disposed(by: bag)
```

---

### ⑧ 日常使用 —— `send(command:)`

**时机**：用户在 UI 上做了一个"对设备说话"的动作（截图、调音量、翻译……）。

```swift
volumeSlider.rx.value
    .throttle(.milliseconds(200), scheduler: MainScheduler.instance)
    .subscribe(onNext: { value in
        BluetoothService.shared.send(command: C100Command.setVolume(value))
    })
    .disposed(by: bag)
```

没有焦点设备时 `send` 是 no-op，不会抛错。多设备共存时通过 `switchDevice(_:)` 切焦点。

---

### ⑨ 自动重连 —— **你不用做任何事**

**时机**：设备意外掉线（用户走出蓝牙范围、设备进充电仓、电量耗尽……）。

SDK 默认行为（`autoReconnectPolicy = .default`）：
- 最多重试 3 次；1s → 2s → 4s … 30s 上限的指数退避；
- 系统蓝牙关闭时自动暂停，重新打开后批量恢复；
- `service.reconnecting` 流告诉 UI 哪些 UUID 正在重连。

若需更多次数或无限重试（`maxAttempts: nil`）：

```swift
BluetoothService.shared.autoReconnectPolicy = AutoReconnectPolicy(
    isEnabled: true,
    maxAttempts: 6,         // 6 次后放弃；nil = 无限
    initialDelay: 1.0,
    maxDelay: 30.0,
    backoffMultiplier: 2.0,
    retryOnConnectFailure: true
)
```

---

### ⑩ 用户解绑某台设备 —— `removeDevice(_:)`

**时机**：用户在"我的眼镜"页点击"解绑此设备"。

**做了什么（一次性全包）**：
1. 撤销重连意图（之后掉线不会自动连）；
2. 取消该设备所有排队中的重试任务；
3. 如果当前还连着，触发 `manager.disconnect`；
4. 从缓存中移除占位（焦点会切到下一台）；
5. 从当前用户的持久化记录里删掉。

```swift
unbindButton.rx.tap
    .withLatestFrom(service.currentDevice)
    .compactMap { $0 }
    .subscribe(onNext: { device in
        BluetoothService.shared.removeDevice(device)
    })
    .disposed(by: bag)
```

---

### ⑪ 退出登录 —— `unbindUser()`

**时机**：用户点击"退出登录"按钮。

**关键差异（vs `clearDevices()`）**：`unbindUser` **保留持久化**——下次同一个 userID 登回来，
`bindUser` 还能完整恢复列表。`clearDevices` 会连持久化一起清，那是"注销账号"才用的。

```swift
logoutButton.rx.tap
    .subscribe(onNext: { _ in
        BluetoothService.shared.unbindUser()
        AuthService.shared.signOut()
        coordinator.showLogin()
    })
    .disposed(by: bag)
```

---

### ⑫ 注销账号 / "解绑全部" —— `clearDevices()`

**时机**：账号注销流程；或用户在设置里点了"解绑全部设备"。

```swift
deleteAccountButton.rx.tap
    .subscribe(onNext: { _ in
        BluetoothService.shared.clearDevices()    // 清当前用户的内存 + 持久化
        BluetoothService.shared.unbindUser()      // 把 currentUserID 也置 nil
        AuthService.shared.deleteAccount()
    })
    .disposed(by: bag)
```

如果只想清掉某个**非当前用户**的存盘数据（例如管理后台清理离职员工绑定）：

```swift
BluetoothService.shared.clearPersistedDevices(for: targetUserID)
```

---

### 时机速查表

| 业务事件                  | 调用                                                  | 在哪里调                            |
|---------------------------|-------------------------------------------------------|-------------------------------------|
| App 启动                  | `DeviceRegistry.shared.register(...)`                 | `AppDelegate.didFinishLaunching`    |
| 登录成功 / 冷启动有 token | `BluetoothService.shared.bindUser(userID)`            | 登录回调 / `sceneDidBecomeActive`   |
| 自动连上"上次的眼镜"      | `BluetoothService.shared.reconnectLast()`             | `bindUser` 之后下一行                |
| 进入设备页                | 订阅 `devices` / `currentDevice` / `connectionState`  | `viewDidLoad`                       |
| 已绑定设备需要联网        | `connect(peripheral:)`                                | 用户点击"立即连接"或自动连接策略    |
| 进入"添加设备"页          | `startScan(for: 工厂)`                                 | `viewDidLoad`                       |
| 用户选中扫描结果          | `connect(peripheral:)`                                | 列表点击事件                        |
| 连上之后                  | `stopScan()`                                          | `connectionState == .connected`     |
| 下发指令                  | `send(command:)`                                      | UI 动作回调                         |
| 设备意外掉线              | （无需调用）                                            | SDK 自动重连                        |
| 用户解绑某台              | `removeDevice(device)`                                | "解绑此设备"按钮                    |
| 用户退出登录              | `unbindUser()`                                        | "退出登录"按钮                      |
| 注销账号 / 解绑全部       | `clearDevices()` + `unbindUser()`                     | 注销流程                            |
| 切换账号                  | `bindUser(newID)`（无须先 unbind）                     | 切换账号回调                        |

### 容易踩的坑

1. **忘了 `bindUser`**：所有 `addDevice / removeDevice / connect / clearDevices` 都不会写持久化，下次启动一片空白。
2. **`bindUser` 之后立刻 `clearDevices`**：会把当前用户的持久化也清掉。复位请用 `unbindUser` + 再次 `bindUser`。
3. **多个 ViewController 各自 `register` 工厂**：注册顺序混乱，匹配优先级不可控。注册只能在 App 启动入口做一次。
4. **在订阅之前 startScan**：第一帧广播会被丢。先订阅 `discoveredPeripherals`，再调 `startScan`。
5. **试图持久化非 Codable 的广播报字段**（如 `CBUUID`）：SDK 会自动丢弃这部分，连接后服务发现阶段会重新拿到，**不影响业务**。

---

## 3. 启动期注册设备工厂

只需要在 `AppDelegate` / `SceneDelegate` 启动逻辑里注册一次即可：

```swift
DeviceRegistry.shared.register(C100Factory())
// DeviceRegistry.shared.register(SmartGlassesFactory())  // 源码 pod 专用（Example 子规格），二进制不可用
// 还有更多官方设备类型，继续 register…
```

> 注册顺序即匹配优先级。同一台外设若同时被多个 filter 命中，先注册的工厂胜出。
>
> **源码 pod 专用：** `SmartGlassesFactory` 等 Example 示例类型仅存在于源码仓 `Example` 子规格，**不会**打进二进制交付；二进制客户请只注册 `C100Factory` / `C110Factory` / `XA01Factory` 等官方工厂。
---

## 4. 扫描

### 4.1 普通扫描（不限类型）

```swift
service.startScan()
service.stopScan()

service.discoveredPeripherals
    .subscribe(onNext: { list in /* 全部扫描结果 */ })
    .disposed(by: bag)
```

### 4.2 按设备类型搜索（新方法）

> 入参与 `DeviceRegistry.register(_:)` 完全一致：把同一个工厂实例传进去即可。  
> 用于"我现在只想搜某一类设备"的场景。

```swift
service.startScan(for: C100Factory())
    .subscribe(onNext: { c100List in
        // 这里只会拿到 C100，不会出现别的设备
        print("当前扫描到 \(c100List.count) 台 C100")
    })
    .disposed(by: bag)
```

特性：

- 内部仍调用一次普通 `startScan()`，**不会**自行 stopScan，由调用方控制；
- 返回的 Observable 已经做了"按 UUID 列表"去抖（同一台设备 RSSI 刷新不会重复发布列表）；
- 可以同时订阅多个类型：

```swift
let c100$ = service.startScan(for: C100Factory())
let c110$ = service.startScan(for: C110Factory())
// let glasses$ = service.startScan(for: SmartGlassesFactory())  // 源码 pod 专用（Example）

Observable.combineLatest(c100$, c110$)
    .subscribe(onNext: { c100List, c110List in
        // 同一次扫描期间分别拿到两类设备的最新列表
    })
    .disposed(by: bag)
```
### 4.3 按任意过滤器搜索

业务侧手里没有完整工厂，只想临时按名字 / 服务 UUID 搜一批设备时：

```swift
let myServiceUUID = CBUUID(string: "0000XXXX-0000-1000-8000-00805F9B34FB") // 业务自有服务 UUID
let filter = AllOfFilter(
    NameLengthFilter(minLength: 1),
    AnyOfFilter(
        NamePrefixFilter("INMO", "Demo"),
        ServiceUUIDFilter(myServiceUUID)
    )
)

service.startScan(matching: filter)
    .subscribe(onNext: { list in /* 命中的外设 */ })
    .disposed(by: bag)
```

---

## 5. 连接 / 断开 / 多设备切换

### 5.1 连接

```swift
service.connect(peripheral: peripheral)
```

调用后内部会：

1. 标记"保持连接意图"位（后续掉线会自动重连）；
2. 通过 `DeviceRegistry` 找到匹配工厂，构造 `BluetoothDevice` 占位；
3. 触发底层 `central.connect`。

### 5.2 主动断开

```swift
service.disconnect(device: device)
```

会**清除"保持连接意图"位**，从此不再自动重连；同时移除 `devicesRelay` 中的占位与查找表。

### 5.3 取消自动重连但保持当前连接

```swift
service.cancelAutoReconnect(for: device)
```

不会立即断开——只是把"未来掉线后是否自动重连"开关关掉。

### 5.4 多设备切换

```swift
// 切换策略：默认 .disconnectPrevious（独占模式）
service.switchPolicy = .disconnectPrevious   // 切换时断开旧设备
service.switchPolicy = .keepBothConnected    // 保持双连，仅切换"焦点"

service.switchDevice(targetDevice)
```

### 5.5 设备缓存管理

> 自 `BluetoothService` 改为单例后，整个 App 共享同一份"已接管的 BluetoothDevice 列表"，
> 该列表即"设备缓存"。响应式视图 = `devices` 流；同步视图 = `cachedDevices` 属性。
>
> 缓存的生命周期**与 BLE 连接事件解耦**：业务侧可以独立 add / remove / clear 占位，
> BLE 层的连接 / 重连仍然各自按原逻辑跑。这意味着"已绑定但未连接"、
> "扫描到但未连接"、"已连接"三种状态都可以在缓存中表示。

#### 5.5.1 `addDevice(_ device: BluetoothDevice)`

把一个**已经构造好**的 `BluetoothDevice` 占位放入缓存。

| 项目              | 行为                                                     |
|-------------------|----------------------------------------------------------|
| 是否触发 BLE 连接 | **否**——只更新内存中的缓存与焦点                         |
| 是否设置重连意图  | **否**——后续即便系统蓝牙恢复也不会自动连这台设备         |
| 幂等性            | 是。同一 UUID 重复 add 会被静默忽略                       |
| 焦点行为          | 仅当缓存原本为空时，被 add 的设备会成为 `currentDevice`   |

**典型用法 — 启动期从持久化恢复"已绑定设备"列表：**

```swift
// 假设 MyBindingStore 持久化了上次绑定时的外设元信息（identifier / 名称等），
// 重新构造 BluetoothPeripheral 占位用于显示，但暂不发起连接。
let stored: [BluetoothPeripheral] = MyBindingStore.load()
let factory = C100Factory()

for peripheral in stored where factory.canHandle(peripheral) {
    let device = factory.makeDevice(peripheral, manager: BluetoothManager())
    BluetoothService.shared.addDevice(device)
}

// UI 订阅 devices 流，立刻就能看到"已绑定 N 台 C100"
BluetoothService.shared.devices
    .subscribe(onNext: { list in tableView.reloadData(with: list) })
    .disposed(by: bag)

// 用户点击其中某一台 → 才真正发起连接
BluetoothService.shared.connect(peripheral: stored[0])
```

**典型用法 — 单测 / Mock 场景手动注入设备：**

```swift
let mock = MockBluetoothManager()
let service = BluetoothService(manager: mock, registry: .shared)
let device  = C100Factory().makeDevice(mock.makePeripheral(name: "C100-Test"),
                                       manager: mock)
service.addDevice(device)
// 后续就可以直接对 device 派发字节、断言状态机
```

⚠️ **不要这样用**：

- ❌ 拿来"代替"`connect`：`addDevice` 只是把对象塞进缓存，并不会让 BLE 真正连上设备。
- ❌ 重复构造同一 UUID 的 Device：会被忽略，但说明上层逻辑可能在重复触发，应排查调用源。

---

#### 5.5.2 `removeDevice(_ device: BluetoothDevice)` / `removeDevice(identifier: UUID)`

从缓存中移除一台设备，并完成**一站式清理**：

1. 撤销"保持连接意图"位（之后掉线不会再自动重连）；
2. 取消该设备所有排队中的重试任务，并从 `reconnecting` 集合里移除；
3. 若该外设当前仍处连接状态，调用 `manager.disconnect`（对未连接外设也是安全的）；
4. 从 `peripheralsByID` 查找表里清掉 CBPeripheral 句柄；
5. 从 `devicesRelay` 中移除占位；若被移除的恰好是 `currentDevice`，焦点会切到列表中的第一个候选（可能为 `nil`）。

两个重载在功能上完全等价，仅在调用方手里持有的对象不同时使用：

```swift
// 持有 BluetoothDevice 实例时
BluetoothService.shared.removeDevice(device)

// 只持有 UUID（例如从持久化里读到的标识、回调里只暴露 UUID 的场景）
BluetoothService.shared.removeDevice(identifier: device.peripheralIdentifier)
```

**典型用法 — 用户在 UI 上点击"解绑此设备"：**

```swift
unbindButton.rx.tap
    .withLatestFrom(BluetoothService.shared.currentDevice)
    .compactMap { $0 }
    .subscribe(onNext: { device in
        BluetoothService.shared.removeDevice(device)
        MyBindingStore.delete(device.peripheralIdentifier)
    })
    .disposed(by: bag)
```

**典型用法 — 后端回调"设备已被远端注销"（只能拿到 UUID）：**

```swift
notificationCenter.rx.notification(.deviceRevoked)
    .compactMap { $0.userInfo?["uuid"] as? UUID }
    .subscribe(onNext: { uuid in
        BluetoothService.shared.removeDevice(identifier: uuid)
    })
    .disposed(by: bag)
```

**与 `disconnect(device:)` 的关系**：`disconnect(device:)` 在内部直接调 `removeDevice(_:)`，
两者在外部行为上等价。保留 `disconnect` 是为了语义清晰（"只是想断开这一次"）。

⚠️ **不要这样用**：

- ❌ 用 `removeDevice` 来"暂时挂起"一台设备：它会**清掉重连意图**，
  挂起后再连不会自动恢复重连。临时挂起请使用 `cancelAutoReconnect(for:)`。
- ❌ 在 `connectionState.disconnected` 回调里调用 `removeDevice`：内部已经按
  "意图位 + reason" 自动清理过了，外部再调一次容易让用户的"想保持连接"被误清。

---

#### 5.5.3 `clearDevices()`

一键清空缓存。等价于对当前缓存里每台设备依次调用 `removeDevice(_:)`，外加一次"全量复位"：

| 副作用                   | 行为                                                |
|--------------------------|-----------------------------------------------------|
| 重连意图位 / 排队任务    | 全部清空（包括"只在 trackers 里登记过、还没进缓存"的） |
| `peripheralsByID` 查找表 | 全部清空                                            |
| `reconnecting` 集合      | 立即发布 `[]`                                       |
| `devicesRelay`           | 清空，订阅者立即收到 `[]`                            |
| `currentRelay`           | 置 `nil`                                            |
| 已连接外设               | 全部触发 `manager.disconnect`                        |
| 当前正在进行的扫描       | **不影响**——`startScan` / `stopScan` 自管           |

**典型用法 — 退出登录 / 切换账号：**

```swift
func logout() {
    BluetoothService.shared.stopScan()        // 可选：顺便停掉扫描
    BluetoothService.shared.clearDevices()    // 把"上一个账号绑定的设备"全清掉
    MyBindingStore.removeAll()
    AuthService.shared.signOut()
}
```

**典型用法 — 调试 / 集成测试做"复位"：**

```swift
override func tearDown() {
    BluetoothService.shared.clearDevices()
    DeviceRegistry.shared.unregisterAll()
    super.tearDown()
}
```

⚠️ **不要这样用**：

- ❌ 在 ViewController 的 `deinit` 里调用：当前页关闭不代表"全部解绑"，
  可能误清其它页面正在使用的设备。这种"局部复位"应只 `removeDevice` 自己关心的那一台。

---

#### 5.5.4 `device(for identifier: UUID) -> BluetoothDevice?`

按 UUID **同步**查询缓存中的占位。适合一次性判断，例如：

```swift
// 启动时判断"上次绑定的设备是否已经在缓存里"
if BluetoothService.shared.device(for: lastBoundUUID) == nil {
    // 还没 add 过，触发恢复流程
    restoreBoundDevice()
}

// 在 connect 之前避免重复构造
guard BluetoothService.shared.device(for: peripheral.identifier) == nil else { return }
```

需要**响应式订阅**整张列表请改用 `devices` 流；本方法返回的是当前快照，
后续状态变化不会回调。

---

#### 5.5.5 `cachedDevices: [BluetoothDevice]` / `devices: Observable<[BluetoothDevice]>`

两者展示的是同一份缓存，只是访问方式不同：

| 接口             | 形态     | 何时用                                                  |
|------------------|----------|---------------------------------------------------------|
| `cachedDevices`  | 同步快照 | 想立刻读一次（log、判断个数、构造命令前的预检）          |
| `devices`        | Rx 流    | UI 跟随刷新；与其它 Observable 组合（combineLatest 等） |

```swift
// 同步：日志当前缓存中的设备数
BluetoothLogger.info("当前缓存 \(BluetoothService.shared.cachedDevices.count) 台")

// 响应式：列表 UI
BluetoothService.shared.devices
    .observe(on: MainScheduler.instance)
    .bind(to: tableView.rx.items(cellIdentifier: "Cell")) { _, device, cell in
        cell.textLabel?.text = device.name
    }
    .disposed(by: bag)
```

---

#### 5.5.6 速查表

| 方法                            | 修改重连意图位 | 触发 BLE 断开    | 修改设备缓存          | 联动持久化¹           |
|---------------------------------|----------------|-------------------|------------------------|------------------------|
| `addDevice(_:)`                 | 否             | 否                | 是（幂等加入）         | 否（无快照）           |
| `addDevice(_:peripheral:)`      | 否             | 否                | 是（幂等加入）         | 是²                    |
| `removeDevice(_:)`              | 是（清掉）     | 是（仅当还连着）  | 是（移除）             | 是²                    |
| `removeDevice(identifier:)`     | 是（清掉）     | 是（仅当还连着）  | 是（移除）             | 是²                    |
| `clearDevices()`                | 全部清掉       | 全部断开          | 全部清空               | 是²（清当前用户）      |
| `disconnect(device:)`           | 是（清掉）     | 是                | 是（= `removeDevice`） | 是²                    |
| `cancelAutoReconnect(for:)`     | 是（清掉）     | 否                | 否                    | 否                     |
| `device(for:)` / `cachedDevices`| 否             | 否                | 否（只读）             | 否                     |

¹ 持久化联动一律以 `currentUserID != nil` 为前提；若未 `bindUser`，所有"是²"列退化为"否"。
² 调用方可通过 `persist: false` 显式禁用本次落库 / 删库（多用于内部恢复路径）。

---

### 5.6 用户身份与持久化

> 设备缓存以**用户身份**为分区键。同一台手机可以承载多个账号的绑定关系，
> SDK 会按 `BluetoothUserID` 把"已绑定外设列表"独立存到持久化里，
> 切换账号时只需 `bindUser(newID)`，缓存与持久化会自动按新用户重新装载。
>
> 用户身份本身**完全由业务侧定义**——SDK 只把它当成一个分区键 String 使用，
> 不解释含义。常见取值：登录态返回的 `userId` / `accountId` / 设备绑定关系 ID。

#### 5.6.1 单例 + 默认 UserDefaults 持久化的最简流程

```swift
// 0) 启动期注册设备工厂
DeviceRegistry.shared.register(C100Factory())

// 1) 登录成功 → 把当前账号绑给 SDK
let myUserID: BluetoothUserID = AuthService.shared.user.id   // String
BluetoothService.shared.bindUser(myUserID)
//   ↳ 自动从 UserDefaults 读出该用户上次绑过的 C100 列表，
//     借 DeviceRegistry 工厂构造 BluetoothDevice 占位，
//     塞进缓存（不会重复落库）。UI 立刻能看到"已绑定 N 台"。

// 2) 用户在 UI 上点击 "搜索 + 绑定一台新眼镜"
BluetoothService.shared.discoveredPeripherals
    .compactMap { $0.first(where: { C100Factory().filter.matches($0) }) }
    .take(1)
    .subscribe(onNext: { peripheral in
        BluetoothService.shared.connect(peripheral: peripheral)
        //   ↳ connect 内部 addDevice(_:peripheral:peripheral) 时
        //     检测到 currentUserID != nil，自动把这条快照写进
        //     UserDefaultsBluetoothPersistence。下次启动 bindUser 同一个 userID 就能恢复。
    })
    .disposed(by: bag)

// 3) 用户解绑某台
BluetoothService.shared.removeDevice(device)
//   ↳ 同步把这台从持久化里删掉。

// 4) 退出登录（保留绑定关系，下次登回来还能恢复）
BluetoothService.shared.unbindUser()

// 5) 注销账号 / 解绑全部（连持久化一起清）
BluetoothService.shared.clearDevices()        // 清当前用户 + 内存
//   或显式：
BluetoothService.shared.clearPersistedDevices(for: myUserID)   // 仅清持久化
```

#### 5.6.2 `bindUser(_ userID: BluetoothUserID)`

**作用**：把当前用户绑给 SDK，并自动恢复该用户的已绑定设备到内存缓存。

| 步骤 | 行为                                                                   |
|------|------------------------------------------------------------------------|
| 1    | 对**上一位用户**的内存缓存做 `clearDevices(persist: false)` —— 只清内存、不动持久化，避免账号串号 |
| 2    | `currentUserID = userID`                                              |
| 3    | `persistence.loadPeripherals(for: userID)` 读出快照列表                 |
| 4    | 对每条快照：`DeviceRegistry.factory(for:)` 找工厂 → `factory.makeDevice(...)` 构造 Device → `addDevice(..., persist: false)` 塞入缓存 |
| 5    | 找不到工厂的快照打 warn 日志后跳过（视为脏数据，下次 connect 时正常路径仍会重新走）|

**调用时机**：
- 登录成功后；
- 切换账号时（直接 `bindUser(newID)` 即可，不需要先 `unbindUser`）；
- 已 `bindUser` 后想"按外部数据强制刷新"时（重复绑定同一 userID 会执行幂等的重新加载）。

**典型用法**：

```swift
// 登录回调里
AuthService.shared.signIn { result in
    switch result {
    case .success(let user):
        BluetoothService.shared.bindUser(user.id)
    case .failure:
        break
    }
}

// 切换账号
func switchAccount(to newUser: User) {
    BluetoothService.shared.bindUser(newUser.id)
    // 旧账号设备占位已自动清空，新账号绑定关系已自动恢复
}
```

⚠️ **不要这样用**：

- ❌ 在 `bindUser` 之后立刻调用 `clearDevices()` 想做"复位"——这会把当前用户的持久化也清掉。
  正确做法是在 `bindUser` 之前调，或换用 `unbindUser` + `bindUser`。
- ❌ 把多个不同用户的设备混在同一个 userID 下——SDK 不会做去重 / 校验，污染了就需要 `clearPersistedDevices(for:)` 手动恢复。

---

#### 5.6.3 `unbindUser()`

**作用**：解绑当前用户。清空内存缓存、`currentUserID = nil`，**保留持久化**。

与 `clearDevices()` 的差异：

| 副作用              | `unbindUser()` | `clearDevices()` |
|---------------------|----------------|------------------|
| 内存缓存            | 清空           | 清空             |
| `currentUserID`     | 置 `nil`       | 不变             |
| 当前用户的持久化    | **保留**       | 清空             |
| 已连接外设          | 全部断开       | 全部断开         |

**典型用法**：

```swift
// 退出登录但保留绑定记录（下次登回来仍可看到自己的眼镜列表）
func logout() {
    BluetoothService.shared.unbindUser()
    AuthService.shared.signOut()
}

// 临时让 SDK 进入"无主"状态（例如某些匿名页面）
BluetoothService.shared.unbindUser()
// ... 匿名扫描 / 试连 ...
BluetoothService.shared.bindUser(userID)
```

---

#### 5.6.4 `loadPersistedDevices(for userID:)`

**作用**：在**不改变** `currentUserID` 的前提下，把指定用户的持久化记录补到当前缓存里。
已存在的占位（同 UUID）不会被重复加入。

适合场景：
- "预览另一个账号的已绑定设备"：跨账号查看绑定历史，不会污染当前用户的持久化；
- 已 `bindUser` 后某些路径需要"按需补刷"：例如服务端推送了"该账号刚加了一台设备"，业务侧把推送数据写入 `persistence` 后调用此方法刷新视图。

```swift
// 跨账号查看：管理员视角
let preview = BluetoothService.shared.persistedPeripherals(for: "admin-target-user")
print("目标用户绑定了 \(preview.count) 台设备")
//   ↳ 不会污染缓存；如果要把这些放进当前缓存做高亮 / 调试：
BluetoothService.shared.loadPersistedDevices(for: "admin-target-user")
```

---

#### 5.6.5 `clearPersistedDevices(for userID:)`

**作用**：**只清持久化**，不动内存缓存。可以传任意 userID（不一定是 `currentUserID`）。

适合场景：
- 注销账号（账号已删，缓存里的占位无所谓，先把存盘记录清掉）；
- 数据迁移工具：清理某个旧账号的残留绑定。

```swift
// 注销账号
func deleteAccount(userID: BluetoothUserID) {
    BluetoothService.shared.clearPersistedDevices(for: userID)
    if BluetoothService.shared.currentUserID == userID {
        BluetoothService.shared.unbindUser()
    }
}
```

> 与 `clearDevices()` 的差异：`clearDevices()` 同时清内存和当前用户持久化，
> 适合"当前账号一键解绑全部"的语义；`clearPersistedDevices(for:)` 适合
> "仅清盘 / 跨用户清盘"的语义。

---

#### 5.6.6 `persistedPeripherals(for userID:) -> [BluetoothPersistedPeripheral]`

**只读**地一次性读取指定用户的全部持久化快照。常用于：
- 调试 / 诊断面板 "看一眼磁盘里有什么"；
- "解绑前预览一遍"；
- 和服务端的绑定关系做 diff。

```swift
let snapshots = BluetoothService.shared.persistedPeripherals(for: myUserID)
for s in snapshots {
    print("  \(s.identifier) | \(s.name) | last RSSI=\(s.rssi)")
}
```

---

#### 5.6.7 替换持久化后端

默认实现写到 `UserDefaults.standard`，key 前缀为 `BluetoothKit.boundDevices.`（如 `BluetoothKit.boundDevices.<userID>` 与 `BluetoothKit.boundDevices.lastConnected.<userID>`）。首次读写时若新 key 为空，会依次从 `IMBluetoothKit.boundDevices.*`、`IMBluetoothFramework.boundDevices.*` 迁移到 `BluetoothKit.boundDevices.*` 并删除已迁走的旧 key。自定义 `keyPrefix` 不触发迁移。

若业务对持久化位置有约束（Keychain / 自定义 DB / 远端同步等），按以下方式注入：

```swift
final class MyKeychainPersistence: BluetoothDevicePersistence {
    // 已绑定外设列表（按 userID 分区）
    func loadPeripherals(for userID: BluetoothUserID) -> [BluetoothPersistedPeripheral] { ... }
    func savePeripherals(_ peripherals: [BluetoothPersistedPeripheral],
                         for userID: BluetoothUserID) { ... }
    func clearPeripherals(for userID: BluetoothUserID) { ... }

    // 「上次连接」的外设 UUID（按 userID 分区，给 reconnectLast() 用）
    func loadLastConnectedIdentifier(for userID: BluetoothUserID) -> UUID? { ... }
    func saveLastConnectedIdentifier(_ identifier: UUID?,
                                     for userID: BluetoothUserID) { ... }
}

// 必须在 bindUser 之前替换；切换后立即生效
BluetoothService.shared.persistence = MyKeychainPersistence()
BluetoothService.shared.bindUser(myUserID)
```

> 实现要求（与默认 `UserDefaultsBluetoothPersistence` 对齐）：
>
> - 所有方法**线程安全**（SDK 可能从主线程或重连队列调用）；
> - 同一 `userID` 下保留写入顺序（数组 append / remove，去重由 SDK 内部保证）；
> - `clearPeripherals(for:)` 是否同时清掉 `lastConnected` 由实现自定义；SDK 在 `clearDevices(persist: true)` 等路径里会**显式**再调一次 `saveLastConnectedIdentifier(nil, for:)`，所以即便实现里没顺手清也不会出问题；
> - 完全不需要持久化时直接用 `NoopBluetoothPersistence()`。

`BluetoothPersistedPeripheral` 是 `Codable`，业务侧可以直接 JSON 编/解码。
广播报字段会被裁成可序列化的子集（String / Int / Double / Bool / Data / 数组 / 字典），
非 Codable 类型（如 `CBUUID`）在持久化阶段被丢弃 —— 不影响下次 connect 后的正常服务发现。

#### 5.6.8 速查表

| 方法                                 | currentUserID  | 内存缓存       | 持久化（指定用户）    | 上次设备指针 |
|--------------------------------------|----------------|----------------|------------------------|--------------|
| `bindUser(_:)`                       | 写为新值       | 清空 + 按新值恢复 | 读                  | 不动        |
| `unbindUser()`                       | 置 `nil`       | 清空           | 不动                   | 不动（保留） |
| `loadPersistedDevices(for:)`         | 不变           | 追加（去重）   | 读                     | 不动        |
| `clearPersistedDevices(for:)`        | 不变           | 不动           | 清空                   | 清空        |
| `clearDevices(persist: true)`        | 不变           | 清空           | 清空（当前用户）       | 清空        |
| `persistedPeripherals(for:)`         | 不变           | 不动           | 读                     | 不动        |
| `removeDevice(_:persist: true)`      | 不变           | 移除该台       | 移除该条               | 仅当被删的就是上次设备时清空 |
| `connect(peripheral:)` 成功后        | 不变           | 占位入缓存     | 落库                   | **写入**为该 UUID |
| `switchDevice(_:)`                   | 不变           | 仅切焦点       | 不动                   | **写入**为新焦点 UUID |

---

### 5.7 获取与回连上一次设备

> **要解决的痛点**：用户上次连过一台 C100，App 杀掉重开后默认看不到任何"已连上"的状态——
> 必须重新扫描 → 在列表里挑一台 → connect。这个流程对老用户来说没必要。
>
> SDK 提供"按用户分区"记录"最近一次成功连接的外设 UUID"的能力，业务侧**一行 API** 就能恢复连接，无须扫描。

#### 5.7.1 数据是怎么进 / 怎么出的

```
.connected 事件
   ↓ 自动写入
persistence.saveLastConnectedIdentifier(uuid, for: currentUserID)
   ↓ 读出（按需）
service.lastConnectedIdentifier
service.lastConnectedPeripheral
service.lastConnectedDevice
   ↓ 一行回连
service.reconnectLast()
```

| 何时**写**入            | 触发                                              |
|-------------------------|---------------------------------------------------|
| 任意外设进入 `.connected` 状态 | SDK 在 `handleConnectionState` 里自动调 `recordLastConnected(id:)` |
| `switchDevice(_:)` 切焦点到一台已在缓存的设备 | 视作"用户主动选定" → 同步写入新焦点 UUID（无论是否双连） |

| 何时**清**空            | 触发                                              |
|-------------------------|---------------------------------------------------|
| `removeDevice(_:persist: true)` 且被删的恰是上次设备 | 联动调 `saveLastConnectedIdentifier(nil, ...)` |
| `clearDevices(persist: true)` | 显式再清一次 `lastConnected`                  |
| `clearPersistedDevices(for:)` | 显式再清一次 `lastConnected`                  |

| 何时**保留**            | 触发                                              |
|-------------------------|---------------------------------------------------|
| `unbindUser()`          | 保留（下次同一个 userID 重新 `bindUser` 还能用）   |
| `disconnect(device:)` 主动断开 | 也会清 —— 因为 `disconnect` 内部就是 `removeDevice(_:)` |

> 未 `bindUser` 时所有读 / 写都是 no-op，与"无用户分区"语义一致。

#### 5.7.2 `lastConnectedIdentifier: UUID?`

**只读**，同步返回当前用户最近一次成功连接的外设 UUID。未 `bindUser` 或本用户从未连过任何设备时为 `nil`。

```swift
if let id = BluetoothService.shared.lastConnectedIdentifier {
    print("上次连的设备：\(id)")
}
```

#### 5.7.3 `lastConnectedPeripheral: BluetoothPersistedPeripheral?`

**只读**，返回 UUID 对应的持久化快照（含 `name` / `rssi` / `advertisementData` 等）。**仅在该 UUID 同时也在"已绑定列表"里时才有值** —— 如果上次连过但后来被 `removeDevice` 清掉了，这里返回 `nil`。

适合做"无打扰提示"：

```swift
if let last = BluetoothService.shared.lastConnectedPeripheral {
    bigCardTitle.text = last.name           // 显示设备名
    bigCardSubtitle.text = "上次连接 \(last.name)"
}
```

#### 5.7.4 `lastConnectedDevice: BluetoothDevice?`

**只读**，返回上次设备在内存缓存（`cachedDevices`）里的 `BluetoothDevice` 占位。仅查内存，不会触发任何恢复或连接动作；调用前如未 `bindUser` / 未 `connect` 过，会返回 `nil`。

这是希望"立即拿一个 Device 对象，向它订阅状态流、发指令"时的快捷入口：

```swift
if let device = BluetoothService.shared.lastConnectedDevice {
    device.stateStream
        .compactMap { $0 as? C100DeviceState }
        .subscribe(onNext: { state in /* ... */ })
        .disposed(by: bag)
}
```

如果想立刻拿到 Device 占位但当前缓存没占位，请使用 `reconnectLast()` —— 它会先按持久化快照重建占位、再回连。

#### 5.7.5 `@discardableResult func reconnectLast() -> Bool`

**触发对"上次设备"的回连。无须扫描。**

返回值含义：

- `true`：已成功调度一次连接尝试。后续 `connectionState` 会出 `.connecting` → `.connected`。
- `false`：放弃。调用方需要走扫描兜底（或提示用户重新绑定）。

**内部决策顺序**（与协议注释一致，复述方便对照）：

```
1. currentUserID == nil 或没有 lastConnected 记录
   → 返回 false（同时打 info 日志 "reconnectLast skip: no lastConnected"）

2. 当前缓存里没有 Device 占位
   → 从 persistence 里找该 UUID 的快照
      - 快照不存在  → 返回 false
      - 找不到工厂  → 返回 false（产品已下架的脏数据）
      - 否则        → 通过 DeviceRegistry 工厂构造占位，addDevice(persist: false)

3. 找 CBPeripheral 句柄
      - 内部 peripheralsByID 里有       → 用之
      - manager.retrievePeripherals 拿到 → 用之（CoreBluetooth 标准 API，无须扫描）
      - 都拿不到                         → 返回 false（系统侧已遗忘，必须扫描）

4. 包装成 BluetoothPeripheral 走公开 connect(peripheral:) 路径
   意图位 / 自动重连 / 心跳一并跑起来 → 返回 true
```

**最常用模式**：登录后立刻调一次。

```swift
BluetoothService.shared.bindUser(user.id)
BluetoothService.shared.reconnectLast()    // 不关心返回值，UI 让 connectionState 驱动即可
```

**带兜底的完整模式**：参见 [2.A 时间线 ②.5](#a-紧跟-binduser--reconnectlast-自动回连上次的眼镜)。

#### 5.7.6 完整接入示例（跨冷启动）

下面这段代码完整覆盖"App 冷启动 → 登录态恢复 → 无扫描连接"。把它塞进 `SceneDelegate.willConnectTo` / `App.swift` 启动入口即可。

```swift
import BluetoothKit
import RxSwift

final class BluetoothBootstrap {

    private let bag = DisposeBag()
    private let service = BluetoothService.shared

    /// App 启动时调一次。会自动注册工厂、根据登录态绑定用户、并回连上次设备。
    func boot() {
        // 1) 注册支持的设备工厂
        DeviceRegistry.shared.register(C100Factory())

        // 2) 有登录态就 bindUser；没有就停在"无用户"状态等登录
        guard let userID = AuthService.shared.cachedUserID else { return }
        service.bindUser(userID)

        // 3) 回连上次设备；失败则降级到定向扫描
        if !service.reconnectLast() {
            scanForLastConnected()
        }

        // 4) 监听连接状态，UI 上做 toast / 角标
        service.connectionState
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] state in self?.handle(state) })
            .disposed(by: bag)
    }

    private func scanForLastConnected() {
        guard let id = service.lastConnectedIdentifier else { return }

        service.discoveredPeripherals
            .compactMap { list in list.first { $0.identifier == id } }
            .take(1)
            .timeout(.seconds(15), scheduler: MainScheduler.instance)
            .subscribe(
                onNext: { [weak self] hit in
                    self?.service.stopScan()
                    self?.service.connect(peripheral: hit)
                },
                onError: { [weak self] _ in
                    self?.service.stopScan()
                    NotificationCenter.default.post(name: .bluetoothLastDeviceUnavailable, object: nil)
                }
            )
            .disposed(by: bag)

        service.startScan()
    }

    private func handle(_ state: ConnectionState) {
        switch state {
        case .connected(let id):    print("[BT] connected \(id)")
        case .poweredOff:           print("[BT] please open Bluetooth")
        default:                    break
        }
    }
}
```

#### 5.7.7 常见疑问

**Q：用户清掉 App / 还原系统设置后，`reconnectLast()` 还能用吗？**
A：清 App → 默认 `UserDefaultsBluetoothPersistence` 写在 `UserDefaults.standard`，会随 App 数据被清掉，回连无效。还原系统设置 → CBPeripheral 句柄被回收，`retrievePeripherals` 拿不到，回连失败、走扫描兜底。

**Q：`reconnectLast()` 和 `connect(peripheral:)` 的 BLE 连接行为有区别吗？**
A：没有区别。前者只是帮你**省掉了寻找 peripheral 的过程**，最终走的是同一个公开 `connect(peripheral:)` 路径，意图位、自动重连、心跳完全一致。

**Q：可以把 `reconnectLast()` 放在 `bindUser` 之前调吗？**
A：不可以。`reconnectLast()` 内部读 `currentUserID`，没绑定时返回 `false` no-op。

**Q：登录之后想"换一台"怎么办？**
A：直接搜索 → `connect(peripheral: 新外设)`。一旦新设备进了 `.connected`，"上次设备"指针就会被自动覆盖成新 UUID，下次启动 `reconnectLast()` 会连新的那台。

**Q：怎么判断"上次设备就是我现在连着的这台"？**
A：

```swift
let isCurrentLastConnected =
    BluetoothService.shared.lastConnectedIdentifier ==
    BluetoothService.shared.cachedDevices.first(where: { /* 当前焦点 */ })?.peripheralIdentifier
```

或用响应式版本：

```swift
service.currentDevice
    .map { device in device?.peripheralIdentifier == BluetoothService.shared.lastConnectedIdentifier }
    .subscribe(onNext: { isLast in /* 显示"上次连接的设备"角标 */ })
    .disposed(by: bag)
```

**Q：双连模式（`switchPolicy = .keepBothConnected`）下，"上次设备"指向哪一台？**
A：永远跟随**当前焦点**（`currentDevice`）：
- 新连一台进 `.connected` → 自动写入这台；
- 调 `switchDevice(其它已在缓存的设备)` 切焦点 → 立刻写入新焦点 UUID（即便双连两台都没断）；
- 切回到原来那台再切回去也是同样规则：永远 = 最近一次"被用户当成主用"的设备。

#### 5.7.8 速查表

| API                                | 返回 / 副作用                                        | 何时用                              |
|------------------------------------|-----------------------------------------------------|-------------------------------------|
| `lastConnectedIdentifier`          | `UUID?`，只读                                       | 判断"是否有上次设备"                 |
| `lastConnectedPeripheral`          | `BluetoothPersistedPeripheral?`，只读               | 想拿到设备名 / 广播报做提示          |
| `lastConnectedDevice`              | `BluetoothDevice?`，只读（仅查内存）                  | 想立即给上次设备发指令 / 订阅状态    |
| `reconnectLast()`                  | `Bool`，触发回连                                    | 登录后第一行；UI 上"立即连接"按钮    |
| —（自动钩子）                      | `.connected` 时写入 `lastConnected` 持久化           | 业务侧无需关心                       |
| —（自动钩子）                      | `removeDevice` 命中上次设备时联动清空                | 业务侧无需关心                       |

---

## 6. 订阅设备状态与事件

### 6.1 全局连接状态

```swift
service.connectionState
    .subscribe(onNext: { state in
        switch state {
        case .scanning:                 print("扫描中")
        case .connecting(let id):       print("连接中 \(id)")
        case .connected(let id):        print("已连接 \(id)")
        case .disconnected(let id, let reason):
            print("断开 \(id) reason=\(reason ?? "nil")")
        case .failed(_, let reason):    print("连接失败 \(reason)")
        case .poweredOff:               print("系统蓝牙未开启")
        default: break
        }
    })
    .disposed(by: bag)
```

### 6.2 当前焦点设备 + 业务状态

```swift
let battery$: Observable<Int?> = service.currentDevice
    .flatMapLatest { device -> Observable<Int?> in
        guard let device = device else { return .just(nil) }
        return device.stateStream
            .compactMap { $0 as? C100DeviceState }  // 官方设备；SmartGlassesState 为源码 pod 专用（Example）
            .map { $0.battery }
    }

battery$
    .subscribe(onNext: { battery in /* 刷新电量 UI */ })
    .disposed(by: bag)
```
### 6.3 正在重连的设备集合（UI 角标用）

```swift
service.reconnecting
    .subscribe(onNext: { set in print("正在重连：\(set)") })
    .disposed(by: bag)
```

---

## 7. 下发业务指令

```swift
service.send(command: C100DeviceCommand.takePhoto)
// service.send(command: SmartGlassesCommand.translate(text: "你好", targetLang: "en"))  // 源码 pod 专用（Example）
```
行为说明：

- 没有焦点设备时是 no-op，不抛错；
- 真正的"指令 → 字节"打包逻辑在该设备的 `BluetoothCommandBuilder` 里；
- 多帧分包由 `builder.frames(for:)` 提供；
- 写入类型（withResponse / withoutResponse）由 `builder.writeType(for:)` 提供。

---

## 8. 自动重连策略

### 8.1 默认行为

- 启用、最多重试 3 次、1s 起退避、30s 上限、2 倍退避、对 `.failed` 也重试（`AutoReconnectPolicy.default`）。

### 8.2 自定义

```swift
service.autoReconnectPolicy = AutoReconnectPolicy(
    isEnabled: true,
    maxAttempts: 6,            // 最多 6 次
    initialDelay: 0.5,         // 第一次 0.5s
    maxDelay: 10,              // 最多等 10s
    backoffMultiplier: 2.0,    // 指数退避：0.5 → 1 → 2 → 4 → 8 → 10
    retryOnConnectFailure: true
)
```

预置项：

```swift
service.autoReconnectPolicy = .default
service.autoReconnectPolicy = .disabled   // 完全关闭自动重连
```

### 8.3 重连触发时机

| 事件                     | 是否触发                                    |
|--------------------------|--------------------------------------------|
| 已连接后掉线             | 是（前提：用户没有调用 disconnect）         |
| 连接动作失败（.failed）  | 取决于 `retryOnConnectFailure`            |
| 系统蓝牙从关到开         | 是（对所有"意图保持连接"的设备批量重连）   |

---

## 9. 系统蓝牙状态联动

`BluetoothService` 在内部会监听 `manager.bluetoothState`：

- 进入 `.poweredOn`（且上一态非 poweredOn）→ 对所有意图设备触发一次重连；
- 进入任意非 `.poweredOn` 状态 → 取消所有排队重试，清空 `reconnecting` 集合。

UI 侧若需要展示"请打开蓝牙"提示，可订阅 `service.connectionState` 中的 `.poweredOff`。

---

## 10. Mock / 单测

> **源码 pod 专用：** `Mock` 子规格与 `MockBluetoothManager` **不会**打进二进制 XCFramework。二进制客户请跳过本节；单测请在源码仓或内部 `:path` 集成下使用。

```swift
import BluetoothKit

let mock = MockBluetoothManager()
let service = BluetoothService(manager: mock, registry: .shared)

// 1) 凭空造一台外设并发布到扫描结果
let p = mock.emitDiscovered(name: "INMO C100-Mock")

// 2) 模拟连接成功
service.connect(peripheral: p)
mock.simulateConnected(peripheral: p)

// 3) 模拟外设上报字节（payload 由对应设备 Parser 解释，勿在业务侧硬编码私有帧）
let samplePayload = Data() // 测试里填入与目标 Parser 约定的合法报文
mock.simulateReceived(samplePayload,
                      from: /* 任意 CBPeripheral 句柄 */)

// 4) 写入回环：把发出去的字节立刻 echo 回 dataRelay，方便做 round-trip 单测
mock.echoWrites = true
```

> Mock 设备没有真实 CBPeripheral 句柄，`send(command:)` 会跳过实际写入，只走解析/状态机部分。

---

## 11. 扩展一种新设备类型

以"加一种 X100 设备"为例，需要 4 个文件：

```
Devices/X100/
├── X100Filter.swift       (可选；通常直接复用通用 Filter 组合)
├── X100Factory.swift      DeviceFactory
├── X100Parser.swift       BluetoothProtocolParser
├── X100CommandBuilder.swift BluetoothCommandBuilder
└── X100Device.swift       继承 BaseReducerDevice
```

骨架示例：

```swift
// X100Factory.swift
public final class X100Factory: DeviceFactory {
    public let filter: DeviceFilter = AllOfFilter(
        NameLengthFilter(minLength: 1),
        NamePrefixFilter("X100")
    )
    public init() {}
    public func makeDevice(_ peripheral: BluetoothPeripheral,
                           manager: BluetoothManagerProtocol) -> BluetoothDevice {
        return X100Device(peripheral: peripheral, manager: manager)
    }
}

// X100Device.swift
public final class X100Device: BaseReducerDevice {
    public init(peripheral: BluetoothPeripheral,
                manager: BluetoothManagerProtocol) {
        super.init(peripheral: peripheral,
                   manager: manager,
                   parser: X100Parser(),
                   builder: X100CommandBuilder(),
                   initialState: X100State())
    }
    public override func reduce(current: DeviceState, event: DeviceEvent) -> DeviceState {
        guard var s = current as? X100State else { return current }
        switch event {
        case let e as X100Event.Battery: s.battery = e.value
        default: break
        }
        return s
    }
}
```

启动期注册：

```swift
DeviceRegistry.shared.register(X100Factory())
```

完成。新增设备**不需要**修改 `BluetoothManager` / `BluetoothService` 任何一行代码。

---

## 12. 日志

```swift
BluetoothLogger.isEnabled = true                   // 全局开关
BluetoothLogger.sink = { line in MyLogger.log(line) }  // 替换为业务日志通道
```

日志风格：

```
ℹ️ [BT] startScan services=[]
🔵 [BT][TX] 12345678 01 02 03 04
🔵 [BT][RX] 12345678 0A 0B 0C
⚠️ [BT] auto-reconnect gave up: ... attempts=10 trigger=disconnected
❌ [BT] write failed: characteristic XXXX not found
```

数据日志会自动按 `peripheral.identifier` 前 8 位做来源标识，方便多设备并行调试。

---

## 13. 常见问题

**Q: 为什么我连接后没收到数据？**  
A: `BluetoothManager` 已经对所有带 `.notify / .indicate` 属性的特征值自动开启订阅。如果仍收不到数据，多半是设备特征值缺失或者厂商协议需要先下发激活指令——查阅设备文档，在连接成功后 `service.send(command: ...)` 一次激活即可。

**Q: 为什么 `service.startScan()` 看起来没反应？**  
A: 当系统蓝牙尚未就绪（state != .poweredOn）时，`BluetoothManager` 会**把本次扫描请求挂起**（打一条 `startScan pending until poweredOn` 的 warn 日志），并不会丢弃；等到系统蓝牙切到 .poweredOn 后会用同样的参数自动补发一次扫描。所以用户即便"先点搜索再打开蓝牙"也能拿到结果。如果要在 UI 上提示"请打开蓝牙"，可订阅 `service.connectionState` 的 `.poweredOff` 状态。

**Q: 自动重连会重试几次？**  
A: 默认 `maxAttempts = 3`。需要更多次数或无限重试时自行改 `autoReconnectPolicy`（`nil` = 无限）。达到上限后 Service 会撤销意图位、移除 Device 占位。

**Q: `startScan(for:)` 与 `startScan()` 有冲突吗？**  
A: 没有。两者底层调的是同一个 `manager.startScan(serviceUUIDs: nil)`；前者只是在 Service 层多了一层"按 filter 过滤"的订阅投影，不影响其它订阅者拿到的全量列表。

**Q: 我能在切换设备时不断开旧设备吗？**  
A: 可以，把 `service.switchPolicy = .keepBothConnected` 即可，旧设备保持连接，仅"焦点"切换到新设备。

**Q: Mock 设备能跑完整链路吗？**（**源码 pod 专用**）  
A: 可以跑响应式链路（扫描 → 连接 → 状态变化），但 `send(command:)` 不会真正发字节。需要 round-trip 时把 `MockBluetoothManager.echoWrites = true`。二进制交付不含 Mock。

**Q: 怎么实现"打开 App 自动连上次的眼镜"？**  
A: 两行：

```swift
BluetoothService.shared.bindUser(userID)
BluetoothService.shared.reconnectLast()
```

`reconnectLast()` 会自动定位 CBPeripheral 句柄并连接，**无须扫描**。返回 `false` 时（极少数：用户卸载过 App、还原系统设置等）需要降级到扫描兜底，详见 [§5.7](#57-获取与回连上一次设备)。

---

# 公开 API 参考

> Part B：符号一览，说明与源码 `///` 对齐。场景细节见上方 Part A 对应章节。不含私有帧布局 / 魔数。

## Service

| 符号 | 说明 |
|---|---|
| `BluetoothServiceProtocol` | 业务中间层抽象；UI 只应依赖此协议 |
| `BluetoothService.shared` | 全局单例；生产路径统一入口，见 [§2](#2-快速开始) |
| `BluetoothService(manager:registry:)` | 注入 Mock / 自定义 manager 时自行构造 |
| `discoveredPeripherals` | 扫描结果快照流（按 UUID 去重） |
| `devices` / `cachedDevices` | 已接管设备列表流 / 同步快照，见 [§5.5](#55-设备缓存管理) |
| `currentDevice` | 焦点设备流；`send` 目标 |
| `reconnecting` | 正在自动重连的 UUID 集合流 |
| `connectionState` | 连接状态机事件流，见 [§6.1](#61-全局连接状态) |
| `autoReconnectPolicy` | 自动重连策略，见 [§8](#8-自动重连策略) |
| `switchPolicy` | 切焦点时是否断开旧设备，见 [§5.4](#54-多设备切换) |
| `heartbeatPolicy` | 心跳间隔 / 开关 |
| `currentUserID` | 当前绑定用户（只读）；`nil` 时不做持久化 |
| `persistence` | 持久化后端；可在 `bindUser` 前替换 |
| `startScan()` / `stopScan()` | 全量扫描 / 停止；未上电时扫描请求会挂起 |
| `startScan(for:)` | 按工厂 filter 过滤的扫描流，见 [§4.2](#42-按设备类型搜索新方法) |
| `startScan(matching:)` | 按任意 `DeviceFilter` 过滤的扫描流 |
| `connect(peripheral:)` | 连接外设并建 Device 占位；标记重连意图 |
| `disconnect(device:)` | 主动断开并清意图 / 缓存（≈ `removeDevice`） |
| `disconnectKeepingCache(device:)` | 断 BLE 但保留缓存与持久化（如 OTA） |
| `cancelAutoReconnect(for:)` | 取消重连意图，不断开当前连接 |
| `switchDevice(_:)` | 切换焦点（行为受 `switchPolicy` 约束） |
| `switchAndConnect(to:)` | 切到已缓存设备并发起真实连接 |
| `send(command:)` | 向焦点设备下发业务指令，见 [§7](#7-下发业务指令) |
| `addDevice(_:)` / `removeDevice(_:)` / `clearDevices()` | 设备缓存管理，见 [§5.5](#55-设备缓存管理) |
| `device(for:)` | 按 UUID 同步查缓存占位 |
| `bindUser(_:)` / `unbindUser()` | 绑定 / 解绑用户并恢复或清空内存缓存，见 [§5.6](#56-用户身份与持久化) |
| `loadPersistedDevices(for:)` / `clearPersistedDevices(for:)` | 跨用户补刷 / 只清盘 |
| `persistedPeripherals(for:)` | 只读持久化快照列表 |
| `lastConnectedIdentifier` | 当前用户上次成功连接的 UUID |
| `lastConnectedPeripheral` | 上次设备的持久化快照（名 / RSSI 等） |
| `lastConnectedDevice` | 上次设备在内存缓存中的占位 |
| `reconnectLast()` | 无扫描回连上次设备，见 [§5.7](#57-获取与回连上一次设备) |
| `AutoReconnectPolicy` | 指数退避重连参数；`.default` / `.disabled` |
| `SwitchPolicy` | `.keepBothConnected` / `.disconnectPrevious` |
| `HeartbeatPolicy` | 连接成功后心跳策略 |
| `AudioRouteMonitor` / `BluetoothAudioPort` | 经典蓝牙音频路由监测（设备侧可选用） |

## Core

| 符号 | 说明 |
|---|---|
| `BluetoothManagerProtocol` | 传输层抽象：扫描 / 连接 / 读写 / 状态流 |
| `BluetoothManager` | CoreBluetooth 实现；无业务分支 |
| `BluetoothPeripheral` | 外设只读快照（含可选 `CBPeripheral` 句柄） |
| `ConnectionState` | `.poweredOff` / `.scanning` / `.connecting` / `.connected` / `.disconnected` / `.failed` 等 |
| `BluetoothError` | 统一错误枚举（权限、未连接、缺服务/特征、解析失败等） |
| `ConnectFailReason` | 连接失败结构化原因（超时、不可达、连接上限等） |
| `MockBluetoothManager` | **源码 pod 专用**单测传输层，见 [§10](#10-mock--单测)；二进制 XCFramework 不含 |

## Device / Registry

| 符号 | 说明 |
|---|---|
| `BluetoothDevice` | 业务设备抽象：身份 + 编解码 + 状态流 |
| `DeviceState` / `DeviceEvent` / `DeviceCommand` | 状态机三角色协议 |
| `BaseReducerDevice` | `reduce(current:event:)` 状态机基类（各具体 Device 继承） |
| `DeviceFactory` | `filter` + `makeDevice`；识别与构造入口 |
| `DeviceRegistry.shared` | 工厂注册表；注册顺序即匹配优先级，见 [§3](#3-启动期注册设备工厂) |
| `register(_:)` / `unregisterAll()` / `factory(for:)` | 注册 / 清空 / 按外设或类型标签查工厂 |
| `OTAType` | 设备 OTA 通道类型提示 |

## Protocol / Filters

| 符号 | 说明 |
|---|---|
| `BluetoothProtocolParser` | 字节 → `DeviceEvent`（自行处理粘包 / 分包） |
| `BluetoothCommandBuilder` | 指令 → 写入特征 / 写类型 / 分帧 |
| `DeviceFilter` | `matches(_:)` 扫描预判协议 |
| `AllOfFilter` / `AnyOfFilter` | AND / OR 组合器 |
| `NameLengthFilter` | 名字长度下限 |
| `AdvertisementLengthFilter` | 广播报粗略长度下限 |
| `NamePrefixFilter` | 名字前缀（大小写不敏感） |
| `ServiceUUIDFilter` | 广播宣称的服务 UUID 命中 |

## C100 / C110 / XA01

| 符号 | 说明 |
|---|---|
| `C100Factory` / `C100Device` | Moment Max：注册工厂 + Device 占位 |
| `C100DeviceState` / `C100DeviceEvent` / `C100DeviceCommand` | C100 状态 / 事件 / 指令 |
| `C100Parser` / `C100CommandBuilder` | C100 编解码入口（业务侧通常经 `send` / `stateStream`） |
| `C100WifiSession` / `C100FileSyncEngine` / `C100OTAEngine` | Wi‑Fi 会话、文件同步、OTA 辅助 |
| `C100ConnectionCoordinator` / `C100ReconnectWatcher` | C100 连接协调与回连守望 |
| `C100ClassicLinkDetector` | 经典蓝牙链路状态检测 |
| `C110Factory` / `C110Device` | 拍照眼镜：注册工厂 + Device |
| `C110ManufacturerFilter` | 按广播 manufacturer 识别 C110 |
| `C110DeviceState` / `C110DeviceEvent` / `C110DeviceCommand` | C110 状态 / 事件 / 指令 |
| `C110CommandBuilder` / `C110CommandParser` | C110 编解码入口 |
| `C110WifiSession` / `C110KeyMapping` | Wi‑Fi 会话、按键映射 |
| `XA01Factory` / `XA01Device` | 音频眼镜：注册工厂 + Device |
| `XA01BeaconFilter` | 按广播 beacon / productId 识别 XA01 |
| `XA01DeviceState` / `XA01DeviceEvent` / `XA01DeviceCommand` | XA01 状态 / 事件 / 指令 |
| `XA01Parser` / `XA01CommandBuilder` | XA01 编解码入口 |
| `XA01DeviceBeacon` / `XA01Ack` | Beacon 快照与应答模型 |
| `SmartGlassesFactory` 等（Example） | **源码 pod 专用**示例设备，演示扩展套路，见 [§11](#11-扩展一种新设备类型)；二进制不含 |

> 各设备另有若干公开枚举 / 结构体（音量、ANC、按键、电量快照等）。完整列表以模块 `public` 声明与 `///` 为准；组合包未包含的设备类型在链接期不可用。

## Logger / Persistence

| 符号 | 说明 |
|---|---|
| `BluetoothLogger` | 统一日志出口；`isEnabled` / `sink` / `info` / `warn` / `error` / 数据 hex |
| `BluetoothUserID` | 用户分区键（`String`） |
| `BluetoothPersistedPeripheral` | 已绑定外设 Codable 快照 |
| `BluetoothDevicePersistence` | 持久化协议（列表 + lastConnected） |
| `UserDefaultsBluetoothPersistence` | 默认实现；key 前缀 `BluetoothKit.boundDevices.`，自 `IMBluetoothKit.boundDevices.*` / `IMBluetoothFramework.boundDevices.*` 自动迁移 |
| `NoopBluetoothPersistence` | 空实现（完全不落盘） |

