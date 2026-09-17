import SwiftUI

/// 应用状态与动作。
@MainActor
final class AppModel: ObservableObject {
    @Published var status: StatusPayload?
    @Published var errorText: String?
    @Published var message: String?
    @Published var isBusy = false

    private let control = BatteryControl()

    var pythonAvailable: Bool { Resources.pythonPath() != nil }

    func refresh() {
        guard pythonAvailable else {
            errorText = "找不到 Python 3 解释器，无法读取状态。"
            return
        }
        do {
            status = try control.fetchStatus()
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// 在后台线程执行提权动作，避免阻塞主线程。
    ///
    /// 提权会弹出系统密码框，属于阻塞调用，必须离开主线程；
    /// 结果回到 MainActor 更新。
    private func performAdmin(_ action: String, success: String) {
        guard !isBusy else { return }
        isBusy = true
        message = "正在执行 \(action)…"
        let control = self.control

        Task.detached {
            let outcome = Result { try control.runAsAdmin(action: action) }
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                switch outcome {
                case .success(let r):
                    self.message = r.ok ? success : "未完成：\(r.message)"
                case .failure(let err):
                    self.message = "失败：\(err.localizedDescription)"
                }
                self.isBusy = false
                self.refresh()
            }
        }
    }

    func apply(_ profile: Profile) {
        performAdmin("apply \(profile.name)", success: "模式「\(profile.name)」已应用")
    }

    func restore() {
        performAdmin("restore", success: "已回滚到最近快照")
    }

    /// 返回某模式缺失的前置条件描述；为空表示可以应用。
    func missingRequirements(_ profile: Profile) -> [String] {
        guard let status = status else { return [] }
        var missing: [String] = []
        for req in profile.requires {
            if req == "external_display" && status.external_displays == 0 {
                missing.append("需要外接显示器或 HDMI 欺骗器")
            }
            if req == "screen_recording" && !status.screen_recording {
                missing.append("需要「屏幕录制」权限")
            }
        }
        return missing
    }
}

struct StatusCard: View {
    let status: StatusPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("当前电源").foregroundStyle(.secondary)
                Text(status.powerSourceText).bold()
                if let soc = status.soc_percent {
                    Text("· \(soc)%").bold()
                }
                Text(status.batteryStateText).foregroundStyle(.secondary)
                Spacer()
            }

            HStack {
                Text("休眠开关").foregroundStyle(.secondary)
                if status.sleepDisabled {
                    Label("已禁用（合盖不会睡）", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else {
                    Text("未禁用（合盖会睡）")
                }
                Spacer()
            }

            HStack {
                Text("接电").foregroundStyle(.secondary)
                Text(status.ac.text())
                Spacer()
            }
            HStack {
                Text("电池").foregroundStyle(.secondary)
                Text(status.battery.text())
                Spacer()
            }

            if let ad = status.adapter {
                HStack {
                    Text("适配器").foregroundStyle(.secondary)
                    Text(ad.summary)
                    Spacer()
                }
                HStack(spacing: 6) {
                    ForEach(Array(ad.menu.enumerated()), id: \.offset) { _, item in
                        Text("\(item.voltageText)/\(item.wattsText)")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(item.voltage >= 20000
                                        ? Color.green.opacity(0.2)
                                        : Color.secondary.opacity(0.12))
                            .clipShape(Capsule())
                    }
                    Spacer()
                }
                HStack {
                    Image(systemName: ad.has_20v ? "checkmark.seal.fill" : "xmark.seal.fill")
                        .foregroundStyle(ad.has_20v ? .green : .red)
                    Text(ad.has_20v
                         ? "存在 20V 档，该口具备 45W 以上供电能力"
                         : "无 20V 档，该口无法达到 45W 以上，高负载会显示「没有在充电」")
                        .font(.callout)
                    Spacer()
                }
            }

            HStack(spacing: 12) {
                Label(status.external_displays > 0 ? "有外接屏" : "无外接屏",
                      systemImage: status.external_displays > 0 ? "display" : "display.slash")
                    .foregroundStyle(status.external_displays > 0 ? .primary : .secondary)
                Label(status.screen_recording ? "已授权屏幕录制" : "未授权屏幕录制",
                      systemImage: status.screen_recording ? "checkmark.circle" : "circle.slash")
                    .foregroundStyle(status.screen_recording ? .primary : .secondary)
                Spacer()
            }
            .font(.callout)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct ProfileRow: View {
    let name: String
    let profile: Profile
    let isActive: Bool
    let missing: [String]
    let busy: Bool
    let onApply: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name).font(.system(.body, design: .monospaced)).bold()
                    Text(ProfileMeta.title(name)).foregroundStyle(.secondary)
                    if isActive {
                        Text("当前")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.2))
                            .clipShape(Capsule())
                    }
                }
                Text(profile.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !missing.isEmpty {
                    Text("不可用：" + missing.joined(separator: "、"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if let warn = profile.warn {
                    Text(warn)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            Button("应用", action: onApply)
                .disabled(busy || !missing.isEmpty || isActive)
        }
        .padding(10)
        .background(isActive ? Color.accentColor.opacity(0.08) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct ContentView: View {
    @StateObject private var model = AppModel()
    private let timer = Timer.publish(every: 8, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("BatteryCtl").font(.title2).bold()
                Spacer()
                if model.isBusy { ProgressView().controlSize(.small) }
                Button {
                    model.refresh()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(model.isBusy)
            }

            if let err = model.errorText {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(err).font(.callout).textSelection(.enabled)
                    Spacer()
                }
                .padding(10)
                .background(Color.red.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if let status = model.status {
                StatusCard(status: status)

                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        let active = status.currentProfileName()
                        ForEach(status.profiles, id: \.self) { name in
                            if let p = ProfileCatalog.shared.profiles[name] {
                                ProfileRow(
                                    name: name,
                                    profile: p,
                                    isActive: (active == name),
                                    missing: model.missingRequirements(p),
                                    busy: model.isBusy,
                                    onApply: { model.apply(p) }
                                )
                                Divider()
                            }
                        }
                    }
                }
                .frame(maxHeight: 300)
            } else {
                Spacer()
                HStack {
                    Spacer()
                    ProgressView("正在读取状态…")
                    Spacer()
                }
                Spacer()
            }

            HStack {
                Text(model.message ?? "就绪")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Button("回滚最近快照") { model.restore() }
                    .disabled(model.isBusy || model.status == nil)
            }
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 560)
        .onAppear { model.refresh() }
        .onReceive(timer) { _ in
            if !model.isBusy { model.refresh() }
        }
    }
}
