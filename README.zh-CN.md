# LidAwake

让 MacBook 合盖后继续运行——不装内核扩展，只用 Apple 自带的 `pmset`，但把它包装成安全可控的形式。

**[English](README.md)**

## 为什么需要它

MacBook 合盖默认就会睡眠，但有些场景你恰恰不想让它睡：

- 合盖跑长任务（下载、编译、AI agent、备份）
- 合盖外接显示器（clamshell 模式）时保持可用
- 无头 Mac 挂在 SSH / 屏幕共享上当服务器

Apple 提供的 `pmset` 有三个大坑：

1. **`pmset -c sleep 0` 压不住合盖休眠**。它只管空闲计时器；真正压住合盖休眠的是 `pmset -a disablesleep 1`。
2. **`disablesleep` 是全局的**，不区分插电还是电池。用完忘关，拔电合盖塞进包里它会继续运行、发热、耗电。
3. **`0` 的含义是"永不"**，与直觉相反（`displaysleep 0` = 屏幕永不关闭）。

LidAwake 把这些收敛成命名的电源模式：切换前自动快照、可一键回滚、附带只读诊断。

## 项目组成

| 组件 | 作用 |
|---|---|
| [`lidawake.sh`](lidawake.sh) | 一条命令版：apply / restore / show。最小化的"合盖不睡"方案。 |
| [`batteryctl/`](batteryctl/README.md) | 主工具。命名电源模式（`default` / `charging` / `background` / `awake`）、切换前自动快照、一键回滚、含 USB-C PD 充电档位分析的只读诊断。Python CLI + 原生 SwiftUI App。 |
| [`batteryctl/app/`](batteryctl/app/README.md) | `BatteryCtl.app` —— 原生 SwiftUI 图形界面，复用同一份 CLI 核心。只需 `swiftc`（Xcode Command Line Tools），不需要完整 Xcode。 |
| [`charge-watch.sh`](charge-watch.sh) | 采样监控，专门抓"充电突然不正常"的瞬间：PD 协商降级、插着电却不在充电、NotChargingReason / ChargerInhibitReason 非零。 |
| [`charger-info.c`](charger-info.c) | 约 40 行的演示程序，展示两条充电器检测通路（`IOPSCopyExternalPowerAdapterDetails` 公共 API + IORegistry `AppleSmartBattery`）。判断"这个 USB-C 口到底能供多少电"的核心。 |

## 快速开始

### 1. 一条命令版（最简单）

```bash
sudo bash lidawake.sh apply    # 合盖不睡（插电时空闲也不睡）
bash lidawake.sh show          # 只看状态，不需要 sudo
sudo bash lidawake.sh restore  # 还原为 Apple 出厂默认
```

### 2. batteryctl（推荐）

```bash
cd batteryctl

# 只读，不需要 sudo
python3 batteryctl.py status
python3 batteryctl.py list

# 切换模式（需要 sudo；切换前自动快照）
sudo python3 batteryctl.py apply background   # 合盖跑长任务
sudo python3 batteryctl.py apply awake        # 合盖外接显示器
sudo python3 batteryctl.py apply default      # 恢复日常

# 回滚到最近一次快照
sudo python3 batteryctl.py restore
```

### 3. 图形界面（可选）

```bash
cd batteryctl/app
bash build.sh
open ../BatteryCtl.app
```

## 电源模式

| 模式 | 用途 | `disablesleep` |
|---|---|---|
| `default` | 日常，该睡就睡（含插电） | 0 |
| `charging` | 车上/慢口充电最快，把功率让给电池 | 0 |
| `background` | **合盖跑长任务，脚本继续运行** | 1 |
| `awake` | **合盖 + 外接显示器**（应用前会校验外接屏与屏幕录制权限，缺了就拒绝应用） | 1 |

## ⚠️ 安全说明

- `background` / `awake` 会启用 `disablesleep`，它是**全局**的。用电池时合盖放进包里，Mac 会继续运行、发热、耗电。用完请执行 `restore` 或 `apply default`。
- 每次 `apply` 前自动写入快照；任何一条 `pmset` 失败都会自动回滚。
- 只读命令（`status` / `list`）永不提权。
- 合盖后**有画面输出**（而不只是不睡眠）必须有外接显示器或 HDMI 欺骗器——Apple Silicon 合盖后会切断内置屏的显示管线，任何软件都绕不过。`awake` 模式会在应用前校验这两个前提。

## 环境要求

- macOS 13+（在 Apple Silicon 上开发和测试；GUI 在 Intel Mac 上需调整 `build.sh`）
- `batteryctl` 需要 Python 3
- GUI 需要 Xcode Command Line Tools
- 仅切换模式时需要 `sudo`

## 测试

```bash
cd batteryctl
python3 -m unittest discover -s tests -v
```

36 个单元测试，全部针对纯逻辑（解析、profile 加载、命令构造）。**测试不会触碰系统电源设置。**

## 设计文档

- [CLI 设计](docs/2026-09-13-batteryctl-design.md)
- [App 设计](docs/2026-09-13-batteryctl-app-design.md)
- [实施计划](docs/2026-09-13-batteryctl.md)

## 许可证

MIT —— 见 [LICENSE](LICENSE)。
