import SwiftUI

/// Sizes the approved wordmark by its visible artwork instead of its PNG canvas.
/// The original asset remains unchanged, including the folded D and its shading.
struct DropackBrandLogo: View {
    let width: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    // Measured from the 2171 × 724 source. Alpha >= 8 encloses the artwork;
    // pixels outside these bounds are export residue with alpha <= 5 / 255.
    private static let canvas = CGSize(width: 2171, height: 724)
    private static let artwork = CGRect(x: 151, y: 160, width: 1887, height: 430)

    private var scale: CGFloat { max(0, width) / Self.artwork.width }

    var body: some View {
        Image("DropackLogo")
            .resizable()
            .interpolation(.high)
            .frame(width: Self.canvas.width * scale, height: Self.canvas.height * scale)
            // A fixed luminance lift keeps the original green and fold detail in
            // dark mode, without inverting or rotating the logo's colors.
            .brightness(colorScheme == .dark ? 0.34 : 0)
            .offset(x: -Self.artwork.minX * scale, y: -Self.artwork.minY * scale)
            .frame(width: max(0, width), height: Self.artwork.height * scale, alignment: .topLeading)
            .clipped()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Dropack")
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("brandLogo")
    }
}

/// Decorative paper photos tucked into a packet. This is intentionally an
/// illustration, never a placeholder that could be mistaken for a user's photo.
struct DropackPacketArtwork: View {
    var width: CGFloat = 152
    @Environment(\.colorScheme) private var colorScheme

    private var scale: CGFloat { max(0, width) / 152 }
    private var paper: Color {
        colorScheme == .dark ? Color(red: 0.84, green: 0.93, blue: 0.87) : .white
    }

    var body: some View {
        ZStack {
            Ellipse()
                .fill(RelayTheme.accent.opacity(0.13))
                .frame(width: 117, height: 17)
                .blur(radius: 9)
                .offset(y: 50)

            illustratedPhoto(sky: Color(red: 0.85, green: 0.93, blue: 0.83), mountain: Color(red: 0.50, green: 0.69, blue: 0.53))
                .rotationEffect(.degrees(-13))
                .offset(x: -23, y: -16)
            illustratedPhoto(sky: Color(red: 0.79, green: 0.90, blue: 0.91), mountain: Color(red: 0.33, green: 0.59, blue: 0.49))
                .rotationEffect(.degrees(9))
                .offset(x: 20, y: -16)

            RoundedRectangle(cornerRadius: 19, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.12, green: 0.46, blue: 0.35), Color(red: 0.06, green: 0.34, blue: 0.26)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 128, height: 70)
                .overlay(alignment: .top) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(.white.opacity(0.18))
                        .frame(width: 100, height: 1)
                        .padding(.top, 10)
                }
                .overlay {
                    HStack(spacing: 0) {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(Color(red: 0.79, green: 0.93, blue: 0.79))
                        Spacer()
                        VStack(spacing: 3) {
                            ForEach(0..<7, id: \.self) { _ in
                                Capsule().fill(.white.opacity(0.40)).frame(width: 6, height: 2)
                            }
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(.white.opacity(0.70), lineWidth: 1.5)
                                .frame(width: 8, height: 10)
                        }
                    }
                    .padding(.horizontal, 21)
                }
                .offset(y: 28)
        }
        .frame(width: 152, height: 138)
        .scaleEffect(scale)
        .frame(width: width, height: 138 * scale)
        .accessibilityHidden(true)
    }

    private func illustratedPhoto(sky: Color, mountain: Color) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(paper)
            .frame(width: 68, height: 80)
            .overlay(alignment: .top) {
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 4).fill(sky)
                    Circle().fill(Color(red: 1, green: 0.92, blue: 0.65))
                        .frame(width: 10, height: 10)
                        .padding(8)
                    MountainSilhouette()
                        .fill(mountain)
                        .padding(.top, 16)
                }
                .frame(width: 58, height: 57)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .padding(.top, 5)
            }
            .shadow(color: Color.black.opacity(0.07), radius: 4, y: 2)
    }
}

private struct MountainSilhouette: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.height * 0.72))
            path.addLine(to: CGPoint(x: rect.width * 0.32, y: rect.height * 0.18))
            path.addLine(to: CGPoint(x: rect.width * 0.59, y: rect.height * 0.70))
            path.addLine(to: CGPoint(x: rect.width * 0.78, y: rect.height * 0.43))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.height * 0.77))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}
