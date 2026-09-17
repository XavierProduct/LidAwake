#!/usr/bin/env python3
"""batteryctl - macOS 电源策略模式切换与诊断工具。

把分散的 pmset 参数收敛为若干命名模式（profiles/*.json），
提供一键切换、切换前自动快照、可回滚，以及只读诊断。

用法:
  batteryctl status              只读诊断（不需要 sudo）
  batteryctl list                列出所有模式
  batteryctl apply <模式>        快照并应用模式（需要 sudo）
  batteryctl restore [快照路径]  回滚到最近或指定快照（需要 sudo）
  batteryctl apple-defaults      恢复 Apple 出厂默认（需要 sudo）
"""

import datetime
import glob
import json
import os
import re
import subprocess
import sys

# ---------------------------------------------------------------------------
# 常量
# ---------------------------------------------------------------------------

_HERE = os.path.dirname(os.path.abspath(__file__))
_PROFILE_DIR = os.path.join(_HERE, "profiles")
_SNAPSHOT_DIR = os.path.join(_HERE, "snapshots")

# 只关心这几项；hibernatefile 等非数值项忽略
BRANCH_KEYS = {"displaysleep", "sleep", "disksleep", "womp"}
SYSTEM_KEYS = {"SleepDisabled", "displaysleep", "sleep", "disksleep",
               "womp", "powernap", "standby"}

_BRANCH_HEADERS = {"Battery Power:": "battery", "AC Power:": "ac"}
_SCOPE_FLAG = {"battery": "-b", "ac": "-c"}

# 匹配 " name   value" 或 " name   value (备注)"
_NUM = re.compile(r"^([A-Za-z ]+?)\s+(\d+)\s*(?:\(.*\))?$")


# ---------------------------------------------------------------------------
# Parser（纯函数）
# ---------------------------------------------------------------------------

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


# ---------------------------------------------------------------------------
# Profiles（纯数据 + 加载）
# ---------------------------------------------------------------------------

def list_profiles():
    """返回可用模式名列表。"""
    names = []
    if not os.path.isdir(_PROFILE_DIR):
        return names
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


# ---------------------------------------------------------------------------
# Capability（只读探测）
# ---------------------------------------------------------------------------

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


# ---------------------------------------------------------------------------
# Applier（快照 / 执行 / 回滚）
# ---------------------------------------------------------------------------

def snapshot_filename(timestamp, reason):
    """生成可读、可按字典序排序、文件名安全的快照名。"""
    safe = timestamp.replace(":", "").replace("+", "_")
    return "%s_%s.json" % (safe, reason)


def run_cmd(argv):
    """执行命令，返回 (returncode, stdout, stderr)。

    注意：沙箱或权限限制可能让 subprocess 抛出 OSError
    （FileNotFoundError / PermissionError 都是其子类），
    这里统一转成非零返回码，避免调用方崩溃。
    """
    try:
        p = subprocess.run(argv, capture_output=True, text=True)
    except OSError as exc:
        return 126, "", str(exc)
    return p.returncode, p.stdout, p.stderr


def read_state():
    """读取当前完整电源状态，用于快照。"""
    _, custom, _ = run_cmd(["pmset", "-g", "custom"])
    _, system, _ = run_cmd(["pmset", "-g"])
    _, batt, _ = run_cmd(["pmset", "-g", "batt"])
    state = parse_pmset_custom(custom)
    state["global"] = parse_pmset_system(system)
    state["power_source"] = "AC" if "'AC Power'" in batt else "Battery"
    return state


def take_snapshot(reason):
    """保存当前状态到 snapshots/<时间>_<reason>.json，返回文件路径。"""
    os.makedirs(_SNAPSHOT_DIR, exist_ok=True)
    ts = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
    payload = read_state()
    payload["captured_at"] = ts
    payload["reason"] = reason
    path = os.path.join(_SNAPSHOT_DIR, snapshot_filename(ts, reason))
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=2, ensure_ascii=False)
    return path


def latest_snapshot():
    """返回最近一次快照路径，没有则 None。"""
    files = sorted(glob.glob(os.path.join(_SNAPSHOT_DIR, "*.json")))
    return files[-1] if files else None


def apply_snapshot(path):
    """把快照里的值写回系统。任一步失败抛 RuntimeError。"""
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    cmds = []
    for branch in ("battery", "ac"):
        flag = _SCOPE_FLAG[branch]
        for key, value in data.get(branch, {}).items():
            cmds.append(["pmset", flag, key, str(value)])
    for key, value in data.get("global", {}).items():
        cmds.append(["pmset", "-a", key, str(value)])
    for argv in cmds:
        rc, _, err = run_cmd(argv)
        if rc != 0:
            raise RuntimeError("failed: %s (%s)" % (" ".join(argv), err.strip()))


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def ensure_root():
    """确保可以提权执行。失败时打印指引并返回 False。

    策略：
      1. 已是 root -> 直接放行
      2. 终端可交互 -> sudo -v 提示输密码（整个进程只问一次）
      3. 非交互环境 -> 试 sudo -n（免密）
    """
    if os.geteuid() == 0:
        return True

    if sys.stdin.isatty():
        rc, _, err = run_cmd(["sudo", "-v"])
        if rc == 0:
            return True
        if err.strip():
            print("提权失败: %s" % err.strip(), file=sys.stderr)
    else:
        rc, _, _ = run_cmd(["sudo", "-n", "true"])
        if rc == 0:
            return True

    print("错误: 该操作需要 root 权限。", file=sys.stderr)
    print("请改用: sudo python3 %s <命令>" % sys.argv[0], file=sys.stderr)
    return False


def has_screen_recording_permission():
    """检测是否已有程序获得屏幕录制权限。

    通过查询 TCC 数据库；读取失败时保守返回 False。
    """
    db = os.path.expanduser(
        "~/Library/Application Support/com.apple.TCC/TCC.db")
    if not os.path.isfile(db):
        return False
    rc, out, _ = run_cmd([
        "sqlite3", db,
        "select count(*) from access "
        "where service='kTCCServiceScreenCapture';"])
    if rc != 0:
        return False
    try:
        return int(out.strip()) > 0
    except ValueError:
        return False


def check_requirements(profile):
    """返回未满足的前置条件描述列表。"""
    missing = []
    for req in profile.get("requires", []):
        if req == "external_display":
            _, prof, _ = run_cmd(["system_profiler", "SPDisplaysDataType"])
            if count_external_displays(prof) == 0:
                missing.append(
                    "需要外接显示器或 HDMI 欺骗器：内置屏合盖后会断电，"
                    "没有画面可截。")
        elif req == "screen_recording":
            if not has_screen_recording_permission():
                missing.append(
                    "需要「屏幕录制」权限：打开 系统设置 > 隐私与安全性 > "
                    "屏幕录制，为你运行测试的终端/App 勾选授权"
                    "（必须人工操作，无法自动完成）。")
    return missing


def _fmt_minutes(value):
    if value is None:
        return "?"
    return "永不" if value == 0 else "%s 分钟" % value


def parse_battery_line(text):
    """从 `pmset -g batt` 输出提取 (state, soc)。

    state 形如 'charging' / 'discharging' / 'AC attached'；
    解析不到时返回 (None, None)。
    """
    m = re.search(r"(\d+)%;\s*([^;]+);", text)
    if not m:
        return None, None
    return m.group(2).strip(), int(m.group(1))


def gather_status():
    """汇总结构化状态，供 status 文本模式与 --json 模式共用。"""
    state = read_state()
    _, batt, _ = run_cmd(["pmset", "-g", "batt"])
    batt_state, soc = parse_battery_line(batt)

    _, prof, _ = run_cmd(["system_profiler", "SPDisplaysDataType"])
    ext = count_external_displays(prof)

    _, ioreg_out, _ = run_cmd(["ioreg", "-rn", "AppleSmartBattery"])
    ad = parse_adapter(ioreg_out)

    return {
        "battery": state.get("battery", {}),
        "ac": state.get("ac", {}),
        "global": state.get("global", {}),
        "power_source": state.get("power_source"),
        "battery_state": batt_state,
        "soc_percent": soc,
        "profiles": list_profiles(),
        "external_displays": ext,
        "screen_recording": has_screen_recording_permission(),
        "adapter": ad,
    }


def cmd_status(as_json=False):
    data = gather_status()

    if as_json:
        print(json.dumps(data, ensure_ascii=False, indent=2))
        return 0

    state = data
    print("===== 当前电源设置 =====")
    for branch, label in (("battery", "电池"), ("ac", "接电")):
        vals = state.get(branch, {})
        print("%s: 屏幕关闭=%s  系统睡眠=%s  硬盘停转=%s  网络唤醒=%s" % (
            label,
            _fmt_minutes(vals.get("displaysleep")),
            _fmt_minutes(vals.get("sleep")),
            _fmt_minutes(vals.get("disksleep")),
            vals.get("womp")))
    sd = state.get("global", {}).get("SleepDisabled")
    print("SleepDisabled=%s  ->  %s" % (
        sd, "合盖不会睡" if sd == 1 else "合盖会睡"))
    print("当前电源: %s" % state.get("power_source"))

    print()
    print("===== 供电状态 =====")
    _, out, _ = run_cmd(["pmset", "-g", "batt"])
    for line in out.strip().splitlines():
        print("  " + line.strip())

    print()
    print("===== 外接显示器（合盖截图前提） =====")
    ext = state.get("external_displays", 0)
    print("外接显示器数量: %d" % ext)
    if ext > 0:
        print("合盖截图: 显示条件满足")
    else:
        print("合盖截图: 不可用 —— 内置屏合盖后断电，无画面可截。")
    if state.get("screen_recording"):
        print("屏幕录制权限: 已授予")
    else:
        print("屏幕录制权限: 未授予（截图会被系统拦截）")

    print()
    print("===== 适配器 PD 档位 =====")
    ad = state.get("adapter")
    if not ad:
        print("未检测到适配器。")
    else:
        print("标称功率: %s W" % ad["watts"])
        if ad["voltage"] and ad["current"]:
            print("当前协商: %.0f V / %.2f A = %.1f W" % (
                ad["voltage"] / 1000.0, ad["current"] / 1000.0,
                ad["voltage"] / 1000.0 * ad["current"] / 1000.0))
        for v, c in ad["menu"]:
            marker = "  <- 20V 档" if v >= 20000 else ""
            print("  %5.0f V / %.2f A = %5.1f W%s" % (
                v / 1000.0, c / 1000.0, v / 1000.0 * c / 1000.0, marker))
        if ad["has_20v"]:
            print("判断: 存在 20V 档 -> 该口具备 45W 以上供电能力。")
        else:
            print("判断: 无 20V 档 -> 该口无法达到 45W 以上，"
                  "高负载下会掉到「没有在充电」。")
    return 0


def cmd_list():
    for name in list_profiles():
        p = load_profile(name)
        print("%-12s %s" % (name, p.get("description", "")))
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
        return 3

    if not ensure_root():
        return 1

    try:
        snap = take_snapshot("before-%s" % name)
    except OSError as exc:
        print("错误: 无法保存快照，已中止（未做任何修改）: %s" % exc,
              file=sys.stderr)
        return 1
    print("已保存快照: %s" % snap)

    if profile.get("warn"):
        print()
        print("!! 警告: %s" % profile["warn"])

    for argv in build_commands(profile):
        rc, _, err = run_cmd(argv)
        if rc != 0:
            print("命令失败: %s" % " ".join(argv), file=sys.stderr)
            print("正在回滚到快照 ...", file=sys.stderr)
            try:
                apply_snapshot(snap)
                print("已回滚。", file=sys.stderr)
            except (RuntimeError, OSError) as rb_exc:
                print("回滚也失败: %s" % rb_exc, file=sys.stderr)
                print("请手动恢复，快照在: %s" % snap, file=sys.stderr)
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
    try:
        apply_snapshot(path)
    except (RuntimeError, OSError) as exc:
        print("错误: 恢复失败: %s" % exc, file=sys.stderr)
        return 1
    print("已从快照恢复: %s" % path)
    return 0


def cmd_apple_defaults():
    if not ensure_root():
        return 1
    # 必须先关 disablesleep：实测 restoredefaults 不会重置它
    rc, _, err = run_cmd(["pmset", "-a", "disablesleep", "0"])
    if rc != 0:
        print("错误: 无法关闭 disablesleep: %s" % err.strip(), file=sys.stderr)
        return 1
    rc, _, err = run_cmd(["pmset", "restoredefaults"])
    if rc != 0:
        print("错误: restoredefaults 失败: %s" % err.strip(), file=sys.stderr)
        return 1
    print("已恢复 Apple 出厂默认，并关闭全局休眠禁用。")
    return 0


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
        return cmd_status(as_json="--json" in argv[2:])
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
