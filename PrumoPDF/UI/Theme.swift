import SwiftUI
import UIKit

/// Cores e medidas tiradas da imagem de referência (cartões cinza sobre fundo cinza-claro,
/// ícone colorido no alto à esquerda, contador em negrito à direita, título embaixo).
enum Theme {
    static func dynamic(light: UIColor, dark: UIColor) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }

    static let backgroundUI = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.07, alpha: 1) : UIColor(white: 233 / 255, alpha: 1) }
    static let tileUI = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.17, alpha: 1) : UIColor(white: 208 / 255, alpha: 1) }
    static let background = Color(backgroundUI)
    static let tile = dynamic(light: UIColor(white: 208 / 255, alpha: 1), dark: UIColor(white: 0.17, alpha: 1))
    static let search = dynamic(light: UIColor(white: 220 / 255, alpha: 1), dark: UIColor(white: 0.14, alpha: 1))
    static let text = dynamic(light: UIColor(white: 60 / 255, alpha: 1), dark: UIColor(white: 0.92, alpha: 1))
    static let secondaryText = dynamic(light: UIColor(white: 0.42, alpha: 1), dark: UIColor(white: 0.62, alpha: 1))
    static let placeholder = dynamic(light: UIColor(white: 0.55, alpha: 1), dark: UIColor(white: 0.5, alpha: 1))

    static let yellow = Color(red: 246 / 255, green: 207 / 255, blue: 70 / 255)
    static let red = Color(red: 0.89, green: 0.27, blue: 0.23)
    static let blue = Color(red: 0.16, green: 0.47, blue: 0.96)
    static let green = Color(red: 0.25, green: 0.72, blue: 0.36)
    static let orange = Color(red: 0.96, green: 0.58, blue: 0.16)
    static let purple = Color(red: 0.55, green: 0.38, blue: 0.86)
    static let indigo = Color(red: 0.33, green: 0.36, blue: 0.82)
    static let teal = Color(red: 0.05, green: 0.55, blue: 0.53)
    static let gray = Color(red: 0.36, green: 0.39, blue: 0.43)
    static let pink = Color(red: 0.92, green: 0.33, blue: 0.53)
    static let brown = Color(red: 0.62, green: 0.45, blue: 0.30)

    static let tileRadius: CGFloat = 14
    static let tileHeight: CGFloat = 86
    static let spacing: CGFloat = 12
    static let margin: CGFloat = 16
}

// MARK: - Ícone

enum IconShape { case circle, rounded }

struct TileIcon: View {
    let systemImage: String
    let color: Color
    var shape: IconShape = .circle
    var size: CGFloat = 32

    var body: some View {
        ZStack {
            if shape == .circle {
                Circle().fill(color)
            } else {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(color)
            }
            Image(systemName: systemImage)
                .font(.system(size: size * 0.48, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Cartão

/// Destaque do cartão ao tocar: o fundo assume a cor do ícone e o texto fica branco,
/// como o cartão amarelo selecionado da referência.
private struct TileHighlightKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var tileHighlighted: Bool {
        get { self[TileHighlightKey.self] }
        set { self[TileHighlightKey.self] = newValue }
    }
}

struct TileButtonStyle: ButtonStyle {
    var color: Color
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        let on = configuration.isPressed || selected
        configuration.label
            .environment(\.tileHighlighted, on)
            .background(
                RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous)
                    .fill(on ? color : Theme.tile)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous))
            .animation(.easeOut(duration: 0.12), value: on)
    }
}

/// Conteúdo de um cartão: ícone no alto à esquerda, contador à direita, título embaixo.
struct TileLabel: View {
    let title: String
    let systemImage: String
    let color: Color
    var count: String? = nil
    var shape: IconShape = .circle
    var subtitle: String? = nil
    @Environment(\.tileHighlighted) private var highlighted

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                TileIcon(systemImage: systemImage, color: highlighted ? Color.white.opacity(0.28) : color, shape: shape)
                Spacer(minLength: 4)
                if let count {
                    Text(count)
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(highlighted ? Color.white : Theme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
            Spacer(minLength: 6)
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(highlighted ? Color.white : Theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(highlighted ? Color.white.opacity(0.9) : Theme.secondaryText)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: Theme.tileHeight, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct Tile: View {
    let title: String
    let systemImage: String
    let color: Color
    var count: String? = nil
    var shape: IconShape = .circle
    var subtitle: String? = nil
    var selected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            TileLabel(title: title, systemImage: systemImage, color: color, count: count, shape: shape, subtitle: subtitle)
        }
        .buttonStyle(TileButtonStyle(color: color, selected: selected))
    }
}

/// Cartão de largura total (como "Suggestions de Siri" na referência).
struct WideTileLabel: View {
    let title: String
    var systemImage: String? = nil
    var color: Color = Theme.gray
    var count: String? = nil
    var subtitle: String? = nil
    @Environment(\.tileHighlighted) private var highlighted

    var body: some View {
        HStack(spacing: 12) {
            if let systemImage {
                TileIcon(systemImage: systemImage, color: highlighted ? Color.white.opacity(0.28) : color, size: 28)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(highlighted ? Color.white : Theme.text)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(highlighted ? Color.white.opacity(0.9) : Theme.secondaryText)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if let count {
                Text(count)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(highlighted ? Color.white : Theme.text)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct WideTile: View {
    let title: String
    var systemImage: String? = nil
    var color: Color = Theme.gray
    var count: String? = nil
    var subtitle: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            WideTileLabel(title: title, systemImage: systemImage, color: color, count: count, subtitle: subtitle)
        }
        .buttonStyle(TileButtonStyle(color: color))
    }
}

/// Área de cartão sem ação (agrupa conteúdos, como opções e informações).
struct TileCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous).fill(Theme.tile))
    }
}

// MARK: - Busca

struct SearchField: View {
    @Binding var text: String
    var placeholder = "Buscar"
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.text)
            TextField("", text: $text, prompt: Text(placeholder).foregroundColor(Theme.placeholder))
                .font(.system(size: 17))
                .foregroundStyle(Theme.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($focused)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.placeholder)
                }
                .accessibilityLabel("Limpar busca")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.search))
    }
}

// MARK: - Grade e títulos de seção

struct TileGrid<Content: View>: View {
    var columns = 2
    @ViewBuilder var content: Content
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.spacing), count: columns),
                  spacing: Theme.spacing) {
            content
        }
    }
}

struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.secondaryText)
            .textCase(.uppercase)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.top, 6)
    }
}

/// Fundo e rolagem padrão de todas as telas.
struct Screen<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                content
            }
            .padding(.horizontal, Theme.margin)
            .padding(.top, 8)
            .padding(.bottom, 96)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.background.ignoresSafeArea())
    }
}

extension Int {
    var pagesText: String { self == 1 ? "1 página" : "\(self) páginas" }
}

extension Int64 {
    var fileSizeText: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}

extension Date {
    var shortText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: self)
    }
}

extension View {
    /// Garante os objetos compartilhados também dentro de janelas modais (sheets).
    @MainActor
    func appEnvironment() -> some View {
        environmentObject(Library.shared)
            .environmentObject(AppFlow.shared)
            .environmentObject(JobCenter.shared)
    }
}
