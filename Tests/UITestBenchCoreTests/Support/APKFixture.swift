import Foundation
@testable import UITestBenchCore

/// 现场拼一个最小 APK：只有 AndroidManifest.xml，没有 lib/，即纯 Java/Kotlin 包。
enum APKFixture {
    static let android = AndroidManifestParser.androidNamespaceURI

    static func minimalAPK(
        package: String = "com.example.demo",
        versionCode: Int = 7,
        versionName: String = "0.7",
        minSdk: Int = 24,
        targetSdk: Int = 34,
        launcherActivity: String? = nil,
        extraEntries: [String: Data] = [:]
    ) -> Data {
        var children: [AXmlFixtureBuilder.Node] = [
            .element(
                name: "uses-sdk",
                attributes: [
                    .integer("minSdkVersion", Int32(minSdk), namespace: android),
                    .integer("targetSdkVersion", Int32(targetSdk), namespace: android)
                ],
                children: []
            )
        ]
        if let launcherActivity {
            children.append(
                .element(
                    name: "application",
                    attributes: [],
                    children: [
                        .element(
                            name: "activity",
                            attributes: [.string("name", launcherActivity, namespace: android)],
                            children: [
                                .element(
                                    name: "intent-filter",
                                    attributes: [],
                                    children: [
                                        .element(
                                            name: "action",
                                            attributes: [.string(
                                                "name",
                                                "android.intent.action.MAIN",
                                                namespace: android
                                            )],
                                            children: []
                                        ),
                                        .element(
                                            name: "category",
                                            attributes: [.string(
                                                "name",
                                                "android.intent.category.LAUNCHER",
                                                namespace: android
                                            )],
                                            children: []
                                        )
                                    ]
                                )
                            ]
                        )
                    ]
                )
            )
        }

        let manifest = AXmlFixtureBuilder(
            root: .element(
                name: "manifest",
                attributes: [
                    .string("package", package),
                    .integer("versionCode", Int32(versionCode), namespace: android),
                    .string("versionName", versionName, namespace: android)
                ],
                children: children
            )
        ).build()

        var zip = ZipFixtureBuilder().addingStoredEntry(path: "AndroidManifest.xml", contents: manifest)
        for (path, contents) in extraEntries.sorted(by: { $0.key < $1.key }) {
            zip = zip.addingStoredEntry(path: path, contents: contents)
        }
        return zip.build()
    }
}
