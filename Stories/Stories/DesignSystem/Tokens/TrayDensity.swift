import SwiftUI

/// Inter-item spacing in the horizontal tray. Avatar size stays 64pt
/// across densities — only the gap between items moves — so the ring
/// signature is constant and the user perception of "this is a stories
/// tray" never wobbles.
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
