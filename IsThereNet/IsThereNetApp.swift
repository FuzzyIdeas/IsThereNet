//
//  IsThereNetApp.swift
//  IsThereNet
//
//  Created by Alin Panaitiu on 03.01.2024.
//

import AppKit
import Cocoa
import Combine
import Foundation
import Network
import os.log
import ServiceManagement
import SwiftUI

let FPING = Bundle.main.path(forResource: "fping", ofType: nil)!
let LOG_PATH = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("IsThereNet.log")
let LOG_FILE: FileHandle? = {
    guard FileManager.default.fileExists(atPath: LOG_PATH.path) || FileManager.default.createFile(atPath: LOG_PATH.path, contents: nil, attributes: nil) else {
        print("Failed to create log file")
        return nil
    }
    guard let file = try? FileHandle(forUpdating: LOG_PATH) else {
        print("Failed to open log file")
        return nil
    }
    print("Logging to \(LOG_PATH.path)")
    return file
}()

private var window: NSWindow = {
    let w = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: NSScreen.main!.frame.width, height: 20),
        styleMask: [.fullSizeContentView, .borderless],
        backing: .buffered,
        defer: false
    )
    w.backgroundColor = .clear
    w.level = NSWindow.Level(Int(CGShieldingWindowLevel()))

    w.isOpaque = false
    w.hasShadow = false
    w.hidesOnDeactivate = false
    w.ignoresMouseEvents = true
    w.isReleasedWhenClosed = false
    w.isMovableByWindowBackground = false

    w.sharingType = .none
    w.setAccessibilityRole(.popover)
    w.setAccessibilitySubrole(.unknown)

    w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenDisallowsTiling]
    w.alphaValue = 0.0

    return w
}()
private var windowController = NSWindowController(window: window)
private var fader: DispatchWorkItem? { didSet { oldValue?.cancel() } }
private var closer: DispatchWorkItem? { didSet { oldValue?.cancel() } }

private func mainAsyncAfter(_ duration: TimeInterval, _ action: @escaping () -> Void) -> DispatchWorkItem {
    let workItem = DispatchWorkItem { action() }
    DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: workItem)

    return workItem
}

private func drawColoredTopLine(_ color: NSColor, hideAfter: TimeInterval = 5) {
    DispatchQueue.main.async {
        lastColor = color
        lastHideAfter = hideAfter
        fader?.cancel()
        closer?.cancel()

        let box = NSBox()
        box.boxType = .custom
        box.fillColor = color
        box.frame = NSRect(x: 0, y: 10, width: NSScreen.main!.frame.width + 10, height: 3)

        box.shadow = NSShadow()
        box.shadow!.shadowColor = color
        box.shadow!.shadowBlurRadius = 3
        box.shadow!.shadowOffset = .init(width: 0, height: -2)

        let containerView = NSView()
        containerView.frame = NSRect(x: 0, y: 0, width: NSScreen.main!.frame.width + 10, height: 20)
        containerView.addSubview(box)

        window.setContentSize(NSSize(width: NSScreen.main!.frame.width, height: 20))
        window.contentView = containerView
        window.setFrameOrigin(NSPoint(x: NSScreen.main!.frame.minX - 5, y: NSScreen.main!.frame.maxY - 12))

        windowController.showWindow(nil)
        window.fade(to: 1.0) {
            guard let appearance = menubarIcon?.button?.effectiveAppearance, appearance.isDark else {
                return
            }
            window.fade(to: 0.7)
        }

        guard hideAfter > 0 else { return }

        fader = mainAsyncAfter(hideAfter) {
            window.fade(to: 0.01, duration: 2.0)

            closer = mainAsyncAfter(2.0) {
                window.alphaValue = 0.0
                lastColor = nil
                lastHideAfter = nil
            }
        }
    }
}

extension NSWindow {
    func fade(to alpha: CGFloat, duration: TimeInterval = 1.0, then: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = alpha
        } completionHandler: { then?() }
    }
}

extension NSAppearance {
    var isDark: Bool { name == .vibrantDark || name == .darkAqua }
}

private enum PingStatus: Equatable {
    case reachable(Double)
    case timedOut
    case slow(Double)

    var color: NSColor {
        switch self {
        case .reachable: .systemGreen
        case .timedOut: .systemRed
        case .slow: .systemYellow
        }
    }

    var hideAfter: TimeInterval {
        switch self {
        case .reachable: 5
        case .timedOut: 0
        case .slow: 10
        }
    }

    var message: String {
        switch self {
        case let .reachable(time): "OK (\(time) ms)"
        case .timedOut: "TIMEOUT"
        case let .slow(time): "SLOW (\(time) ms)"
        }
    }

    static func == (lhs: PingStatus, rhs: PingStatus) -> Bool {
        switch (lhs, rhs) {
        case (.reachable, .reachable): true
        case (.timedOut, .timedOut): true
        case (.slow, .slow): true
        default: false
        }
    }

}

private var menubarIcon: NSStatusItem?
private var lastColor: NSColor?
private var lastHideAfter: TimeInterval?
private var lastStatus: NWPath.Status?
private var lastPingStatus: PingStatus? {
    didSet {
        guard let lastPingStatus, lastPingStatus != oldValue else { return }

        drawColoredTopLine(lastPingStatus.color, hideAfter: lastPingStatus.hideAfter)
        log("Internet connection: \(lastPingStatus.message)")
    }
}

private var monitor: NWPathMonitor?
private var process: Process? {
    didSet {
        oldValue?.terminate()
        lastPingStatus = nil
    }
}
private var observers: [AnyCancellable] = []
private let dateFormatter: DateFormatter = {
    let d = DateFormatter()
    d.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
    return d
}()

private func log(_ message: String) {
    let line = "\(dateFormatter.string(from: Date())) \(message)"

    print(line)
    os_log("%{public}@", message)

    guard let LOG_FILE else {
        return
    }
    LOG_FILE.seekToEndOfFile()
    LOG_FILE.write("\(line)\n".data(using: .utf8)!)
}

func start() {
    NotificationCenter.default.publisher(for: NSApplication.didFinishLaunchingNotification)
        .sink { _ in
            menubarIcon = NSStatusBar.system.statusItem(withLength: 1)
            menubarIcon!.isVisible = false
        }
        .store(in: &observers)
    NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
        .sink { _ in
            process?.terminate()
        }
        .store(in: &observers)
    NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
        .throttle(for: 0.5, scheduler: DispatchQueue.main, latest: true)
        .sink { _ in
            guard let color = lastColor, let hideAfter = lastHideAfter else {
                return
            }
            drawColoredTopLine(color, hideAfter: hideAfter)
        }
        .store(in: &observers)

    monitor = NWPathMonitor()
    monitor!.pathUpdateHandler = { path in
        guard path.status != lastStatus else {
            return
        }
        lastStatus = path.status

        switch path.status {
        case .satisfied, .requiresConnection:
            log("Internet connection: CHECKING")
            startPingMonitor()
        case .unsatisfied:
            log("Internet connection: OFF")
            DispatchQueue.main.async {
                process = nil
                pingRestartTask = nil
            }
            drawColoredTopLine(.systemRed, hideAfter: 0)
        @unknown default:
            log("Internet connection: \(path.status)")
        }
    }
    monitor!.start(queue: DispatchQueue.global())

    #if !DEBUG
        if #available(macOS 13, *), SMAppService.mainApp.status == .notRegistered || SMAppService.mainApp.status == .notFound {
            try? SMAppService.mainApp.register()
        }
    #endif
}

let MS_REGEX_PATTERN: NSRegularExpression = try! NSRegularExpression(pattern: "([0-9.]+) ms", options: [])

func startPingMonitor() {
    DispatchQueue.main.async {
        pingRestartTask = nil

        process = Process()
        process!.launchPath = FPING
        process!.arguments = ["--loop", "--size", "12", "--timeout", "1000", "--interval", "5000", "1.1.1.1"]
        process!.qualityOfService = .userInteractive

        let pipe = Pipe()
        process!.standardOutput = pipe
        pipe.fileHandleForReading.readabilityHandler = { fh in
            guard let line = String(data: fh.availableData, encoding: .utf8), !line.isEmpty else {
                fh.readabilityHandler = nil
                DispatchQueue.main.async { process = nil }
                pingRestartTask = mainAsyncAfter(5) { startPingMonitor() }
                return
            }
            #if DEBUG
                print(line)
            #endif

            /*
                 * fping output:
                 * REACHABLE: `1.1.1.1 : [0], 20 bytes, 7.66 ms (7.66 avg, 0% loss)`
                 * TIMEOUT: `1.1.1.1 : [0], timed out (NaN avg, 100% loss)`
                 * SLOW: `1.1.1.1 : [0], 20 bytes, 127.66 ms (127.66 avg, 0% loss)`
             */

            if line.contains("timed out") {
                fastCounter = MAX_COUNTS
                slowCounter = MAX_COUNTS

                if timeoutCounter == 0 {
                    timeoutCounter = MAX_COUNTS
                    lastPingStatus = .timedOut
                } else {
                    timeoutCounter -= 1
                }

            } else if let match = MS_REGEX_PATTERN.firstMatch(in: line, options: [], range: NSRange(location: 0, length: line.count)), let ms = Double((line as NSString).substring(with: match.range(at: 1))) {
                guard let status = lastPingStatus, status != .timedOut else {
                    slowCounter = MAX_COUNTS
                    fastCounter = MAX_COUNTS
                    timeoutCounter = MAX_COUNTS
                    lastPingStatus = ms > 300 ? .slow(ms) : .reachable(ms)
                    return
                }

                if ms > 160 {
                    fastCounter = MAX_COUNTS
                    timeoutCounter = MAX_COUNTS

                    if slowCounter == 0 {
                        slowCounter = MAX_COUNTS
                        lastPingStatus = .slow(ms)
                    } else {
                        slowCounter -= 1
                    }

                } else if lastPingStatus == .slow(ms) {
                    guard ms < 80 else { return }
                    slowCounter = MAX_COUNTS
                    timeoutCounter = MAX_COUNTS

                    if fastCounter == 0 {
                        fastCounter = MAX_COUNTS
                        lastPingStatus = .reachable(ms)
                    } else {
                        fastCounter -= 1
                    }

                } else {
                    slowCounter = MAX_COUNTS
                    fastCounter = MAX_COUNTS
                    timeoutCounter = MAX_COUNTS
                    lastPingStatus = .reachable(ms)
                }
            }
        }

        process!.launch()
    }
}

private let MAX_COUNTS = 2

private var slowCounter = MAX_COUNTS
private var timeoutCounter = MAX_COUNTS
private var fastCounter = MAX_COUNTS
private var pingRestartTask: DispatchWorkItem? {
    didSet {
        oldValue?.cancel()
    }
}

@main
struct IsThereNetApp: App {
    init() { start() }

    var body: some Scene { Settings { EmptyView() }}
}
