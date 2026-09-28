import Foundation

extension Int64 {
    /// "412 GB", "8.4 GB", "1.2 TB", "640 MB": whole gigabytes once there
    /// are ten, for places too small for the Overview's "412.35 GB" (the
    /// menu bar, the widget's secondary figures).
    public var compactBytes: String {
        let gb = Double(self) / 1e9
        if gb >= 1000 { return (gb / 1000).formatted(.number.precision(.fractionLength(1))) + " TB" }
        if gb < 1 { return (gb * 1000).formatted(.number.precision(.fractionLength(0))) + " MB" }
        return gb.formatted(.number.precision(.fractionLength(gb < 10 ? 1 : 0))) + " GB"
    }
}
