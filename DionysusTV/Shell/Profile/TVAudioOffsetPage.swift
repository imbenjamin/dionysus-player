import SwiftUI

/// Profile → Playback → Audio Offset: the global lip-sync offset, stepped
/// 10 ms at a time with − and + (`TVStepperPage`). Titles override it from
/// the player's Audio tab (`AudioOffsetController`).
struct TVAudioOffsetPage: View {
    @Binding var milliseconds: Int

    var body: some View {
        TVStepperPage(
            title: "Audio Offset",
            value: $milliseconds,
            range: AudioOffset.range,
            step: AudioOffset.step,
            display: AudioOffsetFormat.value,
            caption: AudioOffsetFormat.hint,
            spoken: AudioOffsetFormat.spoken,
            resetTitle: "Reset to 0 ms",
            resetValue: 0,
            footer: "Delays or advances audio to correct lip sync for your TV or receiver. Titles can override it from the player's Audio panel.",
            ids: .init(
                value: A11yID.TV.Profile.audioOffsetValue,
                decrease: A11yID.TV.Profile.audioOffsetDecrease,
                increase: A11yID.TV.Profile.audioOffsetIncrease,
                reset: A11yID.TV.Profile.audioOffsetReset
            )
        )
    }
}

/// A number stepped with − and +, on a cover like `TVSettingsPicker`'s: the
/// value large in the middle, Reset below, the setting's explanation at the
/// foot. Audio Offset and Read-Ahead Buffer (Benjamin, 2026-10-21: a stepper,
/// not a twenty-row list).
///
/// Holding Select on − or + repeats the step every 0.1 s after 0.4 s, as the
/// player's Offset row does with Left/Right: a tvOS button doesn't repeat by
/// itself.
struct TVStepperPage: View {
    struct IDs {
        let value: String
        let decrease: String
        let increase: String
        let reset: String
    }

    let title: LocalizedStringKey
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    let display: (Int) -> String
    /// A line under the value ("audio later"), if the setting has one.
    var caption: ((Int) -> String)?
    let spoken: (Int) -> String
    let resetTitle: LocalizedStringKey
    let resetValue: Int
    let footer: LocalizedStringKey
    let ids: IDs

    @FocusState private var focused: String?
    @State private var repeatTask: Task<Void, Never>?
    /// The hold stepped at least once, so the button's own action, which
    /// fires on release, mustn't step again.
    @State private var holdRepeated = false

    static let repeatDelay: Duration = .milliseconds(400)
    static let repeatInterval: Duration = .milliseconds(100)

    var body: some View {
        VStack(spacing: 40) {
            Text(title)
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(A11yID.TV.Profile.pageTitle)
            VStack(spacing: 8) {
                Text(verbatim: display(value))
                    .font(.system(size: 96, weight: .bold).monospacedDigit())
                if let caption {
                    Text(verbatim: caption(value))
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: spoken(value)))
            .accessibilityIdentifier(ids.value)
            HStack(spacing: 40) {
                stepButton("minus", steps: -1, enabled: value > range.lowerBound, id: ids.decrease, label: "Decrease")
                stepButton("plus", steps: 1, enabled: value < range.upperBound, id: ids.increase, label: "Increase")
            }
            .focusSection()
            Button(resetTitle) { value = resetValue }
                .disabled(value == resetValue)
                .focused($focused, equals: ids.reset)
                .accessibilityIdentifier(ids.reset)
            Text(footer)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 900)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { Rectangle().fill(.ultraThickMaterial).ignoresSafeArea() }
        .defaultFocus($focused, ids.increase)
        .onDisappear { stopRepeating() }
    }

    private func stepButton(_ symbol: String, steps: Int, enabled: Bool, id: String, label: LocalizedStringKey) -> some View {
        Button {
            if holdRepeated {
                holdRepeated = false
            } else {
                stepBy(steps)
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

    private func stepBy(_ steps: Int) {
        value = min(max(value + steps * step, range.lowerBound), range.upperBound)
    }

    private func startRepeating(_ steps: Int) {
        repeatTask?.cancel()
        holdRepeated = false
        repeatTask = Task {
            try? await Task.sleep(for: Self.repeatDelay)
            while !Task.isCancelled {
                holdRepeated = true
                stepBy(steps)
                try? await Task.sleep(for: Self.repeatInterval)
            }
        }
    }

    private func stopRepeating() {
        repeatTask?.cancel()
        repeatTask = nil
    }
}
