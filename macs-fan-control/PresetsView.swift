import SwiftUI

struct PresetsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var renaming: FanPreset?
    @State private var deleting: FanPreset?

    // 同一视图同一时刻只能呈现一个 sheet。收敛成单枚举,按优先级选唯一 sheet。
    private enum ActiveSheet: Identifiable {
        case savePreset
        case controlSetup
        case fullSpeed
        case rename(FanPreset)
        var id: String {
            switch self {
            case .savePreset: return "savePreset"
            case .controlSetup: return "controlSetup"
            case .fullSpeed: return "fullSpeed"
            case .rename(let preset): return "rename-\(preset.id)"
            }
        }
    }
    private var activeSheet: Binding<ActiveSheet?> {
        Binding(
            get: {
                if let preset = renaming { return .rename(preset) }
                if store.showFullSpeed { return .fullSpeed }
                if store.showSavePreset { return .savePreset }
                if store.showControlSetup { return .controlSetup }
                return nil
            },
            set: { newValue in
                guard newValue == nil else { return }
                if renaming != nil { renaming = nil }
                else if store.showFullSpeed { store.showFullSpeed = false }
                else if store.showSavePreset { store.showSavePreset = false }
                else if store.showControlSetup { store.showControlSetup = false }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(store.text("管理预设", "Manage presets")).font(.title3.weight(.semibold))
                    Text(store.deviceName).foregroundStyle(.secondary)
                }
                Spacer()
                Button { store.showSavePreset = true } label: { Label(store.text("保存当前配置", "Save current"), systemImage: "plus") }
                    .disabled(store.snapshot?.fans.isEmpty != false || store.configurationError != nil)
                Button(store.text("完成", "Done")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            VStack(spacing: 0) {
                builtInRow(icon: "leaf", title: store.text("系统自动", "System automatic"),
                           subtitle: store.text("交还所有风扇，由系统管理散热。", "Let the system manage all fan speeds.")) { store.restoreAutomatic() }
                Divider().padding(.leading, 62)
                builtInRow(icon: "wind", title: store.text("全速散热", "Full speed"),
                           subtitle: store.text("所有可调速风扇使用各自允许的最高转速。", "Run every controllable fan at its maximum supported speed.")) {
                    if store.canControl { store.showFullSpeed = true } else { store.showControlSetup = true }
                }
            }.dataPanel()

            HStack {
                Text(store.text("我的预设", "MY PRESETS")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text("\(store.currentPresets.count)").font(.caption).foregroundStyle(.secondary)
            }
            if let error = store.configurationError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            } else if store.currentPresets.isEmpty {
                ContentUnavailableView {
                    Label(store.text("还没有保存的预设", "No saved presets yet"), systemImage: "slider.horizontal.3")
                } description: {
                    Text(store.text("调整一只风扇，再保存当前配置。下次可以一键切换。", "Configure a fan, then save the current setup to switch back in one click."))
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(store.currentPresets) { preset in
                            HStack(spacing: 14) {
                                Image(systemName: "slider.horizontal.3").font(.title3).foregroundStyle(Color.accentColor).frame(width: 28)
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(preset.name).font(.headline)
                                        if store.activePresetID == preset.id { Text(store.text("使用中", "Active")).font(.caption).foregroundStyle(Color.accentColor) }
                                    }
                                    Text(summary(preset)).font(.callout).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(store.text("应用", "Apply")) { store.applyPreset(preset) }.disabled(store.controlPending)
                                Menu {
                                    Button(store.text("重命名…", "Rename…")) { renaming = preset }
                                    Button(store.text("删除预设…", "Delete preset…"), role: .destructive) { deleting = preset }
                                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                                    .accessibilityLabel(store.text("预设操作", "Preset actions"))
                            }.padding(18)
                            if preset.id != store.currentPresets.last?.id { Divider().padding(.leading, 62) }
                        }
                    }.dataPanel()
                }
            }
        }.padding(28).frame(width: 690, height: 470)
        .background(WindowBackdrop().ignoresSafeArea())
        .sheet(item: activeSheet) { sheet in
            switch sheet {
            case .savePreset: PresetNameSheet()
            case .controlSetup: ControlSetupView()
            case .fullSpeed: FullSpeedSheet()
            case .rename(let preset): PresetNameSheet(preset: preset)
            }
        }
        .confirmationDialog(store.text("删除这个预设？", "Delete this preset?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button(store.text("删除", "Delete"), role: .destructive) { if let deleting { store.deletePreset(deleting) }; deleting = nil }
            Button(store.text("取消", "Cancel"), role: .cancel) { deleting = nil }
        } message: { Text(store.text("删除不会改变正在运行的风扇策略。", "Deleting does not change the running fan policy.")) }
    }

    private func builtInRow(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.title3).foregroundStyle(Color.accentColor).frame(width: 28)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline)
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button(store.text("应用", "Apply"), action: action).disabled(store.controlPending)
        }.padding(18)
    }
    private func summary(_ preset: FanPreset) -> String {
        preset.policies.map { policy in
            let fan = store.snapshot?.fans.first { $0.id == policy.fanID }
            let name = fan.map(store.fanName) ?? policy.fanID
            return name + " · " + (policy.mode == .fixed ? store.formattedRPM(policy.rpm) + " RPM" : store.modeName(policy.mode))
        }.joined(separator: "   /   ")
    }
}

struct FullSpeedSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(store.text("全速散热", "Full speed"), systemImage: "wind").font(.title2.weight(.semibold))
            Text(store.text("将以下风扇设置为各自允许的最高目标转速。", "Set the following fans to their maximum supported target speeds."))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach((store.snapshot?.fans ?? []).filter(\.controlSupported)) { fan in
                LabeledContent(store.fanName(fan), value: store.formattedRPM(fan.validRange?.upperBound) + " RPM").monospacedDigit()
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            Divider()
            HStack {
                if store.controlPending { ProgressView().controlSize(.small) }
                Spacer()
                Button(store.text("取消", "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(store.text("应用", "Apply")) {
                    Task {
                        do { try await store.applyFullSpeed(); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!store.canControl)
            }
        }.padding(24).frame(width: 400)
            .background(WindowBackdrop().ignoresSafeArea())
    }
}

struct DiagnosticsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(store.text("连接与诊断", "Connection & diagnostics")).font(.title3.weight(.semibold))
                    Text(store.text("仅保留本次会话最近 100 条事件。导出前可在下方预览。", "The latest 100 session events stay in memory. Preview the report before exporting."))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { store.retry() } label: { Label(store.text("重新检测", "Check again"), systemImage: "arrow.clockwise") }
                Button { store.exportDiagnostics() } label: { Label(store.text("导出…", "Export…"), systemImage: "square.and.arrow.up") }
                Button(store.text("完成", "Done")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Grid(alignment: .leading, horizontalSpacing: 30, verticalSpacing: 12) {
                GridRow { Text(store.text("设备", "Device")).foregroundStyle(.secondary); Text(store.deviceName) }
                GridRow { Text(store.text("硬件访问", "Hardware access")).foregroundStyle(.secondary); Text("AppleSMC") }
                GridRow { Text(store.text("真实风扇控制", "Hardware fan control")).foregroundStyle(.secondary); Text(store.helperMessage) }
            }.font(.callout).padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .dataPanel()
            ScrollView([.vertical, .horizontal]) {
                Text(store.diagnosticReport).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading).padding(16)
            }.background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }.padding(28)
            .background(WindowBackdrop().ignoresSafeArea())
    }
}
