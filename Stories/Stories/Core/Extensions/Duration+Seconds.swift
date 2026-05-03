import Foundation

extension Duration {

    var seconds: Double {
        let (s, attoseconds) = components
        return Double(s) + Double(attoseconds) / 1e18
    }

    static func / (lhs: Duration, rhs: Duration) -> Double {
        lhs.seconds / rhs.seconds
    }
}
