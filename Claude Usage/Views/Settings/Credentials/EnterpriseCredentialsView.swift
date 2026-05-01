// Claude Usage/Views/Settings/Credentials/EnterpriseCredentialsView.swift
import SwiftUI

/// Enterprise Account credential setup.
/// Uses the same session key + org ID auth as PersonalUsageView, but sets
/// connectionType = .enterprise so usage is read from extra_usage (monthly spend).
struct EnterpriseCredentialsView: View {
    @StateObject private var profileManager = ProfileManager.shared
    @State private var wizardState = WizardState()
    @State private var isConnected = false
    @State private var maskedKey = ""
    private let apiService = ClaudeAPIService()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.section) {
                SettingsPageHeader(
                    title: "Enterprise Account",
                    subtitle: "For NiCE/enterprise claude.ai accounts. Shows your personal monthly spend against your allocated cap."
                )

                // Connection status card
                HStack(spacing: DesignTokens.Spacing.medium) {
                    Circle()
                        .fill(isConnected ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: DesignTokens.StatusDot.standard, height: DesignTokens.StatusDot.standard)

                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.extraSmall) {
                        Text(isConnected ? "Connected" : "Not connected")
                            .font(DesignTokens.Typography.bodyMedium)
                        if isConnected {
                            Text(maskedKey)
                                .font(DesignTokens.Typography.captionMono)
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    if isConnected {
                        Button(action: removeCredentials) {
                            HStack(spacing: DesignTokens.Spacing.extraSmall) {
                                Image(systemName: "trash")
                                    .font(.system(size: DesignTokens.Icons.small))
                                Text("Remove")
                                    .font(DesignTokens.Typography.body)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .foregroundColor(.red)
                    }
                }
                .padding(DesignTokens.Spacing.medium)
                .background(DesignTokens.Colors.cardBackground)
                .cornerRadius(DesignTokens.Radius.card)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.card)
                        .strokeBorder(DesignTokens.Colors.cardBorder, lineWidth: 1)
                )

                // Wizard card
                VStack(alignment: .leading, spacing: 0) {
                    // Step indicator
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
                        Text("Configuration")
                            .font(DesignTokens.Typography.sectionTitle)
                            .foregroundColor(.secondary)

                        HStack(spacing: DesignTokens.Spacing.small) {
                            ForEach(1...3, id: \.self) { step in
                                let stepEnum = WizardStep(rawValue: step)!
                                let isCurrent = wizardState.currentStep == stepEnum
                                let isCompleted = wizardState.currentStep > stepEnum

                                HStack(spacing: DesignTokens.Spacing.extraSmall) {
                                    ZStack {
                                        Circle()
                                            .fill(isCompleted ? Color.green : (isCurrent ? Color.accentColor : Color.secondary.opacity(0.2)))
                                            .frame(width: 20, height: 20)
                                        if isCompleted {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 10, weight: .semibold))
                                                .foregroundColor(.white)
                                        } else {
                                            Text("\(step)")
                                                .font(.system(size: 11, weight: .medium))
                                                .foregroundColor(isCurrent ? .white : .secondary)
                                        }
                                    }
                                    if isCurrent {
                                        Text(stepTitle(for: step))
                                            .font(DesignTokens.Typography.body)
                                            .fontWeight(.medium)
                                    }
                                }
                                if step < 3 {
                                    Rectangle()
                                        .fill(isCompleted ? Color.green.opacity(0.3) : Color.secondary.opacity(0.2))
                                        .frame(height: 1)
                                }
                            }
                        }
                    }
                    .padding(DesignTokens.Spacing.cardPadding)
                    .padding(.bottom, DesignTokens.Spacing.extraSmall)

                    Divider()

                    Group {
                        switch wizardState.currentStep {
                        case .enterKey:
                            EnterKeyStep(wizardState: $wizardState, apiService: apiService)
                        case .selectOrg:
                            SelectOrgStep(wizardState: $wizardState)
                        case .confirm:
                            EnterpriseConfirmStep(
                                wizardState: $wizardState,
                                onSave: { loadStatus() }
                            )
                        }
                    }
                    .padding(DesignTokens.Spacing.cardPadding)
                    .animation(.easeInOut(duration: 0.25), value: wizardState.currentStep)
                }
                .background(DesignTokens.Colors.cardBackground)
                .cornerRadius(DesignTokens.Radius.card)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.card)
                        .strokeBorder(DesignTokens.Colors.cardBorder, lineWidth: 1)
                )
            }
            .padding()
        }
        .onAppear { loadStatus() }
        .onChange(of: profileManager.activeProfile?.id) { _, _ in
            loadStatus()
            wizardState = WizardState()
        }
    }

    private func stepTitle(for step: Int) -> String {
        switch step {
        case 1: return "setup.step.enter_session_key".localized
        case 2: return "wizard.select_organization".localized
        case 3: return "Confirm & Save"
        default: return ""
        }
    }

    private func loadStatus() {
        guard let profile = profileManager.activeProfile else {
            isConnected = false
            return
        }
        isConnected = profile.connectionType == .enterprise && profile.claudeSessionKey != nil
        if let key = profile.claudeSessionKey, isConnected {
            let prefix = String(key.prefix(12))
            let suffix = String(key.suffix(4))
            maskedKey = "\(prefix)•••••\(suffix)"
        }
    }

    private func removeCredentials() {
        guard let profileId = profileManager.activeProfile?.id else { return }
        do {
            try profileManager.removeClaudeAICredentials(for: profileId)
            // Reset connectionType back to .claudeAI
            if var profile = profileManager.activeProfile {
                profile.connectionType = .claudeAI
                profileManager.updateProfile(profile)
            }
            loadStatus()
            wizardState = WizardState()
        } catch {
            let appError = AppError.wrap(error)
            ErrorPresenter.shared.showAlert(for: appError)
        }
    }
}

// MARK: - Enterprise Confirm Step

/// Like PersonalUsageView's ConfirmStep but saves connectionType = .enterprise
struct EnterpriseConfirmStep: View {
    @Binding var wizardState: WizardState
    let onSave: () -> Void
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("wizard.review_config".localized)
                    .font(.system(size: 13, weight: .medium))
                Text("wizard.confirm_settings".localized)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            // Summary
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "key")
                        .font(.system(size: 14))
                        .foregroundColor(.accentColor)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("wizard.session_key".localized)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                        Text(maskKey(wizardState.sessionKey))
                            .font(.system(size: 12, design: .monospaced))
                    }
                }

                if let org = wizardState.testedOrganizations.first(where: { $0.uuid == wizardState.selectedOrgId }) {
                    Divider()
                    HStack(spacing: 10) {
                        Image(systemName: "building.2")
                            .font(.system(size: 14))
                            .foregroundColor(.accentColor)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("wizard.organization".localized)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)
                            Text(org.name)
                                .font(.system(size: 12, weight: .medium))
                            Text(org.uuid)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "building.2.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.accentColor)
                    Text("Connection type: Enterprise (monthly spend)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .padding(12)
            .background(DesignTokens.Colors.cardBackground)
            .cornerRadius(6)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DesignTokens.Colors.cardBorder, lineWidth: 1))

            HStack(spacing: 10) {
                Button(action: {
                    withAnimation { wizardState.currentStep = .selectOrg }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left").font(.system(size: 11))
                        Text("common.back".localized).font(.system(size: 12))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(isSaving)

                Spacer()

                Button(action: saveConfiguration) {
                    HStack(spacing: 6) {
                        if isSaving {
                            ProgressView().scaleEffect(0.8).frame(width: 12, height: 12)
                        } else {
                            Image(systemName: "checkmark.circle").font(.system(size: 12))
                        }
                        Text(isSaving ? "wizard.saving".localized : "wizard.save_configuration".localized)
                            .font(.system(size: 12))
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(isSaving)
            }
        }
    }

    private func saveConfiguration() {
        guard let profileId = ProfileManager.shared.activeProfile?.id else { return }
        isSaving = true

        Task {
            do {
                var creds = try ProfileStore.shared.loadProfileCredentials(profileId)
                creds.claudeSessionKey = wizardState.sessionKey
                creds.organizationId = wizardState.selectedOrgId
                try ProfileStore.shared.saveProfileCredentials(profileId, credentials: creds)

                if var profile = ProfileManager.shared.activeProfile {
                    profile.claudeSessionKey = wizardState.sessionKey
                    profile.organizationId = wizardState.selectedOrgId
                    profile.connectionType = .enterprise          // ← the key difference
                    ProfileManager.shared.updateProfile(profile)
                }

                try? StatuslineService.shared.updateScriptsIfInstalled()

                await MainActor.run {
                    NotificationCenter.default.post(name: .credentialsChanged, object: nil)
                    onSave()
                    withAnimation { wizardState = WizardState() }
                    isSaving = false
                }
            } catch {
                let appError = AppError.wrap(error)
                await MainActor.run {
                    wizardState.validationState = .error(appError.message)
                    isSaving = false
                }
            }
        }
    }

    private func maskKey(_ key: String) -> String {
        guard key.count > 20 else { return "•••••••••" }
        return "\(key.prefix(12))•••••\(key.suffix(4))"
    }
}
