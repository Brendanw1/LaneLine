import SwiftUI
import UIKit

/// Pair and manage Bluetooth speed/cadence sensors (Magene S3+ and any
/// other Cycling Speed and Cadence device), set the wheel size that turns
/// wheel revolutions into speed, and explain how the Apple Watch fits in.
struct SensorsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.services) private var services
    @Environment(\.openURL) private var openURL

    private var sensorService: any CyclingSensorMonitoring { services.cyclingSensorService }

    var body: some View {
        Form {
            radioSection
            pairedSection
            if sensorService.isScanning {
                discoveredSection
            }
            liveSection
            wheelSection
            appleWatchSection
        }
        .navigationTitle("Sensors")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            sensorService.setWheelCircumference(meters: appModel.riderProfile.wheelCircumferenceMm / 1000)
            // Settings shows live readings but leaves the Watch stream to
            // rides — no Health prompt just for opening this screen.
            sensorService.start(includingAppleWatch: false)
        }
        .onDisappear {
            sensorService.stop()
        }
    }

    // MARK: Bluetooth state

    @ViewBuilder
    private var radioSection: some View {
        switch sensorService.radioState {
        case .poweredOff:
            Section {
                Label("Bluetooth is off. Turn it on in Control Center to connect sensors.",
                      systemImage: "antenna.radiowaves.left.and.right.slash")
                    .foregroundStyle(LaneLineDesign.Colors.warning)
            }
        case .unauthorized:
            Section {
                Label("LaneLine doesn't have Bluetooth access.", systemImage: "lock")
                    .foregroundStyle(LaneLineDesign.Colors.danger)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
        case .unsupported:
            Section {
                Text("This device doesn't support Bluetooth Low Energy.")
                    .foregroundStyle(.secondary)
            }
        case .unknown, .ready:
            EmptyView()
        }
    }

    // MARK: Paired

    private var pairedSection: some View {
        let paired = sensorService.sensors.filter(\.isPaired)
        return Section {
            if paired.isEmpty {
                Text("No sensors paired yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(paired) { sensor in
                SensorRow(sensor: sensor)
                    .swipeActions {
                        Button("Forget", role: .destructive) { sensorService.forget(sensor.id) }
                    }
                    .contextMenu {
                        Button("Forget sensor", systemImage: "trash", role: .destructive) {
                            sensorService.forget(sensor.id)
                        }
                    }
            }
            Button {
                if sensorService.isScanning { sensorService.stopScan() } else { sensorService.startScan() }
            } label: {
                if sensorService.isScanning {
                    HStack {
                        ProgressView()
                        Text("Searching… tap to stop")
                    }
                } else {
                    Label("Add sensor", systemImage: "plus.circle")
                }
            }
        } header: {
            Text("My sensors")
        } footer: {
            Text("Spin the wheel or turn the crank to wake the sensor before searching. Pair two if you run one in speed mode and one in cadence mode — LaneLine detects each sensor's mode from its data.")
        }
    }

    private var discoveredSection: some View {
        let found = sensorService.sensors.filter { !$0.isPaired }
        return Section {
            if found.isEmpty {
                Text("Looking for speed/cadence sensors nearby…")
                    .foregroundStyle(.secondary)
            }
            ForEach(found) { sensor in
                Button {
                    sensorService.pair(sensor.id)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sensor.name).foregroundStyle(.primary)
                            if let rssi = sensor.signalStrength {
                                Text(signalLabel(rssi))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text("Pair")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(LaneLineDesign.Colors.primary)
                    }
                }
            }
        } header: {
            Text("Nearby")
        }
    }

    // MARK: Live

    @ViewBuilder
    private var liveSection: some View {
        if sensorService.currentCadenceRPM != nil || sensorService.currentSpeedKmh != nil {
            Section {
                if let rpm = sensorService.currentCadenceRPM {
                    LabeledContent("Cadence", value: "\(RideFormat.wholeNumber(rpm)) rpm")
                }
                if let kmh = sensorService.currentSpeedKmh {
                    LabeledContent("Wheel speed", value: "\(RideFormat.speedValue(kmh)) km/h")
                }
                if let source = sensorService.cadenceSource {
                    LabeledContent("Source", value: source.label)
                }
            } header: {
                Text("Live")
            }
        }
    }

    // MARK: Wheel size

    private var wheelSection: some View {
        Section {
            Picker("Tire size", selection: wheelPresetBinding) {
                ForEach(WheelSize.allCases) { size in
                    Text("\(size.label) · \(Int(size.circumferenceMm)) mm").tag(Optional(size))
                }
                Text("Custom").tag(WheelSize?.none)
            }
            Stepper(value: wheelMmBinding, in: 1500...2500, step: 1) {
                LabeledContent("Circumference", value: "\(Int(wheelMmBinding.wrappedValue)) mm")
            }
        } header: {
            Text("Wheel")
        } footer: {
            Text("Used only with a sensor in speed mode — it counts wheel revolutions, so speed and distance are as accurate as this number. With a wheel sensor connected, ride speed comes from it instead of GPS.")
        }
    }

    private var wheelMmBinding: Binding<Double> {
        Binding(
            get: { appModel.riderProfile.wheelCircumferenceMm },
            set: { newValue in
                var profile = appModel.riderProfile
                profile.wheelCircumferenceMm = newValue
                appModel.updateProfile(profile)
                sensorService.setWheelCircumference(meters: newValue / 1000)
            }
        )
    }

    private var wheelPresetBinding: Binding<WheelSize?> {
        Binding(
            get: { WheelSize.matching(mm: appModel.riderProfile.wheelCircumferenceMm) },
            set: { preset in
                guard let preset else { return }
                wheelMmBinding.wrappedValue = preset.circumferenceMm
            }
        )
    }

    // MARK: Apple Watch

    private var appleWatchSection: some View {
        Section {
            Label("Heart rate streams from your Apple Watch automatically during rides.",
                  systemImage: "heart.fill")
            Label("If your sensor is paired to the Watch instead (Watch Settings → Bluetooth) and you're recording a Watch cycling workout, LaneLine picks up its cadence from Health.",
                  systemImage: "applewatch")
        } header: {
            Text("Apple Watch")
        } footer: {
            Text("Most sensors accept one Bluetooth connection at a time, so pair the sensor to either the iPhone or the Watch. A sensor connected to the iPhone always takes priority. ANT+ isn't available on iPhone; LaneLine uses the sensor's Bluetooth mode.")
        }
    }

    private func signalLabel(_ rssi: Int) -> String {
        switch rssi {
        case (-60)...: "Strong signal"
        case (-75)...: "Good signal"
        default: "Weak signal — move closer"
        }
    }
}

// MARK: - Sensor Row

private struct SensorRow: View {
    let sensor: CyclingSensor

    var body: some View {
        HStack(spacing: LaneLineDesign.Spacing.small) {
            Image(systemName: sensor.reportsSpeed && !sensor.reportsCadence
                  ? "speedometer" : "arrow.triangle.2.circlepath")
                .foregroundStyle(LaneLineDesign.Colors.primary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(sensor.name)
                Text("\(connectionLabel) · \(sensor.modeLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let battery = sensor.batteryPercent {
                Label("\(battery)%", systemImage: batteryIcon(battery))
                    .font(.caption)
                    .foregroundStyle(battery <= 15 ? LaneLineDesign.Colors.danger : .secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var connectionLabel: String {
        switch sensor.connection {
        case .connected: "Connected"
        case .connecting: "Waiting for sensor"
        case .disconnected: "Not connected"
        }
    }

    private func batteryIcon(_ percent: Int) -> String {
        switch percent {
        case 75...: "battery.100"
        case 50...: "battery.75"
        case 25...: "battery.50"
        case 10...: "battery.25"
        default: "battery.0"
        }
    }
}

#Preview {
    NavigationStack {
        SensorsView()
    }
    .serviceContainer(.preview())
    .environment(PreviewData.appModel())
}
