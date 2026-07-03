import Foundation

public struct HarnessWorkbenchLayoutState: Codable, Sendable, Equatable {
    public static let defaultSidebarWidth: Double = 260
    public static let minimumSidebarWidth: Double = 220
    public static let maximumSidebarWidth: Double = 300
    public static let defaultInspectorWidth: Double = 420
    public static let minimumInspectorWidth: Double = 360
    public static let maximumInspectorWidth: Double = 460
    public static let transcriptMinimumWidth: Double = 560
    public static let resizeHandleWidth: Double = 8
    public static let dividerWidth: Double = 1

    public var isSidebarVisible: Bool
    public var isInspectorVisible: Bool
    public var sidebarWidth: Double
    public var inspectorWidth: Double

    public init(
        isSidebarVisible: Bool = true,
        isInspectorVisible: Bool = true,
        sidebarWidth: Double = Self.defaultSidebarWidth,
        inspectorWidth: Double = Self.defaultInspectorWidth
    ) {
        self.isSidebarVisible = isSidebarVisible
        self.isInspectorVisible = isInspectorVisible
        self.sidebarWidth = Self.clampedSidebarWidth(sidebarWidth)
        self.inspectorWidth = Self.clampedInspectorWidth(inspectorWidth)
    }

    public var minimumWindowWidth: Double {
        Self.transcriptMinimumWidth
        + (isSidebarVisible ? sidebarWidth : 0)
        + (isInspectorVisible ? inspectorWidth : 0)
        + (visiblePanelCount * (Self.resizeHandleWidth + Self.dividerWidth))
    }

    private var visiblePanelCount: Double {
        Double((isSidebarVisible ? 1 : 0) + (isInspectorVisible ? 1 : 0))
    }

    public mutating func toggleSidebar() {
        isSidebarVisible.toggle()
    }

    public mutating func toggleInspector() {
        isInspectorVisible.toggle()
    }

    public mutating func resizeSidebar(to width: Double) {
        sidebarWidth = Self.clampedSidebarWidth(width)
    }

    public mutating func resizeInspector(to width: Double) {
        inspectorWidth = Self.clampedInspectorWidth(width)
    }

    public static func clampedSidebarWidth(_ width: Double) -> Double {
        min(max(width, minimumSidebarWidth), maximumSidebarWidth)
    }

    public static func clampedInspectorWidth(_ width: Double) -> Double {
        min(max(width, minimumInspectorWidth), maximumInspectorWidth)
    }
}
