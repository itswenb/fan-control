import AppKit
import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @EnvironmentObject private var updater: AppUpdater
    @State private var showControlSetup = false
    var body: some View {
        @Bindable var store = store
        Form {
            Section(store.text("通用", "General")) {
                Toggle(store.text("登录时启动", "Launch at login"), isOn: Binding(get: { store.loginEnabled || store.loginNeedsApproval }, set: { store.setLoginEnabled($0) }))
                if store.loginNeedsApproval {
                    Button(store.text("在系统设置中批准登录项", "Approve in System Settings")) { SMAppService.openSystemSettingsLoginItems() }
                }
                Picker(store.text("语言", "Language"), selection: $store.settings.language) {
                    Text(store.text("跟随系统", "System default")).tag(AppLanguage.system)
                    Text("简体中文").tag(AppLanguage.chinese)
                    Text("English").tag(AppLanguage.english)
                }
            }
            Section(store.text("温度显示", "Temperature")) {
                Picker(store.text("温度单位", "Unit"), selection: $store.settings.unit) {
                    Text("Celsius (°C)").tag(TemperatureUnit.celsius)
                    Text("Fahrenheit (°F)").tag(TemperatureUnit.fahrenheit)
                }
                Toggle(store.text("显示一位小数", "Show one decimal place"), isOn: $store.settings.precise)
            }
            Section(store.text("风扇控制服务", "Fan control service")) {
                Text(store.helperMessage).font(.callout).foregroundStyle(.secondary)
                if store.helperRegistered {
                    if store.helperConnectionFailed {
                        Button(store.text("更新并重新连接服务…", "Update and reconnect service…")) { store.registerHelper() }
                            .disabled(!store.canRegisterHelper || store.helperInstalling)
                    }
                    Button(store.text("恢复自动并停用服务", "Restore automatic and disable service")) { store.removeHelper() }
                        .disabled(store.controlPending || store.helperInstalling)
                } else {
                    Button(store.text("启用控制服务…", "Enable control service…")) { showControlSetup = true }
                }
                Text(store.text("首次启用时由 macOS 请求管理员授权。", "macOS requests administrator approval the first time you enable control."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(store.text("菜单栏", "Menu bar")) {
                Toggle(store.text("显示图标", "Show icon"), isOn: $store.settings.showMenuIcon)
                    .disabled(store.settings.menuDisplay == .none)
                Picker(store.text("显示内容", "Display content"), selection: Binding(
                    get: { store.settings.menuDisplay },
                    set: { value in
                        store.settings.menuDisplay = value
                        if value == .none { store.settings.showMenuIcon = true }
                    }
                )) {
                    Text(store.text("不显示", "None")).tag(MenuDisplay.none)
                    Text(store.text("温度", "Temperature")).tag(MenuDisplay.temperature)
                    Text(store.text("风扇转速", "Fan speed")).tag(MenuDisplay.fan)
                    Text(store.text("温度与转速", "Temperature and speed")).tag(MenuDisplay.both)
                }
                Picker(store.text("温度来源", "Temperature source"), selection: $store.settings.sensorID) {
                    Text(store.text("首个可用传感器", "First available sensor")).tag("")
                    if !store.settings.sensorID.isEmpty, !store.sensorCatalog.contains(where: { $0.id == store.settings.sensorID }) {
                        Text(store.settings.sensorID + store.text("（不可用）", " (unavailable)")).tag(store.settings.sensorID)
                    }
                    ForEach(store.sensorCatalog) { Text(store.sensorName($0)).tag($0.id) }
                }
                Picker(store.text("风扇", "Fan"), selection: $store.settings.fanID) {
                    Text(store.text("第一只风扇", "First fan")).tag("")
                    if !store.settings.fanID.isEmpty, !store.fanCatalog.contains(where: { $0.id == store.settings.fanID }) {
                        Text(store.settings.fanID + store.text("（不可用）", " (unavailable)")).tag(store.settings.fanID)
                    }
                    ForEach(store.fanCatalog) { Text(store.fanName($0)).tag($0.id) }
                }
            }
            Section {
                LabeledContent(store.text("版本", "Version"), value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                Toggle(store.text("自动检查更新", "Automatically check for updates"), isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates }, set: { updater.automaticallyChecksForUpdates = $0 }
                ))
                Button(store.text("检查更新…", "Check for Updates…")) { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
                Text(store.text("关闭窗口后继续在菜单栏运行。重新启动或唤醒后，硬件数据通过校验时恢复上次策略。", "Closing the window keeps the app in the menu bar. The last policy resumes after launch or wake when hardware readings pass validation."))
                    .font(.caption).foregroundStyle(.secondary)
                Button(store.text("恢复显示默认值", "Reset display preferences")) {
                    let language = store.settings.language
                    store.settings = AppSettings()
                    store.settings.language = language
                }
            }
        }.formStyle(.grouped).scrollContentBackground(.hidden)
            .frame(width: 510, height: 660)
            .background(WindowBackdrop().ignoresSafeArea())
            .background(SettingsWindowSpaceBehavior())
            .sheet(isPresented: $showControlSetup) { ControlSetupView() }
            .onAppear { store.refreshLoginStatus(); store.refreshHelperRegistration() }
            .alert(store.text("操作未完成", "Unable to complete"), isPresented: Binding(get: { store.alertMessage != nil }, set: { if !$0 { store.alertMessage = nil } })) {
                Button("OK") { store.alertMessage = nil }
            } message: { Text(store.alertMessage ?? "") }
    }
}

struct MenuBarView: View {
    @Environment(AppStore.self) private var store
    @EnvironmentObject private var updater: AppUpdater
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Fan Control", systemImage: "fan.fill").font(.headline)
                Spacer()
                Text(store.deviceName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if store.menuPresented {
                MenuBarReadings()
            }
            if store.connectionError != nil { Label(store.text("硬件连接异常", "Hardware connection issue"), systemImage: "exclamationmark.circle").foregroundStyle(.orange) }
            Divider()
            Menu(store.activePresetName) {
                Button(store.text("系统自动", "System automatic")) {
                    if !store.canControl { showMainWindow() }
                    store.restoreAutomatic()
                }
                Button(store.text("全速散热", "Full speed")) {
                    guard store.canControl else {
                        showMainWindow()
                        store.showControlSetup = true
                        return
                    }
                    Task {
                        do { try await store.applyFullSpeed() }
                        catch {
                            store.alertMessage = error.localizedDescription
                            showMainWindow()
                        }
                    }
                }
                ForEach(store.currentPresets) { preset in
                    Button(preset.name) {
                        if !store.canControl { showMainWindow() }
                        store.applyPreset(preset)
                    }
                }
            }.disabled(store.controlPending)
            Button(store.text("全部恢复系统自动", "Restore all to automatic")) { store.restoreAutomatic() }
                .disabled((!store.hasCustomControl && !store.recoveryUnconfirmed) || store.controlPending)
            Button(store.text("检查更新…", "Check for Updates…")) { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
            Divider()
            HStack {
                Button(store.text("打开主窗口", "Open window")) { showMainWindow() }
                Spacer()
                Button {
                    AppWindowVisibility.prepareToOpen()
                    openSettings()
                    DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
                } label: {
                    Image(systemName: "gearshape")
                }.accessibilityLabel(store.text("设置", "Settings"))
                Button(store.text("退出", "Quit")) {
                    DispatchQueue.main.async {
                        NSApp.activate(ignoringOtherApps: true)
                        NSApp.terminate(nil)
                    }
                }
            }
        }.padding(18).frame(width: 320).task { store.start() }
            #if DEBUG
            .background(UIInspection(isMenu: true))
            #endif
            .onAppear { store.setMenuPresented(true) }
            .onDisappear { store.setMenuPresented(false) }
    }

    private func showMainWindow() {
        AppWindowVisibility.prepareToOpen()
        openWindow(id: "main")
        DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
    }
}

/// 实时读数仅在弹窗打开时观察，不让采样重建菜单操作和隐藏的视图。
private struct MenuBarReadings: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let sensor = store.selectedSensor {
                HStack {
                    Text(store.sensorName(sensor)).foregroundStyle(.secondary)
                    Spacer()
                    Text(store.formattedTemperature(sensor.celsius, fresh: sensor.isFresh(at: store.now))).monospacedDigit()
                }
            }
            ForEach(store.snapshot?.fans ?? []) { fan in
                let current = store.formattedRPM(fan.rpm, fresh: fan.isFresh(at: store.now))
                let maximum = store.formattedRPM(fan.maximum)
                HStack {
                    Text(store.fanName(fan)).foregroundStyle(.secondary)
                    Spacer()
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text(current).font(.body.weight(.medium)).foregroundStyle(.primary)
                        Text("/" + maximum + " RPM").font(.caption).foregroundStyle(.secondary)
                    }
                    .monospacedDigit().fixedSize()
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(store.text("当前转速 \(current) RPM，最大转速 \(maximum) RPM", "Current speed \(current) RPM, maximum speed \(maximum) RPM"))
                }
            }
            if store.snapshot == nil { Text(store.text("暂无硬件读数", "No hardware readings")).foregroundStyle(.secondary) }
            if !store.settings.sensorID.isEmpty && store.selectedSensor == nil {
                Label(store.text("所选温度传感器不可用", "Selected temperature sensor unavailable"), systemImage: "exclamationmark.circle").foregroundStyle(.orange)
            } else if let sensor = store.selectedSensor, !sensor.isFresh(at: store.now) {
                Label(store.text("温度读数已失效", "Temperature reading unavailable or stale"), systemImage: "clock.badge.exclamationmark").foregroundStyle(.orange)
            }
        }
    }
}

private struct SettingsWindowSpaceBehavior: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { SpaceAwareView() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class SpaceAwareView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.collectionBehavior.insert(.moveToActiveSpace)
        }
    }
}

struct ControlSetupView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(store.helperConnectionFailed ? store.text("修复风扇控制服务", "Repair fan control service") : store.text("启用风扇控制", "Enable fan control"), systemImage: "fan.fill").font(.title2.weight(.semibold))
            Text(store.helperConnectionFailed ? store.text("更新服务会检查旧安装及风扇恢复状态，然后请求管理员授权。", "Updating checks the existing installation and fan recovery status, then requests administrator approval.") : store.text("安装本机控制服务后，可以使用固定转速、温度调速和预设。macOS 会请求管理员授权。", "Install the local control service to use fixed speed, temperature control and presets. macOS will request administrator approval."))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            LabeledContent(store.text("设备", "Device"), value: store.deviceName)
            if !store.hasCustomControl, store.snapshot?.fans.contains(where: { $0.mode == .fixed }) == true {
                Label(store.text("当前风扇由其他工具控制。请先在该工具中恢复自动并退出，避免争抢控制。", "Another utility controls the fans. Restore automatic mode there and quit it before applying a policy."), systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text(store.helperMessage).font(.callout).textSelection(.enabled)
            Divider()
            HStack {
                if store.helperInstalling { ProgressView().controlSize(.small) }
                Spacer()
                Button(store.text("关闭", "Close")) { dismiss() }.keyboardShortcut(.cancelAction)
                if !store.helperRegistered || !store.helperAvailable {
                    Button(store.helperRegistered ? store.text("更新并重新连接…", "Update and reconnect…") : store.text("安装并启用…", "Install and enable…")) { store.registerHelper() }
                        .buttonStyle(.borderedProminent).disabled(!store.canRegisterHelper || store.helperInstalling)
                }
            }
        }.padding(24).frame(width: 460)
            .background(WindowBackdrop().ignoresSafeArea())
            .onAppear { store.refreshHelperRegistration() }
    }
}
