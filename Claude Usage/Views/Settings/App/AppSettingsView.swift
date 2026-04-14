//
//  AppSettingsView.swift
//  Claude Usage
//
//  App-wide settings (launch at login, etc.)
//

import SwiftUI

struct AppSettingsView: View {
    @State private var launchAtLogin = LaunchAtLoginManager.shared.isEnabled
    @State private var peakHoursEnabled: Bool = SharedDataStore.shared.loadPeakHoursIndicatorEnabled()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.section) {
                SettingsPageHeader(
                    title: "section.app_settings_title".localized,
                    subtitle: "section.app_settings_desc".localized
                )

                SettingsSectionCard(
                    title: "general.launch_at_login".localized,
                    subtitle: "general.launch_at_login.description".localized
                ) {
                    SettingToggle(
                        title: "general.launch_at_login".localized,
                        description: "general.launch_at_login.description".localized,
                        isOn: $launchAtLogin
                    )
                }

                SettingsSectionCard(
                    title: "popover.peak_hours".localized,
                    subtitle: "popover.peak_hours_desc".localized(with: PeakHoursService.localTimeRangeString())
                ) {
                    SettingToggle(
                        title: "popover.peak_hours_toggle".localized,
                        description: "popover.peak_hours_toggle_desc".localized,
                        badge: .new,
                        isOn: $peakHoursEnabled
                    )
                }
            }
            .padding()
        }
        .onChange(of: launchAtLogin) { _, newValue in
            LaunchAtLoginManager.shared.setEnabled(newValue)
        }
        .onChange(of: peakHoursEnabled) { _, newValue in
            SharedDataStore.shared.savePeakHoursIndicatorEnabled(newValue)
            NotificationCenter.default.post(name: .peakHoursSettingChanged, object: nil)
        }
    }
}

#Preview {
    AppSettingsView()
        .frame(width: 520, height: 400)
}
