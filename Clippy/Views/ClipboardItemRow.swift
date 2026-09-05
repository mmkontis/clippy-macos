import SwiftUI
import ClipboardKit

/// A row displaying a single clipboard item
struct ClipboardItemRow: View {
    let item: ClipboardItem
    let index: Int
    let isSelected: Bool
    var onSelect: (() -> Void)?
    var onDelete: (() -> Void)?
    var onShowPreview: ((ClipboardItem, NSRect) -> Void)?
    var onHidePreview: (() -> Void)?

    @State private var isHovered = false
    @State private var showDelayedInfo = false
    @State private var hoverTimer: Timer?

    var body: some View {
        HStack(spacing: 10) {
            // Shortcut badge with cmd icon for items 1-10
            if index <= 10 {
                HStack(spacing: 2) {
                    Text("⌘")
                        .font(.system(size: 8, weight: .medium))
                    Text("\(index % 10)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                }
                .foregroundColor(isSelected ? .blue : .secondary.opacity(0.6))
                .frame(width: 28)
            } else {
                Text("\(index)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.3))
                    .frame(width: 28)
            }

            // Content
            HStack(spacing: 10) {
                if item.contentType != .text && item.contentType != .richText {
                    contentIcon
                        .font(.system(size: 14))
                        .foregroundColor(iconColor)
                        .frame(width: 18)
                }

                Text(item.previewText)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .foregroundColor(.primary.opacity(0.9))
            }

            Spacer()

            if isSelected || showDelayedInfo {
                HStack(spacing: 4) {
                    if let source = item.sourceApplication {
                        Text(source)
                    }
                    Text(item.formattedTimestamp)
                }
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(0.5))
                .transition(.opacity)
            }

            // Delete button (shows immediately on hover)
            if isHovered {
                Button(action: {
                    onDelete?()
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary.opacity(0.5))
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            GeometryReader { geometry in
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        isSelected
                            ? Color.blue.opacity(0.12)
                            : (isHovered ? Color.primary.opacity(0.04) : .clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(isSelected ? Color.blue.opacity(0.3) : Color.clear, lineWidth: 1)
                    )
                    .preference(key: RowFramePreferenceKey.self, value: geometry.frame(in: .global))
            }
        )
        .contentShape(Rectangle())
        .onPreferenceChange(RowFramePreferenceKey.self) { frame in
            if showDelayedInfo {
                onShowPreview?(item, frame)
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                isHovered = hovering
            }

            if hovering {
                // Start timer for delayed preview (0.5s - faster)
                hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
                    DispatchQueue.main.async {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showDelayedInfo = true
                        }
                        if let window = NSApp.keyWindow {
                            let windowFrame = window.frame
                            let relativePoint = NSRect(
                                x: windowFrame.maxX,
                                y: windowFrame.midY,
                                width: 0,
                                height: 0
                            )
                            onShowPreview?(item, relativePoint)
                        }
                    }
                }
            } else {
                hoverTimer?.invalidate()
                hoverTimer = nil
                withAnimation(.easeInOut(duration: 0.1)) {
                    showDelayedInfo = false
                }
                onHidePreview?()
            }
        }
        .onTapGesture {
            onSelect?()
        }
        .onDisappear {
            hoverTimer?.invalidate()
            hoverTimer = nil
        }
    }

    private var contentIcon: some View {
        Group {
            switch item.contentType {
            case .text, .richText:
                EmptyView()
            case .image:
                Image(systemName: "photo")
            case .fileURL:
                Image(systemName: "folder")
            }
        }
    }

    private var iconColor: Color {
        switch item.contentType {
        case .text, .richText:
            return .blue
        case .image:
            return .blue // Changed from purple to match icon
        case .fileURL:
            return .orange
        }
    }
}

// Preference key to capture row frame
struct RowFramePreferenceKey: PreferenceKey {
    static var defaultValue: NSRect = .zero
    static func reduce(value: inout NSRect, nextValue: () -> NSRect) {
        value = nextValue()
    }
}

// MARK: - Image Preview Row

struct ClipboardImageRow: View {
    let item: ClipboardItem
    let index: Int
    let isSelected: Bool
    var onSelect: (() -> Void)?
    var onDelete: (() -> Void)?
    var onShowPreview: ((ClipboardItem, NSRect) -> Void)?
    var onHidePreview: (() -> Void)?

    @State private var isHovered = false
    @State private var showDelayedInfo = false
    @State private var hoverTimer: Timer?
    @State private var loadedImage: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            // Shortcut badge with cmd icon for items 1-10
            if index <= 10 {
                HStack(spacing: 2) {
                    Text("⌘")
                        .font(.system(size: 8, weight: .medium))
                    Text("\(index % 10)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                }
                .foregroundColor(isSelected ? .blue : .secondary.opacity(0.6))
                .frame(width: 28)
            } else {
                Text("\(index)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.3))
                    .frame(width: 28)
            }

            // Image and Info
            HStack(spacing: 10) {
                if let image = loadedImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 40, height: 40)
                        .cornerRadius(4)
                } else {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.1))
                        .frame(width: 40, height: 40)
                        .overlay(
                            Image(systemName: "photo")
                                .font(.system(size: 14))
                                .foregroundColor(.secondary.opacity(0.4))
                        )
                }

                Text("Image")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary.opacity(0.9))
            }

            Spacer()

            if isSelected || showDelayedInfo {
                HStack(spacing: 4) {
                    if let source = item.sourceApplication {
                        Text(source)
                    }
                    Text(item.formattedTimestamp)
                }
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(0.5))
                .transition(.opacity)
            }

            // Delete button
            if isHovered {
                Button(action: {
                    onDelete?()
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(
                    isSelected
                        ? Color.blue.opacity(0.12)
                        : (isHovered ? Color.primary.opacity(0.04) : .clear))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isSelected ? Color.blue.opacity(0.3) : Color.clear, lineWidth: 1)
                )
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                isHovered = hovering
            }

            if hovering {
                // Faster hover delay (0.5s)
                hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
                    DispatchQueue.main.async {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showDelayedInfo = true
                        }
                        if let window = NSApp.keyWindow {
                            let windowFrame = window.frame
                            let relativePoint = NSRect(
                                x: windowFrame.maxX,
                                y: windowFrame.midY,
                                width: 0,
                                height: 0
                            )
                            onShowPreview?(item, relativePoint)
                        }
                    }
                }
            } else {
                hoverTimer?.invalidate()
                hoverTimer = nil
                withAnimation(.easeInOut(duration: 0.1)) {
                    showDelayedInfo = false
                }
                onHidePreview?()
            }
        }
        .onTapGesture {
            onSelect?()
        }
        .onDisappear {
            hoverTimer?.invalidate()
            hoverTimer = nil
        }
        .task(id: item.id) {
            if loadedImage == nil {
                loadedImage = item.image
            }
        }
    }
}

#Preview {
    VStack {
        ClipboardItemRow(
            item: ClipboardItem.fromText("Hello, World!", source: "Safari"),
            index: 1,
            isSelected: false
        )
        ClipboardItemRow(
            item: ClipboardItem.fromText(
                "This is a longer piece of text that might need to be truncated because it's too long to display in a single line",
                source: "Notes"),
            index: 2,
            isSelected: true
        )
    }
    .padding()
    .frame(width: 400)
}
