# batteryctl 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 macOS 电源策略收敛为 4 个命名模式，支持一键切换、切换前自动快照、可回滚，并提供含 PD 档位诊断的只读状态查询。

**Architecture:** 单文件 Python 3 脚本（零第三方依赖），内含三个职责单元：Parser（纯函数，`pmset` 文本 → dict）、Capability（只读探测）、Applier（快照 → 执行 → 失败回滚）。模式定义外置为 `profiles/*.json` 纯数据。

**Tech Stack:** Python 3（本机 `/opt/homebrew/bin/python3`）、`pmset`、`ioreg`、`system_profiler`、`unittest`（标准库，无需 pytest）。

**设计依据：** `docs/2026-09-13-batteryctl-design.md`

---

## 文件结构

| 文件 | 职责 |
|---|---|
| `tools/batteryctl/batteryctl.py` | 唯一入口；含 Parser / Capability / Applier 三段 |
| `tools/batteryctl/profiles/*.json` | 4 个模式定义，纯数据 |
| `tools/batteryctl/tests/test_batteryctl.py` | 标准库 unittest，只测纯函数 |
| `tools/batteryctl/snapshots/` | 运行时生成，需 gitignore |
| `tools/batteryctl/README.md` | 用法与与旧脚本的关系 |

## 关键实测事实（实现时依赖）

Apple 出厂默认（本机 `restoredefaults` 实测）：
- Battery: `displaysleep 2`, `sleep 1`, `disksleep 10`, `womp 0`
- AC: `displaysleep 10`, `sleep 1`, `disksleep 10`, `womp 1`

`pmset -g` 真实输出（注意 `sleep` 行可能带括号说明，且**列顺序不固定**）：
```
System-wide power settings:
 SleepDisabled		0
Currently in use:
 standby              1
 Sleep On Power Button 1
 hibernatefile        /var/vm/sleepimage
 powernap             1
 networkoversleep     0
 disksleep            10
 sleep                1 (sleep prevented by UURemote, ChatGPT, powerd, sharingd)
 hibernatemode        3
 ttyskeepawake        1
 displaysleep         10
 tcpkeepalive         1
```

`AdapterDetails`（PD 档位菜单是**嵌套**的，正则必须匹配到最后一个 `}`）：
```
"AdapterDetails" = {"IsWireless"=No,"AdapterID"=0,"AdapterVoltage"=20000,"FamilyCode"=18446744073172697098,"UsbHvcHvcIndex"=4,"Watts"=60,"UsbHvcMenu"=({"Index"=0,"MaxCurrent"=2960,"MaxVoltage"=5000},...,{"Index"=4,"MaxCurrent"=2990,"MaxVoltage"=20000}),"Current"=2990,"PMUConfiguration"=2990,"Description"="pd charger"}
```

---

### Task 1: Parser — 解析 `pmset` 输出（纯函数）

**Files:**
- Create: `tools/batteryctl/batteryctl.py`
- Create: `tools/batteryctl/tests/test_batteryctl.py`

- [ ] **Step 1: 写失败的测试**

创建 `tools/batteryctl/tests/test_batteryctl.py`：

```python
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from batteryctl import parse_pmset_custom, parse_pmset_system  # noqa: E402


CUSTOM_SAMPLE = """Battery Power:
 Sleep On Power Button 1
 lowpowermode         0
 displaysleep         2
 sleep                1
 disksleep            10
 womp                 0
AC Power:
 Sleep On Power Button 1
 lowpowermode         0
 displaysleep         10
 sleep                1
 disksleep            10
 womp                 1
"""

SYSTEM_SAMPLE = """System-wide power settings:
 SleepDisabled\t\t0
Currently in use:
 standby              1
 disksleep            10
 sleep                1 (sleep prevented by UURemote, ChatGPT, powerd, sharingd)
 hibernatemode        3
 displaysleep         10
"""


class TestParsePmsetCustom(unittest.TestCase):
    def test_splits_two_branches(self):
        result = parse_pmset_custom(CUSTOM_SAMPLE)
        self.assertEqual(set(result), {"battery", "ac"})

    def test_reads_battery_values(self):
        result = parse_pmset_custom(CUSTOM_SAMPLE)
        self.assertEqual(result["battery"]["displaysleep"], 2)
        self.assertEqual(result["battery"]["sleep"], 1)
        self.assertEqual(result["battery"]["disksleep"], 10)
        self.assertEqual(result["battery"]["womp"], 0)

    def test_reads_ac_values(self):
        result = parse_pmset_custom(CUSTOM_SAMPLE)
        self.assertEqual(result["ac"]["displaysleep"], 10)
        self.assertEqual(result["ac"]["womp"], 1)

    def test_ignores_non_numeric_settings(self):
        """hibernatefile 等非数值项不应出现在结果里。"""
        result = parse_pmset_custom(CUSTOM_SAMPLE)
        self.assertNotIn("hibernatefile", result["ac"])
        self.assertNotIn("Sleep On Power Button", result["ac"])

    def test_survives_garbage_input(self):
        self.assertEqual(parse_pmset_custom(""), {})
        self.assertEqual(parse_pmset_custom("random text"), {})


class TestParsePmsetSystem(unittest.TestCase):
    def test_reads_sleepdisabled(self):
        self.assertEqual(parse_pmset_system(SYSTEM_SAMPLE)["SleepDisabled"], 0)

    def test_strips_parenthetical_note(self):
        """sleep 行的 '(sleep prevented by ...)' 必须被剥掉。"""
        self.assertEqual(parse_pmset_system(SYSTEM_SAMPLE)["sleep"], 1)

    def test_reads_displaysleep(self):
        self.assertEqual(parse_pmset_system(SYSTEM_SAMPLE)["displaysleep"], 10)

    def test_survives_garbage_input(self):
        self.assertEqual(parse_pmset_system(""), {})


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: 跑测试确认失败**

```bash
cd tools/batteryctl && python3 -m unittest discover -s tests -v
```
Expected: `ModuleNotFoundError: No module named 'batteryctl'`

- [ ] **Step 3: 写最小实现**

创建 `tools/batteryctl/batteryctl.py`：

```python
#!/usr/bin/env python3
"""batteryctl - macOS 电源策略模式切换与诊断工具。"""

import re

# 只关心这几项，其余（hibernatefile 等）忽略
BRANCH_KEYS = {"displaysleep", "sleep", "disksleep", "womp"}
SYSTEM_KEYS = {"SleepDisabled", "displaysleep", "sleep", "disksleep",
               "womp", "powernap", "standby"}

_BRANCH_HEADERS = {"Battery Power:": "battery", "AC Power:": "ac"}
_NUM = re.compile(r"^([A-Za-z ]+?)\s+(\d+)\s*(?:\(.*\))?$")


def _parse_lines(text, keys):
    """把 ' name   value (备注)' 形式的行解析为 dict。"""
    out = {}
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        m = _NUM.match(line)
        if not m:
            continue
        name = m.group(1).strip()
        if name in keys:
            out[name] = int(m.group(2))
    return out


def parse_pmset_custom(text):
    """解析 `pmset -g custom`，返回 {'battery': {...}, 'ac': {...}}。"""
    result = {}
    current = None
    bucket = []
    for line in text.splitlines():
        stripped = line.strip()
        if stripped in _BRANCH_HEADERS:
            if current:
                result[current] = _parse_lines("\n".join(bucket), BRANCH_KEYS)
            current = _BRANCH_HEADERS[stripped]
            bucket = []
        elif current is not None:
            bucket.append(line)
    if current:
        result[current] = _parse_lines("\n".join(bucket), BRANCH_KEYS)
    return result


def parse_pmset_system(text):
    """解析 `pmset -g`，返回 {'SleepDisabled': 0, 'sleep': 1, ...}。"""
    return _parse_lines(text, SYSTEM_KEYS)
```

- [ ] **Step 4: 跑测试确认通过**

```bash
cd tools/batteryctl && python3 -m unittest discover -s tests -v
```
Expected: `OK`（11 个测试全过）

- [ ] **Step 5: 提交**

```bash
cd <repo-root>
git add tools/batteryctl/batteryctl.py tools/batteryctl/tests/test_batteryctl.py
git commit -m "feat(batteryctl): add pmset output parser with tests"
```

---

### Task 2: Profile 加载与命令构造

**Files:**
- Modify: `tools/batteryctl/batteryctl.py`
- Modify: `tools/batteryctl/tests/test_batteryctl.py`
- Create: `tools/batteryctl/profiles/default.json`
- Create: `tools/batteryctl/profiles/charging.json`
- Create: `tools/batteryctl/profiles/background.json`
- Create: `tools/batteryctl/profiles/awake.json`

- [ ] **Step 1: 写失败的测试**

在 `test_batteryctl.py` 的 import 行改为：

```python
from batteryctl import (parse_pmset_custom, parse_pmset_system,
                        load_profile, build_commands, list_profiles)
```

在文件末尾 `if __name__` 之前追加：

```python
class TestProfiles(unittest.TestCase):
    def test_all_four_profiles_exist(self):
        self.assertEqual(sorted(list_profiles()),
                         ["awake", "background", "charging", "default"])

    def test_background_disables_sleep(self):
        p = load_profile("background")
        self.assertEqual(p["global"]["disablesleep"], 1)

    def test_charging_reenables_sleep(self):
        """防回归：从 background 切回 charging 时必须关掉全局 disablesleep。"""
        p = load_profile("charging")
        self.assertEqual(p["global"]["disablesleep"], 0)

    def test_default_reenables_sleep(self):
        """防回归：default 模式必须关掉全局 disablesleep。"""
        p = load_profile("default")
        self.assertEqual(p["global"]["disablesleep"], 0)

    def test_default_matches_apple_factory_values(self):
        p = load_profile("default")
        self.assertEqual(p["battery"]["displaysleep"], 2)
        self.assertEqual(p["battery"]["sleep"], 1)
        self.assertEqual(p["ac"]["displaysleep"], 10)
        self.assertEqual(p["ac"]["sleep"], 1)

    def test_load_profile_rejects_unknown_name(self):
        with self.assertRaises(KeyError):
            load_profile("nope")


class TestBuildCommands(unittest.TestCase):
    def test_uses_c_flag_for_battery_branch(self):
        p = load_profile("default")
        cmds = build_commands(p)
        self.assertIn(["pmset", "-b", "displaysleep", "2"], cmds)

    def test_uses_c_flag_for_ac_branch(self):
        p = load_profile("default")
        cmds = build_commands(p)
        self.assertIn(["pmset", "-c", "displaysleep", "10"], cmds)

    def test_uses_a_flag_for_global(self):
        p = load_profile("background")
        cmds = build_commands(p)
        self.assertIn(["pmset", "-a", "disablesleep", "1"], cmds)

    def test_commands_are_lists_of_strings(self):
        cmds = build_commands(load_profile("charging"))
        for c in cmds:
            self.assertIsInstance(c, list)
            self.assertTrue(all(isinstance(x, str) for x in c))
```

- [ ] **Step 2: 跑测试确认失败**

```bash
cd tools/batteryctl && python3 -m unittest discover -s tests -v
```
Expected: `ImportError: cannot import name 'load_profile'`

- [ ] **Step 3: 创建四个 profile JSON**

`profiles/default.json`：
```json
{
  "name": "default",
  "description": "日常使用，该睡就睡（含插电），等同 Apple 出厂默认",
  "requires": [],
  "warn": null,
  "global": { "disablesleep": 0 },
  "battery": { "displaysleep": 2, "sleep": 1, "disksleep": 10, "womp": 0 },
  "ac": { "displaysleep": 10, "sleep": 1, "disksleep": 10, "womp": 1 }
}
```

`profiles/charging.json`：
```json
{
  "name": "charging",
  "description": "车上充电最快：接电时屏幕尽快关闭、系统允许休眠，把功率让给电池",
  "requires": [],
  "warn": null,
  "global": { "disablesleep": 0 },
  "battery": { "displaysleep": 2, "sleep": 1, "disksleep": 10, "womp": 0 },
  "ac": { "displaysleep": 1, "sleep": 0, "disksleep": 10, "womp": 1 }
}
```

`profiles/background.json`：
```json
{
  "name": "background",
  "description": "合盖跑长任务：合盖不睡、屏幕尽快关闭，脚本继续运行",
  "requires": [],
  "warn": "disablesleep 是全局设置，不区分插电。拔电后合盖放包里会持续运行、发热耗电。",
  "global": { "disablesleep": 1 },
  "battery": { "displaysleep": 2, "sleep": 1, "disksleep": 10, "womp": 0 },
  "ac": { "displaysleep": 0, "sleep": 0, "disksleep": 10, "womp": 1 }
}
```

`profiles/awake.json`：
```json
{
  "name": "awake",
  "description": "外接屏合盖做端到端测试并截图",
  "requires": ["external_display", "screen_recording"],
  "warn": "disablesleep 是全局设置，不区分插电。拔电后合盖放包里会持续运行、发热耗电。",
  "global": { "disablesleep": 1 },
  "battery": { "displaysleep": 2, "sleep": 1, "disksleep": 10, "womp": 0 },
  "ac": { "displaysleep": 0, "sleep": 0, "disksleep": 10, "womp": 1 }
}
```

- [ ] **Step 4: 实现加载与命令构造**

在 `batteryctl.py` 顶部 import 区改为：

```python
import json
import os
import re

_PROFILE_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            "profiles")

# 各分支使用的 pmset 作用域开关
_SCOPE_FLAG = {"battery": "-b", "ac": "-c"}
```

在文件末尾追加：

```python
def list_profiles():
    """返回可用模式名列表。"""
    names = []
    for fn in os.listdir(_PROFILE_DIR):
        if fn.endswith(".json"):
            names.append(fn[: -len(".json")])
    return sorted(names)


def load_profile(name):
    """按名称加载模式定义。不存在时抛 KeyError。"""
    path = os.path.join(_PROFILE_DIR, name + ".json")
    if not os.path.isfile(path):
        raise KeyError("unknown profile: %s" % name)
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def build_commands(profile):
    """把模式定义翻译成 pmset 命令序列（list of argv list）。"""
    cmds = []
    for branch in ("battery", "ac"):
        flag = _SCOPE_FLAG[branch]
        for key, value in profile.get(branch, {}).items():
            cmds.append(["pmset", flag, key, str(value)])
    for key, value in profile.get("global", {}).items():
        cmds.append(["pmset", "-a", key, str(value)])
    return cmds
```

- [ ] **Step 5: 跑测试确认通过**

```bash
cd tools/batteryctl && python3 -m unittest discover -s tests -v
```
Expected: `OK`（22 个测试全过）

- [ ] **Step 6: 提交**

```bash
cd <repo-root>
git add tools/batteryctl/
git commit -m "feat(batteryctl): add profiles and pmset command builder"
```

---

### Task 3: Capability — 只读探测与外接屏/权限检测

**Files:**
- Modify: `tools/batteryctl/batteryctl.py`
- Modify: `tools/batteryctl/tests/test_batteryctl.py`

- [ ] **Step 1: 写失败的测试**

import 行改为追加 `count_external_displays, parse_adapter`：

```python
from batteryctl import (parse_pmset_custom, parse_pmset_system,
                        load_profile, build_commands, list_profiles,
                        count_external_displays, parse_adapter)
```

追加测试：

```python
# 只有一个内置屏
ONE_INTERNAL = """Graphics/Displays:
    Apple M5:
      Displays:
          Display Type: Built-in Liquid Retina Display
          Resolution: 2560 x 1664 Retina
          Main Display: Yes
          Mirror: Off
"""

# 内置 + 1 个外接
WITH_EXTERNAL = """Graphics/Displays:
    Apple M5:
      Displays:
          Display Type: Built-in Liquid Retina Display
          Resolution: 2560 x 1664 Retina
          Main Display: Yes
          Mirror: Off
          Display Type: External
          Resolution: 1920 x 1080
"""

ADAPTER_60W = ('"AdapterDetails" = {"IsWireless"=No,"AdapterID"=0,'
               '"AdapterVoltage"=20000,"FamilyCode"=18446744073172697098,'
               '"UsbHvcHvcIndex"=4,"Watts"=60,"UsbHvcMenu"=({"Index"=0,'
               '"MaxCurrent"=2960,"MaxVoltage"=5000},{"Index"=4,'
               '"MaxCurrent"=2990,"MaxVoltage"=20000}),"Current"=2990,'
               '"PMUConfiguration"=2990,"Description"="pd charger"}')

ADAPTER_18W = ('"AdapterDetails" = {"IsWireless"=No,"AdapterID"=0,'
               '"AdapterVoltage"=12000,"FamilyCode"=18446744073172697098,'
               '"UsbHvcHvcIndex"=2,"Watts"=18,"UsbHvcMenu"=({"Index"=0,'
               '"MaxCurrent"=3000,"MaxVoltage"=5000},{"Index"=1,'
               '"MaxCurrent"=2000,"MaxVoltage"=9000},{"Index"=2,'
               '"MaxCurrent"=1500,"MaxVoltage"=12000}),"Current"=1500,'
               '"PMUConfiguration"=1500,"Description"="pd charger"}')


class TestCountExternalDisplays(unittest.TestCase):
    def test_only_builtin(self):
        self.assertEqual(count_external_displays(ONE_INTERNAL), 0)

    def test_with_external(self):
        self.assertEqual(count_external_displays(WITH_EXTERNAL), 1)

    def test_empty_input(self):
        self.assertEqual(count_external_displays(""), 0)


class TestParseAdapter(unittest.TestCase):
    def test_reads_watts(self):
        self.assertEqual(parse_adapter(ADAPTER_60W)["watts"], 60)

    def test_reads_current_contract(self):
        a = parse_adapter(ADAPTER_60W)
        self.assertEqual(a["voltage"], 20000)
        self.assertEqual(a["current"], 2990)

    def test_menu_is_not_truncated_by_nested_brace(self):
        """回归：UsbHvcMenu 是嵌套结构，必须解析出全部档位。"""
        self.assertEqual(len(parse_adapter(ADAPTER_60W)["menu"]), 2)

    def test_detects_20v_capability(self):
        self.assertTrue(parse_adapter(ADAPTER_60W)["has_20v"])

    def test_18w_lacks_20v(self):
        a = parse_adapter(ADAPTER_18W)
        self.assertEqual(a["watts"], 18)
        self.assertFalse(a["has_20v"])

    def test_returns_none_when_absent(self):
        self.assertIsNone(parse_adapter("no adapter here"))
```

- [ ] **Step 2: 跑测试确认失败**

```bash
cd tools/batteryctl && python3 -m unittest discover -s tests -v
```
Expected: `ImportError: cannot import name 'count_external_displays'`

- [ ] **Step 3: 实现探测函数**

在 `batteryctl.py` 末尾追加：

```python
def count_external_displays(profiler_text):
    """从 system_profiler SPDisplaysDataType 输出数外接屏个数。

    每个显示器有一个 'Resolution:' 行；内置屏带 'Built-in'。
    """
    resolutions = profiler_text.count("Resolution:")
    builtin = profiler_text.count("Built-in")
    return max(0, resolutions - builtin)


def parse_adapter(ioreg_text):
    """解析 ioreg 里的 AdapterDetails。

    返回 {'watts','voltage','current','menu':[(v,c),...],'has_20v'} 或 None。
    """
    # 关键：UsbHvcMenu 是嵌套的，必须匹配到最后一个 "Description"
    m = re.search(r'"AdapterDetails" = \{.*?"Description"="[^"]*"\}',
                  ioreg_text, re.S)
    if not m:
        return None
    blk = m.group(0)

    def num(pattern):
        hit = re.search(pattern, blk)
        return int(hit.group(1)) if hit else None

    menu = [(int(v), int(c))
            for c, v in re.findall(r'"MaxCurrent"=(\d+),"MaxVoltage"=(\d+)', blk)]
    return {
        "watts": num(r'"Watts"=(\d+)'),
        "voltage": num(r'"AdapterVoltage"=(\d+)'),
        "current": num(r'"Current"=(\d+)'),
        "menu": menu,
        "has_20v": any(v >= 20000 for v, _ in menu),
    }
```

- [ ] **Step 4: 跑测试确认通过**

```bash
cd tools/batteryctl && python3 -m unittest discover -s tests -v
```
Expected: `OK`（31 个测试全过）

- [ ] **Step 5: 提交**

```bash
cd <repo-root>
git add tools/batteryctl/
git commit -m "feat(batteryctl): add display count and PD adapter parsing"
```

---

### Task 4: Applier — 快照、执行、校验、回滚

**Files:**
- Modify: `tools/batteryctl/batteryctl.py`
- Modify: `tools/batteryctl/tests/test_batteryctl.py`

- [ ] **Step 1: 写失败的测试**

import 行追加 `snapshot_path_name`，并追加测试：

```python
from batteryctl import (parse_pmset_custom, parse_pmset_system,
                        load_profile, build_commands, list_profiles,
                        count_external_displays, parse_adapter,
                        snapshot_filename)
```

```python
class TestSnapshotFilename(unittest.TestCase):
    def test_is_sortable_and_names_profile(self):
        name = snapshot_filename("2026-09-13T18:30:00+08:00", "charging")
        self.assertIn("charging", name)
        self.assertTrue(name.endswith(".json"))

    def test_colons_replaced_for_filesystem_safety(self):
        name = snapshot_filename("2026-09-13T18:30:00+08:00", "charging")
        self.assertNotIn(":", name)

    def test_lexicographic_order_matches_time_order(self):
        a = snapshot_filename("2026-09-13T18:30:00+08:00", "charging")
        b = snapshot_filename("2026-09-13T19:30:00+08:00", "default")
        self.assertLess(a, b)
```

- [ ] **Step 2: 跑测试确认失败**

```bash
cd tools/batteryctl && python3 -m unittest discover -s tests -v
```
Expected: `ImportError: cannot import name 'snapshot_filename'`

- [ ] **Step 3: 实现快照命名与 Applier**

在 `batteryctl.py` 追加（注意 `import` 区需补充 `datetime`、`glob`、`shutil`、`subprocess`、`sys`）：

```python
def snapshot_filename(timestamp, profile_name):
    """生成可读、可按字典序排序的快照文件名。"""
    safe = timestamp.replace(":", "").replace("+", "_")
    return "%s_before-%s.json" % (safe, profile_name)
```

```python
def run_cmd(argv):
    """执行命令，返回 (returncode, stdout, stderr)。"""
    p = subprocess.run(argv, capture_output=True, text=True)
    return p.returncode, p.stdout, p.stderr


def read_state():
    """读取当前完整电源状态，用于快照与校验。"""
    _, custom, _ = run_cmd(["pmset", "-g", "custom"])
    _, system, _ = run_cmd(["pmset", "-g"])
    _, batt, _ = run_cmd(["pmset", "-g", "batt"])
    state = parse_pmset_custom(custom)
    state["global"] = parse_pmset_system(system)
    state["power_source"] = "AC" if "'AC Power'" in batt else "Battery"
    return state
```

```python
def take_snapshot(reason):
    """保存当前状态到 snapshots/<时间>_<reason>.json，返回文件路径。"""
    snap_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            "snapshots")
    os.makedirs(snap_dir, exist_ok=True)
    ts = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
    payload = read_state()
    payload["captured_at"] = ts
    payload["reason"] = reason
    path = os.path.join(snap_dir, snapshot_filename(ts, reason))
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=2, ensure_ascii=False)
    return path


def latest_snapshot():
    """返回最近一次快照路径，没有则 None。"""
    snap_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            "snapshots")
    files = sorted(glob.glob(os.path.join(snap_dir, "*.json")))
    return files[-1] if files else None


def apply_snapshot(path):
    """把快照里的值写回系统。"""
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    cmds = []
    for branch, flag in (("battery", "-b"), ("ac", "-c")):
        for key, value in data.get(branch, {}).items():
            cmds.append(["pmset", flag, key, str(value)])
    for key, value in data.get("global", {}).items():
        cmds.append(["pmset", "-a", key, str(value)])
    for argv in cmds:
        rc, _, err = run_cmd(argv)
        if rc != 0:
            raise RuntimeError("failed: %s (%s)" % (" ".join(argv), err.strip()))
```

- [ ] **Step 4: 跑测试确认通过**

```bash
cd tools/batteryctl && python3 -m unittest discover -s tests -v
```
Expected: `OK`（34 个测试全过）

- [ ] **Step 5: 提交**

```bash
cd <repo-root>
git add tools/batteryctl/
git commit -m "feat(batteryctl): add snapshot capture and apply"
```

---

### Task 5: CLI — status / list / apply / restore / apple-defaults

**Files:**
- Modify: `tools/batteryctl/batteryctl.py`
- Create: `tools/batteryctl/.gitignore`
- Create: `tools/batteryctl/README.md`

- [ ] **Step 1: 实现 privilege 处理与 CLI**

在 `batteryctl.py` 末尾追加：

```python
def ensure_root():
    """确保以 root 运行。失败时返回 False 并打印指引。"""
    if os.geteuid() == 0:
        return True
    rc, _, _ = run_cmd(["sudo", "-n", "true"])
    if rc == 0:
        return True
    print("错误: 该操作需要 root 权限。", file=sys.stderr)
    print("请用: sudo python3 %s <命令>" % sys.argv[0], file=sys.stderr)
    return False


def cmd_status():
    state = read_state()
    print("===== 当前电源设置 =====")
    for branch, label in (("battery", "电池"), ("ac", "接电")):
        vals = state.get(branch, {})
        print("%s: displaysleep=%s  sleep=%s  disksleep=%s  womp=%s" % (
            label, vals.get("displaysleep"), vals.get("sleep"),
            vals.get("disksleep"), vals.get("womp")))
    sd = state.get("global", {}).get("SleepDisabled")
    print("SleepDisabled=%s  ->  %s" % (
        sd, "合盖不会睡" if sd == 1 else "合盖会睡"))

    print()
    print("===== 供电状态 =====")
    rc, out, _ = run_cmd(["pmset", "-g", "batt"])
    print(out.strip())

    print()
    print("===== 外接显示器（合盖截图前提） =====")
    _, prof, _ = run_cmd(["system_profiler", "SPDisplaysDataType"])
    ext = count_external_displays(prof)
    print("外接显示器数量: %d" % ext)
    print("合盖截图: %s" % ("可以" if ext > 0 else "不可以（内置屏合盖后断电，无画面）"))

    print()
    print("===== 适配器 PD 档位 =====")
    _, ioreg_out, _ = run_cmd(["ioreg", "-rn", "AppleSmartBattery"])
    ad = parse_adapter(ioreg_out)
    if not ad:
        print("未检测到适配器。")
    else:
        print("标称: %s W" % ad["watts"])
        if ad["voltage"] and ad["current"]:
            print("协商: %.0f V / %.2f A = %.1f W" % (
                ad["voltage"] / 1000, ad["current"] / 1000,
                ad["voltage"] / 1000 * ad["current"] / 1000))
        for v, c in ad["menu"]:
            print("  %5.0f V / %.2f A = %5.1f W" % (
                v / 1000, c / 1000, v / 1000 * c / 1000))
        print("判断: %s" % ("存在 20V 档，具备 45W 以上能力"
                          if ad["has_20v"] else
                          "无 20V 档，无法达到 45W 以上"))
    return 0


def cmd_list():
    for name in list_profiles():
        p = load_profile(name)
        print("%-12s %s" % (name, p["description"]))
    return 0


def cmd_apply(name):
    try:
        profile = load_profile(name)
    except KeyError:
        print("错误: 未知模式 '%s'。可用: %s"
              % (name, ", ".join(list_profiles())), file=sys.stderr)
        return 2

    missing = check_requirements(profile)
    if missing:
        print("错误: 模式 '%s' 的前置条件不满足：" % name, file=sys.stderr)
        for item in missing:
            print("  - %s" % item, file=sys.stderr)
        print("请先满足上述条件再重试。", file=sys.stderr)
        return 3

    if not ensure_root():
        return 1

    snap = take_snapshot("before-%s" % name)
    print("已保存快照: %s" % snap)

    if profile.get("warn"):
        print()
        print("!! 警告: %s" % profile["warn"])
        print()

    for argv in build_commands(profile):
        rc, _, err = run_cmd(argv)
        if rc != 0:
            print("命令失败: %s" % " ".join(argv), file=sys.stderr)
            print("正在回滚到快照 ...", file=sys.stderr)
            apply_snapshot(snap)
            print("已回滚。", file=sys.stderr)
            return 1
        print("  ok  %s" % " ".join(argv))

    print()
    print("模式 '%s' 已应用。" % name)
    return 0


def cmd_restore(target=None):
    path = target or latest_snapshot()
    if not path:
        print("错误: 没有可用快照。", file=sys.stderr)
        return 2
    if not os.path.isfile(path):
        print("错误: 快照不存在: %s" % path, file=sys.stderr)
        return 2
    if not ensure_root():
        return 1
    apply_snapshot(path)
    print("已从快照恢复: %s" % path)
    return 0


def cmd_apple_defaults():
    if not ensure_root():
        return 1
    # 必须先关 disablesleep：实测 restoredefaults 不会重置它
    rc, _, err = run_cmd(["pmset", "-a", "disablesleep", "0"])
    if rc != 0:
        print("错误: 无法关闭 disablesleep: %s" % err, file=sys.stderr)
        return 1
    rc, _, err = run_cmd(["pmset", "restoredefaults"])
    if rc != 0:
        print("错误: restoredefaults 失败: %s" % err, file=sys.stderr)
        return 1
    print("已恢复 Apple 出厂默认，并关闭全局休眠禁用。")
    return 0
```

- [ ] **Step 2: 实现前置条件校验与 main**

追加：

```python
def check_requirements(profile):
    """返回未满足的前置条件描述列表。"""
    missing = []
    for req in profile.get("requires", []):
        if req == "external_display":
            _, prof, _ = run_cmd(["system_profiler", "SPDisplaysDataType"])
            if count_external_displays(prof) == 0:
                missing.append(
                    "需要外接显示器或 HDMI 欺骗器：内置屏合盖后会断电，截不到图")
        elif req == "screen_recording":
            if not has_screen_recording_permission():
                missing.append(
                    "需要「屏幕录制」权限：系统设置 > 隐私与安全性 > 屏幕录制，"
                    "为你运行测试的终端/App 勾选授权（必须人工操作）")
    return missing


def has_screen_recording_permission():
    """检测是否已有程序获得屏幕录制权限。

    通过查询 TCC 数据库；无权限读取时保守返回 False。
    """
    db = os.path.expanduser(
        "~/Library/Application Support/com.apple.TCC/TCC.db")
    if not os.path.isfile(db):
        return False
    rc, out, _ = run_cmd([
        "sqlite3", db,
        "select count(*) from access where service='kTCCServiceScreenCapture';"])
    if rc != 0:
        return False
    try:
        return int(out.strip()) > 0
    except ValueError:
        return False


USAGE = """batteryctl - macOS 电源策略模式切换与诊断

用法:
  batteryctl status              只读诊断（不需要 sudo）
  batteryctl list                列出所有模式
  batteryctl apply <模式>        快照并应用模式（需要 sudo）
  batteryctl restore [快照路径]  回滚到最近或指定快照（需要 sudo）
  batteryctl apple-defaults      恢复 Apple 出厂默认（需要 sudo）
"""


def main(argv):
    if len(argv) < 2:
        print(USAGE)
        return 2
    command = argv[1]
    if command == "status":
        return cmd_status()
    if command == "list":
        return cmd_list()
    if command == "apply":
        if len(argv) < 3:
            print("错误: apply 需要一个模式名。", file=sys.stderr)
            return 2
        return cmd_apply(argv[2])
    if command == "restore":
        return cmd_restore(argv[2] if len(argv) > 2 else None)
    if command == "apple-defaults":
        return cmd_apple_defaults()
    print("错误: 未知命令 '%s'" % command, file=sys.stderr)
    print(USAGE)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
```

在 `batteryctl.py` 的 import 区补全：

```python
import datetime
import glob
```

- [ ] **Step 3: 创建 .gitignore**

`tools/batteryctl/.gitignore`：
```
snapshots/
__pycache__/
*.pyc
```

- [ ] **Step 4: 手动验证（不需要 root 的部分）**

```bash
cd tools/batteryctl
python3 batteryctl.py list
```
Expected: 列出 4 个模式及描述。

```bash
python3 batteryctl.py status
```
Expected: 打印电源设置、供电状态、外接屏数量（当前为 0）、适配器档位（当前应为 60W 且含 20V 档）。

- [ ] **Step 5: 手动验证 awk 无关性与前置条件拒绝**

```bash
python3 batteryctl.py apply awake; echo "exit=$?"
```
Expected: 退出码 3，提示缺少外接显示器与屏幕录制权限。

- [ ] **Step 6: 提交**

```bash
cd <repo-root>
git add tools/batteryctl/
git commit -m "feat(batteryctl): add CLI with status/list/apply/restore"
```

---

### Task 6: README 与端到端验证

**Files:**
- Create: `tools/batteryctl/README.md`

- [ ] **Step 1: 写 README**

内容需覆盖：四个模式的用途对照表、每条命令示例、`disablesleep` 全局性风险提醒、合盖截图的两个前提（外接屏 + 屏幕录制权限）、与工作区既有 `合盖常驻配置.sh` 的关系（后者保留为无 Python 环境时的应急方案）。

- [ ] **Step 2: 端到端验证（需要用户输入 sudo 密码）**

```bash
cd tools/batteryctl
sudo python3 batteryctl.py apply background
python3 batteryctl.py status          # 期望 SleepDisabled=1
sudo python3 batteryctl.py apply default
python3 batteryctl.py status          # 期望 SleepDisabled=0、ac.displaysleep=10
sudo python3 batteryctl.py restore    # 期望回到 background 之前的状态
```

- [ ] **Step 3: 全量测试**

```bash
cd tools/batteryctl && python3 -m unittest discover -s tests -v
```
Expected: `OK`（34 个测试全过）

- [ ] **Step 4: 提交**

```bash
cd <repo-root>
git add tools/batteryctl/
git commit -m "docs(batteryctl): add README and finish end-to-end verification"
```

---

## 验收标准（对齐设计文档第 9 节）

1. `batteryctl.py status` 覆盖并增强 `合盖常驻配置.sh show` 的检测能力
2. `apply background` 后合盖脚本继续运行（人工验证，需合盖实测）
3. `apply charging` 后 `SleepDisabled=0`、AC `sleep=0`、`displaysleep=1`
4. `apply default` 后各项与 Apple 原生默认一致
5. `restore` 能准确回到快照状态
6. 单元测试全绿，且测试过程不改动系统电源设置
