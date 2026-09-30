import AppKit
import SwiftUI
import Charts

struct FanEditorView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let fan: FanReading
    var initialMode: FanMode?
    @State private var mode: FanMode = .automatic
    @State private var rpm = ""
    @State private var sensorID = ""
    @State private var low = ""
    @State private var high = ""
    @State private var error: String?
    @State private var saveDraft = false
    @State private var editingUnit: TemperatureUnit = .celsius
    private enum EditorSheet: Identifiable {
        case saveDraft, controlSetup
        var id: Self { self }
    }

    private var policy: FanPolicy {
        FanPolicy(fanID: fan.id, mode: mode, rpm: Double(rpm), sensorID: sensorID,
                  low: Double(low).map { editingUnit.celsius(from: $0) },
                  high: Double(high).map { editingUnit.celsius(from: $0) })
    }
    private var currentFan: FanReading { store.snapshot?.fans.first { $0.id == fan.id } ?? fan }
    private var editorMessage: String? {
        if let error { return error }
        if !currentFan.controlSupported { return store.text("此风扇目前仅支持监控。", "This fan currently supports monitoring only.") }
        return store.canControl || store.helperMessage.isEmpty ? nil : store.helperMessage
    }
    private var contentHeight: CGFloat {
        switch mode {
        case .automatic: 68
        case .fixed: 145
        case .sensor: 238
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "fan.fill").font(.title).foregroundStyle(Color.accentColor)
                    .frame(width: 42, height: 42).glassControl(radius: 12)
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.fanName(fan)).font(.title2.weight(.semibold))
                    Text(store.text("实际转速 ", "Actual speed ") + store.formattedRPM(currentFan.rpm, fresh: currentFan.isFresh(at: store.now)) + " RPM")
                        .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                Text(store.formattedRPM(fan.minimum) + "–" + store.formattedRPM(fan.maximum) + " RPM")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            GlassModeSegments(selection: $mode, labels: FanMode.allCases.map(store.modeName))

            Group {
                switch mode {
                case .automatic:
                    VStack(alignment: .leading, spacing: 12) {
                        Label(store.text("交由 macOS 管理散热", "Let macOS manage cooling"), systemImage: "leaf").font(.headline)
                        Text(store.text("停止这只风扇的自定义策略。系统会根据运行状态自动调整转速。", "Stop the custom policy for this fan. The system adjusts its speed as conditions change."))
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                case .fixed:
                    fixedControls
                case .sensor:
                    sensorControls
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .modifier(AnimatedEditorHeight(height: contentHeight))
            if let message = editorMessage {
                Text(message)
                    .font(.callout).foregroundStyle(error == nil ? Color.secondary : .red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                if store.controlPending { ProgressView().controlSize(.small) }
                Button(store.text("存为预设…", "Save as preset…")) {
                    validate { saveDraft = true }
                }.disabled(store.configurationError != nil)
                Spacer()
                Button(store.text("取消", "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(store.canControl ? store.text("应用", "Apply") : store.text("启用控制…", "Enable control…")) {
                    guard store.canControl else { store.showControlSetup = true; return }
                    validate {
                        Task {
                            do { try await store.applyFan(policy); dismiss() }
                            catch { self.error = error.localizedDescription }
                        }
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(store.controlPending || !currentFan.controlSupported)
            }
        }
        .padding(24).frame(width: 560)
        .background(WindowBackdrop().ignoresSafeArea())
        .onAppear {
            editingUnit = store.settings.unit
            let existing = store.displayPolicies.first { $0.fanID == fan.id }
            var initialTransaction = Transaction(animation: nil)
            initialTransaction.disablesAnimations = true
            withTransaction(initialTransaction) {
                mode = initialMode ?? existing?.mode ?? fan.mode ?? .automatic
            }
            rpm = (existing?.rpm ?? fan.target).map { String(Int($0)) } ?? fan.validRange.map { String(Int($0.lowerBound)) } ?? ""
            sensorID = existing?.sensorID ?? ""
            low = existing?.low.map { String(editingUnit.display($0)) } ?? ""
            high = existing?.high.map { String(editingUnit.display($0)) } ?? ""
        }
        // 同一视图同一时刻只能呈现一个 sheet:saveDraft(本地)与 showControlSetup(全局)
        // 二选一呈现,saveDraft 优先。
        .sheet(item: Binding<EditorSheet?>(
            get: {
                if saveDraft { return .saveDraft }
                if store.showControlSetup { return .controlSetup }
                return nil
            },
            set: { newValue in
                guard newValue == nil else { return }
                if saveDraft { saveDraft = false }
                else if store.showControlSetup { store.showControlSetup = false }
            }
        )) { sheet in
            switch sheet {
            case .saveDraft:
                PresetNameSheet(customPolicies: store.displayPolicies.filter { $0.fanID != fan.id } + [policy])
            case .controlSetup:
                ControlSetupView()
            }
        }
    }

    private var fixedControls: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(store.text("目标转速", "Target speed")).font(.headline)
                Spacer()
                TextField("RPM", text: $rpm).textFieldStyle(.roundedBorder).frame(width: 100)
                    .multilineTextAlignment(.trailing).monospacedDigit()
                    .accessibilityLabel(store.text("目标转速", "Target speed"))
                Text("RPM").foregroundStyle(.secondary)
            }
            if let range = currentFan.validRange {
                RPMControlSlider(value: Binding(get: {
                    guard let value = Double(rpm), value.isFinite else { return range.lowerBound }
                    return min(range.upperBound, max(range.lowerBound, value))
                }, set: { rpm = String(Int($0.rounded())) }), range: range, label: store.text("目标转速", "Target speed"))
                    .frame(height: 26).frame(maxWidth: .infinity)
                HStack {
                    Text(store.formattedRPM(range.lowerBound) + " RPM")
                    Spacer()
                    Text(store.formattedRPM(range.upperBound) + " RPM")
                }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
            } else {
                Text(store.text("尚未读取到有效的风扇范围。", "The fan’s valid speed range is not available.")).foregroundStyle(.secondary)
            }
            Text(store.text("点击应用后才会改变目标转速。实际转速会逐步接近目标。", "The target changes only when you apply. Actual fan speed takes time to reach it."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 8)
    }

    private var sensorControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(store.text("温度来源", "Temperature source"), selection: $sensorID) {
                Text(store.text("选择传感器", "Choose a sensor")).tag("")
                ForEach(store.snapshot?.sensors.filter { $0.isFresh(at: store.now) } ?? []) { sensor in
                    Text(store.sensorName(sensor) + " · " + store.formattedTemperature(sensor.celsius)).tag(sensor.id)
                }
            }
            HStack(spacing: 20) {
                thresholdField(title: store.text("开始加速", "Start increasing"), value: $low)
                thresholdField(title: store.text("达到最高转速", "Reach full speed"), value: $high)
            }
            if let range = fan.validRange, let lowValue = policy.low, let highValue = policy.high,
               lowValue.isFinite, highValue.isFinite, highValue > lowValue {
                Chart {
                    ForEach(Array(curvePoints(low: lowValue, high: highValue, range: range).enumerated()), id: \.offset) { _, point in
                        LineMark(x: .value("Temperature", editingUnit.display(point.0)), y: .value("RPM", point.1))
                            .foregroundStyle(Color.accentColor).lineStyle(StrokeStyle(lineWidth: 2))
                    }
                }
                .chartYAxisLabel("RPM", alignment: .trailing).chartXAxisLabel(editingUnit.symbol, alignment: .trailing)
                .frame(height: 110)
                .accessibilityLabel(store.text("转速曲线：在两个阈值之间线性增加，之外保持最低或最高转速。", "Fan curve: linear increase between the thresholds, minimum and maximum speed outside them."))
            } else {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)).frame(height: 100)
                    .overlay { Text(store.text("设置两个温度阈值，预览调速曲线", "Set both thresholds to preview the fan curve")).font(.callout).foregroundStyle(.secondary) }
            }
            Text(store.text("不同测点的温度含义不同。选择适合此风扇的传感器；数据失效时将回退到系统自动。", "Sensor locations measure different temperatures. Choose a suitable source; stale readings cause a return to automatic mode."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func thresholdField(title: String, value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.callout)
            HStack {
                TextField("—", text: value).textFieldStyle(.roundedBorder).monospacedDigit().accessibilityLabel(title)
                Text(editingUnit.symbol).foregroundStyle(.secondary)
            }
        }
    }
    private func curvePoints(low: Double, high: Double, range: ClosedRange<Double>) -> [(Double, Double)] {
        [(low - 10, range.lowerBound), (low, range.lowerBound), (high, range.upperBound), (high + 10, range.upperBound)]
    }
    private func validate(_ action: () -> Void) {
        guard let snapshot = store.snapshot else { error = ControlError.missingFan.localizedDescription; return }
        do { try PolicyValidator.validate([policy], in: snapshot, at: Date()); error = nil; action() }
        catch { self.error = error.localizedDescription }
    }
}

/// 插值后的高度参与布局，让 sheet 跟随内容逐帧调整，而不是先跳到终点高度。
private struct AnimatedEditorHeight: ViewModifier, Animatable {
    var height: CGFloat
    var animatableData: CGFloat {
        get { height }
        set { height = newValue }
    }

    func body(content: Content) -> some View {
        content.frame(height: height, alignment: .top).clipped()
    }
}

struct GlassModeSegments: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var selection: FanMode
    let labels: [String]
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let segmentWidth = max(0, (geometry.size.width - 16) / 3)
            let step = segmentWidth + 4
            let selectedIndex = FanMode.allCases.firstIndex(of: selection) ?? 0
            let selectedX = CGFloat(selectedIndex) * step
            ZStack(alignment: .topLeading) {
                selectedBackground
                    .frame(width: segmentWidth, height: 32)
                    .offset(x: 4 + min(max(0, selectedX + dragOffset), 2 * step), y: 4)
                HStack(spacing: 4) {
                    ForEach(Array(FanMode.allCases.enumerated()), id: \.element) { index, value in
                        Button {
                            if reduceMotion { selection = value }
                            else { withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) { selection = value } }
                        } label: {
                            Text(labels[index])
                                .font(.callout.weight(selection == value ? .semibold : .regular))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity)
                                .frame(height: 32)
                                .contentShape(RoundedRectangle(cornerRadius: 9))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selection == value ? .isSelected : [])
                    }
                }
                .padding(4)
            }
            .frame(width: geometry.size.width, height: 40)
            .background { trackBackground }
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)) }
            .highPriorityGesture(DragGesture(minimumDistance: 3)
                .onChanged { dragOffset = $0.translation.width }
                .onEnded { gesture in
                    let index = min(2, max(0, Int((CGFloat(selectedIndex) + gesture.translation.width / step).rounded())))
                    let target = FanMode.allCases[index]
                    if reduceMotion {
                        selection = target
                        dragOffset = 0
                    } else {
                        withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
                            selection = target
                            dragOffset = 0
                        }
                    }
                })
        }
        .frame(height: 40)
    }

    @ViewBuilder
    private var trackBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 12)
        if #available(macOS 26.0, *) {
            shape.fill(.ultraThinMaterial).glassEffect(.regular, in: shape)
        } else {
            shape.fill(.thinMaterial)
        }
    }

    @ViewBuilder
    private var selectedBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 9)
        if #available(macOS 26.0, *) {
            shape.fill(Color.clear)
                .glassEffect(.regular.tint(Color.accentColor.opacity(0.16)).interactive(), in: shape)
                .overlay(shape.fill(Color.accentColor.opacity(0.09)))
                .overlay(shape.strokeBorder(Color.primary.opacity(0.10)))
        } else {
            shape.fill(.regularMaterial)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.10)))
        }
    }
}

struct RPMControlSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let label: String

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound, target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        slider.numberOfTickMarks = 0
        slider.isContinuous = true
        slider.setAccessibilityLabel(label)
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return slider
    }
    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.value = $value
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.doubleValue = value
        slider.setAccessibilityLabel(label)
    }
    func makeCoordinator() -> Coordinator { Coordinator(value: $value) }
    @MainActor final class Coordinator: NSObject {
        var value: Binding<Double>
        init(value: Binding<Double>) { self.value = value }
        @objc func changed(_ sender: NSSlider) { value.wrappedValue = sender.doubleValue.rounded() }
    }
}

struct PresetNameSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var preset: FanPreset?
    var customPolicies: [FanPolicy]?
    @State private var name = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(preset == nil ? store.text("保存预设", "Save preset") : store.text("重命名预设", "Rename preset")).font(.title2.weight(.semibold))
            Text(store.text("给这组风扇配置一个易于识别的名称。保存不会应用新的控制策略。", "Give this fan configuration a recognizable name. Saving does not apply a new policy."))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField(store.text("预设名称", "Preset name"), text: $name).textFieldStyle(.roundedBorder).focused($focused)
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(store.text("取消", "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(store.text("保存", "Save")) {
                    do {
                        if let preset { try store.renamePreset(preset, name: name) }
                        else { try store.savePreset(name: name, customPolicies: customPolicies) }
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 390)
            .background(WindowBackdrop().ignoresSafeArea())
            .onAppear { name = preset?.name ?? ""; focused = true }
    }
}
