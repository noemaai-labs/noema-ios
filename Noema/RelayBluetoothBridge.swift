import Foundation
#if canImport(CoreBluetooth)
import CoreBluetooth
#endif

struct RelayBluetoothPayload: Codable, Equatable, Hashable, Identifiable {
    let id: UUID
    let containerID: String
    let deviceName: String
    let provider: String
    let hostDeviceID: String
    let lanURL: String?
    let apiToken: String?
    let wifiSSID: String?
    let updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case containerID
        case deviceName
        case provider
        case hostDeviceID
        case lanURL
        case apiToken
        case wifiSSID
        case updatedAt
    }

    init(id: UUID,
         containerID: String,
         deviceName: String,
         provider: String,
         hostDeviceID: String,
         lanURL: String?,
         apiToken: String?,
         wifiSSID: String?,
         updatedAt: Date) {
        self.id = id
        self.containerID = containerID
        self.deviceName = deviceName
        self.provider = provider
        self.hostDeviceID = hostDeviceID
        self.lanURL = lanURL
        self.apiToken = apiToken
        self.wifiSSID = wifiSSID
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        containerID = try container.decode(String.self, forKey: .containerID)
        deviceName = try container.decode(String.self, forKey: .deviceName)
        provider = try container.decode(String.self, forKey: .provider)
        hostDeviceID = try container.decodeIfPresent(String.self, forKey: .hostDeviceID) ?? ""
        lanURL = try container.decodeIfPresent(String.self, forKey: .lanURL)
        apiToken = try container.decodeIfPresent(String.self, forKey: .apiToken)
        wifiSSID = try container.decodeIfPresent(String.self, forKey: .wifiSSID)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(containerID, forKey: .containerID)
        try container.encode(deviceName, forKey: .deviceName)
        try container.encode(provider, forKey: .provider)
        try container.encode(hostDeviceID, forKey: .hostDeviceID)
        try container.encodeIfPresent(lanURL, forKey: .lanURL)
        try container.encodeIfPresent(apiToken, forKey: .apiToken)
        try container.encodeIfPresent(wifiSSID, forKey: .wifiSSID)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

#if canImport(CoreBluetooth)
private enum RelayBluetoothConstants {
    static let serviceUUIDString = "F3B2C6B6-62FA-4DE1-90E6-3CB91A81E3F2"
    static let payloadCharacteristicUUIDString = "A5F3FA07-8286-4E73-BCA0-06D4DA2D0198"

    static func serviceUUID() -> CBUUID {
        CBUUID(string: serviceUUIDString)
    }

    static func payloadCharacteristicUUID() -> CBUUID {
        CBUUID(string: payloadCharacteristicUUIDString)
    }
}
#endif

#if canImport(CoreBluetooth) && os(macOS)
import AppKit

@MainActor
final class RelayBluetoothAdvertiser: NSObject, ObservableObject, CBPeripheralManagerDelegate {
    enum State: Equatable {
        case idle
        case poweringOn
        case advertising
        case error(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastPayload: RelayBluetoothPayload?

    private var peripheralManager: CBPeripheralManager?
    private var payloadCharacteristic: CBMutableCharacteristic?
    private var relayService: CBMutableService?
    private var pendingPayload: RelayBluetoothPayload?
    private var shouldAdvertise = false
    private let encoder: JSONEncoder
    private let relayServiceUUID = RelayBluetoothConstants.serviceUUID()
    private let relayPayloadCharacteristicUUID = RelayBluetoothConstants.payloadCharacteristicUUID()

    override init() {
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        super.init()
    }

    var isAdvertisingActive: Bool {
        shouldAdvertise
    }

    func startAdvertising(payload: RelayBluetoothPayload) {
        pendingPayload = payload
        if lastPayload != payload {
            lastPayload = payload
        }
        shouldAdvertise = true
        ensurePeripheralManager()
        updateAdvertisingState()
    }

    func stopAdvertising() {
        shouldAdvertise = false
        peripheralManager?.stopAdvertising()
        state = .idle
    }

    private func ensurePeripheralManager() {
        if peripheralManager == nil {
            peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
        }
    }

    private func updateAdvertisingState() {
        guard shouldAdvertise else { return }
        guard let manager = peripheralManager else {
            ensurePeripheralManager()
            return
        }
        guard manager.state == .poweredOn else {
            state = .poweringOn
            return
        }

        if relayService == nil {
            installService()
        }

        if let payload = pendingPayload {
            updateCharacteristic(with: payload)
            pendingPayload = nil
        }

        if !manager.isAdvertising {
            let advertisement: [String: Any] = [
                CBAdvertisementDataServiceUUIDsKey: [relayServiceUUID],
                CBAdvertisementDataLocalNameKey: Host.current().localizedName ?? "Noema Relay"
            ]
            manager.startAdvertising(advertisement)
        }

        state = .advertising
    }

    private func installService() {
        let characteristic = CBMutableCharacteristic(
            type: relayPayloadCharacteristicUUID,
            properties: [.read],
            value: nil,
            permissions: [.readable]
        )
        let service = CBMutableService(type: relayServiceUUID, primary: true)
        service.characteristics = [characteristic]
        payloadCharacteristic = characteristic
        relayService = service
        peripheralManager?.add(service)
    }

    private func updateCharacteristic(with payload: RelayBluetoothPayload) {
        guard let characteristic = payloadCharacteristic else { return }
        do {
            let data = try encoder.encode(payload)
            characteristic.value = data
        } catch {
            state = .error("Failed to encode payload: \(error.localizedDescription)")
        }
    }

    // MARK: - CBPeripheralManagerDelegate

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            updateAdvertisingState()
        case .unauthorized:
            state = .error("Bluetooth access denied. Enable Bluetooth in System Settings.")
        case .unsupported:
            state = .error("Bluetooth is not supported on this Mac.")
        case .poweredOff:
            state = .error("Bluetooth is turned off. Enable it to share relay details.")
        default:
            break
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            state = .error("Unable to publish relay service: \(error.localizedDescription)")
            return
        }
        updateAdvertisingState()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard request.characteristic.uuid == relayPayloadCharacteristicUUID,
              let payloadData = payloadCharacteristic?.value else {
            peripheral.respond(to: request, withResult: .attributeNotFound)
            return
        }
        guard request.offset <= payloadData.count else {
            peripheral.respond(to: request, withResult: .invalidOffset)
            return
        }

        let remainingLength = payloadData.count - request.offset
        let rangeStart = payloadData.index(payloadData.startIndex, offsetBy: request.offset)
        let responseSlice = payloadData[rangeStart..<payloadData.endIndex]
        request.value = remainingLength == payloadData.count
            ? payloadData
            : Data(responseSlice)
        peripheral.respond(to: request, withResult: .success)
    }
}
#endif

#if canImport(CoreBluetooth) && (os(iOS) || os(visionOS))
import UIKit

@MainActor
final class RelayBluetoothScanner: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    struct DiscoveredRelay: Identifiable, Equatable, Hashable {
        let id: UUID
        let payload: RelayBluetoothPayload
        let peripheral: CBPeripheral
        let rssi: NSNumber

        var name: String { payload.deviceName }
    }

    enum State: Equatable {
        case idle
        case poweringOn
        case scanning
        case unauthorized
        case error(String)
    }

    enum ScannerError: LocalizedError {
        case busy
        case unavailable
        case failed(String)
        case timedOut

        var errorDescription: String? {
            switch self {
            case .busy:
                return "A connection check is already running."
            case .unavailable:
                return "Bluetooth is unavailable right now."
            case .failed(let message):
                return message
            case .timedOut:
                return "Connection timed out. Move closer to your Mac and try again."
            }
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var discovered: [DiscoveredRelay] = []

    private lazy var decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private var central: CBCentralManager?
    private var shouldScan = false
    private var pendingPeripherals: [UUID: CBPeripheral] = [:]
    private var pendingRSSI: [UUID: NSNumber] = [:]
    private var connectionTestContinuation: CheckedContinuation<Void, Error>?
    private var connectionTestPeripheralID: UUID?
    private var connectionTestTimeoutTask: Task<Void, Never>?
    private let relayServiceUUID = RelayBluetoothConstants.serviceUUID()
    private let relayPayloadCharacteristicUUID = RelayBluetoothConstants.payloadCharacteristicUUID()

    override init() {
        super.init()
    }

    func startScanning() {
        discovered.removeAll()
        shouldScan = true
        ensureCentralManager()
        updateScanningState()
    }

    func stopScanning() {
        shouldScan = false
        central?.stopScan()
        state = .idle
        if connectionTestContinuation != nil {
            completeConnectionTest(.failure(ScannerError.failed("Scanning stopped.")))
        }
    }

    func performConnectionTest(for relay: DiscoveredRelay) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard connectionTestContinuation == nil else {
                continuation.resume(throwing: ScannerError.busy)
                return
            }
            ensureCentralManager()
            guard let central else {
                continuation.resume(throwing: ScannerError.unavailable)
                return
            }

            connectionTestContinuation = continuation
            connectionTestPeripheralID = relay.peripheral.identifier
            relay.peripheral.delegate = self
            pendingPeripherals[relay.peripheral.identifier] = relay.peripheral
            pendingRSSI[relay.peripheral.identifier] = relay.rssi
            central.connect(relay.peripheral, options: nil)

            connectionTestTimeoutTask?.cancel()
            connectionTestTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
                await self?.handleConnectionTestTimeout()
            }
        }
    }

    private func ensureCentralManager() {
        if central == nil {
            central = CBCentralManager(delegate: self, queue: nil)
        }
    }

    private func updateScanningState() {
        guard shouldScan else { return }
        guard let central else {
            ensureCentralManager()
            return
        }
        guard central.state == .poweredOn else {
            state = .poweringOn
            return
        }
        state = .scanning
        central.scanForPeripherals(withServices: [relayServiceUUID], options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if #available(iOS 13.0, *) {
            switch CBCentralManager.authorization {
            case .restricted, .denied:
                state = .unauthorized
                return
            default:
                break
            }
        }

        switch central.state {
        case .poweredOn:
            updateScanningState()
        case .unauthorized:
            state = .unauthorized
        case .unsupported:
            state = .error("Bluetooth is not supported on this device.")
        case .poweredOff:
            state = .error("Bluetooth is turned off.")
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        if discovered.contains(where: { $0.peripheral.identifier == peripheral.identifier }) {
            return
        }
        pendingPeripherals[peripheral.identifier] = peripheral
        pendingRSSI[peripheral.identifier] = RSSI
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([relayServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if let error {
            state = .error("Failed to connect: \(error.localizedDescription)")
        }
        pendingPeripherals.removeValue(forKey: peripheral.identifier)
        pendingRSSI.removeValue(forKey: peripheral.identifier)
        if connectionTestPeripheralID == peripheral.identifier {
            completeConnectionTest(.failure(ScannerError.failed("Failed to connect: \(error?.localizedDescription ?? "Unknown error").")))
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            state = .error("Service discovery failed: \(error.localizedDescription)")
            central?.cancelPeripheralConnection(peripheral)
            pendingPeripherals.removeValue(forKey: peripheral.identifier)
            pendingRSSI.removeValue(forKey: peripheral.identifier)
            if connectionTestPeripheralID == peripheral.identifier {
                completeConnectionTest(.failure(ScannerError.failed("Service discovery failed: \(error.localizedDescription)")))
            }
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == relayServiceUUID }) else {
            central?.cancelPeripheralConnection(peripheral)
            pendingPeripherals.removeValue(forKey: peripheral.identifier)
            pendingRSSI.removeValue(forKey: peripheral.identifier)
            if connectionTestPeripheralID == peripheral.identifier {
                completeConnectionTest(.failure(ScannerError.failed("Relay details were not found on this device.")))
            }
            return
        }
        peripheral.discoverCharacteristics([relayPayloadCharacteristicUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            state = .error("Characteristic discovery failed: \(error.localizedDescription)")
            central?.cancelPeripheralConnection(peripheral)
            pendingPeripherals.removeValue(forKey: peripheral.identifier)
            pendingRSSI.removeValue(forKey: peripheral.identifier)
            if connectionTestPeripheralID == peripheral.identifier {
                completeConnectionTest(.failure(ScannerError.failed("Characteristic discovery failed: \(error.localizedDescription)")))
            }
            return
        }
        guard let characteristic = service.characteristics?.first(where: { $0.uuid == relayPayloadCharacteristicUUID }) else {
            central?.cancelPeripheralConnection(peripheral)
            pendingPeripherals.removeValue(forKey: peripheral.identifier)
            if connectionTestPeripheralID == peripheral.identifier {
                completeConnectionTest(.failure(ScannerError.failed("Relay characteristic was missing on this device.")))
            }
            return
        }
        peripheral.readValue(for: characteristic)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        defer {
            central?.cancelPeripheralConnection(peripheral)
            pendingPeripherals.removeValue(forKey: peripheral.identifier)
            pendingRSSI.removeValue(forKey: peripheral.identifier)
        }
        if let error {
            state = .error("Unable to read relay info: \(error.localizedDescription)")
            if connectionTestPeripheralID == peripheral.identifier {
                completeConnectionTest(.failure(ScannerError.failed("Unable to read relay info: \(error.localizedDescription)")))
            }
            return
        }
        guard let data = characteristic.value else { return }
        do {
            let payload = try decoder.decode(RelayBluetoothPayload.self, from: data)
            let entry = DiscoveredRelay(
                id: payload.id,
                payload: payload,
                peripheral: peripheral,
                rssi: pendingRSSI[peripheral.identifier] ?? NSNumber(value: 0)
            )
            if !discovered.contains(entry) {
                discovered.append(entry)
            }
            if connectionTestPeripheralID == peripheral.identifier {
                completeConnectionTest(.success(()))
            }
        } catch {
            state = .error("Received invalid relay payload.")
            if connectionTestPeripheralID == peripheral.identifier {
                completeConnectionTest(.failure(ScannerError.failed("Received invalid relay payload.")))
            }
        }
    }

    @MainActor
    private func handleConnectionTestTimeout() {
        guard let testID = connectionTestPeripheralID else { return }
        if let peripheral = pendingPeripherals[testID] {
            central?.cancelPeripheralConnection(peripheral)
        }
        pendingPeripherals.removeValue(forKey: testID)
        pendingRSSI.removeValue(forKey: testID)
        completeConnectionTest(.failure(ScannerError.timedOut))
    }

    @MainActor
    private func completeConnectionTest(_ result: Result<Void, Error>) {
        connectionTestTimeoutTask?.cancel()
        connectionTestTimeoutTask = nil
        guard let continuation = connectionTestContinuation else { return }
        connectionTestContinuation = nil
        connectionTestPeripheralID = nil
        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}
#endif
