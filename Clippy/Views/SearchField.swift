import SwiftUI

/// A custom search field with styling
struct SearchField: View {
    @Binding var text: String
    var placeholder: String = "Search clipboard history..."
    var onSubmit: (() -> Void)?
    
    @FocusState private var isFocused: Bool
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.system(size: 14, weight: .medium))
            
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .focusEffectDisabled()
                .font(.system(size: 14))
                .focused($isFocused)
                .onSubmit {
                    onSubmit?()
                }
            
            if !text.isEmpty {
                Button(action: {
                    text = ""
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary.opacity(0.8))
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .background(Color.clear)
        .onAppear {
            isFocused = true
        }
    }
}

#Preview {
    SearchField(text: .constant(""))
        .padding()
        .frame(width: 300)
}





