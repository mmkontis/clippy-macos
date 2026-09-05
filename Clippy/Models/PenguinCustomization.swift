import SwiftUI

// MARK: - Penguin Color Theme

struct PenguinColorTheme: Identifiable, Equatable {
    let id: String
    let name: String
    let light: String
    let mid: String
    let dark: String
    let preview: Color

    static let themes: [PenguinColorTheme] = [
        PenguinColorTheme(id: "blue",    name: "Classic Blue",  light: "#66D9FF", mid: "#00BFFF", dark: "#0077CC", preview: Color(hex: "#00BFFF")),
        PenguinColorTheme(id: "red",     name: "Fiery Red",     light: "#FF7777", mid: "#E53935", dark: "#B71C1C", preview: Color(hex: "#E53935")),
        PenguinColorTheme(id: "green",   name: "Forest Green",  light: "#81C784", mid: "#43A047", dark: "#1B5E20", preview: Color(hex: "#43A047")),
        PenguinColorTheme(id: "purple",  name: "Royal Purple",  light: "#CE93D8", mid: "#8E24AA", dark: "#4A148C", preview: Color(hex: "#8E24AA")),
        PenguinColorTheme(id: "pink",    name: "Bubblegum",     light: "#F48FB1", mid: "#EC407A", dark: "#AD1457", preview: Color(hex: "#EC407A")),
        PenguinColorTheme(id: "orange",  name: "Sunset Orange", light: "#FFB74D", mid: "#FB8C00", dark: "#E65100", preview: Color(hex: "#FB8C00")),
        PenguinColorTheme(id: "teal",    name: "Ocean Teal",    light: "#80CBC4", mid: "#00897B", dark: "#004D40", preview: Color(hex: "#00897B")),
        PenguinColorTheme(id: "yellow",  name: "Sunny Yellow",  light: "#FFF176", mid: "#FDD835", dark: "#F9A825", preview: Color(hex: "#FDD835")),
        PenguinColorTheme(id: "black",   name: "Midnight",      light: "#757575", mid: "#424242", dark: "#212121", preview: Color(hex: "#424242")),
        PenguinColorTheme(id: "gold",    name: "Golden",        light: "#FFD54F", mid: "#FFB300", dark: "#FF8F00", preview: Color(hex: "#FFB300")),
        PenguinColorTheme(id: "crimson", name: "Crimson Rose",  light: "#EF9A9A", mid: "#C62828", dark: "#7F0000", preview: Color(hex: "#C62828")),
        PenguinColorTheme(id: "ice",     name: "Arctic Ice",    light: "#E0F7FA", mid: "#B2EBF2", dark: "#80DEEA", preview: Color(hex: "#B2EBF2")),
    ]

    static func find(_ id: String) -> PenguinColorTheme {
        themes.first { $0.id == id } ?? themes[0]
    }
}

// MARK: - Personality Trait

struct PersonalityTrait: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let icon: String
    let description: String
    let prompt: String

    static let allTraits: [PersonalityTrait] = [
        PersonalityTrait(id: "friendly",    name: "Friendly",    icon: "face.smiling",         description: "Warm and welcoming to everyone",           prompt: "You are warm, welcoming, and always positive."),
        PersonalityTrait(id: "sarcastic",   name: "Sarcastic",   icon: "theatermask.and.paintbrush", description: "Dry wit and clever comebacks",        prompt: "You are dry, witty, and use sarcasm playfully."),
        PersonalityTrait(id: "nerdy",       name: "Nerdy",       icon: "brain.head.profile",   description: "Loves facts, trivia, and deep dives",      prompt: "You love sharing obscure facts and geeking out."),
        PersonalityTrait(id: "adventurous", name: "Adventurous", icon: "mountain.2",           description: "Always seeking the next thrill",            prompt: "You are bold, daring, and love exploring new ideas."),
        PersonalityTrait(id: "chill",       name: "Chill",       icon: "leaf",                 description: "Relaxed and goes with the flow",            prompt: "You are calm, laid-back, and never stressed."),
        PersonalityTrait(id: "dramatic",    name: "Dramatic",    icon: "theatermasks",          description: "Everything is a big deal!",                 prompt: "You are theatrical, expressive, and over-the-top dramatic."),
        PersonalityTrait(id: "witty",       name: "Witty",       icon: "lightbulb",            description: "Quick-thinking and clever",                 prompt: "You are sharp, clever, and love wordplay and puns."),
        PersonalityTrait(id: "chaotic",     name: "Chaotic",     icon: "tornado",              description: "Unpredictable and full of surprises",       prompt: "You are chaotic, unpredictable, and say unexpected things."),
        PersonalityTrait(id: "wise",        name: "Wise",        icon: "book.closed",          description: "Thoughtful and full of sage advice",        prompt: "You are thoughtful, philosophical, and give wise advice."),
        PersonalityTrait(id: "playful",     name: "Playful",     icon: "gamecontroller",       description: "Fun-loving and always joking",              prompt: "You are silly, playful, and love making people laugh."),
        PersonalityTrait(id: "mysterious",  name: "Mysterious",  icon: "moon.stars",           description: "Enigmatic and cryptic",                     prompt: "You are enigmatic, mysterious, and speak in riddles."),
        PersonalityTrait(id: "motivating",  name: "Motivating",  icon: "flame",                description: "Your personal hype penguin",                prompt: "You are an enthusiastic motivator and hype up the user."),
    ]

    static func find(_ id: String) -> PersonalityTrait? {
        allTraits.first { $0.id == id }
    }
}

// MARK: - Penguin Customization (Persisted)

class PenguinCustomization: ObservableObject {
    static let shared = PenguinCustomization()

    private let defaults = UserDefaults.standard

    @Published var name: String {
        didSet { save() }
    }
    @Published var colorThemeId: String {
        didSet { save() }
    }
    @Published var traitIds: [String] {
        didSet { save() }
    }
    @Published var hasBeenCustomized: Bool {
        didSet { save() }
    }

    var colorTheme: PenguinColorTheme {
        PenguinColorTheme.find(colorThemeId)
    }

    var traits: [PersonalityTrait] {
        traitIds.compactMap { PersonalityTrait.find($0) }
    }

    var personalityPrompt: String {
        guard !traits.isEmpty else {
            return "You are a friendly AI penguin assistant."
        }
        let traitPrompts = traits.map(\.prompt).joined(separator: " ")
        let namePrefix = name.isEmpty ? "You are an AI penguin." : "Your name is \(name). You are an AI penguin."
        return "\(namePrefix) \(traitPrompts) Always stay in character."
    }

    private init() {
        self.name = defaults.string(forKey: "penguin_name") ?? ""
        self.colorThemeId = defaults.string(forKey: "penguin_color") ?? "blue"
        self.traitIds = defaults.stringArray(forKey: "penguin_traits") ?? ["friendly"]
        self.hasBeenCustomized = defaults.bool(forKey: "penguin_customized")
    }

    private func save() {
        defaults.set(name, forKey: "penguin_name")
        defaults.set(colorThemeId, forKey: "penguin_color")
        defaults.set(traitIds, forKey: "penguin_traits")
        defaults.set(hasBeenCustomized, forKey: "penguin_customized")
    }

    func reset() {
        name = ""
        colorThemeId = "blue"
        traitIds = ["friendly"]
        hasBeenCustomized = false
    }
}

// MARK: - Color Extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let scanner = Scanner(string: hex)
        var rgbValue: UInt64 = 0
        scanner.scanHexInt64(&rgbValue)
        let r = Double((rgbValue & 0xFF0000) >> 16) / 255.0
        let g = Double((rgbValue & 0x00FF00) >> 8) / 255.0
        let b = Double(rgbValue & 0x0000FF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}
