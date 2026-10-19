import SwiftUI

/// Profile → Playback → Audio Offset: the global lip-sync offset, stepped
/// 10 ms at a time with − and +, on a cover like `TVSettingsPicker`'s. Titles
/// override it from the player's Audio tab (`AudioOffsetController`).
///
/// Holding Select on − or + repeats the step every 0.1 s after 0.4 s, as the
/// player's Offset row does with Left/Right: a tvOS button doesn't repeat by
/// itself.
struct TVAudioOffsetPage: View {
    @Binding var milliseconds: Int
    @FocusState private var focused: String?
    @State private var repeatTask: Task<Void, Never>?
    /// The hold stepped at least once, so the button's own action, which
    /// fires on release, mustn't step again.
    @State private var holdRepeated = false

    static let repeatDelay: Duration = .milliseconds(400)
    static let repeatInterval: Duration = .milliseconds(100)

    var body: some View {
        VStack(spacing: 40) {
            Text("Audio Offset")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(A11yID.TV.Profile.pageTitle)
            VStack(spacing: 8) {
                Text(verbatim: AudioOffsetFormat.value(milliseconds))
                    .font(.system(size: 96, weight: .bold).monospacedDigit())
                Text(verbatim: AudioOffsetFormat.hint(milliseconds))
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: AudioOffsetFormat.spoken(milliseconds)))
            .accessibilityIdentifier(A11yID.TV.Profile.audioOffsetValue)
            HStack(spacing: 40) {
                stepButton("minus", steps: -1, enabled: milliseconds > AudioOffset.range.lowerBound,
                           id: A11yID.TV.Profile.audioOffsetDecrease, label: "Decrease")
                stepButton("plus", steps: 1, enabled: milliseconds < AudioOffset.range.upperBound,
                           id: A11yID.TV.Profile.audioOffsetIncrease, label: "Increase")
            }
            .focusSection()
            Button("Reset to 0 ms") { milliseconds = 0 }
                .disabled(milliseconds == 0)
                .focused($focused, equals: A11yID.TV.Profile.audioOffsetReset)
                .accessibilityIdentifier(A11yID.TV.Profile.audioOffsetReset)
            Text("Delays or advances audio to correct lip sync for your TV or receiver. Titles can override it from the player's Audio panel.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 900)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { Rectangle().fill(.ultraThickMaterial).ignoresSafeArea() }
        .defaultFocus($focused, A11yID.TV.Profile.audioOffsetIncrease)
        .onDisappear { stopRepeating() }
    }

    private func stepButton(_ symbol: String, steps: Int, enabled: Bool, id: String, label: LocalizedStringKey) -> some View {
        Button {
            if holdRepeated {
                holdRepeated = false
            } else {
                step(steps)
            }
        } label: {
            Image(systemName: symbol)
                .font(.title.bold())
                .frame(width: 120, height: 80)
        }
        .onLongPressGesture(minimumDuration: 0.4, perform: {}, onPressingChanged: { pressing in
            pressing ? startRepeating(steps) : stopRepeating()
        })
        .disabled(!enabled)
        .focused($focused, equals: id)
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier(id)
    }

    private func step(_ steps: Int) {
        milliseconds = AudioOffset.normalized(milliseconds + steps * AudioOffset.step)
    }

    private func startRepeating(_ steps: Int) {
        repeatTask?.cancel()
        holdRepeated = false
        repeatTask = Task {
            try? await Task.sleep(for: Self.repeatDelay)
            while !Task.isCancelled {
                holdRepeated = true
                step(steps)
                try? await Task.sleep(for: Self.repeatInterval)
            }
        }
    }

    private func stopRepeating() {
        repeatTask?.cancel()
        repeatTask = nil
    }
}
