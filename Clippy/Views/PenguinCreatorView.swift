import SwiftUI

// Club Penguin color palette
private let cpDarkBlue = Color(hex: "#0B2545")
private let cpMidBlue = Color(hex: "#13477D")
private let cpLightBlue = Color(hex: "#1B6CB0")
private let cpSkyBlue = Color(hex: "#3DA5E0")
private let cpIce = Color(hex: "#B8E4FF")
private let cpSnow = Color(hex: "#E8F6FF")
private let cpGold = Color(hex: "#FFD700")
private let cpOrange = Color(hex: "#FF8C00")

struct PenguinCreatorView: View {
    @ObservedObject var customization = PenguinCustomization.shared
    @State private var penguinName: String = ""
    @State private var selectedColor: String = "blue"
    @State private var selectedTraits: Set<String> = ["friendly"]
    @State private var isAnimating = false
    @State private var showSaved = false
    var onComplete: () -> Void

    private let maxTraits = 3

    init(onComplete: @escaping () -> Void) {
        self.onComplete = onComplete
        _penguinName = State(initialValue: PenguinCustomization.shared.name)
        _selectedColor = State(initialValue: PenguinCustomization.shared.colorThemeId)
        _selectedTraits = State(initialValue: Set(PenguinCustomization.shared.traitIds))
    }

    var body: some View {
        ZStack {
            // Full background gradient
            LinearGradient(
                colors: [cpDarkBlue, cpMidBlue, cpLightBlue],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Title bar
                titleBar

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 20) {
                        // Penguin preview + name
                        penguinCard

                        // Color picker
                        colorSection

                        // Personality traits
                        traitsSection
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 20)
                }

                // Bottom bar
                bottomBar
            }
        }
        .frame(width: 580, height: 700)
    }

    // MARK: - Title Bar

    private var titleBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Penguin Creator")
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .foregroundColor(.white)
                Text("Customize your buddy!")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(cpIce)
            }
            Spacer()
            Image(systemName: "snowflake")
                .font(.system(size: 20))
                .foregroundColor(cpIce.opacity(0.6))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(cpDarkBlue.opacity(0.5))
    }

    // MARK: - Penguin Card (Preview + Name)

    private var penguinCard: some View {
        VStack(spacing: 14) {
            // Penguin preview
            PenguinSVGPreview(theme: PenguinColorTheme.find(selectedColor))
                .frame(width: 100, height: 100)
                .scaleEffect(isAnimating ? 1.04 : 1.0)
                .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: isAnimating)
                .onAppear { isAnimating = true }

            // Name field
            VStack(spacing: 6) {
                Text("NAME")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundColor(cpIce.opacity(0.7))
                    .tracking(1.5)

                TextField("Enter a name...", text: $penguinName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.white.opacity(0.1))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(cpSkyBlue.opacity(0.4), lineWidth: 1)
                    )
                    .frame(maxWidth: 240)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(sectionBackground)
    }

    // MARK: - Color Section

    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(icon: "paintpalette.fill", title: "COLOR")

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 10) {
                ForEach(PenguinColorTheme.themes) { theme in
                    colorSwatch(theme)
                }
            }
        }
        .padding(16)
        .background(sectionBackground)
    }

    private func colorSwatch(_ theme: PenguinColorTheme) -> some View {
        let isSelected = selectedColor == theme.id
        return Button {
            withAnimation(.spring(response: 0.3)) {
                selectedColor = theme.id
            }
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color(hex: theme.light), Color(hex: theme.mid), Color(hex: theme.dark)],
                                center: .init(x: 0.35, y: 0.3),
                                startRadius: 0,
                                endRadius: 30
                            )
                        )
                        .frame(width: 44, height: 44)
                        .overlay(
                            Circle()
                                .strokeBorder(isSelected ? cpGold : Color.clear, lineWidth: 3)
                        )
                        .shadow(color: isSelected ? cpGold.opacity(0.5) : .clear, radius: 6)

                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .black))
                            .foregroundColor(.white)
                            .shadow(color: .black.opacity(0.5), radius: 1)
                    }
                }

                Text(theme.name)
                    .font(.system(size: 9, weight: isSelected ? .bold : .medium, design: .rounded))
                    .foregroundColor(isSelected ? cpGold : cpIce.opacity(0.7))
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Traits Section

    private var traitsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionHeader(icon: "sparkles", title: "PERSONALITY")
                Spacer()
                Text("\(selectedTraits.count)/\(maxTraits)")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(selectedTraits.count == maxTraits ? cpGold : cpIce.opacity(0.6))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(Color.white.opacity(0.1))
                    )
            }

            // Selected traits pills
            if !selectedTraits.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(selectedTraits).sorted().compactMap({ PersonalityTrait.find($0) })) { trait in
                        HStack(spacing: 4) {
                            Image(systemName: trait.icon)
                                .font(.system(size: 10))
                            Text(trait.name)
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill(cpSkyBlue.opacity(0.3))
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(cpSkyBlue.opacity(0.5), lineWidth: 1)
                        )
                        .foregroundColor(.white)
                    }
                }
                .padding(.bottom, 4)
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(PersonalityTrait.allTraits) { trait in
                    traitCard(trait)
                }
            }
        }
        .padding(16)
        .background(sectionBackground)
    }

    private func traitCard(_ trait: PersonalityTrait) -> some View {
        let isSelected = selectedTraits.contains(trait.id)
        let isDisabled = !isSelected && selectedTraits.count >= maxTraits

        return Button {
            withAnimation(.spring(response: 0.25)) {
                if isSelected {
                    selectedTraits.remove(trait.id)
                } else if selectedTraits.count < maxTraits {
                    selectedTraits.insert(trait.id)
                }
            }
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isSelected ? cpSkyBlue : Color.white.opacity(0.08))
                        .frame(width: 34, height: 34)
                    Image(systemName: trait.icon)
                        .font(.system(size: 15))
                        .foregroundColor(isSelected ? .white : cpIce.opacity(0.6))
                }

                Text(trait.name)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(isSelected ? .white : cpIce.opacity(0.8))

                Text(trait.description)
                    .font(.system(size: 8, weight: .medium, design: .rounded))
                    .foregroundColor(cpIce.opacity(0.5))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(height: 20)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? cpSkyBlue.opacity(0.2) : Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? cpSkyBlue.opacity(0.6) : Color.white.opacity(0.08), lineWidth: 1.5)
            )
            .opacity(isDisabled ? 0.35 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack {
            if showSaved {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Saved!")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundColor(.green)
                }
                .transition(.opacity.combined(with: .scale))
            }

            Spacer()

            Button {
                applyAndFinish()
            } label: {
                HStack(spacing: 6) {
                    Text("Save & Go!")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 14))
                }
                .foregroundColor(cpDarkBlue)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [cpGold, cpOrange],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                )
                .shadow(color: cpGold.opacity(0.4), radius: 8, y: 2)
            }
            .buttonStyle(.plain)
            .disabled(selectedTraits.isEmpty)
            .opacity(selectedTraits.isEmpty ? 0.5 : 1.0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(cpDarkBlue.opacity(0.7))
    }

    // MARK: - Helpers

    private var sectionBackground: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(Color.white.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
            )
    }

    private func sectionHeader(icon: String, title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(cpSkyBlue)
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(cpIce.opacity(0.7))
                .tracking(1.5)
        }
    }

    private func applyAndFinish() {
        customization.name = penguinName
        customization.colorThemeId = selectedColor
        customization.traitIds = Array(selectedTraits)
        customization.hasBeenCustomized = true

        withAnimation(.spring(response: 0.3)) {
            showSaved = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            onComplete()
        }
    }
}

// MARK: - Inline Penguin SVG Preview (pure SwiftUI)

struct PenguinSVGPreview: View {
    let theme: PenguinColorTheme

    var body: some View {
        ZStack {
            // Shadow
            Ellipse()
                .fill(Color.black.opacity(0.2))
                .frame(width: 60, height: 12)
                .offset(y: 42)
                .blur(radius: 3)

            // Body
            Ellipse()
                .fill(
                    RadialGradient(
                        colors: [Color(hex: theme.light), Color(hex: theme.mid), Color(hex: theme.dark)],
                        center: .init(x: 0.35, y: 0.3),
                        startRadius: 0,
                        endRadius: 55
                    )
                )
                .frame(width: 80, height: 74)
                .overlay(
                    Ellipse()
                        .strokeBorder(Color.black.opacity(0.3), lineWidth: 2)
                )

            // Belly
            Ellipse()
                .fill(
                    RadialGradient(
                        colors: [.white, Color(white: 0.95), Color(white: 0.82)],
                        center: .init(x: 0.4, y: 0.3),
                        startRadius: 0,
                        endRadius: 35
                    )
                )
                .frame(width: 50, height: 44)
                .offset(y: 10)

            // Eyes
            HStack(spacing: 12) {
                ZStack {
                    Ellipse().fill(.white).frame(width: 16, height: 18)
                    Circle().fill(.black).frame(width: 8, height: 8).offset(x: 1, y: -1)
                    Circle().fill(.white).frame(width: 3, height: 3).offset(x: 2, y: -3)
                }
                ZStack {
                    Ellipse().fill(.white).frame(width: 16, height: 18)
                    Circle().fill(.black).frame(width: 8, height: 8).offset(x: -1, y: -1)
                    Circle().fill(.white).frame(width: 3, height: 3).offset(x: 0, y: -3)
                }
            }
            .offset(y: -8)

            // Beak
            Ellipse()
                .fill(
                    LinearGradient(
                        colors: [Color(hex: "#FFE033"), Color(hex: "#FFB300")],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 22, height: 12)
                .offset(y: 5)

            // Flippers
            Ellipse()
                .fill(Color(hex: theme.dark))
                .frame(width: 14, height: 30)
                .rotationEffect(.degrees(25))
                .offset(x: -42, y: 4)

            Ellipse()
                .fill(Color(hex: theme.dark))
                .frame(width: 14, height: 30)
                .rotationEffect(.degrees(-25))
                .offset(x: 42, y: 4)

            // Feet
            HStack(spacing: 8) {
                Ellipse()
                    .fill(Color(hex: "#FF9900"))
                    .frame(width: 20, height: 8)
                Ellipse()
                    .fill(Color(hex: "#FF9900"))
                    .frame(width: 20, height: 8)
            }
            .offset(y: 38)
        }
    }
}

// MARK: - Penguin Creator Window Controller

class PenguinCreatorWindowController {
    static let shared = PenguinCreatorWindowController()

    private var window: NSWindow?

    func showCreator() {
        if let existingWindow = window, existingWindow.isVisible {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let creatorView = PenguinCreatorView {
            self.window?.close()
            self.window = nil
        }
        let hostingController = NSHostingController(rootView: creatorView)

        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 700),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        newWindow.titlebarAppearsTransparent = true
        newWindow.titleVisibility = .hidden
        newWindow.backgroundColor = NSColor(cpDarkBlue)
        newWindow.contentViewController = hostingController
        newWindow.title = "Penguin Creator"
        newWindow.center()
        newWindow.isReleasedWhenClosed = false
        newWindow.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)

        window = newWindow
    }
}
