// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation
import Carbon.HIToolbox

/// Production opening and availability methods run with inert presentation
/// doubles. Feature choices live only in a disposable test preferences domain.
enum NotchDestinationContract {
    enum ReviewDefaults { static var current: UserDefaults! }
    enum NotchContentTransition { case none, reveal, replace }
    final class Panel {
        var acceptsKeyFocus = false
        func makeKey() {}
    }
    final class Host { func containsHover(_ point: CGPoint) -> Bool { false } }
    enum NSEvent { static let mouseLocation = CGPoint.zero }
    final class AppDelegate { func closePopover(preservingNotch: Bool) {} }
    struct Application { let delegate: AnyObject? = nil }
    static let NSApp = Application()
    enum ClipboardHistoryService {
        static let shared = Reader()
        struct Reader { func rememberPasteTarget() {} }
    }
    enum QuickLauncherService { static var shared = QuickLauncherContract.Launcher() }
    final class Timer {
        var running = true
        var syncs = 0
        var suspensions = 0
        func syncWithPreferences() { running = true; syncs += 1 }
        func suspend() { running = false; suspensions += 1 }
    }
    enum NotchTimerService { static var shared = Timer() }
    enum PreciseVolumeRollerService {
        static let shared = Service()
        struct Service { func syncWithPreferences() {} }
    }

    class State {
        var running = true
        var session = NotchSessionState()
        var suspended: Bool { !session.canPresent }
        var panel: Panel? = Panel()
        var windowHost: Host? = Host()
        var modules: [NotchModule] = []
        var selected = NotchModule.controls
        var selectedMetric: MetricDetailKind?
        var expanded = false
        var showingAppPanel = false
        var showingSections = false
        var peeking = false
        var pinned = false
        var openedByHover = false
        var inside = false
        var hoverState = NotchHoverState()
        var hoverWork: DispatchWorkItem?
        var requestedDetail: MetricDetailKind?
        var presentationSyncs = 0
        var presentationTearDowns = 0
        var captureControlsCancel: (() -> Void)?
        var captureClose: (() -> Void)?
        func mutatePresentation(transitionContent: NotchContentTransition, _ change: () -> Void) { change() }
        func installEventMonitors() {}
        func syncVisibleConsumers() { requestedDetail = selectedMetric }
        func provideHapticFeedback() {}
        func endCaptureControls() {}
        func clearCapture() { captureControlsCancel = nil; captureClose = nil }
        func tearDownPresentation() { expanded = false; presentationTearDowns += 1 }
    }

    static func run(expect: (Bool, String) -> Void) {
        let domain = "com.vorssaint.tests.notch-destinations"
        let defaults = UserDefaults(suiteName: domain)!
        defaults.removePersistentDomain(forName: domain)
        ReviewDefaults.current = defaults
        let previousLauncherDefaults = QuickLauncherContract.ReviewDefaults.current
        QuickLauncherContract.ReviewDefaults.current = defaults
        defer {
            QuickLauncherContract.ReviewDefaults.current = previousLauncherDefaults
            ReviewDefaults.current = nil
            defaults.removePersistentDomain(forName: domain)
            QuickLauncherService.shared = QuickLauncherContract.Launcher()
            NotchTimerService.shared = Timer()
        }
        for (key, value) in Defaults.registeredDefaults where key.hasPrefix("notch") { defaults.set(value, forKey: key) }
        for feature in AppFeature.allCases { defaults.set(true, forKey: feature.availabilityKey) }
        defaults.set(true, forKey: DefaultsKey.notchEnabled)
        let families: [(MetricDetailKind, AppFeature)] = [
            (.cpu, .monitorCPU), (.gpu, .monitorGPU), (.memory, .monitorMemory),
            (.network, .monitorNetwork), (.disk, .monitorDisk),
            (.battery, .monitorPower), (.power, .monitorPower), (.fan, .fanControl),
        ]
        for (metric, feature) in families {
            let service = Service()
            service.open(.system, pinned: true, metric: metric)
            expect(service.selectedMetric == metric, "an available metric opens its own detail")
            defaults.set(false, forKey: feature.availabilityKey)
            service.syncWithPreferences()
            expect(service.selectedMetric == nil && service.requestedDetail == nil,
                   "removing the selected metric clears its detail even when other system families remain")
            service.open(.system, metric: metric, sections: true)
            service.open(.system, metric: metric)
            expect(service.selectedMetric == nil,
                   "a retained gallery argument cannot restore a metric removed from the hub")
            defaults.set(true, forKey: feature.availabilityKey)
        }
        let service = Service()
        service.open(.system, metric: .cpu)
        for (_, feature) in families { defaults.set(false, forKey: feature.availabilityKey) }
        service.syncWithPreferences()
        expect(!service.modules.contains(.system) && service.selected == .controls
               && service.selectedMetric == nil && service.requestedDetail == nil,
               "removing the last system family selects an available module without keeping its old detail")
        defaults.set(true, forKey: AppFeature.fanControl.availabilityKey)
        service.open(.system, metric: .fan)
        expect(!service.modules.contains(.system) && service.selectedMetric == .fan,
               "a separately installed fan feature retains its direct detail without other system modules")

        QuickLauncherService.shared = QuickLauncherContract.Launcher()
        let launcher = QuickLauncherService.shared
        let firstPresentation = launcher.presentationID
        service.open(.tools)
        expect(service.selected == .tools && launcher.selectedIndex == 0 && launcher.presentationID != firstPresentation,
               "opening Tools inside the island prepares keyboard selection on its first presentation")
        QuickLauncherContract.events.removeAll()
        let enter = QuickLauncherContract.NSEvent(keyCode: UInt16(kVK_Return))
        expect(launcher.handlePanelKey(enter, columns: NotchSupport.toolColumns) == nil
               && QuickLauncherContract.events == ["keepAwake.toggle"],
               "Return works immediately after the island opens Tools")
        let unchangedPresentation = launcher.presentationID
        service.open(.tools)
        expect(launcher.presentationID == unchangedPresentation,
               "reopening the same visible Tools destination does not reset its working presentation")
        launcher.activeUtility = .urlCleaner
        service.open(.controls)
        service.open(.tools)
        expect(launcher.activeUtility == .urlCleaner,
               "navigation preserves a still-available hosted utility")
        service.open(.controls)
        defaults.set(false, forKey: AppFeature.urlCleaner.availabilityKey)
        service.open(.tools)
        expect(launcher.activeUtility == nil,
               "returning to Tools after removal cannot revive its previous utility")
        service.open(.controls)
        launcher.candidates = []
        service.open(.tools)
        expect(launcher.selectedIndex == nil, "an empty Tools module leaves keyboard activation without a target")
        sessionContracts(expect: expect)
    }

    private static func sessionContracts(expect: (Bool, String) -> Void) {
        let service = Service()
        NotchTimerService.shared = Timer()
        let timer = NotchTimerService.shared
        service.updateSession { $0.displaysSleeping = true }
        expect(timer.running && timer.suspensions == 0 && timer.syncs == 0
               && service.presentationTearDowns == 1 && !service.session.canPresent,
               "display sleep removes presentation while leaving the timer and alarm uninterrupted")
        service.updateSession { $0.sleeping = true }
        expect(!timer.running && timer.suspensions == 1 && service.presentationTearDowns == 1,
               "system sleep suspends the timer even after the display already hid the island")
        service.updateSession { $0.locked = true }
        service.updateSession { $0.displaysSleeping = false }
        service.updateSession { $0.sleeping = false }
        expect(!timer.running && timer.syncs == 0 && service.presentationSyncs == 0,
               "display and system wake cannot resume an alarm or presentation while the session is locked")
        service.updateSession { $0.locked = false }
        expect(timer.running && timer.syncs == 1 && service.presentationSyncs == 1,
               "unlocking after every sleep condition clears resumes through the normal presentation path once")

        service.updateSession { $0.displaysSleeping = true }
        service.updateSession { $0.onConsole = false }
        expect(!timer.running && timer.suspensions == 2,
               "switching users suspends an alarm even when the display is already asleep")
        service.updateSession { $0.onConsole = true }
        expect(timer.running && timer.syncs == 2 && service.presentationSyncs == 1 && !service.session.canPresent,
               "returning to the same awake session resumes only the timer while its display remains asleep")
        service.updateSession { $0.displaysSleeping = false }
        expect(timer.running && service.presentationSyncs == 2,
               "the island returns only after the display also wakes")
        service.updateSession { $0.displaysSleeping = true }
        service.updateSession { $0.locked = true }
        service.updateSession { $0.onConsole = false }
        service.updateSession { $0.locked = false }
        service.updateSession { $0.displaysSleeping = false }
        expect(!timer.running && service.presentationSyncs == 2,
               "unlock and display wake cannot resume work while another login session owns the console")
        service.running = false
        service.updateSession { $0.onConsole = true }
        expect(!timer.running && service.presentationSyncs == 2,
               "late session notifications cannot restart a stopped island or timer")
    }
}
