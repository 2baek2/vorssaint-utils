// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Exercises the production hover handler with a controlled clock and pointer.
/// No input is posted and the user's preferences are never read or changed.
enum NotchHoverTests {
    typealias DispatchQueue = NotchScreenRefreshContract.DispatchQueue
    enum NSEvent { static var mouseLocation = CGPoint.zero }
    enum UserDefaults {
        static var standard = Preferences()
        struct Preferences {
            var enabled = true, expands = true
            func bool(forKey key: String) -> Bool {
                key == DefaultsKey.notchOpenOnHover ? enabled : expands
            }
        }
    }
    enum AssistiveKeyboard {
        static var active = false
        static func ownsCocoaPoint(_ point: CGPoint) -> Bool { active }
    }
    final class Host {
        var rect = CGRect.zero
        func containsHover(_ point: CGPoint) -> Bool {
            CGRect(origin: .zero, size: rect.size)
                .contains(CGPoint(x: point.x - rect.minX, y: rect.maxY - point.y))
        }
    }
    enum Transition { case reveal }
    class State {
        var running = true, suspended = false, inside = false
        var pinned = false, heldDrag = false, keepsWorkingSurface = false
        var expanded = false, peeking = false, dragPlaceholder = false, openedByHover = false
        var captureControls: Bool?, notice: Bool?
        var compactActivity: NotchCompactActivity?
        var hoverState = NotchHoverState()
        var hoverWork: DispatchWorkItem?
        var captureHover: ((Bool) -> Void)?
        var windowHost: Host? = Host()
        var geometry = NotchGeometry(screen: CGRect(x: -1920, y: 900, width: 1920, height: 1080),
                                     safeAreaTop: 0, cameraWidth: 0, menuBarHeight: 22, compactSideRoom: 64)
        var compactActivityGeometry: NotchGeometry { geometry.compactMusicGeometry }
        var surfaceSize: CGSize { expanded ? geometry.expanded : peeking ? geometry.peek : geometry.collapsed }
        var openings = 0, closures = 0, feedbacks = 0
        func open(_ module: NotchModule?, takeFocus: Bool) {
            openings += 1; expanded = true; openedByHover = !takeFocus
            hoverState.open(); hoverWork?.cancel(); hoverWork = nil
            updateBounds()
        }
        func collapse() {
            closures += 1; expanded = false; peeking = false; openedByHover = false
            hoverState.close(pointerInside: windowHost?.containsHover(NSEvent.mouseLocation) == true)
            hoverWork?.cancel(); hoverWork = nil
            updateBounds()
        }
        func mutatePresentation(transitionContent: Transition, _ change: () -> Void) { change(); updateBounds() }
        func provideHapticFeedback() { feedbacks += 1 }
        func updateBounds() { windowHost?.rect = geometry.frame(for: surfaceSize) }
    }

    static func run(expect: (Bool, String) -> Void) {
        func fixture(physical: Bool = false) -> Service {
            DispatchQueue.main = NotchScreenRefreshContract.Scheduler()
            UserDefaults.standard = UserDefaults.Preferences()
            AssistiveKeyboard.active = false
            let service = Service()
            if physical {
                service.geometry = NotchGeometry(screen: CGRect(x: 0, y: 0, width: 1470, height: 956),
                                                 safeAreaTop: 32, cameraWidth: 180, compactSideRoom: 64)
            }
            service.updateBounds()
            NSEvent.mouseLocation = CGPoint(x: service.geometry.screen.midX, y: service.geometry.screen.maxY)
            return service
        }
        func leave(_ service: Service) {
            NSEvent.mouseLocation = CGPoint(x: service.geometry.screen.minX, y: service.geometry.screen.minY)
            service.hover(false)
        }
        for physical in [false, true] {
            let service = fixture(physical: physical)
            service.hover(true)
            let initial = service.hoverWork
            DispatchQueue.main.advance(0.06)
            expect(service.openings == 0, "passing briefly over either display's island does not open it")
            service.hover(false) // A tracking exit while the pointer is still inside.
            expect(service.hoverWork === initial, "duplicate tracking events preserve the original opening deadline")
            DispatchQueue.main.advance(0.05)
            expect(service.openings == 1 && service.openedByHover && service.hoverWork == nil,
                   "a deliberate hover opens within 110 ms on both physical and simulated cutouts")
            leave(service)
            let closing = service.hoverWork
            DispatchQueue.main.advance(0.10)
            service.hover(false)
            expect(service.hoverWork === closing, "overlapping exit events do not postpone closing")
            DispatchQueue.main.advance(0.09)
            expect(service.closures == 1 && service.hoverWork == nil,
                   "leaving either display's expanded island closes it within 190 ms")
        }
        let passing = fixture()
        passing.hover(true)
        DispatchQueue.main.advance(0.04)
        leave(passing)
        DispatchQueue.main.advance(1)
        expect(passing.openings == 0, "leaving before the opening deadline cancels expansion")

        let returning = fixture()
        returning.hover(true)
        DispatchQueue.main.advance(0.11)
        leave(returning)
        DispatchQueue.main.advance(0.10)
        NSEvent.mouseLocation = CGPoint(x: returning.geometry.screen.midX, y: returning.geometry.screen.maxY)
        returning.hover(true)
        DispatchQueue.main.advance(1)
        expect(returning.openings == 1 && returning.closures == 0,
               "returning before the closing deadline cancels closing without reopening")

        let preview = fixture()
        UserDefaults.standard.expands = false
        preview.hover(true)
        DispatchQueue.main.advance(0.11)
        expect(preview.peeking && preview.openings == 0 && preview.feedbacks == 1 && preview.hoverWork == nil,
               "preview-only mode responds promptly without expanding the panel")
        leave(preview)
        DispatchQueue.main.advance(0.13)
        expect(preview.closures == 1, "a preview closes within 130 ms of leaving")

        for protect: (Service) -> Void in [
            { $0.pinned = true }, { $0.heldDrag = true }, { $0.keepsWorkingSurface = true },
            { $0.captureControls = true }, { $0.hoverState.close(pointerInside: true) },
            { $0.notice = true }, { $0.dragPlaceholder = true }, { $0.suspended = true }, { $0.running = false },
            { _ in UserDefaults.standard.enabled = false }
        ] {
            let protected = fixture()
            protected.hover(true)
            protect(protected)
            DispatchQueue.main.advance(1)
            expect(protected.openings == 0 && protected.hoverWork == nil,
                   "a pending hover rechecks eligibility before opening")
        }
        for protect: (Service) -> Void in [
            { $0.pinned = true }, { $0.heldDrag = true }, { $0.keepsWorkingSurface = true },
            { $0.captureControls = true }, { $0.suspended = true }, { $0.running = false }
        ] {
            let protected = fixture()
            protected.open(nil, takeFocus: false)
            leave(protected)
            protect(protected)
            DispatchQueue.main.advance(1)
            expect(protected.closures == 0 && protected.hoverWork == nil,
                   "a pending departure cannot interrupt pinning, dragging, capture, a menu or suspension")
        }
        let clicked = fixture()
        clicked.open(nil, takeFocus: true)
        leave(clicked)
        DispatchQueue.main.advance(1)
        expect(clicked.closures == 0, "a panel opened by click stays open when the pointer leaves")

        let keyboard = fixture()
        keyboard.open(nil, takeFocus: false)
        leave(keyboard)
        AssistiveKeyboard.active = true
        DispatchQueue.main.advance(1)
        expect(keyboard.closures == 0, "moving to the Accessibility Keyboard preserves the working panel")
    }
}
