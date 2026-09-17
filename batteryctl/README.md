# batteryctl

把 macOS 分散的 `pmset` 电源参数收敛为**命名模式**，一键切换、切换前自动快照、可回滚，并附带只读诊断。

提供两种使用方式：

- **命令行** `batteryctl.py`（本文档）
- **原生 GUI** `BatteryCtl.app` —— 见 [`app/README.md`](app/README.md)，双击打开、点按钮切换

两者共用同一份核心逻辑（`batteryctl.py` 是唯一真源，GUI 不含业务逻辑）。

## 为什么需要它

`pmset` 有三个容易踩的坑：

1. **`sleep` 压不住合盖休眠**。它只管空闲计时器；要合盖不睡必须用 `disablesleep`。
2. **`disablesleep` 不区分插电/电池**，是全局的。用完不关，拔电合盖放包里会持续发热耗电。
3. **`0` 的含义是"永不"**，与直觉相反（`displaysleep 0` = 屏幕永不关闭）。

batteryctl 把这些打包成模式，并在切换前自动存快照，避免"改完忘了原来的值"。

## 模式

| 模式 | 用途 | 电池：屏幕关/睡眠 | 接电：屏幕关/睡眠 | `disablesleep` |
|---|---|---|---|---|
| `default` | 日常，该睡就睡（含插电） | 2 / 1 分钟 | 10 / 1 分钟 | 0 |
| `charging` | **车上充电最快**，把功率让给电池 | 2 / 1 分钟 | 1 / 0（不空闲睡眠） | 0 |
| `background` | **合盖跑脚本/长任务** | 2 / 1 分钟 | 0 / 0 | **1** |
| `awake` | **外接屏合盖做 E2E + 真实截图** | 2 / 1 分钟 | 0 / 0 | **1** |

`default` 的值取自 Apple 出厂默认（本机 `pmset restoredefaults` 实测）。

## 用法

```bash
cd tools/batteryctl

# 只读诊断，不需要 sudo
python3 batteryctl.py status
python3 batteryctl.py list

# 机器可读输出（供 GUI/脚本消费）
python3 batteryctl.py status --json

# 切换模式，需要 sudo
sudo python3 batteryctl.py apply charging
sudo python3 batteryctl.py apply background

# 回滚（默认回到最近一次快照）
sudo python3 batteryctl.py restore

# 恢复 Apple 出厂默认
sudo python3 batteryctl.py apple-defaults
```

`status` 会输出：当前电源设置、供电与电量、外接显示器数量、屏幕录制权限、**适配器 PD 档位**。
`status --json` 输出同样的结构化数据，字段定义见 [App 设计文档](../../docs/2026-09-13-batteryctl-app-design.md) 第 4 节。

### 用 PD 档位判断充电口够不够用

`status` 会列出适配器广播的全部电压档位，并检查**是否存在 20V 档**：

- **有 20V 档** → 该口具备 45W 以上供电能力
- **无 20V 档** → 最高只到 12V，功率上限约 18–20W。此时高负载（亮屏、视频通话、编译）会让系统功耗吃掉全部供电，macOS 就会显示**「没有在充电」**，甚至插着电掉电。

这是排查"车载 USB-C 口充不进电"的关键判据。

## 安全说明

- **`apply background` / `apply awake` 会启用 `disablesleep`**，它是**全局**的，不区分插电与电池。拔电后合盖放进包里，Mac 会继续运行、发热、耗电。用完请 `restore` 或 `apply default`。
- 每次 `apply` 前会自动写入快照到 `snapshots/`。任何一条 `pmset` 失败都会**自动回滚**到该快照。
- 只读命令（`status` / `list`）永不提权。需要提权的命令在终端里会提示一次密码；非交互环境下若无法免密提权会**明确报错**，不会静默失败。

## 合盖截图的两个前提

要用 `awake` 模式实现"合盖 + 真实截图"，必须同时满足：

1. **外接显示器或 HDMI 欺骗器**。Apple Silicon 笔记本合盖后会切断内置屏的显示管线，内置屏没有画面可截——这一条无法用任何软件设置绕过。
2. **「屏幕录制」权限**。系统设置 > 隐私与安全性 > 屏幕录制，为运行测试的终端/App 勾选授权。**必须人工操作**，无法自动化。

`awake` 模式在应用前会校验这两项；不满足则**拒绝应用**并列出缺失项，避免你以为能截图却拿到黑图。

## 测试

```bash
cd tools/batteryctl
python3 -m unittest discover -s tests -v
```

36 个测试，全部针对纯函数（解析、profile 加载、命令构造、文件名生成）。**测试过程不会调用 `pmset` 写操作，不会改动系统电源设置。**

## 与工作区既有脚本的关系

仓库根目录的 `合盖常驻配置.sh` 是本工具出现之前的应急版本（无 Python 环境时可用）：

```bash
bash 合盖常驻配置.sh show        # 只读
sudo bash 合盖常驻配置.sh apply  # 合盖不睡 + 接电永不睡眠
sudo bash 合盖常驻配置.sh restore
```

它是 `background` 模式的超集简化版，但缺少快照回滚、多模式切换和 PD 诊断。日常请优先用 `batteryctl.py`。

## 设计文档

- CLI 设计：`docs/2026-09-13-batteryctl-design.md`
- App 设计：`docs/2026-09-13-batteryctl-app-design.md`
- 实施计划：`docs/2026-09-13-batteryctl.md`
