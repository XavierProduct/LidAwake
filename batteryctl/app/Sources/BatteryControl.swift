import Foundation

/// 一个模式的中文显示名。
enum ProfileMeta {
    static let titles: [String: String] = [
        "default": "该睡就睡",
        "charging": "车上充电最快",
        "background": "合盖跑脚本",
        "awake": "合盖截图 E2E",
    ]

    static func title(_ name: String) -> String {
        titles[name] ?? name
    }
}

/// 一次性读取 profiles/ 目录，供反推当前模式使用。
final class ProfileCatalog {
    static let shared = ProfileCatalog()

    private(set) var profiles: [String: Profile] = [:]

    private init() {
        guard let dir = Resources.profilesDir else { return }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return }
        let decoder = JSONDecoder()
        for file in files where file.hasSuffix(".json") {
            guard let data = fm.contents(atPath: (dir as NSString).appendingPathComponent(file)),
                  let p = try? decoder.decode(Profile.self, from: data) else { continue }
            profiles[p.name] = p
        }
    }
}

/// bundle 内资源定位。
enum Resources {
    static var bundle: Bundle { Bundle.main }

    static var scriptPath: String? {
        bundle.path(forResource: "batteryctl", ofType: "py")
    }

    static var profilesDir: String? {
        bundle.resourceURL?.appendingPathComponent("profiles").path
    }

    /// 找一个可用的 Python 3 解释器。
    /// Homebrew 的 3.14 已实测可跑；找不到时回退系统自带 3.9。
    static func pythonPath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }
}

/// 子进程输出。
struct RunResult {
    var status: Int32
    var out: String
    var err: String

    var combined: String {
        let e = err.trimmingCharacters(in: .whitespacesAndNewlines)
        return e.isEmpty ? out : e
    }
}

/// pmset 的封装：只读查询走普通权限，修改走 osascript 提权。
final class BatteryControl {

    /// 同步跑一个子进程。
    private func run(_ executable: String, _ args: [String]) -> RunResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        do {
            try p.run()
        } catch {
            return RunResult(status: -1, out: "", err: "无法启动 \(executable): \(error.localizedDescription)")
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()

        return RunResult(
            status: p.terminationStatus,
            out: String(data: outData, encoding: .utf8) ?? "",
            err: String(data: errData, encoding: .utf8) ?? ""
        )
    }

    /// 读取结构化状态。
    func fetchStatus() throws -> StatusPayload {
        guard let script = Resources.scriptPath else {
            throw BatteryCtlError.missingScript
        }
        guard let python = Resources.pythonPath() else {
            throw BatteryCtlError.missingPython
        }

        let result = run(python, [script, "status", "--json"])
        guard result.status == 0 else {
            throw BatteryCtlError.commandFailed(result.combined)
        }
        guard let data = result.out.data(using: .utf8) else {
            throw BatteryCtlError.badOutput("输出不是合法 UTF-8")
        }
        do {
            return try JSONDecoder().decode(StatusPayload.self, from: data)
        } catch {
            throw BatteryCtlError.badOutput("JSON 解析失败: \(error)")
        }
    }

    /// 以管理员权限运行脚本。返回 (是否成功, 消息)。
    ///
    /// 思路：把命令写入临时脚本，再用 osascript 提权执行，并把真实退出码
    /// 落盘回读。这样能可靠区分「用户取消」(-128) 与「执行失败」。
    func runAsAdmin(action: String) throws -> (ok: Bool, message: String) {
        guard let script = Resources.scriptPath else {
            throw BatteryCtlError.missingScript
        }
        guard let python = Resources.pythonPath() else {
            throw BatteryCtlError.missingPython
        }

        let token = UUID().uuidString
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryctl-\(token)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let cmdScript = dir.appendingPathComponent("run.sh")
        let outFile = dir.appendingPathComponent("out.txt")
        let rcFile = dir.appendingPathComponent("rc.txt")

        let body = """
        #!/bin/bash
        "\(python)" "\(script)" \(action) > "\(outFile.path)" 2>&1
        echo $? > "\(rcFile.path)"
        """
        try body.write(to: cmdScript, atomically: true, encoding: .utf8)

        let shellCmd = "/bin/bash \(q(cmdScript.path)); exit 0"
        let osa = "do shell script \"\(esc(shellCmd))\" with administrator privileges"
        let result = run("/usr/bin/osascript", ["-e", osa])

        defer { try? FileManager.default.removeItem(at: dir) }

        // osascript 报错：多半是用户取消了密码框
        if result.status != 0 {
            let msg = result.err.trimmingCharacters(in: .whitespacesAndNewlines)
            if msg.contains("-128") || msg.contains("User canceled") || msg.contains("取消") {
                return (false, "已取消")
            }
            return (false, msg.isEmpty ? "提权失败（退出码 \(result.status)）" : msg)
        }

        // 脚本自身的真实退出码
        let rcText = (try? String(contentsOf: rcFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rc = Int32(rcText ?? "0") ?? 0
        let output = (try? String(contentsOf: outFile, encoding: .utf8)) ?? ""

        if rc == 0 {
            return (true, output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if rc == 3 {
            return (false, output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (false, output.isEmpty ? "执行失败（退出码 \(rc)）" : output)
    }

    /// 转义给 AppleScript 字符串用（反斜杠与双引号）。
    private func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// 给 shell 用单引号包裹路径。
    private func q(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum BatteryCtlError: LocalizedError {
    case missingScript
    case missingPython
    case commandFailed(String)
    case badOutput(String)

    var errorDescription: String? {
        switch self {
        case .missingScript:
            return "App 内找不到 batteryctl.py，bundle 可能不完整。"
        case .missingPython:
            return "找不到可用的 Python 3 解释器。请安装 Python 3 后重试。"
        case .commandFailed(let m):
            return m.isEmpty ? "命令执行失败。" : m
        case .badOutput(let m):
            return m
        }
    }
}
