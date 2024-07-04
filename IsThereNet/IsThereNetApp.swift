//
//  IsThereNetApp.swift
//  IsThereNet
//
//  Created by Alin Panaitiu on 03.01.2024.
//

import AppKit
import Cocoa
import ColorCode
import Combine
import Foundation
import Intents
import Network
import os.log
import ServiceManagement
import SwiftUI

private func mainAsyncAfter(_ duration: TimeInterval, _ action: @escaping () -> Void) -> DispatchWorkItem {
    let workItem = DispatchWorkItem { action() }
    DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: workItem)

    return workItem
}

private func drawColoredTopLine(_ color: NSColor, hideAfter: TimeInterval = 5, sound: NSSound? = nil) {
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

        sound?.playIfNotDND()

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

@available(macOS 12.0, *)
var focused: Bool {
    guard INFocusStatusCenter.default.authorizationStatus == .authorized else {
        INFocusStatusCenter.default.requestAuthorization { status in
            log("Focus Status: \(status)")
        }
        return false
    }

    return INFocusStatusCenter.default.focusStatus.isFocused ?? false
}

private enum PingStatus: Equatable {
    case reachable(Double)
    case timedOut
    case slow(Double)

    var color: NSColor {
        switch self {
        case .reachable: CONFIG.colors?.connectedColor ?? .systemGreen
        case .timedOut: CONFIG.colors?.disconnectedColor ?? .systemRed
        case .slow: CONFIG.colors?.slowColor ?? .systemYellow
        }
    }

    var sound: NSSound? {
        switch self {
        case .reachable: CONFIG.sounds?.connectedSound
        case .timedOut: CONFIG.sounds?.disconnectedSound
        case .slow: CONFIG.sounds?.slowSound
        }
    }

    var hideAfter: TimeInterval {
        switch self {
        case .reachable: CONFIG.fadeSeconds?.connected ?? 5
        case .timedOut: CONFIG.fadeSeconds?.disconnected ?? 0
        case .slow: CONFIG.fadeSeconds?.slow ?? 10
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

        drawColoredTopLine(lastPingStatus.color, hideAfter: lastPingStatus.hideAfter, sound: lastPingStatus.sound)
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
            if let stream = CONFIG_FS_WATCHER {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                CONFIG_FS_WATCHER = nil
            }
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
            drawColoredTopLine(PingStatus.timedOut.color, hideAfter: PingStatus.timedOut.hideAfter, sound: PingStatus.timedOut.sound)
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

func startPingMonitor() {
    DispatchQueue.main.async {
        pingRestartTask = nil

        process = Process()
        process!.launchPath = FPING
        process!.arguments = ["--loop", "--size", "12", "--timeout", "\(CONFIG.pingTimeoutSeconds.ms)", "--interval", "\(CONFIG.pingIntervalSeconds.ms)", CONFIG.pingIP]
        process!.qualityOfService = .userInteractive

        let pipe = Pipe()
        process!.standardOutput = pipe
        pipe.fileHandleForReading.readabilityHandler = { fh in
            guard let line = String(data: fh.availableData, encoding: .utf8), !line.isEmpty else {
                fh.readabilityHandler = nil
                DispatchQueue.main.async {
                    process = nil
                    pingRestartTask = mainAsyncAfter(5) { startPingMonitor() }
                }
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
                    lastPingStatus = (CONFIG.pingSlowThresholdMilliseconds > 0 && ms > CONFIG.pingSlowThresholdMilliseconds) ? .slow(ms) : .reachable(ms)
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

// MARK: Constants

private let MS_REGEX_PATTERN: NSRegularExpression = try! NSRegularExpression(pattern: "([0-9.]+) ms", options: [])
private let MAX_COUNTS = 2
private let FPING = Bundle.main.path(forResource: "fping", ofType: nil)!
private let LOG_PATH = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("IsThereNet.log")
private let LOG_FILE: FileHandle? = {
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
private let CONFIG_PATH = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("config.json")

let SONOMA_TO_ORIGINAL_SOUND_NAMES = [
    "Mezzo": "Basso",
    "Breeze": "Blow",
    "Pebble": "Bottle",
    "Jump": "Frog",
    "Funky": "Funk",
    "Crystal": "Glass",
    "Heroine": "Hero",
    "Pong": "Morse",
    "Sonar": "Ping",
    "Bubble": "Pop",
    "Pluck": "Purr",
    "Sonumi": "Sosumi",
    "Submerge": "Submarine",
    "Boop": "Tink",
]

// MARK: Config

private struct FadeSecondsConfig: Codable, Equatable {
    var connected: Double? = 5.0
    var disconnected: Double? = 0.0
    var slow: Double? = 10.0
}

private struct ColorsConfig: Codable, Equatable {
    var connected: String? = "systemGreen"
    var disconnected: String? = "systemRed"
    var slow: String? = "systemYellow"

    var connectedColor: NSColor { connected != nil
        ? NSColor(colorCode: connected!) ?? NSColor(systemColorName: connected!) ?? .systemGreen
        : .systemGreen
    }
    var disconnectedColor: NSColor { disconnected != nil
        ? NSColor(colorCode: disconnected!) ?? NSColor(systemColorName: disconnected!) ?? .systemRed
        : .systemRed
    }
    var slowColor: NSColor { slow != nil
        ? NSColor(colorCode: slow!) ?? NSColor(systemColorName: slow!) ?? .systemYellow
        : .systemYellow
    }
}

private struct SoundsConfig: Codable, Equatable {
    var connected: String? = "" // e.g. "Funky"
    var disconnected: String? = "" // e.g. "Mezzo"
    var slow: String? = "" // e.g. "Submerge"
    var volume: Float? = 0.7 // relative to system volume, 0.0 - 1.0

    var connectedSound: NSSound? { connected != nil ? sound(named: connected!) : nil }
    var disconnectedSound: NSSound? { disconnected != nil ? sound(named: disconnected!) : nil }
    var slowSound: NSSound? { slow != nil ? sound(named: slow!) : nil }

    func sound(named name: String) -> NSSound? {
        guard let s = NSSound(named: name) ?? NSSound(named: SONOMA_TO_ORIGINAL_SOUND_NAMES[name] ?? "") else {
            return nil
        }

        s.volume = max(min(volume ?? 0.7, 1.0), 0.0)
        return s
    }
}

private struct Config: Codable, Equatable {
    var pingIP = "1.1.1.1"
    var pingIntervalSeconds = 5.0
    var pingTimeoutSeconds = 1.0
    var pingSlowThresholdMilliseconds = 300.0

    var fadeSeconds: FadeSecondsConfig? = FadeSecondsConfig()
    var sounds: SoundsConfig? = SoundsConfig()
    var colors: ColorsConfig? = ColorsConfig()
}

private var CONFIG_FS_WATCHER: FSEventStreamRef?
private var CONFIG: Config = {
    print("Watching config path: \(CONFIG_PATH.path)")

    CONFIG_FS_WATCHER = FSEventStreamCreate(
        kCFAllocatorDefault,
        { _, _, _, _, flags, _ in
            guard flags.pointee != kFSEventStreamEventFlagHistoryDone else {
                return
            }

            guard let data = try? Data(contentsOf: CONFIG_PATH) else {
                log("Failed to read config.json")
                return
            }
            guard let config = try? JSONDecoder().decode(Config.self, from: data) else {
                log("Failed to decode config.json")
                return
            }
            guard config != CONFIG else {
                return
            }

            CONFIG = config
            log("Config updated: \(CONFIG)")

            DispatchQueue.main.async {
                guard process != nil else {
                    return
                }
                process?.terminate()
                process = nil
                pingRestartTask = mainAsyncAfter(1) { startPingMonitor() }
            }
        },
        nil, [CONFIG_PATH.path] as [NSString] as NSArray as CFArray,
        FSEventStreamEventId(UInt32(truncatingIfNeeded: kFSEventStreamEventIdSinceNow)), 0.5 as CFTimeInterval,
        FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
    )
    if let stream = CONFIG_FS_WATCHER {
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    guard let data = try? Data(contentsOf: CONFIG_PATH), let config = try? JSONDecoder().decode(Config.self, from: data) else {
        let defaultConfig = Config()
        let prettyJsonEncoder = JSONEncoder()
        prettyJsonEncoder.outputFormatting = .prettyPrinted
        try? prettyJsonEncoder.encode(defaultConfig).write(to: CONFIG_PATH)

        return defaultConfig
    }
    return config
}()

// MARK: Extensions

extension NSColor {
    private static let systemColors: [String: NSColor] = [
        "systemBlue": .systemBlue,
        "systemBrown": .systemBrown,
        "systemGray": .systemGray,
        "systemGreen": .systemGreen,
        "systemIndigo": .systemIndigo,
        "systemMint": .systemMint,
        "systemOrange": .systemOrange,
        "systemPink": .systemPink,
        "systemPurple": .systemPurple,
        "systemRed": .systemRed,
        "systemTeal": .systemTeal,
        "systemYellow": .systemYellow,
        "clear": .clear,
    ]

    convenience init?(systemColorName: String) {
        if let color = NSColor.systemColors[systemColorName] {
            self.init(cgColor: color.cgColor)
            return
        }
        return nil
    }
}

extension NSSound {
    func playIfNotDND() {
        if #available(macOS 12.0, *), focused {
            return
        }
        play()
    }
}

extension Double {
    var intround: Int { Int(rounded()) }
}

extension TimeInterval {
    var ms: Int { (self * 1000).intround }
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

// MARK: Window

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
