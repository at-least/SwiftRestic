import Foundation
import IOKit.ps

/// Whether the Mac is running on battery, used to honour "pause on battery".
enum PowerState {
    static var isOnBattery: Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return false }
        guard let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return false
        }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            if let state = description[kIOPSPowerSourceStateKey] as? String {
                return state == kIOPSBatteryPowerValue
            }
        }
        return false
    }
}
