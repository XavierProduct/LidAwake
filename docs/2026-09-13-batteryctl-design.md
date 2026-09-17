# batteryctl 设计文档

- **日期**：2026-09-13
- **状态**：已批准，待实施
- **背景**：MacBook Air (Mac17,3 / Apple M5)，车载 USB-C 供电场景下排查"没有在充电"，进而希望把电源策略做成可复用工具。

## 1. 问题与目标

MacBook 的电源策略由 `pmset` 管理，参数分**两套作用域**（接电 `-c` / 电池 `-b`）外加**一个全局开关**（`disablesleep`），语义分散、容易互相冲突：

- `sleep` 只管**空闲计时器**，压不住**合盖休眠**
- `displaysleep`、`sleep`、`disksleep` 都是"0 = 永不"，与"0 = 立即"直觉相反
- `disablesleep` **不区分接电/电池**，是全局的，容易误配
- 用户难以判断"我现在的配置到底会导致什么行为"

**目标**：提供一个工具，把电源策略收敛为若干个**命名模式**，一条命令切换，切换前自动快照、可回滚，并提供只读诊断能力。

**非目标**（YAGNI）：

- 不做图形界面、不做菜单栏常驻
- 不管理 `caffeinate` 式的进程级电源断言
- 不做定时调度（如"到点自动切换模式"）
- 不自动绕过系统权限（TCC 只能人工授权）

## 2. 已确认的关键事实（实测）

| 事实 | 来源 |
|---|---|
| 合盖休眠由硬件事件触发，`sleep 0` 压不住，需 `disablesleep 1` | man pmset + 行为验证 |
| `disablesleep` **未在 man page 文档化**，但系统在跟踪（`pmset -g` 显示 `SleepDisabled`） | man pmset 全文检索 |
| Apple 出厂默认（本机 `restoredefaults` 实测）：Battery `displaysleep 2 / sleep 1 / disksleep 10 / womp 0`；AC `displaysleep 10 / sleep 1 / disksleep 10 / womp 1` | `sudo pmset restoredefaults` 实测输出 |
| 合盖后内置屏设备消失，`screencapture` 无画面可截 | 显示配置查询（仅 1 个内置屏） |
| 截图需 TCC「屏幕录制」权限，需人工授予 | TCC 数据库查询为空 |
| `pmset` 修改设置**必须 root** | man pmset |

## 3. 模式定义

| 模式 | 用途 | Battery `displaysleep/sleep` | AC `displaysleep/sleep` | `disablesleep` |
|---|---|---|---|---|
| `default` | 日常，该睡就睡 | 2 / 1 | 10 / 1 | 0 |
| `charging` | 车上充电最快 | 2 / 1 | 1 / 0 | 0 |
| `background` | 合盖跑长任务 | 2 / 1 | **0 / 0** | **1** |
| `awake` | 外接屏合盖做 E2E + 截图 | 2 / 1 | **0 / 0** | **1** |

三个 `disksleep` 统一为 10。

**`awake` 与 `background` 的差别**：设置相同，但 `awake` 在应用前**额外校验**外接显示器存在、屏幕录制权限已授予；不满足则拒绝应用并给出引导，避免用户以为截图能成却发现是黑图。

**安全设计**：`background` / `awake` 启用时会打印显著警告——`disablesleep` 全局生效，拔电合盖放包内会持续发热耗电。

## 4. 架构

单脚本、零第三方依赖（Python 3，本机 `/opt/homebrew/bin/python3`）。

```
tools/batteryctl/
├── batteryctl.py           # 入口 + 三个单元
├── profiles/               # 预设模式（纯数据，可手改）
│   ├── default.json
│   ├── charging.json
│   ├── background.json
│   └── awake.json
├── snapshots/              # 切换前自动快照（gitignore）
└── tests/
    └── test_batteryctl.py  # 纯函数单元测试
```

### 三个职责单元

| 单元 | 做什么 | 依赖 | 可测性 |
|---|---|---|---|
| **Parser** | `pmset -g custom` / `pmset -g` 文本 → 结构化 dict | 无 | **纯函数，重点测试** |
| **Capability** | 只读探测：电源来源、电量、外接屏数量、截图权限、适配器 PD 档位 | `system_profiler` / `ioreg` | 可注入样本输出 |
| **Applier** | 模式 → 命令序列 → 快照 → 执行 → 失败回滚 | `pmset` + sudo | 命令构造可测 |

**拆分理由**：Parser 是纯文本转换，是最容易随 macOS 版本漂移的部分，必须能脱离真实系统做测试；Applier 是本工具唯一有副作用的单元，要隔离得足够清楚。

### Profile JSON 格式

```json
{
  "name": "background",
  "description": "合盖跑长任务：合盖不睡、屏幕关，脚本继续运行",
  "requires": [],
  "warn": "disablesleep 是全局设置，拔电合盖放包里会持续发热耗电",
  "global": { "disablesleep": 1 },
  "battery": { "displaysleep": 2, "sleep": 1, "disksleep": 10 },
  "ac":      { "displaysleep": 0, "sleep": 0, "disksleep": 10 },
  "verify":  { "expect": { "SleepDisabled": 1, "ac.sleep": 0, "ac.displaysleep": 0 } }
}
```

### 快照格式

`apply` 之前自动写入 `snapshots/<ISO8601>_before-<profile>.json`：

```json
{
  "captured_at": "2026-09-13T18:30:00+08:00",
  "reason": "before applying profile: charging",
  "power_source": "AC",
  "battery": { "displaysleep": 2, "sleep": 1, "disksleep": 10, "womp": 0 },
  "ac":      { "displaysleep": 10, "sleep": 1, "disksleep": 10, "womp": 1 },
  "global":  { "SleepDisabled": 0 }
}
```

## 5. CLI 接口

| 命令 | 作用 | 需要 sudo |
|---|---|---|
| `batteryctl.py status` | 只读诊断：当前模式推断、电源、电量、外接屏、截图权限、适配器 PD 档位 | 否 |
| `batteryctl.py list` | 列出所有模式及摘要 | 否 |
| `batteryctl.py apply <mode>` | 快照 → 应用 → 校验 | **是** |
| `batteryctl.py restore` | 回滚到最近一次快照 | **是** |
| `batteryctl.py restore [snapshot]` | 回滚到指定快照 | **是** |
| `batteryctl.py apple-defaults` | **先关 `disablesleep`**，再调 `pmset restoredefaults`，并同步 `default.json` | **是** |

> ⚠️ **`apple-defaults` 必须先显式执行 `pmset -a disablesleep 0`**。实测表明
> `pmset restoredefaults` **不会**重置 `disablesleep`（前序手动排查中已验证：
> 单独跑 `restoredefaults` 后 `SleepDisabled` 仍为原值）。若漏掉这一步，
> 用户从 `background` 模式"恢复默认"后，合盖仍然不会休眠，形成难以定位的残留状态。

**`status` 额外保留 PD 诊断能力**：读取 `AdapterDetails` 输出适配器瓦数与全部电压档位（`UsbHvcMenu`），并复用前序排查中的判断逻辑——**是否存在 20V 档**决定该口能否达到 45W 以上。

## 6. sudo 处理

1. 若已是 root → 直接执行
2. 否则尝试 `sudo -n`（免密，已授权过即可通过）
3. 失败则交互式提示输密码，**整个进程只问一次**（首次成功后缓存凭证给后续命令）
4. 仍失败 → 非零退出，明确说明卡在哪一步，**绝不静默失败**
5. 只读命令（`status` / `list`）永不请求提权

## 7. 错误处理与回滚

- Profile 解析失败 → 应用前即拒绝，不动系统
- 某条 `pmset` 命令返回非零 → 立即**用刚存的快照回滚**，再报错退出
- `awake` 前置校验不通过 → 拒绝应用，输出缺失项与解决步骤
- 快照写入失败 → 中止，不执行任何修改（保证"改之前一定有退路"）

## 8. 测试策略

**重点测试 Parser**——喂真实 `pmset` 输出样本（已采集），断言解析结果，**不碰真实系统设置**。

覆盖用例：
- 完整 `pmset -g custom` 双段输出解析
- `SleepDisabled` 从 `pmset -g` 提取
- 异常输入（缺段、空值、多余空格）不崩溃
- Profile JSON 加载与字段校验
- 命令序列构造（含 `-a` / `-c` / `-b` 作用域正确性）
- `charging` 模式**必须**产出 `disablesleep 0`（防回归：从 `background` 切回时漏关全局开关是高风险 bug）
- `default` 模式**必须**产出 `disablesleep 0`（同上，这是最容易被漏掉的一条）

**不测**：真实 sudo 执行、真实截图（需要人工授权，无法自动化）。

## 9. 验收标准

1. `bash 合盖常驻配置.sh show` 的检测能力被 `batteryctl.py status` 完整覆盖并增强
2. `apply background` 后合盖脚本继续运行（人工验证）
3. `apply charging` 后 `SleepDisabled` 回到 0、AC `sleep` 为 0、`displaysleep` 为 1
4. `apply default` 后各项与 Apple 原生默认一致
5. `restore` 能准确回到快照状态
6. 单元测试全绿，且测试过程不改动系统电源设置

## 10. 与既有脚本的关系

工作区已有 `合盖常驻配置.sh`（已验证可用的最小版本）。本工具是它的超集；实施完成后，该脚本保留为"无 Python 环境时的应急方案"，并在 README 中说明二者关系。
