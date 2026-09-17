#!/bin/bash
#
# 合盖常驻 + 接电永不休眠 配置脚本
# 用法:
#   sudo bash 合盖常驻配置.sh apply     # 应用
#   sudo bash 合盖常驻配置.sh restore   # 还原为出厂默认
#   bash 合盖常驻配置.sh show           # 只看当前状态（不需要 sudo）
#
set -euo pipefail

MODE="${1:-show}"

show_state() {
  echo "===== 当前电源设置 ====="
  pmset -g custom
  echo
  echo "===== 全局休眠开关 ====="
  local sd
  sd=$(pmset -g | awk '/SleepDisabled/{print $2}')
  if [ "$sd" = "1" ]; then
    echo "SleepDisabled = 1  ->  已禁用休眠（合盖也不会睡）"
  else
    echo "SleepDisabled = 0  ->  未禁用休眠（合盖会睡）"
  fi
  echo
  echo "===== 当前供电与电网状态 ====="
  pmset -g batt
  echo
  echo "===== 外接显示器数量（合盖截图前提） ====="
  local total ext
  total=$(system_profiler SPDisplaysDataType 2>/dev/null | grep -c "Resolution:" || true)
  ext=$(system_profiler SPDisplaysDataType 2>/dev/null | grep -c "Built-in" || true)
  echo "显示器总数: ${total}  (其中内置: ${ext})"
  if [ "$total" -le "$ext" ]; then
    echo "提示: 没有外接显示器 —— 合盖后内置屏会断电，截不到图。"
  else
    echo "已检测到外接显示器，合盖后可以截外接屏。"
  fi
  echo
  echo "===== 适配器功率与 PD 档位 ====="
  python3 - <<'PYEOF'
import subprocess, re, sys
raw = subprocess.run(["ioreg", "-rn", "AppleSmartBattery"],
                     capture_output=True, text=True).stdout
m = re.search(r'"AdapterDetails" = \{.*"Description"="[^"]*"\}', raw, re.S)
if not m:
    print("未检测到适配器信息。")
    sys.exit(0)
blk = m.group(0)
watts = re.search(r'"Watts"=(\d+)', blk)
volt = re.search(r'"AdapterVoltage"=(\d+)', blk)
cur = re.search(r'"Current"=(\d+)', blk)
if watts:
    print(f"适配器标称: {watts.group(1)} W")
if volt and cur:
    v = int(volt.group(1)) / 1000
    c = int(cur.group(1)) / 1000
    print(f"当前协商档位: {v:.0f} V / {c:.2f} A  = {v*c:.1f} W")
menu = re.findall(r'"MaxCurrent"=(\d+),"MaxVoltage"=(\d+)', blk)
if menu:
    print("可选档位:")
    has20v = False
    for c, v in menu:
        vv = int(v) / 1000
        cc = int(c) / 1000
        if vv >= 20:
            has20v = True
        print(f"  {vv:>5.0f} V / {cc:.2f} A  = {vv*cc:>5.1f} W")
    print()
    if has20v:
        print("判断: 存在 20V 档 -> 该口具备 45W 以上供电能力。")
    else:
        print("判断: 无 20V 档 -> 该口无法达到 45W 以上，高负载下会掉到“没有在充电”。")
PYEOF
}

need_root() {
  if [ "$(id -u)" != "0" ]; then
    echo "错误: 应用/还原设置需要 root 权限。" >&2
    echo "请改用: sudo bash $0 $MODE" >&2
    exit 1
  fi
}

apply_all() {
  need_root
  echo "[1/4] 接电时屏幕永不关闭 ..."
  pmset -c displaysleep 0
  echo "[2/4] 接电时系统永不因空闲休眠 ..."
  pmset -c sleep 0
  echo "[3/4] 接电时硬盘永不停转 ..."
  pmset -c disksleep 0
  echo "[4/4] 全局禁用休眠（这一条才是压住合盖休眠的关键）..."
  pmset -a disablesleep 1
  echo
  echo "完成。当前状态："
  show_state
  echo
  echo "================================================================"
  echo "重要提醒："
  echo "  disablesleep 是【全局】设置，不区分插电还是用电池。"
  echo "  也就是说拔掉电源后，合盖放进包里它仍会继续运行："
  echo "  发热、耗电，长时间可能闷热到降频。"
  echo "  不用时请执行: sudo bash $0 restore"
  echo "================================================================"
}

restore_all() {
  need_root
  echo "[1/2] 关闭全局休眠禁用 ..."
  pmset -a disablesleep 0
  echo "[2/2] 恢复 Apple 出厂默认 ..."
  pmset restoredefaults
  echo
  echo "完成。当前状态："
  show_state
}

case "$MODE" in
  apply)   apply_all ;;
  restore) restore_all ;;
  show)    show_state ;;
  *)
    echo "用法: sudo bash $0 {apply|restore|show}" >&2
    exit 1
    ;;
esac
