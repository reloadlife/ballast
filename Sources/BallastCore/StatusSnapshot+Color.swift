import SwiftUI

extension StatusSnapshot.Kind {
    /// The storage bar's category colors, shared by the Overview, the menu
    /// bar item and the widget so they can't drift apart.
    public var color: Color {
        switch self {
        case .applications: .indigo
        case .yourFiles: .blue
        case .caches: .orange
        case .buildFiles: .yellow
        case .system: .gray
        }
    }
}
