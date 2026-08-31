import XCTest
@testable import OpenWorkSwift

final class SmokeTests: XCTestCase {

    func testNavigationDestinationCaseCountAndOrder() {
        let expected: [NavigationDestination] = [
            .chat, .localModels, .agents, .providers, .automations,
            .watchFolders, .artifacts, .memory, .tools, .dashboard, .settings
        ]
        XCTAssertEqual(NavigationDestination.allCases.count, 11, "NavigationDestination should have exactly 11 cases")
        XCTAssertEqual(NavigationDestination.allCases, expected, "NavigationDestination cases should match expected order")
    }

    func testInspectorTabCaseCountAndOrder() {
        let expected: [InspectorTab] = [
            .subagents, .comms, .artifacts, .tools, .terminal
        ]
        XCTAssertEqual(InspectorTab.allCases.count, 5, "InspectorTab should have exactly 5 cases")
        XCTAssertEqual(InspectorTab.allCases, expected, "InspectorTab cases should match expected order")
    }

    func testNavigationDestinationDisplayNamesNonEmpty() {
        for destination in NavigationDestination.allCases {
            XCTAssertFalse(destination.displayName.isEmpty, "NavigationDestination.\(destination.rawValue).displayName should be non-empty")
        }
    }

    func testNavigationDestinationIconsNonEmpty() {
        for destination in NavigationDestination.allCases {
            XCTAssertFalse(destination.icon.isEmpty, "NavigationDestination.\(destination.rawValue).icon should be non-empty")
        }
    }
}
