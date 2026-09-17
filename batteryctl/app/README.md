# BatteryCtl.app

把 `batteryctl` 包装成原生 macOS GUI。双击打开、点按钮切换模式，不需要记命令。

## 构建

只需要 **Xcode Command Line Tools**（含 `swiftc`），不需要完整 Xcode，也不需要任何第三方打包工具。

```bash
cd tools/batteryctl/app
bash build.sh          # 构建
bash build.sh clean    # 清理
```

产物：`tools/batteryctl/BatteryCtl.app`

```bash
open ../BatteryCtl.app
```

## 架构

```
BatteryCtl.app/Contents/
├── MacOS/BatteryCtl              # SwiftUI 二进制（swiftc 编译）
└── Resources/
    ├── batteryctl.py             # 复用 CLI 核心（唯一真源）
    ├── profiles/*.json           # 4 个模式，App 自包含
    └── AppIcon.icns              # 由 make_icon.swift 生成
```

**GUI 不含任何电源逻辑。** 它只做三件事：

1. 调用 `batteryctl.py status --json` 拿结构化数据（**不解析中文文本**，所以 CLI 改文案不会弄坏 App）
2. 渲染界面
3. 用户点按钮时，通过 `osascript ... with administrator privileges` 提权执行

`Sources/` 四个文件：

| 文件 | 职责 |
|---|---|
| `main.swift` | `@main` 入口 |
| `Models.swift` | `status --json` 的 Decodable 模型 |
| `BatteryControl.swift` | 子进程调用、资源定位、提权 |
| `AppUI.swift` | 界面与状态管理 |

## 使用

- **打开即显示状态**，不需要密码
- **点「应用」会弹一次系统密码框** —— `pmset` 需要 root，这是 macOS 设计，无法绕过
- 取消密码框会显示「已取消」，不算错误
- 每 8 秒自动刷新一次状态
- `awake` 在缺外接屏或未授权屏幕录制时**按钮置灰**并说明原因
- 有风险警告的模式（`background` / `awake`）会把警告直接显示在列表里
- 底部「回滚最近快照」= `batteryctl.py restore`

## 已知限制

| 限制 | 说明 |
|---|---|
| **未签名** | 零个签名身份，仅 ad-hoc 签名。本机可用，拷给别人会被 Gatekeeper 拦 |
| **arm64 only** | 编译目标写死 `arm64-apple-macos13.0`，Intel Mac 需改 `build.sh` |
| **每次应用都要输密码** | macOS 设计，除非装常驻特权 helper（明确不做） |
| **无外接屏时 `awake` 不可用** | 硬件限制，非 App 缺陷 |

## 构建期踩过的坑（改 build.sh 前先读）

1. **clang 模块缓存必须在工作区内**。默认位置在系统临时目录，受限环境会因权限被拒，报 `unable to open output file ... .pcm`。`build.sh` 里通过 `CLANG_MODULE_CACHE_PATH` 与 `-module-cache-path` 双重指定。
2. **图标不用 Python 生成**。Homebrew 的 `python3` 不含 PyObjC（`import Quartz` 直接失败），所以改用 `make_icon.swift`，靠 CLT 自带的 CoreGraphics。
3. **不用 `iconutil` / `sips`**，直接手写 ICNS 容器（`icns` 头 + 各尺寸 PNG 块），少一层工具依赖。
4. **提权用「临时脚本 + 退出码回读」而不是内联命令**。内联会丢掉真实退出码，无法区分「用户取消」(-128) 与「执行失败」。

## 测试

Python 核心的单元测试在上一级目录：

```bash
cd tools/batteryctl
python3 -m unittest discover -s tests -v
```

36 个测试，不触碰系统电源设置。

## 文档

- CLI 设计：`docs/2026-09-13-batteryctl-design.md`
- App 设计：`docs/2026-09-13-batteryctl-app-design.md`
- 实施计划：`docs/2026-09-13-batteryctl.md`
