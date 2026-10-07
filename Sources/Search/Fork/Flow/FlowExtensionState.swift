import Foundation

/// Chrome's on/off flags have changed shape across versions.
enum FlowExtensionState {
    static func enabled(_ entry: [String: Any]) -> Bool {
        if let reasons = entry["disable_reasons"] as? [Any], !reasons.isEmpty { return false }
        if let reasons = entry["disable_reasons"] as? Int, reasons != 0 { return false }
        if let state = entry["state"] as? Int { return state == 1 }
        return true
    }
}
