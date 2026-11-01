import Foundation

public struct AndroidObservation {
    public let serial: String
    public let name: String?
    public let connected: Bool
    public let bootCompleted: Bool
    public init(serial: String, name: String?, connected: Bool, bootCompleted: Bool) {
        self.serial = serial; self.name = name; self.connected = connected; self.bootCompleted = bootCompleted
    }
}

/// Preserve AVD identity while adb transitions from offline to connected to booted.
public actor AndroidRegistry {
    private var namesBySerial: [String: String] = [:]
    public init() {}
    public func devices(names: [String], observations: [AndroidObservation]) -> [Device] {
        let activeSerials = Set(observations.map(\.serial))
        namesBySerial = namesBySerial.filter { activeSerials.contains($0.key) }
        var devices = names.map { Device(platform: .Android, key: $0, name: $0, state: .stopped) }
        var unresolved = false
        for observation in observations {
            if let name = observation.name { namesBySerial[observation.serial] = name }
            guard let name = observation.name ?? namesBySerial[observation.serial] else {
                // An unassociated serial is a transport endpoint, not another AVD.
                unresolved = true
                continue
            }
            let state: DeviceState = observation.connected ? (observation.bootCompleted ? .running : .starting) : .unknown
            if let index = devices.firstIndex(where: { $0.key == name && $0.serial == nil }) {
                devices[index].serial = observation.serial
                devices[index].state = state
                devices[index].detail = observation.serial
            } else {
                // Preserve genuine multiple instances and running AVDs outside -list-avds.
                let key = devices.contains(where: { $0.key == name }) ? observation.serial : name
                devices.append(Device(platform: .Android, key: key, name: name, state: state, detail: observation.serial, serial: observation.serial))
            }
        }
        if unresolved {
            for index in devices.indices where devices[index].serial == nil {
                devices[index].state = .unknown
                devices[index].detail = L10n.text("正在识别启动中的模拟器，请稍候")
            }
        }
        return devices
    }
}
