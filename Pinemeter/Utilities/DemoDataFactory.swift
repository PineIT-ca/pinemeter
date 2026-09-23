//
//  DemoDataFactory.swift
//  Pinemeter
//
//  Created by Edd on 2026-02-02.
//

#if DEBUG
import Foundation

/// Factory for creating demo state for App Store screenshots.
@MainActor
enum DemoDataFactory {
    /// Configures the app model for the given demo mode.
    static func configure(_ appModel: AppModel, for mode: DemoMode) {
        switch mode {
        case .safeUsage:
            appModel.applyDemoState(
                usageData: makeUsageData(sessionPercentage: 42, weeklyPercentage: 10),
                isSetupComplete: true,
                errorMessage: nil,
                isLoading: false
            )

        case .warningUsage:
            appModel.applyDemoState(
                usageData: makeUsageData(sessionPercentage: 72, weeklyPercentage: 45),
                isSetupComplete: true,
                errorMessage: nil,
                isLoading: false
            )

        case .criticalUsage:
            appModel.applyDemoState(
                usageData: makeUsageData(sessionPercentage: 92, weeklyPercentage: 85),
                isSetupComplete: true,
                errorMessage: nil,
                isLoading: false
            )

        case .exceededUsage:
            appModel.applyDemoState(
                usageData: makeUsageData(sessionPercentage: 105, weeklyPercentage: 100),
                isSetupComplete: true,
                errorMessage: nil,
                isLoading: false
            )

        case .withFable:
            appModel.applyDemoState(
                usageData: makeUsageData(
                    sessionPercentage: 65,
                    weeklyPercentage: 40,
                    fablePercentage: 25
                ),
                isSetupComplete: true,
                errorMessage: nil,
                isLoading: false
            )
            appModel.settings.isFableUsageShown = true

        case .multiProvider:
            appModel.applyDemoState(
                usageData: makeUsageData(sessionPercentage: 42, weeklyPercentage: 18),
                isSetupComplete: true,
                errorMessage: nil,
                isLoading: false
            )
            appModel.settings.claudeAccounts = [
                ClaudeAccount(
                    id: "11111111-1111-1111-1111-111111111111",
                    label: "Work",
                    organizationId: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                    keychainAccount: ClaudeAccount.primaryKeychainAccount,
                    profileLabel: "Chrome Default"
                ),
                ClaudeAccount(
                    id: "22222222-2222-2222-2222-222222222222",
                    label: "Personal",
                    organizationId: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                    keychainAccount: "22222222-2222-2222-2222-222222222222",
                    profileLabel: "Chrome Profile 1"
                ),
            ]
            appModel.claudeAccountUsage["22222222-2222-2222-2222-222222222222"] =
                makeUsageData(sessionPercentage: 74, weeklyPercentage: 51)
            appModel.hasChatGPTSessionCookie = true
            appModel.settings.isChatGPTUsageShown = true
            appModel.chatGPTUsageData = ChatGPTUsageData(
                rows: [
                    .init(
                        label: "GPT-5.5",
                        usedPercent: 63,
                        resetAt: Date().addingTimeInterval(5 * 3600),
                        menuBarRole: .chatGPT5h
                    ),
                    .init(
                        label: "Codex Tasks",
                        usedPercent: 28,
                        resetAt: Date().addingTimeInterval(2 * 24 * 3600),
                        menuBarRole: .chatGPTWeekly
                    ),
                ],
                lastUpdated: Date()
            )
            appModel.hasGeminiAPIKey = true
            appModel.geminiUsageData = GeminiUsageData(
                label: "Gemini API quota",
                usedPercent: 12,
                resetAt: Date().addingTimeInterval(9 * 3600),
                lastUpdated: Date()
            )

        case .loading:
            appModel.applyDemoState(
                usageData: nil,
                isSetupComplete: true,
                errorMessage: nil,
                isLoading: true
            )

        case .error:
            appModel.applyDemoState(
                usageData: makeUsageData(sessionPercentage: 55, weeklyPercentage: 30),
                isSetupComplete: true,
                errorMessage: "Unable to connect to Claude.ai. Check your internet connection.",
                isLoading: false
            )

        case .setupWizard:
            appModel.applyDemoState(
                usageData: nil,
                isSetupComplete: false,
                errorMessage: nil,
                isLoading: false
            )
        }
    }

    /// Creates UsageData with the given percentages.
    private static func makeUsageData(
        sessionPercentage: Double,
        weeklyPercentage: Double,
        fablePercentage: Double? = nil
    ) -> UsageData {
        let sessionResetAt = Date().addingTimeInterval(3 * 3600) // 3 hours from now
        let weeklyResetAt = Date().addingTimeInterval(4 * 24 * 3600) // 4 days from now

        let sessionUsage = UsageLimit(utilization: sessionPercentage, resetAt: sessionResetAt)
        let weeklyUsage = UsageLimit(utilization: weeklyPercentage, resetAt: weeklyResetAt)

        let fableUsage = fablePercentage.map {
            UsageLimit(utilization: $0, resetAt: weeklyResetAt)
        }

        return UsageData(
            sessionUsage: sessionUsage,
            weeklyUsage: weeklyUsage,
            sonnetUsage: nil,
            fableUsage: fableUsage,
            lastUpdated: Date()
        )
    }
}
#endif
