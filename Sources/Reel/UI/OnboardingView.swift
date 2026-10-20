import AppKit
import ReelCore
import SwiftUI

/// First run: what the strip is, the five keys worth learning first, and the permission.
struct OnboardingView: View {
    @EnvironmentObject var engine: EngineState
    let onFinish: () -> Void
    @State private var step = 0

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: intro
                case 1: keys
                default: permission
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 36)
            .padding(.top, 34)

            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<3) { i in
                        Circle().fill(i == step ? Color.accentColor : Color.secondary.opacity(0.3)).frame(width: 7, height: 7)
                    }
                }
                Spacer()
                if step > 0 { Button("Back") { withAnimation { step -= 1 } } }
                if step < 2 {
                    Button("Next") { withAnimation { step += 1 } }.keyboardShortcut(.defaultAction)
                } else {
                    Button(engine.trusted ? "Start Reel" : "Start When Allowed") { onFinish() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
        }
        .frame(width: 620, height: 470)
    }

    private var intro: some View {
        VStack(spacing: 18) {
            Text("Your windows, on one long strip").font(.largeTitle.bold()).multilineTextAlignment(.center)
            Text("Every window gets its own column, side by side. Opening another app adds a column next to the one you're in, and nothing else shrinks. When the strip is wider than the screen, you scroll it.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            StripDemo().frame(height: 150)
        }
    }

    private var keys: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Five keys to start with").font(.largeTitle.bold())
            Text("Hold ⌃⌥ (Control and Option) with each one. Everything can be changed later in Shortcuts.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                keyRow("⌃⌥ ← →", "Move focus along the strip")
                keyRow("⌃⌥⇧ ← →", "Carry the focused window left or right")
                keyRow("⌃⌥ R", "Cycle the window through preset widths")
                keyRow("⌃⌥ F", "Make it full width, and back")
                keyRow("⌃⌥ ]", "Stack it into the column on its left")
            }
            Text("Or swipe left and right with four fingers on the trackpad.").foregroundStyle(.secondary)
        }
    }

    private func keyRow(_ keys: String, _ what: String) -> some View {
        HStack(spacing: 14) {
            Text(keys)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .frame(width: 130, alignment: .leading)
                .padding(.vertical, 6).padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.12)))
            Text(what)
        }
    }

    private var permission: some View {
        VStack(spacing: 16) {
            Image(systemName: engine.trusted ? "checkmark.shield.fill" : "lock.shield")
                .font(.system(size: 54))
                .foregroundStyle(engine.trusted ? Color.green : Color.accentColor)
            Text(engine.trusted ? "All set" : "One permission").font(.largeTitle.bold())
            Text(engine.trusted ?
                 "Reel can move your windows. Check Mac Setup in the settings for the trackpad and Spaces options that make it work best." :
                 "macOS only lets apps move other apps' windows through Accessibility. Reel uses it for that and nothing else, and nothing leaves your Mac.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !engine.trusted {
                Button("Open Accessibility Settings") {
                    AX.promptForTrust()
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
                .controlSize(.large)
            }
        }
    }
}

/// A little looping animation of columns sliding along a screen.
struct StripDemo: View {
    @State private var offset: CGFloat = 0
    private let colors: [Color] = [.blue, .orange, .green, .purple, .pink, .teal]
    private let widths: [CGFloat] = [120, 170, 120, 200, 120, 150]

    var body: some View {
        GeometryReader { geo in
            let screenW = min(geo.size.width * 0.62, 340)
            ZStack {
                HStack(spacing: 8) {
                    ForEach(0..<colors.count, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 8)
                            .fill(colors[i].gradient)
                            .frame(width: widths[i], height: geo.size.height - 30)
                            .overlay(alignment: .top) {
                                HStack(spacing: 4) {
                                    ForEach(0..<3) { _ in Circle().fill(.white.opacity(0.6)).frame(width: 6, height: 6) }
                                    Spacer()
                                }
                                .padding(7)
                            }
                    }
                }
                .offset(x: offset)
                .frame(width: geo.size.width, alignment: .leading)

                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.primary.opacity(0.7), lineWidth: 3)
                    .frame(width: screenW, height: geo.size.height - 10)
            }
            .mask(LinearGradient(colors: [.clear, .black, .black, .clear], startPoint: .leading, endPoint: .trailing))
            .onAppear {
                offset = geo.size.width / 2 - screenW / 2
                withAnimation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true)) {
                    offset = geo.size.width / 2 + screenW / 2 - widths.reduce(0, +) - 8 * CGFloat(widths.count - 1)
                }
            }
        }
    }
}
