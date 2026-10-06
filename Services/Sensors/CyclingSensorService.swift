import Foundation
import CoreBluetooth
import Observation

// MARK: - Sensor Models

enum CyclingSensorConnection: Equatable {
    case disconnected, connecting, connected
}

/// A Bluetooth speed/cadence pod — discovered in a scan, remembered once
/// paired. What it measures is learned from its data, not its name: a
/// Magene S3+ flips between speed and cadence mode (pull and reinsert the
/// battery), and the app just follows whichever counters arrive.
struct CyclingSensor: Identifiable, Equatable {
    let id: UUID
    var name: String
    var isPaired: Bool
    var connection: CyclingSensorConnection = .disconnected
    var signalStrength: Int?
    var batteryPercent: Int?
    var reportsCadence = false
    var reportsSpeed = false

    var modeLabel: String {
        switch (reportsSpeed, reportsCadence) {
        case (true, true): "Speed + cadence"
        case (true, false): "Speed"
        case (false, true): "Cadence"
        case (false, false): connection == .connected ? "Waiting for motion" : "—"
        }
    }
}

enum SensorRadioState: Equatable {
    case unknown, poweredOff, unauthorized, unsupported, ready
}

/// Where the live cadence is coming from right now.
enum CadenceSource: Equatable {
    /// A sensor connected straight to the phone over Bluetooth.
    case sensor(name: String)
    /// The Apple Watch, which holds the sensor and writes cadence to Health.
    case appleWatch

    var label: String {
        switch self {
        case .sensor(let name): name
        case .appleWatch: "Apple Watch"
        }
    }
}

// MARK: - Protocol

/// Live cycling-sensor data for the ride: cadence (RPM) and wheel speed
/// from Bluetooth Cycling Speed and Cadence sensors such as the Magene
/// S3+, with the Apple Watch's HealthKit cadence stream as a fallback.
/// Values are nil until a source exists, so the UI hides rather than
/// showing a dead zero; a connected-but-still crank reads 0.
@MainActor
protocol CyclingSensorMonitoring: AnyObject, Observable {
    var currentCadenceRPM: Double? { get }
    /// Wheel-sensor speed, nil without a speed-mode sensor.
    var currentSpeedKmh: Double? { get }
    var cadenceSource: CadenceSource? { get }
    /// Paired sensors first, then anything found by the current scan.
    var sensors: [CyclingSensor] { get }
    var radioState: SensorRadioState { get }
    var isScanning: Bool { get }

    /// Connects paired sensors (touching Bluetooth only if any exist, so
    /// a rider without sensors never sees the permission prompt), and, for
    /// rides, also follows the Apple Watch's cadence stream.
    func start(includingAppleWatch: Bool)
    func stop()
    func startScan()
    func stopScan()
    func pair(_ id: UUID)
    func forget(_ id: UUID)
    func setWheelCircumference(meters: Double)
}

extension CyclingSensorMonitoring {
    var hasPairedSensors: Bool { sensors.contains(where: \.isPaired) }
}

// MARK: - Live CoreBluetooth Implementation

@MainActor
@Observable
final class BluetoothCyclingSensorService: CyclingSensorMonitoring {
    static let cscService = CBUUID(string: "1816")
    static let cscMeasurement = CBUUID(string: "2A5B")
    static let batteryService = CBUUID(string: "180F")
    static let batteryLevel = CBUUID(string: "2A19")
    private static let pairedDefaultsKey = "laneline.cyclingSensors.paired"

    private(set) var currentCadenceRPM: Double?
    private(set) var currentSpeedKmh: Double?
    private(set) var cadenceSource: CadenceSource?
    private(set) var sensors: [CyclingSensor] = []
    private(set) var radioState: SensorRadioState = .unknown
    private(set) var isScanning = false

    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var delegateProxy: DelegateProxy?
    @ObservationIgnored private var peripherals: [UUID: CBPeripheral] = [:]
    @ObservationIgnored private var calculators: [UUID: CSCRateCalculator] = [:]
    @ObservationIgnored private var wheelCircumferenceMeters = 2.105
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var wantsScan = false
    @ObservationIgnored private var tickTimer: Timer?
    private let watchCadence: WatchCadenceReader
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.watchCadence = WatchCadenceReader()
        let stored = defaults.dictionary(forKey: Self.pairedDefaultsKey) as? [String: String] ?? [:]
        sensors = stored.compactMap { key, name in
            UUID(uuidString: key).map { CyclingSensor(id: $0, name: name, isPaired: true) }
        }
        .sorted { $0.name < $1.name }
        watchCadence.onUpdate = { [weak self] in self?.recompute() }
    }

    // MARK: Lifecycle

    func start(includingAppleWatch: Bool) {
        isActive = true
        startTicking()
        if includingAppleWatch {
            Task { await watchCadence.start() }
        }
        if hasPairedSensors {
            ensureCentral()
            reconnectPaired()
        }
    }

    func stop() {
        isActive = false
        stopScan()
        tickTimer?.invalidate()
        tickTimer = nil
        watchCadence.stop()
        if let central {
            for sensor in sensors where sensor.connection != .disconnected {
                if let peripheral = peripherals[sensor.id] {
                    central.cancelPeripheralConnection(peripheral)
                }
            }
        }
        for id in calculators.keys { calculators[id]?.resetBaselines() }
        for index in sensors.indices { sensors[index].connection = .disconnected }
        currentCadenceRPM = nil
        currentSpeedKmh = nil
        cadenceSource = nil
    }

    func startScan() {
        wantsScan = true
        ensureCentral()
        beginScanIfReady()
    }

    func stopScan() {
        wantsScan = false
        if isScanning { central?.stopScan() }
        isScanning = false
        // Drop unpaired finds that aren't connected; they were scan results.
        sensors.removeAll { !$0.isPaired && $0.connection == .disconnected }
    }

    func pair(_ id: UUID) {
        guard let index = sensors.firstIndex(where: { $0.id == id }) else { return }
        sensors[index].isPaired = true
        persistPaired()
        isActive = true
        startTicking()
        ensureCentral()
        connect(id)
    }

    func forget(_ id: UUID) {
        if let peripheral = peripherals[id] {
            central?.cancelPeripheralConnection(peripheral)
        }
        sensors.removeAll { $0.id == id }
        peripherals[id] = nil
        calculators[id] = nil
        persistPaired()
        recompute()
    }

    func setWheelCircumference(meters: Double) {
        guard meters > 0 else { return }
        wheelCircumferenceMeters = meters
        for id in calculators.keys {
            calculators[id]?.config.wheelCircumferenceMeters = meters
        }
    }

    // MARK: Central plumbing

    /// Lazy on purpose: creating the manager is what triggers the
    /// Bluetooth permission prompt.
    private func ensureCentral() {
        guard central == nil else { return }
        let proxy = DelegateProxy()
        proxy.owner = self
        delegateProxy = proxy
        central = CBCentralManager(delegate: proxy, queue: .main)
    }

    private func beginScanIfReady() {
        guard wantsScan, let central, central.state == .poweredOn, !isScanning else { return }
        // Sensors already held by iOS (another app, or a previous session)
        // don't advertise; surface them directly.
        for peripheral in central.retrieveConnectedPeripherals(withServices: [Self.cscService]) {
            register(peripheral, rssi: nil, advertisedName: nil)
        }
        central.scanForPeripherals(withServices: [Self.cscService], options: nil)
        isScanning = true
    }

    private func reconnectPaired() {
        guard let central, central.state == .poweredOn else { return }
        let missing = sensors.filter { $0.isPaired && peripherals[$0.id] == nil }.map(\.id)
        for peripheral in central.retrievePeripherals(withIdentifiers: missing) {
            peripherals[peripheral.identifier] = peripheral
        }
        for sensor in sensors where sensor.isPaired {
            connect(sensor.id)
        }
    }

    /// CoreBluetooth connects have no timeout: a pending connect completes
    /// whenever the sensor wakes (a Magene sleeps until the wheel or crank
    /// moves), which is exactly the bike-computer behavior we want.
    private func connect(_ id: UUID) {
        guard isActive, let central, central.state == .poweredOn,
              let peripheral = peripherals[id],
              let index = sensors.firstIndex(where: { $0.id == id }) else { return }
        guard peripheral.state == .disconnected else { return }
        sensors[index].connection = .connecting
        central.connect(peripheral, options: nil)
    }

    private func register(_ peripheral: CBPeripheral, rssi: Int?, advertisedName: String?) {
        let id = peripheral.identifier
        peripherals[id] = peripheral
        let name = peripheral.name ?? advertisedName ?? "Speed/cadence sensor"
        if let index = sensors.firstIndex(where: { $0.id == id }) {
            if !sensors[index].isPaired { sensors[index].name = name }
            if let rssi { sensors[index].signalStrength = rssi }
        } else {
            sensors.append(CyclingSensor(id: id, name: name, isPaired: false, signalStrength: rssi))
        }
    }

    private func persistPaired() {
        var stored: [String: String] = [:]
        for sensor in sensors where sensor.isPaired {
            stored[sensor.id.uuidString] = sensor.name
        }
        defaults.set(stored, forKey: Self.pairedDefaultsKey)
    }

    private func updateSensor(_ id: UUID, _ change: (inout CyclingSensor) -> Void) {
        guard let index = sensors.firstIndex(where: { $0.id == id }) else { return }
        change(&sensors[index])
    }

    // MARK: Delegate events (main queue)

    fileprivate func centralDidUpdateState(_ state: CBManagerState) {
        switch state {
        case .poweredOn: radioState = .ready
        case .poweredOff: radioState = .poweredOff
        case .unauthorized: radioState = .unauthorized
        case .unsupported: radioState = .unsupported
        default: radioState = .unknown
        }
        if state == .poweredOn {
            if isActive { reconnectPaired() }
            beginScanIfReady()
        } else {
            isScanning = false
            for index in sensors.indices { sensors[index].connection = .disconnected }
            for id in calculators.keys { calculators[id]?.resetBaselines() }
            recompute()
        }
    }

    fileprivate func didDiscover(_ peripheral: CBPeripheral, advertisedName: String?, rssi: Int) {
        register(peripheral, rssi: rssi, advertisedName: advertisedName)
    }

    fileprivate func didConnect(_ peripheral: CBPeripheral) {
        peripheral.delegate = delegateProxy
        updateSensor(peripheral.identifier) { $0.connection = .connected }
        peripheral.discoverServices([Self.cscService, Self.batteryService])
    }

    fileprivate func didDisconnect(_ peripheral: CBPeripheral) {
        let id = peripheral.identifier
        calculators[id]?.resetBaselines()
        updateSensor(id) { $0.connection = .disconnected }
        recompute()
        // Dropouts happen (sensor sleeps at a light, a body blocks the
        // radio); queue a fresh pending connect while the ride runs.
        if sensors.first(where: { $0.id == id })?.isPaired == true { connect(id) }
    }

    fileprivate func didDiscoverServices(_ peripheral: CBPeripheral) {
        for service in peripheral.services ?? [] {
            if service.uuid == Self.cscService {
                peripheral.discoverCharacteristics([Self.cscMeasurement], for: service)
            } else if service.uuid == Self.batteryService {
                peripheral.discoverCharacteristics([Self.batteryLevel], for: service)
            }
        }
    }

    fileprivate func didDiscoverCharacteristics(_ peripheral: CBPeripheral, service: CBService) {
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == Self.cscMeasurement {
                peripheral.setNotifyValue(true, for: characteristic)
            } else if characteristic.uuid == Self.batteryLevel {
                peripheral.readValue(for: characteristic)
                if characteristic.properties.contains(.notify) {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            }
        }
    }

    fileprivate func didUpdateValue(_ peripheral: CBPeripheral, characteristic: CBUUID, data: Data) {
        let id = peripheral.identifier
        if characteristic == Self.batteryLevel, let level = data.first {
            updateSensor(id) { $0.batteryPercent = Int(min(level, 100)) }
            return
        }
        guard characteristic == Self.cscMeasurement,
              let measurement = CSCMeasurement(data: data) else { return }
        var calculator = calculators[id] ?? CSCRateCalculator(
            config: CSCRateCalculator.Config(wheelCircumferenceMeters: wheelCircumferenceMeters)
        )
        calculator.ingest(measurement, at: ProcessInfo.processInfo.systemUptime)
        calculators[id] = calculator
        updateSensor(id) { sensor in
            if measurement.hasCrankData { sensor.reportsCadence = true }
            if measurement.hasWheelData { sensor.reportsSpeed = true }
        }
        recompute()
    }

    // MARK: Fusion

    private func startTicking() {
        guard tickTimer == nil else { return }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recompute() }
        }
    }

    /// Direct sensor first (lowest latency, exact), Watch stream second.
    private func recompute() {
        let now = ProcessInfo.processInfo.systemUptime
        for id in calculators.keys { calculators[id]?.expire(now: now) }
        watchCadence.expire()

        let connected = sensors.filter { $0.connection == .connected }
        if let sensor = connected.first(where: { calculators[$0.id]?.cadenceRPM != nil }),
           let rpm = calculators[sensor.id]?.cadenceRPM {
            currentCadenceRPM = rpm
            cadenceSource = .sensor(name: sensor.name)
        } else if let rpm = watchCadence.currentRPM {
            currentCadenceRPM = rpm
            cadenceSource = .appleWatch
        } else {
            currentCadenceRPM = nil
            cadenceSource = nil
        }

        currentSpeedKmh = connected
            .lazy
            .compactMap { self.calculators[$0.id]?.wheelSpeedMs }
            .first
            .map { $0 * 3.6 }
    }
}

// MARK: - Delegate Proxy

/// CoreBluetooth's delegate protocols are nonisolated; the manager runs on
/// the main queue, so each callback asserts main-actor isolation and
/// forwards to the observable service.
private final class DelegateProxy: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    weak var owner: BluetoothCyclingSensorService?

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        MainActor.assumeIsolated { owner?.centralDidUpdateState(state) }
    }

    func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let rssi = RSSI.intValue
        MainActor.assumeIsolated { owner?.didDiscover(peripheral, advertisedName: name, rssi: rssi) }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated { owner?.didConnect(peripheral) }
    }

    func centralManager(
        _ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?
    ) {
        MainActor.assumeIsolated { owner?.didDisconnect(peripheral) }
    }

    func centralManager(
        _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?
    ) {
        MainActor.assumeIsolated { owner?.didDisconnect(peripheral) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated { owner?.didDiscoverServices(peripheral) }
    }

    func peripheral(
        _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?
    ) {
        MainActor.assumeIsolated { owner?.didDiscoverCharacteristics(peripheral, service: service) }
    }

    func peripheral(
        _ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?
    ) {
        guard error == nil, let data = characteristic.value else { return }
        let uuid = characteristic.uuid
        MainActor.assumeIsolated { owner?.didUpdateValue(peripheral, characteristic: uuid, data: data) }
    }
}

// MARK: - Preview / Demo / Test Mock

/// A paired, connected "Magene S3+" in cadence mode: ~85 RPM breathing
/// ±8 over a 40 s period, so the demo chip visibly responds. Speed stays
/// nil (the demo's speed comes from route simulation). `cadenceProvider`
/// overrides the waveform for tests.
@MainActor
@Observable
final class MockCyclingSensorService: CyclingSensorMonitoring {
    private(set) var currentCadenceRPM: Double?
    private(set) var currentSpeedKmh: Double?
    private(set) var cadenceSource: CadenceSource?
    private(set) var sensors: [CyclingSensor]
    private(set) var radioState: SensorRadioState = .ready
    private(set) var isScanning = false

    private var startedAt: Date?
    private var timer: Timer?
    private let cadenceProvider: ((TimeInterval) -> Double?)?

    init(paired: Bool = true, cadenceProvider: ((TimeInterval) -> Double?)? = nil) {
        self.cadenceProvider = cadenceProvider
        sensors = paired
            ? [CyclingSensor(id: UUID(), name: "Magene S3+", isPaired: true, batteryPercent: 92)]
            : []
    }

    func start(includingAppleWatch: Bool) {
        guard timer == nil, hasPairedSensors else { return }
        startedAt = .now
        for index in sensors.indices where sensors[index].isPaired {
            sensors[index].connection = .connected
            sensors[index].reportsCadence = true
        }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        startedAt = nil
        currentCadenceRPM = nil
        cadenceSource = nil
        for index in sensors.indices { sensors[index].connection = .disconnected }
    }

    func startScan() {
        isScanning = true
        if !sensors.contains(where: { !$0.isPaired }) {
            sensors.append(CyclingSensor(id: UUID(), name: "Magene S3+ 40211", isPaired: false, signalStrength: -58))
        }
    }

    func stopScan() {
        isScanning = false
        sensors.removeAll { !$0.isPaired }
    }

    func pair(_ id: UUID) {
        guard let index = sensors.firstIndex(where: { $0.id == id }) else { return }
        sensors[index].isPaired = true
        sensors[index].connection = .connected
        sensors[index].reportsCadence = true
    }

    func forget(_ id: UUID) {
        sensors.removeAll { $0.id == id }
        if !hasPairedSensors {
            currentCadenceRPM = nil
            cadenceSource = nil
        }
    }

    func setWheelCircumference(meters: Double) {}

    private func tick() {
        guard let startedAt, let sensor = sensors.first(where: \.isPaired) else { return }
        let elapsed = Date.now.timeIntervalSince(startedAt)
        if let cadenceProvider {
            currentCadenceRPM = cadenceProvider(elapsed)
        } else {
            currentCadenceRPM = 85 + 8 * sin(elapsed * 2 * .pi / 40)
        }
        cadenceSource = currentCadenceRPM == nil ? nil : .sensor(name: sensor.name)
    }
}
