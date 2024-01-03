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
import ServiceManagement
import SwiftUI

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

        window.contentView = containerView
        window.setFrameOrigin(NSPoint(x: NSScreen.main!.frame.minX - 5, y: NSScreen.main!.frame.maxY - 12))

        windowController.showWindow(nil)
        window.fade(to: 1.0) {
            window.fade(to: 0.5)
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

private var lastColor: NSColor?
private var lastHideAfter: TimeInterval?
private var lastStatus: NWPath.Status?
private var monitor: NWPathMonitor?
private var observers: [AnyCancellable] = []

func start() {
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
        case .satisfied:
            print("Internet connection: ON")
            drawColoredTopLine(.systemGreen, hideAfter: 5)
        case .unsatisfied:
            print("Internet connection: OFF")
            drawColoredTopLine(.systemRed, hideAfter: 0)
        case .requiresConnection:
            print("Internet connection: MAYBE")
            drawColoredTopLine(.systemOrange, hideAfter: 5)
        @unknown default:
            print("Internet connection: UNKNOWN")
            drawColoredTopLine(.systemYellow, hideAfter: 5)
        }
    }
    monitor!.start(queue: DispatchQueue.global())

    #if !DEBUG
        if SMAppService.mainApp.status == .notRegistered || SMAppService.mainApp.status == .notFound {
            try? SMAppService.mainApp.register()
        }
    #endif
}

@main
struct IsThereNetApp: App {
    init() { start() }

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
