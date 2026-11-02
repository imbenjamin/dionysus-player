// duo-pose-ax: presses Device Hub's pose buttons for an iPhone Duo Simulator
// through the macOS Accessibility API. set-duo-pose.sh builds and calls it;
// run it directly only to debug.
//
//   duo-pose-ax trust
//   duo-pose-ax buttons <DeviceHub pid> <simulator UDID> [<simulator name>]
//   duo-pose-ax press   <DeviceHub pid> <simulator UDID> <button label> [<simulator name>]
//
// Every command prints one JSON object on stdout. Exit codes: 0 done, 1 not
// found or the press failed, 2 usage, 3 this process isn't trusted for
// Accessibility, 5 no Device Hub window shows this simulator.
//
// Xcode 27.1 has no pose command (simctl, devicectl and XCUIDevice have
// none), so Device Hub's buttons are the only way to fold the Simulator.
// The trust check never prompts (kAXTrustedCheckOptionPrompt = false).
//
// A trimmed copy of duo-pose-ax.swift from Duology 0.3.0
// (https://github.com/Kimeur/duology): `readout` removed. Its licence:
//
// MIT License
//
// Copyright (c) 2026 Gazouzi Marouane
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import ApplicationServices
import Foundation

let poseLabels = ["Closed", "Partially Open", "Open"]
let knownLabels = poseLabels + ["Rotate Right", "Rotate Left"]

func emit(_ object: [String: Any], exitCode: Int32) -> Never {
    if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
       let text = String(data: data, encoding: .utf8) {
        print(text)
    }
    exit(exitCode)
}

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func text(_ element: AXUIElement, _ name: String) -> String {
    guard let value = attribute(element, name) else { return "" }
    if let string = value as? String { return string }
    if let number = value as? NSNumber { return number.stringValue }
    return ""
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
}

/// Depth-first walk. `visit` returns true to stop.
@discardableResult
func walk(_ element: AXUIElement, depth: Int = 0, maxDepth: Int = 40,
          _ visit: (AXUIElement, Int) -> Bool) -> Bool {
    if visit(element, depth) { return true }
    guard depth < maxDepth else { return false }
    for child in children(element) where walk(child, depth: depth + 1, maxDepth: maxDepth, visit) {
        return true
    }
    return false
}

/// The Device Hub window showing the simulator: the one whose sidebar row for
/// this UDID is selected, or else one whose title starts with the simulator's
/// name. A window with another device's row selected never matches.
func matchWindow(app: AXUIElement, udid: String, name: String?) -> (AXUIElement, String)? {
    let wanted = "TableRow.Device.\(udid)"
    var byTitle: AXUIElement?
    for window in attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
        var selectedRowIDs: [String] = []
        walk(window, maxDepth: 14) { element, _ in
            guard text(element, kAXRoleAttribute) == "AXRow",
                  text(element, kAXSelectedAttribute) == "1" else { return false }
            walk(element, maxDepth: 4) { inner, _ in
                let id = text(inner, kAXIdentifierAttribute)
                if id.hasPrefix("TableRow.Device.") { selectedRowIDs.append(id); return true }
                return false
            }
            return false
        }
        if selectedRowIDs.contains(wanted) { return (window, "selected-row") }
        if !selectedRowIDs.isEmpty { continue }
        if let name, !name.isEmpty, text(window, kAXTitleAttribute).hasPrefix(name), byTitle == nil {
            byTitle = window
        }
    }
    return byTitle.map { ($0, "title") }
}

/// Device Hub's own pose buttons carry the same text as description and help;
/// buttons mirrored from the app on screen don't, so an app button labelled
/// "Open" is never pressed. Prefers the group holding all three pose buttons.
func findButtons(in window: AXUIElement) -> [String: AXUIElement] {
    func isDeviceHubButton(_ element: AXUIElement) -> String? {
        guard text(element, kAXRoleAttribute) == "AXButton" else { return nil }
        let label = text(element, kAXDescriptionAttribute)
        guard knownLabels.contains(label), text(element, kAXHelpAttribute) == label else { return nil }
        return label
    }
    var found: [String: AXUIElement] = [:]
    walk(window) { element, _ in
        var group: [String: AXUIElement] = [:]
        for kid in children(element) { if let label = isDeviceHubButton(kid) { group[label] = kid } }
        if poseLabels.allSatisfy({ group[$0] != nil }) { found = group; return true }
        return false
    }
    if found.isEmpty {
        walk(window) { element, _ in
            if let label = isDeviceHubButton(element), found[label] == nil { found[label] = element }
            return false
        }
    }
    return found
}

/// Device Hub's other button labels, to show what changed when the pose
/// buttons can't be found (after an Xcode update, say).
func otherButtonLabels(in window: AXUIElement) -> [String] {
    var labels: [String] = []
    walk(window) { element, _ in
        if text(element, kAXRoleAttribute) == "AXButton", !text(element, kAXHelpAttribute).isEmpty {
            let label = text(element, kAXDescriptionAttribute)
            if !label.isEmpty, !labels.contains(label) { labels.append(label) }
        }
        return labels.count >= 40
    }
    return labels
}

// MARK: - Main

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    emit(["error": "usage: duo-pose-ax trust | buttons | press"], exitCode: 2)
}

let noPrompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
let trusted = AXIsProcessTrustedWithOptions(noPrompt)
if command == "trust" { emit(["trusted": trusted], exitCode: 0) }
guard trusted else { emit(["trusted": false, "error": "not trusted for Accessibility"], exitCode: 3) }

let needed = ["buttons": 3, "press": 4][command]
guard let needed, args.count >= needed, let pid = Int32(args[1]), pid > 0 else {
    emit(["error": "usage: duo-pose-ax \(command) <pid> <udid> ..."], exitCode: 2)
}
let udid = args[2]
let name: String? = args.count > needed ? args[needed] : nil
let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 5)

guard let (window, match) = matchWindow(app: app, udid: udid, name: name) else {
    let titles = (attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []).map { text($0, kAXTitleAttribute) }
    emit(["trusted": true, "window": NSNull(), "windows": titles,
          "error": "no Device Hub window shows this simulator"], exitCode: 5)
}
let windowTitle = text(window, kAXTitleAttribute)
let buttons = findButtons(in: window)

switch command {
case "buttons":
    let list = knownLabels.compactMap { label -> [String: Any]? in
        guard let button = buttons[label] else { return nil }
        return ["label": label, "enabled": text(button, kAXEnabledAttribute) != "0"]
    }
    var out: [String: Any] = ["trusted": true, "window": windowTitle, "match": match, "buttons": list]
    if buttons.isEmpty { out["otherButtons"] = otherButtonLabels(in: window) }
    emit(out, exitCode: buttons.isEmpty ? 1 : 0)

case "press":
    let label = args[3]
    guard let button = buttons[label] else {
        emit(["trusted": true, "window": windowTitle, "match": match, "pressed": false,
              "error": "no \(label) button in Device Hub"], exitCode: 1)
    }
    let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
    emit(["trusted": true, "window": windowTitle, "match": match, "label": label,
          "pressed": result == .success, "axError": Int(result.rawValue)],
         exitCode: result == .success ? 0 : 1)

default:
    emit(["error": "unknown command \(command)"], exitCode: 2)
}
