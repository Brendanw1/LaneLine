import SwiftUI

/// First-run flow: who's riding, what they ride, how they want to be routed,
/// and whether Apple Music joins the ride screen. Writes a complete
/// `RiderProfile` into `AppModel` at the end.
struct OnboardingFlowView: View {
    @Environment(AppModel.self) private var appModel

    @State private var step: Step = .welcome
    @State private var draft = RiderProfile()

    enum Step: Int, CaseIterable {
        case welcome, bikeType, preferences, appleMusic

        var title: String {
            switch self {
            case .welcome: return "Welcome"
            case .bikeType: return "Your bike"
            case .preferences: return "How you ride"
            case .appleMusic: return "Music"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            stepIndicator
                .padding(.top, LaneLineDesign.Spacing.large)

            Group {
                switch step {
                case .welcome:
                    WelcomeStep()
                case .bikeType:
                    BikeTypeStep(draft: $draft)
                case .preferences:
                    PreferencesStep(draft: $draft)
                case .appleMusic:
                    AppleMusicStep(draft: $draft)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            PrimaryButton(
                title: step == .appleMusic ? "Start Riding" : "Continue",
                icon: step == .appleMusic ? "bicycle" : nil,
                action: advance
            )
            .padding(LaneLineDesign.Spacing.medium)
        }
        .background(LaneLineDesign.Colors.background)
        .animation(.snappy, value: step)
    }

    private var stepIndicator: some View {
        HStack(spacing: LaneLineDesign.Spacing.small) {
            ForEach(Step.allCases, id: \.rawValue) { candidate in
                Capsule()
                    .fill(
                        candidate.rawValue <= step.rawValue
                            ? LaneLineDesign.Colors.primary
                            : LaneLineDesign.Colors.surfaceSecondary
                    )
                    .frame(height: 4)
            }
        }
        .padding(.horizontal, LaneLineDesign.Spacing.large)
        .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count): \(step.title)")
    }

    private func advance() {
        if let next = Step(rawValue: step.rawValue + 1) {
            step = next
        } else {
            appModel.updateProfile(draft)
            appModel.completeOnboarding()
        }
    }
}

// MARK: - Steps

private struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: LaneLineDesign.Spacing.large) {
            Image(systemName: "bicycle.circle.fill")
                .font(.system(size: 88))
                .foregroundStyle(LaneLineDesign.Colors.primary)

            Text("LaneLine")
                .font(LaneLineDesign.Typography.navigationTitle)
                .foregroundStyle(LaneLineDesign.Colors.textPrimary)

            Text("Bike routes built for San Francisco — protected lanes, honest hills, and your music, all on one screen.")
                .font(LaneLineDesign.Typography.body)
                .foregroundStyle(LaneLineDesign.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, LaneLineDesign.Spacing.xlarge)

            VStack(alignment: .leading, spacing: LaneLineDesign.Spacing.medium) {
                promiseRow(icon: "shield.lefthalf.filled", text: "Routes weighted by protected lanes and traffic stress")
                promiseRow(icon: "mountain.2", text: "Grade-aware planning that knows SF hills")
                promiseRow(icon: "music.note", text: "Apple Music controls right on the ride screen")
            }
            .padding(.horizontal, LaneLineDesign.Spacing.xlarge)
        }
    }

    private func promiseRow(icon: String, text: String) -> some View {
        HStack(spacing: LaneLineDesign.Spacing.medium) {
            Image(systemName: icon)
                .frame(width: 28)
                .foregroundStyle(LaneLineDesign.Colors.primary)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(LaneLineDesign.Colors.textPrimary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct BikeTypeStep: View {
    @Binding var draft: RiderProfile

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LaneLineDesign.Spacing.medium) {
                Text("What do you ride?")
                    .font(LaneLineDesign.Typography.sectionHeader)
                Text("Your bike changes which streets make sense — surfaces, grades, and detours are weighted differently.")
                    .font(.subheadline)
                    .foregroundStyle(LaneLineDesign.Colors.textSecondary)

                ForEach(BikeType.allCases, id: \.self) { bikeType in
                    BikeTypeRow(
                        bikeType: bikeType,
                        isSelected: draft.bikeType == bikeType
                    ) {
                        draft.bikeType = bikeType
                    }
                }

                TextField("Your name (optional)", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
                    .padding(.top, LaneLineDesign.Spacing.small)
            }
            .padding(LaneLineDesign.Spacing.large)
        }
    }
}

private struct BikeTypeRow: View {
    let bikeType: BikeType
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(bikeType.displayName)
                        .font(.headline)
                        .foregroundStyle(LaneLineDesign.Colors.textPrimary)
                    Text(bikeType.routingSummary)
                        .font(.caption)
                        .foregroundStyle(LaneLineDesign.Colors.textSecondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(
                        isSelected
                            ? LaneLineDesign.Colors.primary
                            : LaneLineDesign.Colors.textTertiary
                    )
            }
            .padding(LaneLineDesign.Spacing.medium)
            .background(LaneLineDesign.Colors.surface)
            .clipShape(RoundedRectangle(cornerRadius: LaneLineDesign.CornerRadius.medium))
            .overlay(
                RoundedRectangle(cornerRadius: LaneLineDesign.CornerRadius.medium)
                    .strokeBorder(
                        isSelected ? LaneLineDesign.Colors.primary : .clear,
                        lineWidth: 2
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

private struct PreferencesStep: View {
    @Binding var draft: RiderProfile

    var body: some View {
        Form {
            Section {
                Picker("Hill tolerance", selection: $draft.hillTolerance) {
                    ForEach(HillTolerance.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                Picker("Safety priority", selection: $draft.safetyPreference) {
                    ForEach(SafetyPreference.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                Picker("Directness", selection: $draft.directnessPreference) {
                    ForEach(DirectnessPreference.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                Picker("Surface pickiness", selection: $draft.surfaceSensitivity) {
                    ForEach(SurfaceSensitivity.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
            } header: {
                Text("Route preferences")
            } footer: {
                Text("These set the default weights for route scoring. Change them anytime in Settings.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(LaneLineDesign.Colors.background)
    }
}

private struct AppleMusicStep: View {
    @Binding var draft: RiderProfile
    @Environment(\.services) private var services

    var body: some View {
        let music = services.musicService

        VStack(spacing: LaneLineDesign.Spacing.large) {
            Image(systemName: "music.note.list")
                .font(.system(size: 64))
                .foregroundStyle(LaneLineDesign.Colors.primary)

            Text("Music on the ride screen")
                .font(LaneLineDesign.Typography.sectionHeader)
                .foregroundStyle(LaneLineDesign.Colors.textPrimary)

            Text("See what's playing and skip tracks without leaving navigation. Apple Music only — nothing else to configure.")
                .font(.subheadline)
                .foregroundStyle(LaneLineDesign.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, LaneLineDesign.Spacing.xlarge)

            MusicConnectionStatusView(state: music.connectionState, errorMessage: music.lastErrorMessage)

            if music.connectionState == .notDetermined {
                Button {
                    Task {
                        await music.requestAuthorization()
                        draft.appleMusicEnabled = music.connectionState == .authorizedSubscribed
                            || music.connectionState == .authorizedNoSubscription
                    }
                } label: {
                    Label("Connect Apple Music", systemImage: "link")
                        .frame(maxWidth: .infinity)
                        .frame(height: LaneLineDesign.HitTarget.minimum)
                }
                .buttonStyle(.bordered)
                .padding(.horizontal, LaneLineDesign.Spacing.xlarge)
            }

            Toggle("Show music controls while riding", isOn: $draft.appleMusicEnabled)
                .padding(.horizontal, LaneLineDesign.Spacing.xlarge)
        }
    }
}

/// Shared connected / not-authorized / no-subscription indicator.
struct MusicConnectionStatusView: View {
    let state: AppleMusicConnectionState
    /// Set when `.authorizedNoSubscription` actually came from a failed
    /// subscription check (network, account, or missing MusicKit
    /// capability) rather than a genuine no-subscription account, so the
    /// two don't look identical to the rider.
    var errorMessage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: LaneLineDesign.Spacing.small) {
                Circle()
                    .fill(color)
                    .frame(width: 10, height: 10)
                Text(label)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(LaneLineDesign.Colors.textPrimary)
            }
            .padding(.horizontal, LaneLineDesign.Spacing.medium)
            .padding(.vertical, LaneLineDesign.Spacing.small)
            .background(LaneLineDesign.Colors.surfaceSecondary)
            .clipShape(Capsule())
            .accessibilityElement(children: .combine)

            if state == .authorizedNoSubscription, let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(LaneLineDesign.Colors.danger)
                    .padding(.horizontal, LaneLineDesign.Spacing.medium)
            }
        }
    }

    private var color: Color {
        switch state {
        case .authorizedSubscribed: return LaneLineDesign.Colors.success
        case .authorizedNoSubscription: return LaneLineDesign.Colors.warning
        case .denied, .restricted: return LaneLineDesign.Colors.danger
        case .notDetermined: return LaneLineDesign.Colors.textTertiary
        }
    }

    private var label: String {
        switch state {
        case .authorizedSubscribed: return "Connected to Apple Music"
        case .authorizedNoSubscription: return "Connected — no active subscription"
        case .denied: return "Access denied in Settings"
        case .restricted: return "Restricted on this device"
        case .notDetermined: return "Not connected"
        }
    }
}

#Preview {
    OnboardingFlowView()
        .serviceContainer(.preview())
        .environment(AppModel(persistence: PersistenceService()))
}
