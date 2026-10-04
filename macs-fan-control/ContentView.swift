import SwiftUI

struct ContentView: View {
    @Environment(AppStore.self) private var store
    @State private var editingFan: FanReading?

    // 同一视图同一时刻只能呈现一个 sheet。把原先分散的多个 .sheet 布尔状态
    // 收敛成一个枚举,按优先级选出唯一要呈现的 sheet,从结构上杜绝“同时呈现两个”。
    private enum ActiveSheet: Identifiable {
        case editFan(FanReading)
        case savePreset
        case fullSpeed
        case presets
        case diagnostics
        case controlSetup
        var id: String {
            switch self {
            case .editFan(let fan): return "editFan-\(fan.id)"
            case .savePreset: return "savePreset"
            case .fullSpeed: return "fullSpeed"
            case .presets: return "presets"
            case .diagnostics: return "diagnostics"
            case .controlSetup: return "controlSetup"
            }
        }
    }

    // 优先级对应原有守卫:editFan 最高;presets 会抑制 fullSpeed/savePreset/controlSetup;
    // controlSetup 仅在既未编辑风扇也未打开预设时作为兜底呈现。
    private var activeSheet: Binding<ActiveSheet?> {
        Binding(
            get: {
                if let fan = editingFan { return .editFan(fan) }
                if store.showPresets { return .presets }
                if store.showDiagnostics { return .diagnostics }
                if store.showFullSpeed { return .fullSpeed }
                if store.showSavePreset { return .savePreset }
                if store.showControlSetup { return .controlSetup }
                return nil
            },
            set: { newValue in
                guard newValue == nil else { return }
                // 关闭当前 sheet 时,只清除当前生效的那个标志(与 get 优先级一致)。
                if editingFan != nil { editingFan = nil }
                else if store.showPresets { store.showPresets = false }
                else if store.showDiagnostics { store.showDiagnostics = false }
                else if store.showFullSpeed { store.showFullSpeed = false }
                else if store.showSavePreset { store.showSavePreset = false }
                else if store.showControlSetup { store.showControlSetup = false }
            }
        )
    }

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 40, height: 40)
                    .glassControl(radius: 11)
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.deviceName).font(.headline)
                    Text(store.snapshot?.chip ?? "Fan Control").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 6) {
                    Text(store.text("当前预设", "Preset")).foregroundStyle(.secondary)
                    PresetMenu()
                }
                Menu {
                    Button(store.text("保存当前配置…", "Save current configuration…")) { store.showSavePreset = true }
                        .disabled(store.snapshot?.fans.isEmpty != false)
                    Button(store.text("管理预设…", "Manage presets…")) { store.showPresets = true }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 32, height: 32)
                }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .frame(width: 32, height: 32)
                    .glassControl(radius: 10)
                    .accessibilityLabel(store.text("预设操作", "Preset actions"))
            }.padding(.horizontal, 18).frame(height: 72)
            GeometryReader { geometry in
                HStack(spacing: 12) {
                    fanTable
                        .frame(width: max(480, geometry.size.width * 0.58))
                        .dataPanel()
                    SensorsView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .dataPanel()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
            HStack(spacing: 10) {
                Circle().fill(store.connectionError == nil ? Color.accentColor : .orange).frame(width: 6, height: 6)
                Text(statusText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if store.controlPending { ProgressView().controlSize(.small) }
                Button(store.text("恢复自动", "Restore automatic")) { store.restoreAutomatic() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.primary)
                    .padding(.horizontal, 14).frame(height: 30)
                    .glassControl(radius: 9)
                    .disabled(store.controlPending || store.snapshot?.fans.isEmpty != false)
                Button { store.showDiagnostics = true } label: {
                    Image(systemName: "info.circle").frame(width: 32, height: 30).glassControl(radius: 9)
                }.buttonStyle(.plain).help(store.text("连接诊断", "Connection diagnostics"))
                    .accessibilityLabel(store.text("连接诊断", "Connection diagnostics"))
                SettingsLink {
                    Image(systemName: "gearshape").frame(width: 32, height: 30).glassControl(radius: 9)
                }.buttonStyle(.plain).help(store.text("设置", "Settings"))
                    .accessibilityLabel(store.text("设置", "Settings"))
            }.padding(.horizontal, 18).frame(height: 50)
        }
        .background(WindowBackdrop().ignoresSafeArea())
        .frame(minWidth: 860, minHeight: 480)
        .sheet(item: activeSheet) { sheet in
            switch sheet {
            case .editFan(let fan): FanEditorView(fan: fan)
            case .savePreset: PresetNameSheet()
            case .fullSpeed: FullSpeedSheet()
            case .presets: PresetsView()
            case .diagnostics: DiagnosticsView().frame(width: 720, height: 520)
            case .controlSetup: ControlSetupView()
            }
        }
        .alert(store.text("操作未完成", "Unable to complete"), isPresented: Binding(get: { store.alertMessage != nil }, set: { if !$0 { store.alertMessage = nil } })) {
            Button(store.text("知道了", "OK")) { store.alertMessage = nil }
        } message: { Text(store.alertMessage ?? "") }
        .task { store.start() }
    }

    private var fanTable: some View {
        VStack(spacing: 0) {
            HStack {
                Text(store.text("风扇", "Fan")).frame(maxWidth: .infinity, alignment: .leading)
                Text(store.text("最低 / 当前 / 最高", "Min / Current / Max")).frame(width: 180)
                Text(store.text("控制策略", "Control")).frame(width: 150)
            }.font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(.horizontal, 16).frame(height: 38)
            Divider()
            if store.isLoading && store.snapshot == nil {
                ProgressView(store.text("读取风扇…", "Reading fans…")).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.snapshot?.fans.isEmpty != false {
                ContentUnavailableView(store.text("暂无风扇读数", "No fan readings"), systemImage: "fan.slash",
                                       description: Text(store.connectionError ?? store.text("这台设备没有可读取的风扇。", "No readable fans were found on this device.")))
            } else {
                ForEach(Array((store.snapshot?.fans ?? []).enumerated()), id: \.element.id) { index, fan in
                    HStack(spacing: 8) {
                        Image(systemName: "fan.fill").font(.title2).foregroundStyle(Color.accentColor).frame(width: 24)
                        Text(store.fanName(fan)).font(.callout.weight(.medium)).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading).help(fan.id)
                        HStack(spacing: 5) {
                            Text(store.formattedRPM(fan.minimum)).foregroundStyle(.secondary)
                            Text("/").foregroundStyle(.tertiary)
                            Text(store.formattedRPM(fan.rpm, fresh: fan.isFresh(at: store.now))).fontWeight(.semibold)
                            Text("/").foregroundStyle(.tertiary)
                            Text(store.formattedRPM(fan.maximum)).foregroundStyle(.secondary)
                        }.font(.system(size: 12)).monospacedDigit().frame(width: 180)
                        Button { editingFan = fan } label: {
                            HStack(spacing: 6) {
                                Text(controlLabel(fan)).lineLimit(1)
                                Spacer(minLength: 0)
                                Image(systemName: "slider.horizontal.3").font(.caption)
                            }.foregroundStyle(Color.primary)
                                .padding(.horizontal, 10).frame(width: 130, height: 30)
                                .glassControl(radius: 9)
                        }.buttonStyle(.plain).frame(width: 150)
                            .disabled(!fan.controlSupported)
                            .help(fan.controlSupported ? store.text("调节风扇", "Adjust fan speed") : store.text("未检测到可用的调速接口或有效转速范围", "No compatible control interface or valid speed range"))
                            .accessibilityLabel(store.text("设置", "Configure ") + store.fanName(fan))
                    }.padding(.horizontal, 16).frame(height: 64)
                        .background(index.isMultiple(of: 2) ? Color.primary.opacity(0.025) : .clear)
                    Divider()
                }
                Spacer(minLength: 16)
                VStack(alignment: .leading, spacing: 10) {
                    if !store.helperAvailable {
                        Text(store.helperMessage).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button(store.helperConnectionFailed ? store.text("修复控制服务…", "Repair control service…") : store.text("启用风扇控制…", "Enable fan control…")) { store.showControlSetup = true }
                    } else if !store.hasCustomControl && store.snapshot?.fans.contains(where: { $0.mode == .fixed }) == true {
                        Label(store.text("其他工具正在调速，请先在该工具中恢复自动并退出。", "Another utility is controlling the fans. Restore automatic there and quit it first."), systemImage: "info.circle")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
            }
        }.frame(maxHeight: .infinity)
    }

    private func controlLabel(_ fan: FanReading) -> String {
        if !fan.controlSupported { return store.text("仅监控", "Monitoring only") }
        if let policy = store.displayPolicies.first(where: { $0.fanID == fan.id }), policy.mode == .sensor { return store.modeName(.sensor) }
        if fan.mode == .fixed { return store.formattedRPM(fan.target) + " RPM" }
        if fan.mode == .automatic { return store.text("系统自动", "Automatic") }
        return store.modeName(fan.mode)
    }

    private var statusText: String {
        if store.recoveryUnconfirmed { return store.text("恢复系统自动尚未确认", "Automatic mode not yet confirmed") }
        if store.connectionError != nil { return store.text("硬件连接异常", "Hardware connection issue") }
        if store.snapshot == nil { return store.text("正在读取本机硬件", "Reading this Mac") }
        return store.text("实时数据 · 每 2 秒刷新", "Live readings · Refreshing every 2 seconds")
    }
}

struct PresetMenu: View {
    @Environment(AppStore.self) private var store
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            HStack(spacing: 8) {
                Text(store.activePresetName).lineLimit(1)
                    .frame(maxWidth: 210, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .glassControl(radius: 10)
        }
        .buttonStyle(.plain)
        .disabled(store.controlPending)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 3) {
                choice(store.text("系统自动", "System automatic")) { store.restoreAutomatic() }
                choice(store.text("全速散热", "Full speed")) {
                    if store.canControl { store.showFullSpeed = true } else { store.showControlSetup = true }
                }
                if !store.currentPresets.isEmpty { Divider().padding(.vertical, 3) }
                ForEach(store.currentPresets) { preset in
                    choice(preset.name) { store.applyPreset(preset) }
                }
            }
            .padding(8)
            .frame(minWidth: 180)
        }
    }

    private func choice(_ title: String, action: @escaping () -> Void) -> some View {
        Button {
            isPresented = false
            action()
        } label: {
            Text(title).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct SensorsView: View {
    @Environment(AppStore.self) private var store
    @State private var search = ""
    @State private var byTemperature = false
    @State private var showUnidentified = false
    private var sensors: [SensorReading] {
        let values = (store.snapshot?.sensors ?? []).filter {
            let known = SensorCatalog.averageRank(key: $0.id) != nil || $0.name != $0.id
            return (showUnidentified || known || !search.isEmpty) && (search.isEmpty || store.sensorName($0).localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search))
        }
        if byTemperature {
            return values.sorted {
                if let first = SensorCatalog.averageRank(key: $0.id) {
                    return first < (SensorCatalog.averageRank(key: $1.id) ?? Int.max)
                }
                if SensorCatalog.averageRank(key: $1.id) != nil { return false }
                return ($0.celsius ?? -.infinity) > ($1.celsius ?? -.infinity)
            }
        }
        return values.sorted {
            if let first = SensorCatalog.averageRank(key: $0.id) {
                return first < (SensorCatalog.averageRank(key: $1.id) ?? Int.max)
            }
            if SensorCatalog.averageRank(key: $1.id) != nil { return false }
            let firstGroup = SensorGroup.allCases.firstIndex(of: $0.group) ?? 0
            let secondGroup = SensorGroup.allCases.firstIndex(of: $1.group) ?? 0
            return firstGroup == secondGroup ? store.sensorName($0).localizedStandardCompare(store.sensorName($1)) == .orderedAscending : firstGroup < secondGroup
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(store.text("温度传感器", "Temperature sensors"))
                Spacer()
                Text(store.settings.unit.symbol)
                Menu {
                    Toggle(store.text("按温度排序", "Sort by temperature"), isOn: $byTemperature)
                    Toggle(store.text("显示未识别测点", "Show unidentified sensors"), isOn: $showUnidentified)
                } label: { Image(systemName: "line.3.horizontal.decrease") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 22)
                    .accessibilityLabel(store.text("传感器显示选项", "Sensor display options"))
            }.font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(.horizontal, 14).frame(height: 38)
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(store.text("搜索传感器", "Search sensors"), text: $search).textFieldStyle(.plain)
            }.padding(8).glassControl(radius: 9).padding(10)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(sensors.enumerated()), id: \.element.id) { index, sensor in
                        HStack(spacing: 8) {
                            Text(store.sensorName(sensor)).lineLimit(1).help(store.sensorName(sensor) + " · " + sensor.id)
                            Spacer(minLength: 4)
                            Text(store.formattedTemperature(sensor.celsius, fresh: sensor.isFresh(at: store.now)))
                                .monospacedDigit().frame(width: 62, alignment: .trailing)
                            Button { store.settings.sensorID = sensor.id } label: {
                                Image(systemName: store.settings.sensorID == sensor.id ? "pin.fill" : "pin")
                                    .foregroundStyle(store.settings.sensorID == sensor.id ? Color.accentColor : .secondary)
                            }.buttonStyle(.plain).frame(width: 16).help(store.text("在菜单栏显示", "Show in menu bar"))
                        }.font(.callout).padding(.horizontal, 14).frame(height: 32)
                            .background(index.isMultiple(of: 2) ? Color.primary.opacity(0.025) : .clear)
                    }
                    if sensors.isEmpty {
                        Text(store.text("暂无匹配的传感器", "No matching sensors")).foregroundStyle(.secondary).padding(20)
                    }
                }
            }
        }
    }
}
