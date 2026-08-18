import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

let bundleIdentifier = "com.muses.app"

func axValue(_ element: AXUIElement, _ attribute: CFString) -> AnyObject? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
        return nil
    }
    return value
}

func axString(_ element: AXUIElement, _ attribute: CFString) -> String? {
    axValue(element, attribute) as? String
}

func axBoolean(_ element: AXUIElement, _ attribute: CFString) -> Bool? {
    (axValue(element, attribute) as? NSNumber)?.boolValue
}

func axPoint(_ element: AXUIElement, _ attribute: CFString) -> [String: CGFloat]? {
    guard let value = axValue(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else {
        return nil
    }
    var point = CGPoint.zero
    guard AXValueGetType(value as! AXValue) == .cgPoint,
          AXValueGetValue(value as! AXValue, .cgPoint, &point) else {
        return nil
    }
    return ["x": point.x, "y": point.y]
}

func axSize(_ element: AXUIElement, _ attribute: CFString) -> [String: CGFloat]? {
    guard let value = axValue(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else {
        return nil
    }
    var size = CGSize.zero
    guard AXValueGetType(value as! AXValue) == .cgSize,
          AXValueGetValue(value as! AXValue, .cgSize, &size) else {
        return nil
    }
    return ["width": size.width, "height": size.height]
}

var output: [String: Any] = [
    "timestamp": ISO8601DateFormatter().string(from: Date()),
    "bundleIdentifier": bundleIdentifier,
]

let applications = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
output["processCount"] = applications.count
output["frontmostBundleIdentifier"] = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? NSNull()

if let application = applications.first {
    let pid = application.processIdentifier
    output["application"] = [
        "pid": Int(pid),
        "active": application.isActive,
        "hidden": application.isHidden,
        "terminated": application.isTerminated,
        "activationPolicy": application.activationPolicy.rawValue,
        "finishedLaunching": application.isFinishedLaunching,
    ]

    let appElement = AXUIElementCreateApplication(pid)
    let axWindows = (axValue(appElement, kAXWindowsAttribute as CFString) as? [AXUIElement]) ?? []
    output["axWindowCount"] = axWindows.count
    output["axWindows"] = axWindows.enumerated().map { index, window -> [String: Any] in
        var item: [String: Any] = [
            "index": index,
            "title": axString(window, kAXTitleAttribute as CFString) ?? NSNull(),
            "role": axString(window, kAXRoleAttribute as CFString) ?? NSNull(),
            "subrole": axString(window, kAXSubroleAttribute as CFString) ?? NSNull(),
            "minimized": axBoolean(window, kAXMinimizedAttribute as CFString) ?? NSNull(),
            "main": axBoolean(window, kAXMainAttribute as CFString) ?? NSNull(),
            "focused": axBoolean(window, kAXFocusedAttribute as CFString) ?? NSNull(),
        ]
        item["position"] = axPoint(window, kAXPositionAttribute as CFString) ?? NSNull()
        item["size"] = axSize(window, kAXSizeAttribute as CFString) ?? NSNull()
        return item
    }

    let cgInfo = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
    let cgWindows = cgInfo.filter { dictionary in
        (dictionary[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
    }
    output["cgWindowCount"] = cgWindows.count
    output["cgWindows"] = cgWindows.map { dictionary -> [String: Any] in
        var item: [String: Any] = [
            "number": dictionary[kCGWindowNumber as String] ?? NSNull(),
            "owner": dictionary[kCGWindowOwnerName as String] ?? NSNull(),
            "name": dictionary[kCGWindowName as String] ?? NSNull(),
            "layer": dictionary[kCGWindowLayer as String] ?? NSNull(),
            "alpha": dictionary[kCGWindowAlpha as String] ?? NSNull(),
            "onscreen": dictionary[kCGWindowIsOnscreen as String] ?? false,
            "memoryBytes": dictionary[kCGWindowMemoryUsage as String] ?? NSNull(),
        ]
        if let bounds = dictionary[kCGWindowBounds as String] as? [String: Any],
           let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) {
            item["bounds"] = [
                "x": rect.origin.x,
                "y": rect.origin.y,
                "width": rect.size.width,
                "height": rect.size.height,
            ]
        }
        return item
    }
}

let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data("\n".utf8))
