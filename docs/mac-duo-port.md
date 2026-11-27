# Mac Duo 景深效果移植 · 实施记录

## 当前实现

- 右键灵动岛打开统一设置窗口，使用窗口内的「NotchDay / Mac Duo」分段切换。
- 渲染前合成灵动岛的透明快照，让它和屏幕画面一起使用单应变换、模糊和压暗。覆盖层淡出时恢复原来的灵动岛窗口。
- 合盖时才预热采集。停用景深、未获得屏幕录制权限或系统睡眠时暂停轮询。实时采集最多 30 fps，队列深度为 3。投影与画面均未变化时复用已呈现的一帧。
- 应用包携带上游 Apache-2.0 许可证和归属说明。
- 在 MacBook Pro 内置屏上，实时路径以 2940 × 1912 采集，静态和实时预览均成功合成灵动岛。软件预览覆盖两条渲染路径，实际合盖的观感与长时间功耗仍需实测。
- 本机使用 `./Scripts/build-app.sh --install` 更新并启动 `/Applications/NotchDay.app`。

## 早期移植与排查记录

下文记录此前的实现和实验，其中系统菜单栏方案已由窗口内分段设置取代。

> 状态：功能主体已完成并可运行，**菜单栏两个状态项仍不可见（未解决）**。
> 分支：`feature/mac-duo`（由 `develop` 迁出，`develop` 由 `main` @ `fe1315b` 迁出）
> 机器：MacBook Pro（`Mac17,3`），内置屏 1470 × 956 pt，带刘海，macOS 26/27（SDK 27.2）
> 日期：2026-11-27

---

## 0. 摘要

三句话概括：

1. **景深效果本身已经跑通**。合盖/开盖时，屏幕画面会按真实铰链角度被重投影成一张以屏幕下缘为轴的"纸"，越靠上模糊与压暗越强，边缘过渡到纯黑。已用截图逐帧确认。
2. **整合工作已完成**：设置并入 NotchDay 单一设置窗口（分段切换「灵动岛 / Mac Duo」），菜单栏拆成两个状态项（一个进 NotchDay 设置，一个进 Mac Duo 设置）。
3. **唯一未解决的问题**：这两个菜单栏状态项在系统里"存在且可见"，但画面上不出现。已把根因压缩到"NotchDay 这个二进制本身"，排除了 plist、签名、启动方式、框架链接、启动代码等全部外部因素，但最后一层尚未定位。

---

## 1. 分支与产物

### 1.1 分支

```
main @ fe1315b
└── develop
    └── feature/mac-duo   ← 当前分支
```

### 1.2 改动清单

| 状态 | 文件 | 说明 |
|---|---|---|
| 新增 | `Sources/NotchDay/Depth/*.swift`（15 个文件） | 景深效果全部实现，见 §3.1 |
| 新增 | `Sources/NotchDay/MenuBarController.swift` | 两个菜单栏状态项 |
| 新增 | `Sources/NotchDay/SettingsWindowController.swift` | 统一设置窗口 + 分段切换 |
| 新增 | `Sources/NotchDay/MacDuoSettingsView.swift` | Mac Duo 设置分区 |
| 修改 | `Sources/NotchDay/NotchDayApp.swift` | 改用 `NSApplicationMain`，接入 depth / settings / menuBar |
| 修改 | `Sources/NotchDay/NotchController.swift` | 面板参与投影、设置窗口改为外部呈现 |
| 修改 | `Sources/NotchDay/SystemLinks.swift` | 新增 `openScreenRecordingPrivacy()` |
| 修改 | `App/Info.plist` | 新增 `NSPrincipalClass` |
| 未动 | `StorageFeed.swift` / `StoragePage.swift` | 你原有的未提交改动，本次全程未触碰 |

### 1.3 构建

```bash
swift build --disable-sandbox          # SwiftPM 沙箱在本机会失败，必须加 --disable-sandbox
NOTCHDAY_MANAGED_BUILD=1 ./Scripts/build-app.sh
open ./.codex/native-preview/NotchDay.app
```

调试用启动参数（正式版保留）：

- `--settings`：启动后直接打开设置窗口到 Mac Duo 分区
- `--depth-preview`：不依赖合盖，脚本化播放一次景深效果（因为测试无法真的去转屏轴）

---

## 2. 原项目原理（够用即止）

Mac-Duo 的核心不是"让屏幕弯曲"，而是**让画面自己骗过眼睛**：屏幕物理上完全不动，动的是"你以为你在哪个角度看到它"。

五段流水线：

```
铰链角度传感器 ──▶ 触发状态机 ──▶ 截屏 ──▶ Metal 重投影+模糊 ──▶ 覆盖窗口
   (IOHID)         (LidEffectPolicy)  (SCK)     (MPS 高斯金字塔)   (屏蔽级窗口)
```

**反投影补偿**：把当前屏幕截图当作一张贴在屏幕下缘的纸，按铰链角度做单应变换（homography），得到"从当前视角看这张纸应该是什么形状"的梯形，再用高斯金字塔按高度做模糊/压暗梯度，最后铺满整屏。物理屏幕没动，视觉上却像屏幕跟着盖子一起转。

关键数字（沿用原项目，未改）：

| 项 | 值 |
|---|---|
| 传感器 HID | vendor `0x05AC`，usage page `0x20`，usage `0x8A`，需 `kIOHIDBuiltInKey` |
| 传感器精度 | report 7 = 百分之一度（5 字节 LE）；report 1 = 整度（3 字节 LE） |
| 采样率 | 空闲 8 Hz / 效果中 30 Hz |
| 触发阈值 | 关合 2 °/s、开合 2 °/s，滞回 4°，最小回弹 1.5° |
| 平滑 | 临界阻尼弹簧 16 rad/s，`CADisplayLink` 推进 |
| 渲染 | 单三角形全屏、`MPSImageGaussianPyramid`（centerWeight 0.375）、120 pt 黑色留边、`displaySyncEnabled = false` |
| 覆盖窗口 | `CGShieldingWindowLevel()`（实测 2147483628），忽略鼠标事件 |

传感器实测读数：`105.06°`（report 7 = `[7,10,41,0,0]`），解码正确。

---

## 3. 移植方案

### 3.1 文件职责

| 文件 | 职责 | 与原项目的差异 |
|---|---|---|
| `DepthLog.swift` | 三个 `Logger` 通道（lid / render / capture） | 替换原 `Diagnostics` |
| `LidAngleSensor.swift` | 读铰链角度 | 原样移植 |
| `LidEffectPolicy.swift` | 触发状态机 | 逻辑一字未改 |
| `CriticallyDampedSpring.swift` | 弹簧平滑 + `BlurGradient` 梯度曲线 | 原样移植 |
| `Homography.swift` | 方到四边形单应 + `centered(_:at:)` | 新增 `centered`，见 §3.3 |
| `CapturedFrame.swift` | 持有 `CVMetalTexture` 的帧包装 | 原样移植 |
| `DepthShaders.swift` | 内嵌 Metal 源码 | 原样移植 |
| `DepthRenderer.swift` | 高斯金字塔渲染 | 原样移植，`makePicture` 改 `nonisolated` |
| `DepthOverlay.swift` | 覆盖窗口 + 几何 + 调参结构 | `update(...)` 改为返回投影后的四角 |
| `DepthFilter.swift` | 共享的 `SCContentFilter` 构造 | **新增**，静态/实时共用 |
| `ScreenSnapshotter.swift` | 静态路径：`SCScreenshotManager` | 新增 `notchWindowNumber` 钩子 |
| `ScreenStreamer.swift` | 实时路径：`SCStream` 30 fps + P3 | 新增 `notchWindowNumber` 钩子 |
| `DepthPreferences.swift` | 偏好，全部 `depth.*` 命名空间 | 新增 `tuning` 派生属性 |
| `DepthController.swift` | 主控：传感器轮询、策略、采集、渲染 | 新增面板联动钩子 |
| `DepthTransformHostView.swift` | 承载灵动岛的变换容器视图 | **新增** |

### 3.2 与 NotchDay 的四个接入点

**① 灵动岛参与投影**（你提的"notch 应该被当成屏幕的一部分"）

这是本次最关键的改动。原生实现里，灵动岛面板是 `NSPanel`，level = `.statusBar + 1`（26），而覆盖窗口在 2147483628 —— 灵动岛永远浮在覆盖层之上。如果不管它，画面被扭曲了而灵动岛纹丝不动，穿帮极其明显。

实测窗口顺序确认了这一点：

```
index 2 → NotchDay 面板 layer 26
index 3 → NotchDay 覆盖层 layer 2147483628
```

做法是**用同一个单应矩阵去变换面板的 contentView**：

```swift
// NotchController.applyDepthTransform(_:)
let matrix = Homography.matrix(
    width: Double(builtIn.frame.width), height: Double(builtIn.frame.height),
    to: state.corners.map { SIMD2(Double($0.x), Double($0.y)) })
let center = CGPoint(x: panel.frame.midX - builtIn.frame.minX,
                     y: panel.frame.midY - builtIn.frame.minY)
host.depthTransform = Homography.transform(Homography.centered(matrix, at: center))
```

配套改动：

- `panel.contentView` 由裸 `NSHostingView<NotchView>` 换成 `DepthTransformHostView(content:)` 包一层，`anchorPoint (0.5, 0.5)`、`masksToBounds = false`、`isFlipped = false`。
- 变换写入走 `CATransaction` 且 `setDisableActions(true)`，避免隐式动画拖帧。
- 效果期间 `depthActive = true`：命中区域失效（`updatePointer()` 直接返回）、`ignoresMouseEvents = true`、如果岛屿正展开则先 `collapseExplicitly()`。因为此时画面上的位置和真实点击位置已经不一致了。
- 效果结束（`onNotchTransform(nil)`）恢复原状。

两条采集路径都通过 `DepthFilter` 把 NotchDay 自己的窗口从画面里排除，同时又用 `exceptingWindows:` 把灵动岛面板**重新包含**进来 —— 这样灵动岛是"画面的一部分"，被同一次重投影画出来。当面板被移进私有 compositor Space、`SCShareableContent` 列不出它时，则退回"只做面板变换"的方案，保证屏幕上只有一份灵动岛。

**② 设置面板合并**

`NotchController` 里原来的 `settingsWindow` / `makeSettingsWindow()` 全部删除，改成 `settingsPresenter: ((SettingsSection) -> Void)?`。新的 `SettingsWindowController` 持有唯一窗口：

- `enum SettingsSection { notch, depth }`
- 顶部 `Picker`（`.segmented`）切换 `NotchSettingsView` / `MacDuoSettingsView`
- `hosting.sizingOptions = [.preferredContentSize]`，窗口宽度固定 396 pt
- 呈现方式：`makeKeyAndOrderFront(nil)` 之后补一次 `orderFrontRegardless()`（accessory 应用不会被自动激活）

**③ 两个菜单栏状态项**

`MenuBarController` 建两个 `NSStatusItem`：

| 项 | 图标 | 菜单 |
|---|---|---|
| NotchDay | `rectangle.topthird.inset.filled` | NotchDay 设置… / 退出 NotchDay |
| Mac Duo | `laptopcomputer` | 景深效果（勾选）/ 预览效果 / Mac Duo 设置… / 退出 NotchDay |

Mac Duo 菜单用 `NSMenuDelegate.menuNeedsUpdate` 每次打开时刷新勾选态与可用性，因为同一个开关在设置窗口里也能改。

**④ 偏好**

`DepthPreferences` 是 `ObservableObject`，所有 key 前缀 `depth.`，与 NotchDay 其他存储完全隔离，将来删掉这个功能不会污染既有配置。出厂默认对齐原项目（启用、实时渲染、阈值 90°、模糊跨度 60、最大模糊半径 135、最大压暗 1、观看距离 6、后仰倍数 1、模糊均匀度 0、压暗扩散 0.5）。

### 3.3 关键设计决策与取舍

| 决策 | 理由 | 代价 |
|---|---|---|
| 灵动岛用单应变换跟着一起扭，而不是隐藏它 | 隐藏会让刘海区域空出一块，穿帮更明显 | 效果期间命中区域失效，必须禁用 hover |
| 静态 / 实时两条路径都保留，可选 | 静态省电、实时更连续；用户要求都留 | 两套采集代码要各自维护 filter 失效逻辑 |
| 设置合并进一个窗口用分段切换 | 用户要求；且只有一个窗口，不存在两套生命周期 | 需要重构原有 `openSettings()` 链路 |
| 单应施加在 `contentView.layer.transform` 上 | SwiftUI 重画成本高且拿不到亚像素精度；CALayer 变换是 GPU 侧的，零额外开销 | 需要 `Homography.centered` 把变换平移到图层锚点（Core Animation 用行向量且绕锚点变换，与 `simd_double3x3` 的列向量约定相反） |
| `warmFilter()` 用 `isEnabled && CGPreflightScreenCaptureAccess()` 双重门控 | 否则每次启动都会拉起屏幕录制授权弹窗，且退出时会把系统弹窗一起杀掉 | 用户首次授权后需要重启应用（设置页已写明） |
| `presentPicture()` 前再查一次 `CGPreflightScreenCaptureAccess()` | 防御性：没权限时宁可不出效果，也不弹窗 | 无 |

---

## 4. 已验证的部分

| 项目 | 方法 | 结果 |
|---|---|---|
| 铰链传感器可用性与解码 | 独立 Swift 探针读 HID report | ✅ report 7 = `[7,10,41,0,0]` → 105.06° |
| 静态采集 + Metal 渲染 | `--depth-preview` 脚本播放 + 截图 | ✅ 梯形正确，上方模糊更强、逐级压暗，边缘过渡到纯黑 |
| 窗口层级关系 | `CGWindowList` 枚举 | ✅ 面板 26 / 覆盖层 2147483628，证实灵动岛必须参与变换 |
| 设置窗口尺寸 | 打印 `fitting` 尺寸 + 截图 | ✅ 396 × 654（此前为 396 × 992，占满全屏） |
| 设置窗口可被看见 | 截图 | ✅ `orderFrontRegardless()` 后正常置前 |
| 效果期间不抢鼠标 | 窗口属性 + 代码路径核对 | ⚠️ `ignoresMouseEvents = true` 已确认置位，但未做真实点击穿透测试 |
| 菜单栏状态项 | 截图 + 像素比对 + 运行时 frame 打印 | ❌ **不可见**，见 §5.8 |

> 取证方式说明：本机 `log show` 在沙箱下被拒绝（"Cannot run while sandboxed"），即使关闭沙箱也一样，所以全部结论都靠"截图 + 运行时状态打印"确认，没有依赖日志。

---

## 5. 遇到的问题、尝试与结果

### 5.1 构建失败：SwiftPM 沙箱

**现象**：`swift build` 报 `sandbox-exec: sandbox_apply: Operation not permitted`。

**处理**：所有构建改用 `swift build --disable-sandbox`；打包脚本内部已处理。

### 5.2 编译错误：闭包返回类型不匹配

**现象**：`NotchDayApp.swift:48` `cannot convert value of type 'Int?' to closure result type 'Int'`。

**原因**：`DepthController.notchWindowNumber` 声明为 `(() -> Int)?`，而 `NotchController.notchWindowNumber` 是 `Int?`。

**处理**：把钩子类型改成 `(() -> Int?)?`，两端闭包相应调整。**已解决**。

### 5.3 无法读系统日志

**现象**：`log show` 报 "Cannot run while sandboxed"，加 `dangerouslyDisableSandbox` 亦然。

**处理**：放弃日志取证，改为"截图 + 应用内写状态文件 + 独立探针"三件套。后续所有结论都基于这三者。**已绕过**。

### 5.4 屏幕录制权限反复弹窗，退出时把系统弹窗一起杀掉

**现象**：每次启动都拉起"NotchDay 想要录制屏幕"的系统弹窗；退出应用时弹窗被一起杀掉，下次再弹，形成循环；甚至会把系统设置窗口强行拉到前台。

**根因**：启动时无条件 `warmFilter()`（构造 `SCContentFilter`），而 `DistributedNotificationCenter` 的 `com.notchday.depthPreview` 观察者会在不恰当的时候触发预览。

**处理**（三处）：

1. 删除 `DistributedNotificationCenter` 观察者，`--depth-preview` 改由 `AppDelegate` 解析命令行参数触发。
2. `start()` 里只在此条件成立时才预热 filter：
   ```swift
   if preferences.isEnabled, CGPreflightScreenCaptureAccess() { … }
   ```
3. `presentPicture()` 开头加 `guard CGPreflightScreenCaptureAccess() else { … return }`。

**结果**：不再重复弹窗。**已解决**。

### 5.5 `open … --args` 不传参

**现象**：`open ./NotchDay.app --args --settings` 后 `CommandLine.arguments` 里没有 `--settings`。

**处理**：直接执行 bundle 内二进制 `NotchDay.app/Contents/MacOS/NotchDay --settings`。**已绕过**（仅影响调试流程）。

### 5.6 设置窗口高达 1024 pt

**现象**：设置窗口一打开就是整屏高（诊断打印 `fitting (396, 992)`）。

**原因**：`MacDuoSettingsView` 用 `ScrollView` 包了全部内容，SwiftUI 在测量时按内容理想高度报给窗口，`sizingOptions = [.preferredContentSize]` 就照单全收。

**处理**：把 Mac Duo 分区重构成 **头部（标题 + 实时角度）+ 固定 452 pt 的 `ScrollView` + 底部按钮栏**，中间用分隔线切分。

**结果**：窗口稳定在 396 × 654。**已解决**。

### 5.7 设置窗口出现在其他窗口之后

**现象**：accessory 应用不参与常规激活，`makeKeyAndOrderFront(nil)` 之后窗口仍在后台。

**处理**：补一次 `window.orderFrontRegardless()`。**已解决**。

### 5.8 【未解决】菜单栏状态项不可见

这是本次唯一没有解决的问题，也是花时间最多的一个。

**现象**：两个 `NSStatusItem` 都创建成功，运行时自检全部正常：

```
f=Optional((1435.0, 934.0, 35.0, 22.0)) vis=true wvis=true img=true   ← NotchDay 项
f=Optional((1432.0, 934.0, 38.0, 22.0)) vis=true wvis=true img=true   ← Mac Duo 项
```

但菜单栏截图上什么都没有。注意两个细节：**窗口高度是 22 而不是菜单栏真实高度 33**，**两个项几乎重叠在同一个 x 位置**（1432 / 1435），说明系统根本没有给它们做布局，只是把它们扔在屏幕边缘。

#### 排除过程（按顺序）

| # | 被测载体 | bundle id | 入口方式 | 状态项 frame | 结果 |
|---|---|---|---|---|---|
| 1 | `swift` 脚本（无 bundle） | 无 | 顶层代码 + `NSApplication.shared.run()` | (905, 923, 38, 33) | ✅ 显示 |
| 2 | `swiftc` 裸二进制（无 plist） | 无 | 同上 | (905, 923, 38, 33) | ✅ 显示 |
| 3 | 裸二进制 + 内嵌 `__info_plist`（**仅** CFBundleIdentifier） | com.probe.embedded.4412 | 同上 | (0, -6, 38, 22) / (0, -22, …) | ❌ 不可见 |
| 4 | `.app` bundle（ad-hoc 签名） | com.probe.menubar.test9931 | 同上 | (0, -22, 38, 22) | ❌ |
| 5 | 同上 + 安装到 `~/Applications` + `open` | 同上 | 同上 | (0, -22, 38, 22) | ❌ |
| 6 | `.app` + `NSApplicationMain` + `NSPrincipalClass` | com.probe.mainapp.3355 | `NSApplicationMain` | (905, 923, 38, 33) | ✅ |
| 7 | 同上，但入口改 `@main struct` | com.probe.am.2244 | `@main` → `NSApplicationMain` | (867, 923, 38, 33) | ✅ |
| 8 | 同上 + 链接 `ScreenCaptureKit` | com.probe.sck.5566 | 同上 | (905, 923, 38, 33) | ✅ |
| 9 | 同上 + `SwiftUI` + `EventKit` | com.probe.sui.7711 | 同上 | (867, 923, 38, 33) | ✅ |
| 10 | 同上 + **NotchDay 全部 18 个框架** | com.probe.all.6677 | 同上 | (905, 923, 38, 33) | ✅ |
| 11 | **最小 SwiftPM 工程**（`swift build -c release`） | com.probe.spm.8899 | 同上 | (905, 923, 38, 33) | ✅ |
| 12 | **NotchDay 真实二进制**放进最小 bundle | com.zzz.renamed.1234 | `NSApplicationMain` | (0, -22, 38, 22) | ❌ |
| 13 | NotchDay 真实 app（`open` 启动） | com.notchday.preview | `NSApplicationMain` | (0, -6, 38, 22) | ❌ |
| 14 | NotchDay，只创建 1 个状态项、其余全部跳过 | 同上 | 同上 | (0, -22, 38, 22) | ❌ |

结论（逐条排除）：

- **不是 plist 内容**：#3 只加了一个 `CFBundleIdentifier` 就复现；#4/#5 换成标准 plist 也一样。
- **不是签名**：#3 完全未签名照样复现；#4–#11 ad-hoc 签名却正常。
- **不是启动方式**：`open` 与直接执行二进制结果一致（#4 vs #5、#12 vs #13）。
- **不是 SkyLight 私有 Space**（`LockBadgeSpace.attach`）：跳过该调用后状态项依旧不可见。
- **不是灵动岛面板**：跳过 `controller.start()` 后依旧不可见。
- **不是绕过 `NSApplicationMain`**：这是最初的怀疑（Apple 论坛 [thread 794920](https://developer.apple.com/forums/thread/794920) 提到 macOS 26 起系统需要能把进程映射回 bundle，绕开 `NSApplicationMain` 会导致状态项既不显示也不进"允许出现在菜单栏"列表）。已按官方推荐改为 `NSApplicationMain` + `NSPrincipalClass`（改动保留，属正确做法），但**并没有修好**这个问题。
- **不是框架链接**：#10 把 NotchDay 链接的 18 个框架全部加上仍正常。
- **不是 SwiftPM 构建产物**：#11 最小 SwiftPM 工程正常。
- **不是启动时做了什么**：#14 把 `applicationDidFinishLaunching` 削到只剩"创建一个状态项"，仍然不可见。

也就是说：**同一个 bundle、同一种启动方式、同一套 plist、同一批框架、同样是 SwiftPM 产物 —— 探针能显示，NotchDay 不能**。剩下的差异只有 NotchDay 这个二进制里编译进去的代码本身（`ND_MIN=-1` 时几乎不执行任何逻辑，所以怀疑点在加载期/静态初始化）。

一个间接证据：NotchDay 进程读到的 `NSStatusBar.system.thickness` 是 22.0（默认兜底值），而能正常显示的探针读到的也是 22.0 —— 所以厚度不是判据，但两者状态项窗口的最终高度不同（22 vs 33），说明系统确实没有为 NotchDay 做布局。

#### 目前保留的改动

`NSApplicationMain` + `NotchApplication`（`@objc` 命名，`Info.plist` 里 `NSPrincipalClass = NotchApplication`，delegate 在 `init()` 中安装并强引用）。这个改动本身是对的（Apple 明确不建议绕开 `NSApplicationMain`），只是不是本问题的解。

#### 建议的下一步

1. **按源文件二分**：从 `Package.swift` 的 target 里逐个排除源文件（先排除 `Depth/` 整组、再排除 `StorageFeed`/`StoragePage`/`MusicPlayback` 等），直到状态项出现，即可锁定触发点。
2. **优先怀疑加载期副作用**：`dlopen("SkyLight")` 的 `LockBadgeSpace`、`DesktopSpaces` 的私有 API、`IOHIDManager` 的 `LidAngleSensor` 都是 `lazy`，但可以临时改成"永不构造"再测。
3. **兜底方案**：把两个状态项挪到一个独立的、纯 AppKit 的 helper app（完整 bundle、`SMAppService` 或 `NSWorkspace` 启动），主进程通过 XPC/通知通信。Apple 论坛推荐的正是这个结构，且不依赖本问题是否修好。
4. **诊断工具**：装一个已知可用的第三方菜单栏应用做对照，确认本机系统设置里"允许出现在菜单栏"是否存在针对 `com.notchday.preview` 的隐藏项（`defaults read com.apple.controlcenter` 里目前只看到 `NSStatusItem VisibleCC *` 这类系统项）。

---

## 6. 尚未解决的问题清单

| 优先级 | 问题 | 影响 |
|---|---|---|
| P0 | 两个菜单栏状态项不可见 | 用户拿不到"一个设置 NotchDay、一个设置 Mac Duo"的入口；设置窗口目前只能靠启动参数打开 |
| P1 | 灵动岛是否真的跟着画面一起变形，尚无视觉确认 | 因为黑色岛屿与顶部黑色带融合，截图上分辨不出来；需要把岛屿临时改成高对比色再截一次 |
| P1 | 实时模式（`SCStream` 30 fps）长时间运行的稳定性未验证 | 只验证了静态路径 |
| P2 | 未加 Apache-2.0 的 `LICENSE` / `NOTICE` 归属说明 | Mac Duo 是 Apache-2.0，移植代码必须带归属 |
| P2 | 全部改动尚未提交 | `feature/mac-duo` 上还没有任何 commit |
| P2 | `README.md` 未更新；`Info.plist` 缺屏幕录制用途说明文案 | 用户不知道有这个功能、不知道为什么需要录屏权限 |
| P3 | 外接屏 / 多显示器行为 | 目前只在内置屏生效（原项目同样如此），外接屏下效果静默不出现 |

---

## 7. 附录 A：关键实验命令

```bash
# 判断状态项是否被布局（能显示时高度为 33，不显示时为 22 且 x 可能为 0）
cat /tmp/nd-menu.txt

# 只截菜单栏，避免全屏截图噪声
screencapture -x -R600,0,870,40 /tmp/mb.png

# 造一个"正确形态"的探针：真 bundle + NSApplicationMain + NSPrincipalClass
swiftc -O -parse-as-library -o /tmp/Probe.app/Contents/MacOS/Probe /tmp/probe.swift
codesign -f -s - /tmp/Probe.app && open -n /tmp/Probe.app

# 校验签名 / 框架链接
codesign -d --entitlements - NotchDay.app
otool -L NotchDay.app/Contents/MacOS/NotchDay
```

## 8. 附录 B：设置面板暴露的参数

全部落在 `depth.*` 命名空间（`DepthPreferences`）：

| 分组 | 界面文案 | 默认 | 范围 | 作用 |
|---|---|---|---|---|
| 开关 | 景深效果 | 开 | — | 总开关（`isEnabled`） |
| 开关 | 实时渲染 | 开 | — | 关掉后固定使用触发瞬间那一帧（`isLivePicture`） |
| 触发 | 静止后结束 | 关 | — | 角度不再变化时提前结束，不必等盖子抬起（`isTimeoutEnabled`） |
| 触发 | 起始角度 | 90° | 5…130° | 合盖到此角度开始出效果（`thresholdAngle`） |
| 触发 | 满效果角度 | 60° | 5…60° | 再合上这么多度，模糊与压暗达最强（`blurSpan`） |
| 观感 | 模糊 | 135 pt | 10…160 pt | 远端高斯半径（`maxBlurRadius`） |
| 观感 | 模糊扩散 | 0% | 0…100% | 0 只模糊远端，100 整幅一起模糊（`blurEvenness`） |
| 观感 | 压暗 | 100% | 0…100% | 远端压到多黑（`maxDim`） |
| 观感 | 压暗扩散 | 50% | 20…100% | 高于此高度的地方完全变黑（`dimReach`） |
| 透视 | 后仰倍数 | 1.0× | 0…3× | 每合上一度，画面相对玻璃再后仰多少度；1 = 画面在房间里保持不动（`recession`） |
| 透视 | 透视强度 | 0% | 0…100% | 0 两侧平行，100 收束最强；内部映射到 `viewingDistance`（6 → 1 个屏高） |

底部另有「预览效果」「恢复默认」「退出 NotchDay」三个按钮，以及一行提示：效果只作用于内置屏，点击会穿透到下方 App，画面与可点区域并不一致。
