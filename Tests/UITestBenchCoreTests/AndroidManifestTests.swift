import XCTest
@testable import UITestBenchCore

final class AndroidManifestTests: XCTestCase {
    private let android = "http://schemas.android.com/apk/res/android"

    func testExtractsPackageSdkVersionsLabelAndLauncherActivity() throws {
        let xml = AXmlFixtureBuilder(
            root: .element(
                name: "manifest",
                attributes: [
                    .string("package", "com.example.demo"),
                    .integer("versionCode", 42, namespace: android),
                    .string("versionName", "1.2.3", namespace: android)
                ],
                children: [
                    .element(
                        name: "uses-sdk",
                        attributes: [
                            .integer("minSdkVersion", 21, namespace: android),
                            .integer("targetSdkVersion", 34, namespace: android)
                        ],
                        children: []
                    ),
                    .element(
                        name: "application",
                        attributes: [
                            .string("label", "示例应用", namespace: android)
                        ],
                        children: [
                            .element(
                                name: "activity",
                                attributes: [
                                    .string("name", ".MainActivity", namespace: android)
                                ],
                                children: [
                                    .element(
                                        name: "intent-filter",
                                        attributes: [],
                                        children: [
                                            .element(
                                                name: "action",
                                                attributes: [
                                                    .string("name", "android.intent.action.MAIN", namespace: android)
                                                ],
                                                children: []
                                            ),
                                            .element(
                                                name: "category",
                                                attributes: [
                                                    .string("name", "android.intent.category.LAUNCHER", namespace: android)
                                                ],
                                                children: []
                                            )
                                        ]
                                    )
                                ]
                            )
                        ]
                    )
                ]
            )
        ).build()

        let manifest = try AndroidManifestParser.parse(xml)

        XCTAssertEqual(manifest.packageName, "com.example.demo")
        XCTAssertEqual(manifest.versionCode, 42)
        XCTAssertEqual(manifest.versionName, "1.2.3")
        XCTAssertEqual(manifest.minSdkVersion, 21)
        XCTAssertEqual(manifest.targetSdkVersion, 34)
        XCTAssertEqual(manifest.applicationLabel, "示例应用")
        XCTAssertEqual(manifest.launcherActivityName, ".MainActivity")
    }
}
