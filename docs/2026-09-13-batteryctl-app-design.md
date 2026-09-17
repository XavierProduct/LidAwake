# BatteryCtl.app 设计文档

- **日期**：2026-09-13
- **状态**：已批准，待实施
- **前置**：`docs/2026-09-13-batteryctl-design.md`（CLI 版本，已实施完成）

## 1. 目标

把已完成的 `batteryctl.py` CLI 包装成一个**原生 macOS GUI App**，让用户双击即可查看电源状态、点击切换模式，不需要记命令、不需要 `cd` 到工作区。

**非目标**（YAGNI）：

- 不做菜单栏常驻（用户明确选择单窗口形态 A）
- 不做自动更新、不做偏好设置面板
- 不做代码签名与公证（用户零个签名身份，仅本地自用）
- 不重新实现任何电源逻辑（复用 CLI 为唯一真源）

## 2. 可行性验证结论（已实测）

| 验证项 | 结果 |
|---|---|
| `swiftc` 编译 SwiftUI `@main App` | ✅ 成功，产出 58KB arm64 Mach-O |
| 所需编译参数 | `-parse-as-library -target arm64-apple-macos13.0` |
| **沙箱关键坑** | clang 模块缓存默认写系统临时目录会被拒；必须 `-module-cache-path` 指向工作区内 |
| 手动组装 `.app` bundle | ✅ 启动成功 |
| ad-hoc 签名 `codesign -s -` | ✅ 成功 |
| `open` 启动并保持运行 | ✅ 进程存活 |

因此方案成立，无需安装 Xcode 或任何第三方打包工具。

## 3. 架构

```
BatteryCtl.app/Contents/
├── MacOS/BatteryCtl              # SwiftUI 二进制（swiftc 编译）
├── Resources/
│   ├── batteryctl.py             # 复用现有核心（唯一真源）
│   ├── profiles/*.json           # 4 个模式（App 自包含）
│   └── AppIcon.icns              # 由 iconutil 生成
└── Info.plist
```

### 职责边界

| 层 | 职责 | 说明 |
|---|---|---|
| `batteryctl.py` | 全部电源逻辑：解析、快照、应用、回滚、PD 诊断 | **已由 32 个单元测试覆盖，GUI 不碰** |
| `BatteryCtl`(Swift) | 调用脚本、解析 JSON、渲染界面、触发提权 | 薄壳，无业务逻辑 |

**关键设计**：GUI 通过 `batteryctl.py status --json` 获取结构化数据，**不解析人类可读文本**。这样 CLI 的文案改动不会破坏 App。

## 4. 对 CLI 的改动：新增 `--json`

`status --json` 输出：

```json
{
  "battery": { "displaysleep": 2, "sleep": 1, "disksleep": 10, "womp": 0 },
  "ac": { "displaysleep": 10, "sleep": 1, "disksleep": 10, "womp": 1 },
  "global": { "SleepDisabled": 0 },
  "power_source": "AC",
  "battery_state": "charging",
  "soc_percent": 42,
  "profiles": ["awake", "background", "charging", "default"],
  "external_displays": 0,
  "screen_recording": false,
  "adapter": {
    "watts": 60, "voltage": 20000, "current": 2990,
    "menu": [[5000, 2960], [9000, 2980], [12000, 2980], [15000, 2990], [20000, 2990]],
    "has_20v": true
  }
}
```

终端默认仍输出现在的中文可读格式，只有显式加 `--json` 才输出 JSON。

## 5. 提权机制

- **打开 App 查看状态：不提权**，不弹密码框
- **点击应用模式：弹一次系统密码框**，走 `osascript -e 'do shell script "..." with administrator privileges'`

调用示例（App 内构造）：

```
osascript -e 'do shell script "/usr/bin/python3 <res>/batteryctl.py apply charging" with administrator privileges'
```

必须用 `with administrator privileges`，因为 `pmset` 需要 root。这是 macOS 设计，无法绕过；除非引入常驻特权 helper（显著增加复杂度与安全面，明确不做）。

### 关于 Python 解释器

优先用 `/opt/homebrew/bin/python3`（3.14，已验证可跑）；不存在时回退 `/usr/bin/python3`。App 启动时探测一次。

## 6. 界面设计（单窗口）

```
┌──────────────────────────────────────────────┐
│  BatteryCtl                                  │
├──────────────────────────────────────────────┤
│  当前电源: AC 供电      电量 42% ▲ 充电中     │
│  适配器: 60 W (20V/2.99A = 59.8 W)           │
│          ⚠️ 无 20V 档 -> 口径不足            │
│  休眠开关: 未禁用（合盖会睡）                 │
│  当前设置: 接电 屏幕10分/睡眠1分             │
│            电池 屏幕2分/睡眠1分              │
│  合盖截图: ✗ 无外接屏                        │
├──────────────────────────────────────────────┤
│  [ default  该睡就睡        ] [应用]         │
│  [ charging 车上充电最快    ] [应用]         │
│  [ background 合盖跑脚本    ] [应用]         │
│  [ awake    合盖截图 E2E    ] [应用]         │
├──────────────────────────────────────────────┤
│  最近操作: 模式 charging 已应用    [刷新][还原]│
└──────────────────────────────────────────────┘
```

行为细节：
- 启动即刷新状态
- 点「应用」→ 弹密码框 → 执行 → 自动刷新状态并显示结果
- 前置条件不满足的模式（如 `awake` 缺外接屏）**按钮置灰**并显示原因 tooltip
- 有 `warn` 的模式在确认后再执行，把警告显式呈现在弹窗里
- 「还原」= `batteryctl.py restore`

## 7. 错误处理

| 情况 | 行为 |
|---|---|
| 找不到 Python 解释器 | 窗口顶部显著报错，禁用所有应用按钮 |
| `status --json` 返回非零或 JSON 解析失败 | 显示原始 stderr，保留上次成功状态并标注"数据可能过期" |
| 用户取消密码框 | 静默返回，状态栏显示"已取消"，不报错 |
| `apply` 失败（脚本内部已回滚） | 弹窗显示脚本 stderr，提示已回滚 |

**注意**：用户取消 `osascript` 提权时，osascript 返回错误码 **-128**，必须单独识别，否则会误报为失败。

## 8. 构建方式

提供 `build.sh`，一键完成：

1. 生成图标：用 SwiftUI/CoreGraphics 画一个 PNG → `sips` 生成各尺寸 → `iconutil` 打包 `AppIcon.icns`
2. `swiftc` 编译 `Sources/*.swift`（带 `-module-cache-path`）
3. 组装 bundle，拷贝 `batteryctl.py` 与 `profiles/`
4. 写 `Info.plist`
5. `codesign --force --deep --sign -`

构建产物：`tools/batteryctl/app/BatteryCtl.app`

## 9. 验证标准

1. `status --json` 输出合法 JSON，且新增单元测试通过（原 32 个测试不回归）
2. `build.sh` 在只有 Command Line Tools 的环境下**零报错**完成
3. `open BatteryCtl.app` 能启动，窗口正常显示
4. 窗口显示的状态与 `batteryctl.py status` 一致（含 60W / 20V 判断）
5. 点击「应用 default」能弹出密码框、切换成功后状态自动刷新
6. 取消密码框时显示"已取消"而非报错
7. `awake` 按钮在无外接屏时置灰并给出原因

## 10. 已知限制

- **未签名**：仅本地自用。拷贝到别人机器会被 Gatekeeper 拦截。
- **无外接屏时 `awake` 不可用**：这是硬件限制，非 App 缺陷。
- **每次应用都要输密码**：macOS 设计，无法绕过。
