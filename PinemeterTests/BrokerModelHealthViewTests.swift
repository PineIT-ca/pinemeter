import Foundation
import XCTest
@testable import Pinemeter

/// Non-pixel coverage for the Model health block, the Demoted chip and the
/// opt-out row (29-06). The pixel suite does not run on the private lane
/// (docs/ci.md), so every state, label, date and copy string is pinned here.
final class BrokerModelHealthViewTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let posix = Locale(identifier: "en_US_POSIX")

    // MARK: - Service data path (Task 1)

    private func acceptedState(_ name: String = "valid-two-demotions") throws -> BrokerHealthState {
        let payload = try XCTUnwrap(BrokerHealthDocument.accept(
            body: HealthTestSupport.body(name), stored: nil,
            keys: HealthTestSupport.keys(), now: HealthTestSupport.now
        ).payload)
        return BrokerHealthState(payload: payload)
    }

    func test_scoreSnapshot_currentDocumentPartitionsOrderLikePick() async throws {
        let directory = try HealthTestSupport.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let broker = HealthTestSupport.broker(directory: directory)
        await broker.setModelHealth(try acceptedState())

        let raw = await broker.scoreSnapshot(role: "review")
        let snapshot = try XCTUnwrap(raw)
        let decision = try await broker.pick(role: "review", caller: nil)

        XCTAssertEqual(snapshot.orderRows.first?.candidate, decision.model, "the snapshot walks the order pick walks")
        XCTAssertEqual(snapshot.orderRows.map(\.candidate), ["native/model-gamma", "native/model-alpha", "native/model-beta"])
        XCTAssertEqual(snapshot.orderRows.map(\.position), [1, 2, 3])
        XCTAssertEqual(snapshot.orderRows.map(\.isDemoted), [false, true, true])
        XCTAssertEqual(snapshot.moved, 0, "moved counts pricing moves only")
        XCTAssertEqual(snapshot.health.state, .current)
        XCTAssertTrue(snapshot.health.useModelHealth)
        XCTAssertEqual(snapshot.health.demotions.map(\.model), ["model-alpha", "model-beta"])
        XCTAssertEqual(snapshot.health.demotions.first?.methods, ["quality-tracker", "status-incident"])
        XCTAssertEqual(snapshot.health.sources.count, 2)
        XCTAssertFalse(snapshot.health.skipped)
        XCTAssertEqual(snapshot.health.generatedAt, HealthTestSupport.now)
        XCTAssertEqual(snapshot.health.attribution, ["Test data for model health."])
    }

    func test_scoreSnapshot_noStoredDocumentIsNotReceivedAndDemotesNothing() async throws {
        let directory = try HealthTestSupport.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let broker = HealthTestSupport.broker(directory: directory)

        let raw = await broker.scoreSnapshot(role: "review")
        let snapshot = try XCTUnwrap(raw)

        XCTAssertEqual(snapshot.health.state, .notReceived)
        XCTAssertTrue(snapshot.health.demotions.isEmpty)
        XCTAssertTrue(snapshot.health.sources.isEmpty)
        XCTAssertEqual(snapshot.orderRows.map(\.isDemoted), [false, false, false])
        XCTAssertEqual(snapshot.orderRows.map(\.position), [1, 2, 3])
    }

    func test_scoreSnapshot_expiredDocumentIsOutOfDateAndDemotesNothing() async throws {
        let directory = try HealthTestSupport.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let later = HealthTestSupport.now.addingTimeInterval(4 * 86400)
        let broker = HealthTestSupport.broker(directory: directory, now: { later })
        await broker.setModelHealth(try acceptedState())

        let raw = await broker.scoreSnapshot(role: "review")
        let snapshot = try XCTUnwrap(raw)

        XCTAssertEqual(snapshot.health.state, .outOfDate)
        XCTAssertTrue(snapshot.health.demotions.isEmpty)
        XCTAssertEqual(snapshot.health.sources.count, 2, "the last good document's sources stay visible")
        XCTAssertEqual(snapshot.orderRows.map(\.isDemoted), [false, false, false])
        XCTAssertEqual(snapshot.orderRows.first?.candidate, "native/model-alpha")
    }

    func test_scoreSnapshot_optOutKeepsPresetOrderAndReportsOff() async throws {
        let directory = try HealthTestSupport.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var policy = HealthTestSupport.policy
        policy.thresholds.useModelHealth = false
        let service = BrokerService(
            policy: policy,
            cooldownStore: BrokerCooldownStore(storeDirectory: directory, cliCooldownsURL: directory.appendingPathComponent("cli.json")),
            auditStore: BrokerAuditStore(storeDirectory: directory),
            outcomeStore: BrokerOutcomeStore(storeDirectory: directory),
            now: { HealthTestSupport.now }
        )
        await service.setModelHealth(try acceptedState())

        let raw = await service.scoreSnapshot(role: "review")
        let snapshot = try XCTUnwrap(raw)

        XCTAssertFalse(snapshot.health.useModelHealth)
        XCTAssertEqual(snapshot.orderRows.first?.candidate, "native/model-alpha")
        XCTAssertEqual(snapshot.orderRows.map(\.isDemoted), [false, false, false])
        XCTAssertEqual(
            BrokerQualityOrderPresentation.modelHealthLine(snapshot.health), .off,
            "the Off line wins whatever the document state"
        )
    }

    func test_scoreSnapshot_roleScopedDemotionOnlyListsThisRole() async throws {
        let directory = try HealthTestSupport.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var policy = HealthTestSupport.policy
        policy.roles["other"] = policy.roles["review"]
        let service = BrokerService(
            policy: policy,
            cooldownStore: BrokerCooldownStore(storeDirectory: directory, cliCooldownsURL: directory.appendingPathComponent("cli.json")),
            auditStore: BrokerAuditStore(storeDirectory: directory),
            outcomeStore: BrokerOutcomeStore(storeDirectory: directory),
            now: { HealthTestSupport.now }
        )
        await service.setModelHealth(try acceptedState())

        let raw = await service.scoreSnapshot(role: "other")
        let snapshot = try XCTUnwrap(raw)

        XCTAssertEqual(snapshot.health.demotions.map(\.model), ["model-alpha"], "model-beta is scoped to review")
        XCTAssertEqual(snapshot.orderRows.map(\.candidate), ["native/model-beta", "native/model-gamma", "native/model-alpha"])
        XCTAssertEqual(snapshot.orderRows.map(\.isDemoted), [false, false, true])
    }

    // MARK: - Status line (Task 1)

    private func health(
        state: BrokerRoleHealthSnapshot.State = .current, useModelHealth: Bool = true,
        demotions: [BrokerRoleHealthSnapshot.Demotion] = [], skipped: Bool = false,
        sources: [BrokerRoleHealthSnapshot.Source] = [], attribution: [String] = []
    ) -> BrokerRoleHealthSnapshot {
        let generated = HealthTestSupport.now
        return BrokerRoleHealthSnapshot(
            state: state, useModelHealth: useModelHealth, generatedAt: generated,
            issuedAt: generated.addingTimeInterval(-3 * 3600),
            validUntil: generated.addingTimeInterval(86400),
            demotions: demotions, skipped: skipped, sources: sources, attribution: attribution
        )
    }

    private func demotion(_ model: String = "model-alpha") -> BrokerRoleHealthSnapshot.Demotion {
        .init(model: model, expiresAt: HealthTestSupport.now.addingTimeInterval(3 * 86400), methods: ["marginlab-cusum"])
    }

    func test_statusLine_noneInRoleAndDemotedExactCopy() {
        XCTAssertEqual(
            BrokerQualityOrderPresentation.modelHealthStatusLine(health(), locale: posix),
            "No model in this role is demoted. Data issued 3 hours ago."
        )
        XCTAssertEqual(
            BrokerQualityOrderPresentation.modelHealthStatusLine(health(demotions: [demotion()]), locale: posix),
            "1 model in this role runs only after the others until its report expires."
        )
    }

    // MARK: - Status line precedence and copy (Task 2)

    func test_statusLine_precedenceFirstMatchWins() {
        // Off beats every state, including a document with demotions.
        let off = health(useModelHealth: false, demotions: [demotion()], skipped: true)
        XCTAssertEqual(BrokerQualityOrderPresentation.modelHealthLine(off), .off)
        XCTAssertEqual(
            BrokerQualityOrderPresentation.modelHealthLine(health(state: .notReceived, useModelHealth: false)), .off
        )
        XCTAssertEqual(BrokerQualityOrderPresentation.modelHealthLine(health(state: .notReceived)), .notReceived)
        XCTAssertEqual(
            BrokerQualityOrderPresentation.modelHealthLine(health(state: .outOfDate, demotions: [demotion()])), .outOfDate
        )
        XCTAssertEqual(
            BrokerQualityOrderPresentation.modelHealthLine(health(demotions: [demotion()], skipped: true)), .skipped
        )
        XCTAssertEqual(BrokerQualityOrderPresentation.modelHealthLine(health(demotions: [demotion()])), .demoted(1))
        XCTAssertEqual(
            BrokerQualityOrderPresentation.modelHealthLine(health(demotions: [demotion(), demotion("model-beta")])),
            .demoted(2)
        )
        XCTAssertEqual(BrokerQualityOrderPresentation.modelHealthLine(health()), .noneInRole)
        // Skipped needs demotions: an empty list with the flag set is the none line.
        XCTAssertEqual(BrokerQualityOrderPresentation.modelHealthLine(health(skipped: true)), .noneInRole)
    }

    func test_statusLine_everyStateExactCopy() {
        let line = { (h: BrokerRoleHealthSnapshot) in
            BrokerQualityOrderPresentation.modelHealthStatusLine(h, locale: self.posix)
        }
        XCTAssertEqual(
            line(health(useModelHealth: false)),
            "Model health is off, so this order ignores reported quality drops. Turn it on in Quota Ceilings below."
        )
        XCTAssertEqual(line(health(state: .notReceived)), "No model health data yet. This order uses the preset alone.")
        XCTAssertEqual(
            line(health(state: .outOfDate)),
            "Model health data issued 3 hours ago has expired, so no model is demoted. This order uses the preset "
                + "alone. Routing is not affected."
        )
        XCTAssertEqual(
            line(health(demotions: [demotion()], skipped: true)),
            "A quality drop is reported for this role, but no other model here qualifies, so the order is unchanged."
        )
        XCTAssertEqual(
            line(health(demotions: [demotion(), demotion("model-beta")])),
            "2 models in this role run only after the others until their reports expire."
        )
        XCTAssertEqual(line(health()), "No model in this role is demoted. Data issued 3 hours ago.")
    }

    func test_blockVisibility_gridsFollowTheStateMachine() {
        let withSources = [BrokerRoleHealthSnapshot.Source(id: "aa", state: "fresh", newestDataDate: nil, staleLimitDays: 3)]
        XCTAssertTrue(BrokerQualityOrderPresentation.showsDemotionsGrid(health(demotions: [demotion()])))
        XCTAssertTrue(BrokerQualityOrderPresentation.showsDemotionsGrid(health(demotions: [demotion()], skipped: true)))
        XCTAssertFalse(BrokerQualityOrderPresentation.showsDemotionsGrid(health()), "no empty header row")
        XCTAssertFalse(BrokerQualityOrderPresentation.showsDemotionsGrid(health(useModelHealth: false, demotions: [demotion()])))
        XCTAssertFalse(BrokerQualityOrderPresentation.showsDemotionsGrid(health(state: .outOfDate, demotions: [demotion()])))

        XCTAssertTrue(BrokerQualityOrderPresentation.showsSources(health(sources: withSources)))
        XCTAssertTrue(BrokerQualityOrderPresentation.showsSources(health(state: .outOfDate, sources: withSources)))
        XCTAssertTrue(
            BrokerQualityOrderPresentation.showsSources(health(useModelHealth: false, sources: withSources)),
            "Off shows Sources when a document exists"
        )
        XCTAssertFalse(BrokerQualityOrderPresentation.showsSources(health()), "a document with no sources hides the sub-block")
        XCTAssertFalse(BrokerQualityOrderPresentation.showsSources(health(state: .notReceived, sources: withSources)))
    }

    // MARK: - Label maps

    func test_methodLabels_knownUnknownAndJoined() {
        XCTAssertEqual(BrokerQualityOrderPresentation.methodLabel("marginlab-cusum"), "Margin Lab trend")
        XCTAssertEqual(BrokerQualityOrderPresentation.methodLabel("status-incident"), "Provider status")
        XCTAssertEqual(BrokerQualityOrderPresentation.methodLabel("own-probe-cusum"), "Pinemeter probes")
        XCTAssertEqual(BrokerQualityOrderPresentation.methodLabel("quality-tracker"), "Other method")
        XCTAssertEqual(
            BrokerQualityOrderPresentation.methodLabels(["marginlab-cusum", "status-incident"]),
            "Margin Lab trend, Provider status"
        )
        XCTAssertFalse(BrokerQualityOrderPresentation.methodLabels(["secret-method-id"]).contains("secret-method-id"))
    }

    func test_sourceLabels_knownPrefixAndVerbatim() {
        let label = BrokerQualityOrderPresentation.sourceLabel
        XCTAssertEqual(label("marginlab-claude-code"), .init(text: "Margin Lab, Claude Code", isVerbatim: false))
        XCTAssertEqual(label("marginlab-codex"), .init(text: "Margin Lab, Codex", isVerbatim: false))
        XCTAssertEqual(label("aa"), .init(text: "Artificial Analysis", isVerbatim: false))
        XCTAssertEqual(label("aa-index"), .init(text: "Artificial Analysis", isVerbatim: false))
        XCTAssertEqual(label("status-claude"), .init(text: "Claude status page", isVerbatim: false))
        XCTAssertEqual(label("status-openai"), .init(text: "OpenAI status page", isVerbatim: false))
        XCTAssertEqual(label("probe-signal"), .init(text: "Pinemeter probes", isVerbatim: false))
        XCTAssertEqual(label("quality-tracker"), .init(text: "quality-tracker", isVerbatim: true))
    }

    func test_sourceStateChips_textTooltipsAndPlurals() {
        let chip = BrokerQualityOrderPresentation.sourceStateChip
        XCTAssertEqual(chip("fresh", 3), .init(text: "Fresh", tooltip: "Updated within its 3-day limit."))
        XCTAssertEqual(chip("fresh", 1)?.tooltip, "Updated within its 1-day limit.")
        XCTAssertEqual(chip("stale", 7), .init(text: "Stale", tooltip: "No new data within its 7-day limit, so it has no vote."))
        XCTAssertEqual(chip("broken", 3), .init(text: "Broken", tooltip: "Its last response could not be read, so it has no vote."))
        XCTAssertEqual(
            chip("paused", 3), .init(text: "Paused", tooltip: "The source is collecting a new baseline, so it has no vote.")
        )
        XCTAssertEqual(chip("disabled", 3), .init(text: "Off", tooltip: "Not used until its terms allow it."))
        XCTAssertNil(chip("mystery", 3), "an unknown state renders a dash and no chip")
    }

    // MARK: - Dates

    func test_dates_pinnedUTCAndPosixLocale() throws {
        let until = try XCTUnwrap(BrokerHealthDocument.parseTime("2026-10-16T06:00:00Z"))
        XCTAssertEqual(BrokerQualityOrderPresentation.untilText(until, timeZone: utc, locale: posix), "Oct 16, 6:00 AM")
        let toronto = try XCTUnwrap(TimeZone(identifier: "America/Toronto"))
        XCTAssertEqual(BrokerQualityOrderPresentation.untilText(until, timeZone: toronto, locale: posix), "Oct 16, 2:00 AM")
        let day = try XCTUnwrap(BrokerHealthDocument.parseTime("2026-09-29T00:00:00Z"))
        XCTAssertEqual(BrokerQualityOrderPresentation.newestDataText(day, locale: posix), "Sep 29")
        XCTAssertEqual(BrokerQualityOrderPresentation.newestDataText(nil, locale: posix), "\u{2014}")
        XCTAssertEqual(
            BrokerQualityOrderPresentation.spokenUntil(until, timeZone: utc, locale: posix),
            "Friday, October 16, 2026 at 6:00 AM"
        )
    }

    func test_snapshotSourceDateIsTheCalendarDayAnchoredAtUTCMidnight() throws {
        let payload = try XCTUnwrap(BrokerHealthDocument.accept(
            body: HealthTestSupport.body("valid-two-demotions"), stored: nil,
            keys: HealthTestSupport.keys(), now: HealthTestSupport.now
        ).payload)
        let status = BrokerHealthDocument.status(
            stored: payload, now: HealthTestSupport.now, useModelHealth: true, lastCheck: nil
        )
        let snapshot = BrokerRoleHealthSnapshot(
            status: status, resolvedRole: "review", policy: HealthTestSupport.policy, skipped: false,
            now: HealthTestSupport.now
        )
        let expected = status.sources.map(\.newestDataDate)
        XCTAssertEqual(snapshot.sources.count, expected.count)
        for (source, text) in zip(snapshot.sources, expected) {
            XCTAssertEqual(source.newestDataDate, text.flatMap { BrokerHealthDocument.parseTime($0 + "T00:00:00Z") })
        }
    }

    // MARK: - Chip precedence and accessibility

    func test_orderRowChip_demotedTakesPrecedence() {
        XCTAssertEqual(
            BrokerQualityOrderPresentation.orderRowChip(isDemoted: true, reason: "belowFloor")?.text, "Demoted"
        )
        XCTAssertEqual(
            BrokerQualityOrderPresentation.orderRowChip(isDemoted: true, reason: "noEstimate")?.tooltip,
            "Model health reports a quality drop for this model, so it moved behind the others in this role. "
                + "It still runs if nothing above it can."
        )
        XCTAssertEqual(
            BrokerQualityOrderPresentation.orderRowChip(isDemoted: false, reason: "belowFloor")?.text, "Below floor"
        )
        XCTAssertNil(BrokerQualityOrderPresentation.orderRowChip(isDemoted: false, reason: nil))
    }

    func test_orderRowAccessibilityLabel_appendsDemoted() {
        XCTAssertEqual(
            BrokerQualityOrderPresentation.orderRowAccessibilityLabel(
                position: 2, candidate: "native/model-alpha", level: nil, score: nil, chipText: "Demoted",
                isDemoted: true
            ),
            "Position 2, native/model-alpha, price unknown, score unknown, demoted"
        )
        XCTAssertEqual(
            BrokerQualityOrderPresentation.orderRowAccessibilityLabel(
                position: 1, candidate: "native/model-gamma", level: 0, score: 100, chipText: "Below floor"
            ),
            "Position 1, native/model-gamma, price 0, score 10.0, Below floor"
        )
    }

    func test_demotionAndSourceAccessibilityLabels() throws {
        let until = try XCTUnwrap(BrokerHealthDocument.parseTime("2026-10-16T06:00:00Z"))
        let demotion = BrokerRoleHealthSnapshot.Demotion(
            model: "model-alpha", expiresAt: until, methods: ["marginlab-cusum", "status-incident"]
        )
        XCTAssertEqual(
            BrokerQualityOrderPresentation.demotionAccessibilityLabel(demotion, timeZone: utc, locale: posix),
            "model-alpha, demoted until Friday, October 16, 2026 at 6:00 AM, methods Margin Lab trend, Provider status"
        )
        let day = try XCTUnwrap(BrokerHealthDocument.parseTime("2026-09-29T00:00:00Z"))
        let source = BrokerRoleHealthSnapshot.Source(id: "marginlab-codex", state: "stale", newestDataDate: day, staleLimitDays: 3)
        XCTAssertEqual(
            BrokerQualityOrderPresentation.sourceAccessibilityLabel(source, locale: posix),
            "Margin Lab, Codex, Stale, newest data Sep 29"
        )
        var undated = source
        undated.newestDataDate = nil
        XCTAssertEqual(
            BrokerQualityOrderPresentation.sourceAccessibilityLabel(undated, locale: posix),
            "Margin Lab, Codex, Stale, newest data unknown"
        )
    }

    // MARK: - Help, tooltip and static copy

    func test_helpTerms_exactDefinitionsInTheStatedPositions() throws {
        let ceilings = BrokerHelpTopic.ceilings.terms
        XCTAssertEqual(ceilings.last?.name, "Avoid reported quality drops")
        XCTAssertEqual(
            ceilings.last?.definition,
            "Pinemeter receives a signed model health summary. When two independent methods agree that a model's "
                + "quality dropped, that model runs only after the others for a few days. Off ignores the summary."
        )
        let names = BrokerHelpTopic.qualityAndOrder.terms.map(\.name)
        let score = try XCTUnwrap(names.firstIndex(of: "Score"))
        XCTAssertEqual(names[score + 1], "Demoted")
        XCTAssertEqual(names[score + 2], "Sources")
        XCTAssertEqual(names[score + 3], "Derived from chain order")
        let terms = BrokerHelpTopic.qualityAndOrder.terms
        XCTAssertEqual(
            terms[score + 1].definition,
            "Model health reports a quality drop for this model, so it moved to the end of this role's order. "
                + "Every report expires within three days unless it is renewed."
        )
        XCTAssertEqual(
            terms[score + 2].definition,
            "Where the model health summary comes from, and when each last had new data. A stale, broken or paused "
                + "source has no vote."
        )
    }

    func test_toggleCopyIsExact() {
        XCTAssertEqual(
            BrokerQualityOrderPresentation.modelHealthToggleTitle, "Avoid models with a reported quality drop"
        )
        XCTAssertEqual(
            BrokerQualityOrderPresentation.modelHealthToggleDescription,
            "When Pinemeter's signed model health data reports a quality drop for a model, it moves behind the "
                + "others in each affected role until the report expires. Off keeps the normal order."
        )
        XCTAssertEqual(BrokerQualityOrderPresentation.demotionColumnHeaders, ["Model", "Until", "Methods"])
        XCTAssertEqual(BrokerQualityOrderPresentation.sourceColumnHeaders, ["Source", "State", "Newest data"])
        XCTAssertEqual(
            BrokerQualityOrderPresentation.sourcesFootnote,
            "The same for every role. Pinemeter reads only this signed summary and never contacts these sources."
        )
    }

    func test_newCopyNamesNoFieldNameOrRawId() {
        let forbidden = ["use_model_health", "valid_until", "seq", "kid", "demotions_enabled", "useModelHealth"]
        var copy: [String] = [
            BrokerQualityOrderPresentation.modelHealthTitle, BrokerQualityOrderPresentation.sourcesTitle,
            BrokerQualityOrderPresentation.modelHealthOffLine, BrokerQualityOrderPresentation.modelHealthNotReceivedLine,
            BrokerQualityOrderPresentation.modelHealthSkippedLine, BrokerQualityOrderPresentation.sourcesFootnote,
            BrokerQualityOrderPresentation.modelHealthToggleTitle, BrokerQualityOrderPresentation.modelHealthToggleDescription,
            BrokerQualityOrderPresentation.demotedChip.text, BrokerQualityOrderPresentation.demotedChip.tooltip,
            BrokerActivityPane.pickBasisTooltip(.drift) ?? "",
        ]
        for state in ["fresh", "stale", "broken", "paused", "disabled"] {
            let chip = BrokerQualityOrderPresentation.sourceStateChip(state, staleLimitDays: 3)
            copy.append(contentsOf: [chip?.text ?? "", chip?.tooltip ?? ""])
        }
        for h in [health(), health(state: .outOfDate), health(demotions: [demotion()]), health(demotions: [demotion(), demotion("b")])] {
            copy.append(BrokerQualityOrderPresentation.modelHealthStatusLine(h, locale: posix))
        }
        copy.append(contentsOf: BrokerHelpTopic.ceilings.terms.map(\.definition))
        copy.append(contentsOf: BrokerHelpTopic.qualityAndOrder.terms.map(\.definition))
        for text in copy {
            for word in forbidden {
                XCTAssertFalse(text.contains(word), "'\(text)' names '\(word)'")
            }
        }
        XCTAssertFalse(copy.joined().contains("http"), "no source host or URL literal in the copy")
    }
}
