import Foundation
import IOKit.ps

/// Whether the Mac is running on battery, used to honour "pause on battery".
enum PowerState {
    static var isOnBattery: Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return false }
        guard let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return false
        }
        // Any battery-powered source answers for the whole machine: a Mac
        // with a UPS can list both, and the first source carrying a state
        // may be the AC one while the battery discharges.
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            if let state = description[kIOPSPowerSourceStateKey] as? String,
               state == kIOPSBatteryPowerValue
            {
                return true
            }
        }
        return false
    }
}
