"""batteryctl 单元测试。

只测纯函数：解析、profile 加载、命令构造、文件名生成。
测试过程不会调用 pmset 写操作，因此不会改动系统电源设置。
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from batteryctl import (  # noqa: E402
    parse_pmset_custom,
    parse_pmset_system,
    load_profile,
    build_commands,
    list_profiles,
    count_external_displays,
    parse_adapter,
    snapshot_filename,
    parse_battery_line,
)


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

ONE_INTERNAL = """Graphics/Displays:
    Apple M5:
      Displays:
          Display Type: Built-in Liquid Retina Display
          Resolution: 2560 x 1664 Retina
          Main Display: Yes
          Mirror: Off
"""

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

ADAPTER_60W = (
    '"AdapterDetails" = {"IsWireless"=No,"AdapterID"=0,'
    '"AdapterVoltage"=20000,"FamilyCode"=18446744073172697098,'
    '"UsbHvcHvcIndex"=4,"Watts"=60,"UsbHvcMenu"=({"Index"=0,'
    '"MaxCurrent"=2960,"MaxVoltage"=5000},{"Index"=4,'
    '"MaxCurrent"=2990,"MaxVoltage"=20000}),"Current"=2990,'
    '"PMUConfiguration"=2990,"Description"="pd charger"}'
)

ADAPTER_18W = (
    '"AdapterDetails" = {"IsWireless"=No,"AdapterID"=0,'
    '"AdapterVoltage"=12000,"FamilyCode"=18446744073172697098,'
    '"UsbHvcHvcIndex"=2,"Watts"=18,"UsbHvcMenu"=({"Index"=0,'
    '"MaxCurrent"=3000,"MaxVoltage"=5000},{"Index"=1,'
    '"MaxCurrent"=2000,"MaxVoltage"=9000},{"Index"=2,'
    '"MaxCurrent"=1500,"MaxVoltage"=12000}),"Current"=1500,'
    '"PMUConfiguration"=1500,"Description"="pd charger"}'
)


class TestParsePmsetCustom(unittest.TestCase):
    def test_splits_two_branches(self):
        self.assertEqual(set(parse_pmset_custom(CUSTOM_SAMPLE)),
                         {"battery", "ac"})

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
        self.assertEqual(parse_pmset_system(SYSTEM_SAMPLE)["sleep"], 1)

    def test_reads_displaysleep(self):
        self.assertEqual(parse_pmset_system(SYSTEM_SAMPLE)["displaysleep"], 10)

    def test_survives_garbage_input(self):
        self.assertEqual(parse_pmset_system(""), {})


class TestProfiles(unittest.TestCase):
    def test_all_four_profiles_exist(self):
        self.assertEqual(sorted(list_profiles()),
                         ["awake", "background", "charging", "default"])

    def test_background_disables_sleep(self):
        self.assertEqual(load_profile("background")["global"]["disablesleep"], 1)

    def test_charging_reenables_sleep(self):
        """防回归：从 background 切回 charging 必须关掉全局 disablesleep。"""
        self.assertEqual(load_profile("charging")["global"]["disablesleep"], 0)

    def test_default_reenables_sleep(self):
        self.assertEqual(load_profile("default")["global"]["disablesleep"], 0)

    def test_default_matches_apple_factory_values(self):
        p = load_profile("default")
        self.assertEqual(p["battery"]["displaysleep"], 2)
        self.assertEqual(p["battery"]["sleep"], 1)
        self.assertEqual(p["ac"]["displaysleep"], 10)
        self.assertEqual(p["ac"]["sleep"], 1)

    def test_load_profile_rejects_unknown_name(self):
        with self.assertRaises(KeyError):
            load_profile("nope")

    def test_awake_requires_external_display_and_permission(self):
        reqs = load_profile("awake")["requires"]
        self.assertIn("external_display", reqs)
        self.assertIn("screen_recording", reqs)


class TestBuildCommands(unittest.TestCase):
    def test_uses_b_flag_for_battery_branch(self):
        cmds = build_commands(load_profile("default"))
        self.assertIn(["pmset", "-b", "displaysleep", "2"], cmds)

    def test_uses_c_flag_for_ac_branch(self):
        cmds = build_commands(load_profile("default"))
        self.assertIn(["pmset", "-c", "displaysleep", "10"], cmds)

    def test_uses_a_flag_for_global(self):
        cmds = build_commands(load_profile("background"))
        self.assertIn(["pmset", "-a", "disablesleep", "1"], cmds)

    def test_commands_are_lists_of_strings(self):
        for c in build_commands(load_profile("charging")):
            self.assertIsInstance(c, list)
            self.assertTrue(all(isinstance(x, str) for x in c))


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


class TestSnapshotFilename(unittest.TestCase):
    def test_contains_reason_and_extension(self):
        name = snapshot_filename("2026-09-13T18:30:00+08:00", "before-charging")
        self.assertIn("before-charging", name)
        self.assertTrue(name.endswith(".json"))

    def test_colons_replaced_for_filesystem_safety(self):
        name = snapshot_filename("2026-09-13T18:30:00+08:00", "before-charging")
        self.assertNotIn(":", name)

    def test_lexicographic_order_matches_time_order(self):
        a = snapshot_filename("2026-09-13T18:30:00+08:00", "before-charging")
        b = snapshot_filename("2026-09-13T19:30:00+08:00", "before-default")
        self.assertLess(a, b)


class TestParseBatteryLine(unittest.TestCase):
    def test_parses_charging(self):
        state, soc = parse_battery_line(
            " -InternalBattery-0 (id=7209059)\t42%; charging; 1:30 remaining present: true")
        self.assertEqual(state, "charging")
        self.assertEqual(soc, 42)

    def test_parses_ac_attached_not_charging(self):
        state, soc = parse_battery_line(
            " -InternalBattery-0 (id=7209059)\t37%; AC attached; not charging present: true")
        self.assertEqual(state, "AC attached")
        self.assertEqual(soc, 37)

    def test_parses_discharging(self):
        state, _ = parse_battery_line(
            " -InternalBattery-0 (id=1)\t88%; discharging; 4:12 remaining present: true")
        self.assertEqual(state, "discharging")

    def test_returns_none_on_garbage(self):
        self.assertEqual(parse_battery_line("no battery here"), (None, None))


if __name__ == "__main__":
    unittest.main()
