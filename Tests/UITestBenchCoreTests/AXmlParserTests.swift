import XCTest
@testable import UITestBenchCore

final class AXmlParserTests: XCTestCase {
    func testReadsRootElementNameAndPackageAttribute() throws {
        let document = AXmlFixtureBuilder(
            root: .element(
                name: "manifest",
                attributes: [.string("package", "com.example.demo")],
                children: []
            )
        ).build()

        let parsed = try AXmlParser.parse(document)

        XCTAssertEqual(parsed.root.name, "manifest")
        XCTAssertEqual(parsed.root.attributes.count, 1)
        XCTAssertEqual(parsed.root.attributes[0].name, "package")
        XCTAssertEqual(parsed.root.attributes[0].value, .string("com.example.demo"))
    }
}
