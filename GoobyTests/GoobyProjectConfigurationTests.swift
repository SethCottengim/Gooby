import Foundation
import XCTest

final class GoobyProjectConfigurationTests: XCTestCase {
    func testSourceInfoPlistDeclaresAccessoryApplication() throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let workspaceRootURL = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let infoPlistURL = workspaceRootURL.appendingPathComponent("Sources/Info.plist")
        let source = try String(contentsOf: infoPlistURL, encoding: .utf8)
        let accessoryProcessDeclaration = #"<key>\s*LSUIElement\s*</key>\s*<true\s*/>"#

        XCTAssertNotNil(source.range(of: accessoryProcessDeclaration, options: .regularExpression))
    }
}
