import Cocoa
import SwiftUI

/// A transparent, frameless, and draggable overlay window for the floating penguin.
class FloatingPenguinWindow: NSPanel {
    
    // Remember initial drag location
    private var initialLocation: NSPoint?
    
    // Track if a drag actually happened to distinguish from a click
    private var hasDragged = false
    
    // Observable state to bind to SwiftUI
    private let penguinState = PenguinStateModel()
    
    // Keep a reference to the hosting view to forward clicks
    private var hostingView: NSHostingView<PenguinView>?
    
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 220),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        
        self.isFloatingPanel = true
        self.level = .statusBar
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.backgroundColor = .clear
        self.hasShadow = false
        self.isOpaque = false
        
        // This is necessary to receive mouse events without a frame
        self.acceptsMouseMovedEvents = true
        
        // Setup the SwiftUI view
        let view = PenguinView(state: penguinState)
        
        let hostingView = NSHostingView(rootView: view)
        self.hostingView = hostingView
        hostingView.frame = self.contentRect(forFrameRect: self.frame)
        self.contentView = hostingView
        
        // Center it near top initially
        if let screen = NSScreen.main {
            let screenRect = screen.visibleFrame
            let x = screenRect.midX - (150 / 2)
            let y = screenRect.maxY - 200 // 200px from top
            self.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }
    
    override var canBecomeKey: Bool {
        return false
    }
    
    override var canBecomeMain: Bool {
        return false
    }
    
    // MARK: - Dragging Support
    
    override func mouseDown(with event: NSEvent) {
        self.initialLocation = event.locationInWindow
        self.hasDragged = false
    }
    
    override func mouseDragged(with event: NSEvent) {
        guard let initialLocation = self.initialLocation else { return }
        
        let currentLocation = event.locationInWindow
        let dx = currentLocation.x - initialLocation.x
        let dy = currentLocation.y - initialLocation.y
        
        if abs(dx) > 2 || abs(dy) > 2 {
            self.hasDragged = true
        }
        
        var newOrigin = self.frame.origin
        newOrigin.x += dx
        newOrigin.y += dy
        
        self.setFrameOrigin(newOrigin)
    }
    
    override func mouseUp(with event: NSEvent) {
        if !hasDragged {
            if event.clickCount == 2 {
                self.penguinState.handleDoubleClick()
            } else if event.clickCount == 1 {
                self.penguinState.handleClick()
            }
        }
        
        self.initialLocation = nil
        super.mouseUp(with: event)
    }
}
