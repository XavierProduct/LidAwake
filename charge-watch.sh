#!/bin/bash
# mac-charge-watch.sh —— 监控 Mac 充电状态，捕捉「PD 协商降级 / 突然停止充电」的瞬间
#
# 用法:
#   ./mac-charge-watch.sh                # 每 2 秒采样，共 5 分钟，日志写到 ~/Desktop/charge-watch.log
#   ./mac-charge-watch.sh 1 600          # 每 1 秒采样，共 10 分钟
#   ./mac-charge-watch.sh 2 300 /tmp/cw.log
#
# 关注点:
#   adapterW  应该是 60(20V/3A) 或 96/100；如果掉到 18/27/15 说明 PD 档位塌了
#   充电       变成 No 但你仍然插着电 → macOS 停止给电池充电（正在掉电运行）
#   NC/Inh     NotChargingReason / ChargerInhibitReason，非 0 表示系统主动禁止充电
#   battW      实际进入电池的功率，长期接近 0 说明没在充

INTERVAL="${1:-2}"
DURATION="${2:-300}"
LOG="${3:-$HOME/Desktop/charge-watch.log}"

printf '采样间隔 %ss，总时长 %ss，日志: %s\n' "$INTERVAL" "$DURATION" "$LOG"
printf '%-9s %-4s %-5s %-5s %-10s %-11s %-8s %-7s %s\n' \
       '时间' 'SoC' '充电' '外接' '适配器V' '充电mA' '电池W' 'adapterW' 'NC/Inh/Slow'
printf -- '------------------------------------------------------------------------------\n'

end=$(( $(date +%s) + DURATION ))
first=1
while [ "$(date +%s)" -lt "$end" ]; do
  IG=$(ioreg -rn AppleSmartBattery 2>/dev/null)

  soc=$(printf '%s\n' "$IG" | grep -m1 '"CurrentCapacity" ='   | grep -o '[0-9]*$')
  chg=$(printf '%s\n' "$IG" | grep -m1 '"IsCharging" ='        | grep -o 'Yes\|No')
  ext=$(printf '%s\n' "$IG" | grep -m1 '"ExternalConnected" =' | grep -o 'Yes\|No')
  # ioreg 把 Amperage 按无符号 64 位打印：放电时会是个接近 2^64 的天文数字。
  # 必须用 bc 做任意精度运算还原成负数（bash/awk 都是双精度，会直接丢精度变成 0）。
  amp=$(printf '%s\n' "$IG" | grep -m1 '"Amperage" =' | grep -o '[0-9]*$')
  amp=$(printf 'if (%s > 9223372036854775807) %s - 18446744073709551616 else %s\n' \
         "$amp" "$amp" "$amp" | bc)
  pv=$(printf '%s\n'  "$IG" | grep -m1 '"Voltage" ='           | grep -o '[0-9]*$')

  AD=$(printf '%s\n' "$IG" | grep -m1 '"AdapterDetails" =')
  av=$(printf '%s' "$AD" | grep -o '"AdapterVoltage"=[0-9]*' | cut -d= -f2)
  aw=$(printf '%s' "$AD" | grep -o '"Watts"=[0-9]*'          | cut -d= -f2)

  CD=$(printf '%s\n' "$IG" | grep -m1 '"ChargerData" =')
  ncr=$(printf '%s' "$CD" | grep -o '"NotChargingReason"=[0-9]*'    | cut -d= -f2)
  inh=$(printf '%s' "$CD" | grep -o '"ChargerInhibitReason"=[0-9]*' | cut -d= -f2)
  slw=$(printf '%s' "$CD" | grep -o '"SlowChargingReason"=[0-9]*'   | cut -d= -f2)

  # 电池侧实际功率: amperage(mA) x pack voltage(mV) -> W
  battw=$(awk -v a="${amp:-0}" -v v="${pv:-0}" 'BEGIN{printf "%.1f", a*v/1000000}')

  flag=""
  # 只有「插着电」时这些异常码才有意义；没插电时 NotChargingReason=128 是正常的
  if [ "$ext" = "Yes" ]; then
    [ -n "$aw" ] && [ "$aw" != "60" ] && flag="$flag"$'\n  ^^ 适配器档位不是 60W（当前 '"$aw"'W）—— PD 可能已降级'
    [ "$chg" = "No" ] && flag="$flag"$'\n  ^^ 插着电但没在充电！'
    [ -n "$ncr" ] && [ "$ncr" != "0" ] && flag="$flag"$'\n  ^^ NotChargingReason='"$ncr"
    [ -n "$inh" ] && [ "$inh" != "0" ] && flag="$flag"$'\n  ^^ ChargerInhibitReason='"$inh"
  fi

  printf '%-9s %-4s %-5s %-5s %-10s %-11s %-8s %-7s %s/%s/%s%s\n' \
         "$(date '+%H:%M:%S')" "${soc:-?}%" "${chg:-?}" "${ext:-?}" \
         "${av:-?}" "${amp:-?}" "$battw" "${aw:-?}" "${ncr:-?}" "${inh:-?}" "${slw:-?}" "$flag"

  if [ "$first" = 1 ]; then
    { printf '=== mac-charge-watch @ %s ===\n' "$(date)"; } >> "$LOG"
    first=0
  fi
  printf '%s SoC=%s chg=%s ext=%s V=%s mA=%s battW=%s adV=%s adW=%s NC=%s Inh=%s Slow=%s\n' \
         "$(date '+%F %T')" "${soc:-?}" "${chg:-?}" "${ext:-?}" "${av:-?}" \
         "${amp:-?}" "$battw" "${av:-?}" "${aw:-?}" "${ncr:-?}" "${inh:-?}" "${slw:-?}" >> "$LOG"

  sleep "$INTERVAL"
done
echo "完成，日志: $LOG"
