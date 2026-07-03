import Foundation

public struct HarnessWorkbenchLayoutState: Codable, Sendable, Equatable {
    public static let sidebarWidth: Double = 260
    public static let inspectorWidth: Double = 420
    public static let transcriptMinimumWidth: Double = 560

    public var isSidebarVisible: Bool
    public var isInspectorVisible: Bool

    public init(
        isSidebarVisible: Bool = true,
        isInspectorVisible: Bool = true
    ) {
        self.isSidebarVisible = isSidebarVisible
        self.isInspectorVisible = isInspectorVisible
    }

    public var minimumWindowWidth: Double {
        Self.transcriptMinimumWidth
        + (isSidebarVisible ? Self.sidebarWidth : 0)
        + (isInspectorVisible ? Self.inspectorWidth : 0)
    }

    public mutating func toggleSidebar() {
        isSidebarVisible.toggle()
    }

    public mutating func toggleInspector() {
        isInspectorVisible.toggle()
    }
}
