import Foundation

/// 从 AndroidManifest.xml 里取出的、本工具关心的那部分信息。
public struct AndroidManifest: Equatable {
    public let packageName: String?
    public let versionCode: Int?
    public let versionName: String?
    public let minSdkVersion: Int?
    public let targetSdkVersion: Int?
    /// 只有字面量才给值；资源引用（@string/…）不猜，留 nil。
    public let applicationLabel: String?
    public let launcherActivityName: String?

    public init(
        packageName: String?,
        versionCode: Int?,
        versionName: String?,
        minSdkVersion: Int?,
        targetSdkVersion: Int?,
        applicationLabel: String?,
        launcherActivityName: String?
    ) {
        self.packageName = packageName
        self.versionCode = versionCode
        self.versionName = versionName
        self.minSdkVersion = minSdkVersion
        self.targetSdkVersion = targetSdkVersion
        self.applicationLabel = applicationLabel
        self.launcherActivityName = launcherActivityName
    }
}

public enum AndroidManifestParser {
    public static let androidNamespaceURI = "http://schemas.android.com/apk/res/android"

    public static func parse(_ xmlData: Data) throws -> AndroidManifest {
        let root = try AXmlParser.parse(xmlData).root
        let application = root.child(named: "application")
        let usesSdk = root.child(named: "uses-sdk")

        return AndroidManifest(
            packageName: stringValue(root.attribute(named: "package")),
            versionCode: intValue(root.attribute(named: "versionCode", namespaceURI: androidNamespaceURI)),
            versionName: stringValue(root.attribute(named: "versionName", namespaceURI: androidNamespaceURI)),
            minSdkVersion: intValue(usesSdk?.attribute(named: "minSdkVersion", namespaceURI: androidNamespaceURI)),
            targetSdkVersion: intValue(usesSdk?.attribute(named: "targetSdkVersion", namespaceURI: androidNamespaceURI)),
            applicationLabel: application.flatMap {
                stringValue($0.attribute(named: "label", namespaceURI: androidNamespaceURI))
            },
            launcherActivityName: application.flatMap(launcherActivity(in:))
        )
    }

    private static func launcherActivity(in application: AXmlElement) -> String? {
        for activity in application.children where activity.name == "activity" || activity.name == "activity-alias" {
            let launches = activity.children
                .filter { $0.name == "intent-filter" }
                .contains { filter in
                    let hasMain = filter.children.contains {
                        $0.name == "action" && androidName(of: $0) == "android.intent.action.MAIN"
                    }
                    let hasLauncher = filter.children.contains {
                        $0.name == "category" && androidName(of: $0) == "android.intent.category.LAUNCHER"
                    }
                    return hasMain && hasLauncher
                }

            if launches {
                return stringValue(activity.attribute(named: "name", namespaceURI: androidNamespaceURI))
                    ?? (activity.name == "activity-alias"
                        ? stringValue(activity.attribute(named: "targetActivity", namespaceURI: androidNamespaceURI))
                        : nil)
            }
        }
        return nil
    }

    private static func androidName(of element: AXmlElement) -> String? {
        stringValue(element.attribute(named: "name", namespaceURI: androidNamespaceURI))
    }

    private static func stringValue(_ attribute: AXmlAttribute?) -> String? {
        guard case let .string(value)? = attribute?.value else { return nil }
        return value
    }

    private static func intValue(_ attribute: AXmlAttribute?) -> Int? {
        switch attribute?.value {
        case let .integer(value)?: return Int(value)
        default: return nil
        }
    }
}
