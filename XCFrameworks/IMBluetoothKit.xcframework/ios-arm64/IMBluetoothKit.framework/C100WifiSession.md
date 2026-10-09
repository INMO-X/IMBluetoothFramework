# C100WifiSession 使用说明

> 文件位置：`PrivatePods/IMBluetoothKit/IMBluetoothKit/Devices/C100/C100WifiSession.swift`
> 所属 subspec：`IMBluetoothKit/Devices/C100`

C100 眼镜热点会话编排器：把协议 v2.3 里 `0x44 / 0x45` 两条原语和 iOS 端的
`NEHotspotConfigurationManager` 组合成一条**有限状态机**，对外只暴露状态流 +
两个方法（`open` / `finish`）+ 一个紧急按钮（`cancel`）。

业务侧不再需要：
- 手动等 0x44 回包；
- 处理 NEHotspot 错误码；
- 维护 SSID → 加入 → 文件传完 → 拆 hotspot 的散落逻辑；
- 手写各阶段超时定时器。

---

## 一、架构

### 1.1 分层

```
┌──────────────────────────────────────────────────────────────┐
│  业务层（UI / ViewModel）                                     │
│                                                              │
│    c100.wifiSession.stream.subscribe { ... }                │
│    c100.wifiSession.open(fileName: ...)                     │
│    c100.wifiSession.finish(result: 0x00)                    │
└──────────────────────▲───────────────────────────────────────┘
                       │ State Observable
                       │
┌──────────────────────┴───────────────────────────────────────┐
│  C100WifiSession（本模块）                                    │
│                                                              │
│   • State 枚举有限状态机                                       │
│   • 订阅 device.eventStream（0x44/0x45 回包 + errorAck）       │
│   • DispatchWorkItem × 3 个阶段超时                            │
│   • NEHotspotConfigurationManager.apply / remove              │
└─────────▲──────────────────────────────▲─────────────────────┘
          │ DeviceEvent                  │ NEHotspot
          │                              │
┌─────────┴────────────┐      ┌─────────┴──────────────────────┐
│  C100Device          │      │  iOS NetworkExtension          │
│  ・eventStream       │      │  ・apply(config, completion:)  │
│  ・send(command:)    │      │  ・removeConfiguration(ssid:)  │
└──────────────────────┘      └────────────────────────────────┘
```

### 1.2 状态机

```
                  ┌─────────────────────────────────────┐
                  │              idle                   │
                  └────────────────┬────────────────────┘
                                   │ open(fileName)
                                   │ send 0x44
                                   ▼
                  ┌─────────────────────────────────────┐
                  │   requesting(fileName)              │
                  └─┬─────────────┬──────────┬──────────┘
        wifiTransOpened│ errorAck(0x44)│ openTimeout 8s │
                  │             │              │
                  ▼             ▼              ▼
                  │       failed(.openRejected) │
                  │       failed(.openTimeout)  │
                  │
                  ▼ NEHotspotConfiguration.apply
        ┌─────────────────────────────────────┐
        │   joining(ap, fileName)             │
        └─┬──────────────────┬────────────────┘
       完成│            joinDeadline 18s（从收到SSID起）/ 系统错误
          │                  │
          ▼                  ▼
   ┌──────────────────┐ failed(.joinFailed)
   │  joined(ap, file)│
   └─────────┬────────┘
             │ 业务层用 ap.ip:ap.port 起 socket 拉文件
             │ 完成或失败后：
             │ finish(result: 0x00 / 0x01 / 0x02 / 0xFF)
             │ send 0x45
             ▼
   ┌─────────────────────────────────────────┐
   │   finishing(ap, file, result)           │
   └─┬─────────────┬──────────┬──────────────┘
wifiTransDoneAck│ errorAck(0x45)│ finishTimeout 5s
(accepted=true) │  / accepted=false │
           │           │              │
           ▼           ▼              ▼
   ┌─────────────┐ failed(.finishRejected)
   │  finished   │ failed(.finishTimeout)
   └─────────────┘

  ╔════════════════════════════════════════════════════════════╗
  ║  任意非终态调用 cancel() →                                  ║
  ║   leaveHotspotIfNeeded() + failed(.cancelled, fileName?)   ║
  ╚════════════════════════════════════════════════════════════╝
```

### 1.3 超时（可配置）

| 阶段 | 默认 | 字段 | 触发条件 |
|---|---|---|---|
| 等 0x44 回包 | 8s | `openTimeout` | 协议建议 3s 后重试一次，给两次窗口余量 |
| 首次加入前等待 | 8s | `firstJoinDelay` | 眼镜收 0x15 才现起 softAP；仅本轮首次，重发起不等 |
| iOS 加入热点 | 18s | `joinDeadline` | **从收到 SSID 起算**（含首次 8s 预延时 + apply）；超时判加入失败 |
| 等 0x45 ack | 5s | `finishTimeout` | 眼镜接到完成回执后只需短确认 |

所有超时用 `DispatchWorkItem`，进入下一个状态时**立即 cancel**，不会跨阶段误触。

---

## 二、错误上报

所有失败都进 `.failed(SessionError, fileName: String?)`，业务侧只需要订阅
`stream` 然后 switch error 即可。

| `SessionError` case | 触发条件 | 业务侧建议处理 |
|---|---|---|
| `.openTimeout` | 0x44 发了 8s 没回包 | 提示"眼镜没响应"；可重试一次，连续两次失败放弃 |
| `.openRejected(detail:)` | 收到 `errorAck` msgID=0x44（热点起不来 / 文件不存在 / 设备忙） | 提示眼镜端拒绝；如果是"设备忙"语义，间隔 3s 后可重试 |
| `.joinFailed(reason:)` | NEHotspot.apply 系统回错误（已包含 `localizedDescription`），或 15s 超时 | 提示"加入眼镜热点失败"，并把 `reason` 写日志；若 reason 含 "user denied"，引导用户进系统设置 |
| `.finishTimeout` | 0x45 发了 5s 没收到 `wifiTransDoneAck` | 视作"网络不稳"，本地按完成处理，再次连接时眼镜端会因没收到删除指令而保留原文件——可在下次同步时复用 |
| `.finishRejected` | 收到 `wifiTransDoneAck(accepted: false)` 或 `errorAck` msgID=0x45 | 眼镜不会再删原文件 + 关热点；业务层可重发 0x45 或放弃 |
| `.cancelled` | 调用方主动 `cancel()` / `C100WifiSession` 被 `deinit` | 静默，不弹错误 toast；UI 回到 idle |

**约定**：进入任何 `.failed` 之前，已经做完了以下兜底：
1. 取消所有未触发的 DispatchWorkItem；
2. 如果上一阶段已经 join 过热点（`lastJoinedSSID != nil`），主动
   `removeConfiguration(forSSID:)` 拆掉，避免在 iOS 设置 → WiFi 里残留眼镜 SSID。

所以业务侧拿到 `.failed` 时**不需要**再去手动清理超时定时器或断 hotspot。

---

## 三、使用方法

### 3.1 订阅状态

```swift
guard let c100 = device as? C100Device else { return }

c100.wifiSession.stream
    .observe(on: MainScheduler.instance)
    .subscribe(onNext: { [weak self] state in
        switch state {
        case .idle, .requesting, .joining, .finishing:
            self?.showProgress("正在准备 WiFi 通道…")

        case .joined(let ap, _):
            self?.startSocket(host: ap.ip, port: ap.port)

        case .finished(let fileName):
            self?.markFileSynced(fileName)

        case .failed(let err, let fileName):
            self?.showError(self?.message(for: err) ?? "")
        }
    })
    .disposed(by: disposeBag)
```

### 3.2 启动会话

```swift
c100.wifiSession.open(fileName: "1716800000_5000.wmv")
```

`fileName` 来自 0x42（缩略图 zip 内的索引）或 0x43（音频列表），按协议规定要带文件后缀。

### 3.3 socket 完成后收尾

```swift
// 接收成功 + 字节数/CRC 校验通过
c100.wifiSession.finish(result: 0x00)  // → 眼镜删原文件 + 关热点

// 校验失败、socket 断了或其它
c100.wifiSession.finish(result: 0x01)  // 0x01 校验失败 / 0x02 中断 / 0xFF 其它
```

### 3.4 用户主动取消

```swift
c100.wifiSession.cancel()   // 立即拆 hotspot + 推 .failed(.cancelled, ...)
```

### 3.5 同步读取当前状态

```swift
if case .joined(let ap, _) = c100.wifiSession.current {
    // 直接拿 AP 信息发 socket
}
```

---

## 四、注意事项

### 4.1 ⚠️ Hotspot Configuration entitlement 必须开

`NEHotspotConfigurationManager.shared.apply` 调用前提：

1. 主 App target 的 `INMOX.entitlements` 里加：
   ```xml
   <key>com.apple.developer.networking.HotspotConfiguration</key>
   <true/>
   ```
2. Apple Developer 后台对应的 App ID 启用 **Hotspot Configuration** 能力，
   重签 provisioning profile。

漏掉这一步，所有 `open(fileName:)` 都会在 `.joining` 阶段进入
`.failed(.joinFailed(reason: "Missing entitlement ..."))`。

### 4.2 `finish(result:)` 的语义和眼镜端副作用

`result` 字段直接透传给眼镜端，**眼镜端**根据 result 决定是否删原文件：

| result | 含义 | 眼镜端动作 |
|---|---|---|
| `0x00` | 成功 + 校验通过 | **删除原文件 + 关热点** |
| `0x01` | 校验失败 | 保留原文件，等重试 |
| `0x02` | 接收中断 | 保留 |
| `0xFF` | 其它失败 | 保留 |

App 端**只在字节数 + 可选 CRC 都对的上**才发 `0x00`——一旦发了 0x00 而本地文件实际有问题，
眼镜端会把原文件删掉，丢数据。宁可发 `0x01` 让眼镜保留，下次再传。

### 4.3 `.finishTimeout` 的兜底逻辑

`finish(result: 0x00)` 发出后没收到眼镜 ack（5s 内）→ 进入 `.finishTimeout`。
此时**眼镜不会**删原文件 / 关热点，但 App 侧已经主动 `removeConfiguration(ssid)`
退出热点，避免 iOS WiFi 列表残留。

下一次 `open(...)` 时眼镜会重新开热点，原文件还在，可以再传一遍。所以
`.finishTimeout` 不是数据丢失，是"未确认完成"——业务层一般按警告级别处理就够。

### 4.4 状态机的并发与重入

- `open(fileName:)` 在非 `.idle` 状态下调用：内部会先做完
  `cancelTimeouts() + leaveHotspotIfNeeded()`，再迁到 `.requesting`，
  上一轮的回包不会再误触当前轮（每个超时都校验 `current` 的 fileName 字段）。
- `finish(result:)` 不在 `.joined` 状态下调用：等价于 `cancel()`，
  避免错误时序把状态机搞乱。
- `eventStream` 是长订阅，`deinit` 时一并 dispose；`C100Device` 被释放时
  `wifiSession` 也跟着释放、`leaveHotspotIfNeeded()` 会再兜底拆一次 hotspot。

### 4.5 NEHotspot 的 `alreadyAssociated` 不是错误

第二次（或后续）连同一个眼镜热点时，iOS 偶尔会回
`NEHotspotConfigurationError.alreadyAssociated`。本类把它**视作成功**——
实际网络可用、`ap.ip:ap.port` 可以起 socket。日志里能看到状态从 `.joining`
直接到 `.joined`，没有走 `.failed`。

### 4.6 不要和 `queryWifiAP`(0x04) 混用

协议里 `0x04 GET_WIFI_AP` 只**查询** AP 信息，**不开**热点。`C100WifiSession`
走的是 `0x44 WIFI_TRANS_OPEN`——它会让眼镜端**真的开**热点并把信息回过来。
所以：
- 想"开热点 + 加入" → 用 `wifiSession.open(fileName:)`；
- 只想"看看眼镜热点信息" → 直接 `c100.send(.queryWifiAP)`，结果在 `state.wifiAP`。

### 4.7 不订阅 `eventStream` 也能用？不行

`C100WifiSession` 自己持有一份 `eventStream` 订阅（在 `init` 里 `startEventLoop()`），
所以只要业务层访问过 `c100.wifiSession`（lazy 触发初始化），订阅就已经挂上了。
**不需要**业务层另外帮忙转发 0x44/0x45 的回包。

### 4.8 多设备 / 切设备的清理

如果用户在会话进行中切换到其它 C100 设备：
- 旧 `C100Device` 被 `BluetoothService` 移出 cachedDevices 后引用减一；
- 业务层若没有强持有 `wifiSession`，整个会话会被 GC，`deinit` 自动
  `leaveHotspotIfNeeded()`；
- 若业务层强持有了 `wifiSession`（如 ViewModel 里 `let session = c100.wifiSession`），
  手动调 `session.cancel()` 收尾。

### 4.9 `joinOnce = true` 的含义

`NEHotspotConfiguration` 默认会把眼镜 SSID 写入用户的"已知网络"列表（甚至跨设备
同步给 iCloud Keychain）。本类设了 `joinOnce = true`，让连接**仅本次有效**——
用户在 iOS 设置 → WiFi 里不会看到"INMO_C100_xxx"被保存，避免污染用户的 WiFi 历史。
