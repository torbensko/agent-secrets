import SwiftUI

/// A service's icon in a rounded square, or a generated letter placeholder when there's no icon.
struct ServiceIcon: View {
    var name: String
    var iconPNG: Data?
    var size: CGFloat = 28

    init(service: Service?, size: CGFloat = 28) {
        self.name = service?.name ?? "?"
        self.iconPNG = service?.iconPNG
        self.size = size
    }

    init(name: String, iconPNG: Data?, size: CGFloat = 28) {
        self.name = name
        self.iconPNG = iconPNG
        self.size = size
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
    }

    var body: some View {
        Group {
            if let iconPNG, let image = NSImage(data: iconPNG) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(size * 0.1)
                    .background(.white)
            } else {
                Rectangle()
                    .fill(placeholderColor.gradient)
                    .overlay {
                        Text(initial)
                            .font(.system(size: size * 0.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.separator, lineWidth: 0.5))
        .accessibilityHidden(true)
    }

    private var initial: String {
        name.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "?"
    }

    /// Stable across launches (unlike `hashValue`), so a service keeps its colour.
    private var placeholderColor: Color {
        let palette: [Color] = [.blue, .purple, .pink, .red, .orange, .yellow, .green, .mint, .teal, .cyan, .indigo, .brown]
        let hash = name.lowercased().unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        return palette[Int(hash % UInt32(palette.count))]
    }
}
