import SwiftUI

/// Inter-item spacing in the horizontal tray. Avatar size is constant —
/// only the gap moves — so the ring signature stays stable.
enum TrayDensity: Sendable, CaseIterable {
    case compact
    case regular
    case comfy

    var itemSpacing: CGFloat {
        switch self {
        case .compact: return 10
        case .regular: return 14
        case .comfy:   return 18
        }
    }
}

private struct TrayDensityKey: EnvironmentKey {
    static let defaultValue: TrayDensity = .regular
}

extension EnvironmentValues {
    var trayDensity: TrayDensity {
        get { self[TrayDensityKey.self] }
        set { self[TrayDensityKey.self] = newValue }
    }
}
