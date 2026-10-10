import Foundation
import Testing
@testable import QuotaBar

/// WindowKeeper / ClaudeArmer 的纯逻辑测试。
/// 时间相关用例全部用固定构造的 Date，两侧（实现与测试）都走本机时区，
/// CI（UTC）与本地运行结果一致。
struct WindowKeeperTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    private func date(
        year: Int = 2026,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int
    ) -> Date {
        calendar.date(
            from: DateComponents(
                year: year, month: month, day: day, hour: hour, minute: minute
            )
        )!
    }

    private func interval(_ a: Date, _ b: Date) -> TimeInterval {
        b.timeIntervalSince(a)
    }

    // MARK: - KeeperPlanner

    @Test func activeWindowAdoptsAnchorAndWaits() {
        let now = date(month: 10, day: 10, hour: 12, minute: 0)
        let resetAt = now.addingTimeInterval(3 * 3_600)
        let state = KeeperProviderState()
        let decision = KeeperPlanner.plan(
            state: state,
            window: .active(resetAt: resetAt),
            now: now
        )
        guard case .wait(let target) = decision.action else {
            Issue.record("expected wait, got \(decision.action)")
            return
        }
        #expect(interval(resetAt, target) == KeeperPlanner.armDelayAfterReset)
        #expect(decision.resetAt == resetAt)
    }

    @Test func staleActiveWindowTreatedAsNoActive() {
        let now = date(month: 10, day: 10, hour: 12, minute: 0)
        let decision = KeeperPlanner.plan(
            state: KeeperProviderState(),
            window: .active(resetAt: now.addingTimeInterval(-30)),
            now: now
        )
        #expect(decision.action == .armNow)
    }

    @Test func fuseCoolingForcesWait() {
        let now = date(month: 10, day: 10, hour: 12, minute: 0)
        var state = KeeperProviderState()
        state.lastAttemptAt = now.addingTimeInterval(-120)
        let decision = KeeperPlanner.plan(
            state: state,
            window: .noActiveWindow,
            now: now
        )
        guard case .wait(let target) = decision.action else {
            Issue.record("expected wait, got \(decision.action)")
            return
        }
        #expect(interval(now, target) == 480)
    }

    @Test func coldFuseArmsImmediately() {
        let now = date(month: 10, day: 10, hour: 12, minute: 0)
        var state = KeeperProviderState()
        state.lastAttemptAt = now.addingTimeInterval(-KeeperPlanner.fuseInterval - 1)
        let decision = KeeperPlanner.plan(
            state: state,
            window: .noActiveWindow,
            now: now
        )
        #expect(decision.action == .armNow)
    }

    @Test func unknownWithFutureAnchorWaits() {
        let now = date(month: 10, day: 10, hour: 12, minute: 0)
        var state = KeeperProviderState()
        state.lastKnownResetAt = now.addingTimeInterval(2 * 3_600)
        let decision = KeeperPlanner.plan(state: state, window: .unknown, now: now)
        guard case .wait(let target) = decision.action else {
            Issue.record("expected wait, got \(decision.action)")
            return
        }
        #expect(interval(now, target) > 2 * 3_600)
    }

    @Test func unknownWithExpiredAnchorArms() {
        let now = date(month: 10, day: 10, hour: 12, minute: 0)
        var state = KeeperProviderState()
        state.lastKnownResetAt = now.addingTimeInterval(-60)
        let decision = KeeperPlanner.plan(state: state, window: .unknown, now: now)
        #expect(decision.action == .armNow)
    }

    @Test func unknownWithoutAnchorBootstraps() {
        let now = date(month: 10, day: 10, hour: 12, minute: 0)
        let decision = KeeperPlanner.plan(
            state: KeeperProviderState(),
            window: .unknown,
            now: now
        )
        #expect(decision.action == .armNow)
    }

    @Test func retryDelaysFollowSequence() {
        #expect(KeeperPlanner.retryDelay(failures: 1) == 30)
        #expect(KeeperPlanner.retryDelay(failures: 2) == 120)
        #expect(KeeperPlanner.retryDelay(failures: 3) == 600)
        #expect(KeeperPlanner.retryDelay(failures: 99) == 600)
        #expect(KeeperPlanner.retryDelay(failures: 0) == KeeperPlanner.unknownFallbackDelay)
    }

    // MARK: - fiveHourWindow

    @Test func picksFiveHourWindowByMinutesThenId() {
        let five = LimitWindow(
            id: "glm-5h", label: "5h", remainingPercent: 50,
            resetAt: nil, windowMinutes: 300
        )
        let weekly = LimitWindow(
            id: "glm-weekly", label: "weekly", remainingPercent: 30,
            resetAt: nil, windowMinutes: 10_080
        )
        #expect(KeeperPlanner.fiveHourWindow([weekly, five])?.id == "glm-5h")

        let kimiFive = LimitWindow(
            id: "limit-5h", label: "5 小时", remainingPercent: 90,
            resetAt: nil
        )
        #expect(KeeperPlanner.fiveHourWindow([kimiFive])?.id == "limit-5h")
    }

    // MARK: - ClaudeArmer.classify

    @Test func classifyBlockedMessage() {
        let outcome = ClaudeArmer.classify(
            output: "You've hit your session limit · resets 7:40pm (Asia/Singapore)",
            terminationStatus: 0
        )
        guard case .blocked(let resetAt) = outcome else {
            Issue.record("expected blocked, got \(outcome)")
            return
        }
        #expect(resetAt != nil)
    }

    @Test func classifyAuthFailure() {
        let outcome = ClaudeArmer.classify(
            output: "Please run /login to authenticate",
            terminationStatus: 1
        )
        guard case .failed = outcome else {
            Issue.record("expected failed, got \(outcome)")
            return
        }
    }

    @Test func classifySuccess() {
        let outcome = ClaudeArmer.classify(output: "Hello!", terminationStatus: 0)
        #expect(outcome == .armed)
    }

    @Test func classifyNonZeroExit() {
        let outcome = ClaudeArmer.classify(output: "some network error", terminationStatus: 2)
        guard case .failed = outcome else {
            Issue.record("expected failed, got \(outcome)")
            return
        }
    }

    // MARK: - ClaudeArmer.parseResets

    @Test func parsesSameDayClockTime() {
        let now = date(month: 10, day: 10, hour: 18, minute: 16)
        let parsed = ClaudeArmer.parseResets(
            "You've hit your session limit · resets 7:40pm (Asia/Singapore)",
            now: now
        )
        let expected = date(month: 10, day: 10, hour: 19, minute: 40)
        #expect(parsed == expected)
    }

    @Test func parsesMorningSuffix() {
        let now = date(month: 10, day: 10, hour: 6, minute: 5)
        let parsed = ClaudeArmer.parseResets("resets 7:40am (Asia/Singapore)", now: now)
        let expected = date(month: 10, day: 10, hour: 7, minute: 40)
        #expect(parsed == expected)
    }

    @Test func pastClockRollsToTomorrow() {
        let now = date(month: 10, day: 10, hour: 20, minute: 30)
        let parsed = ClaudeArmer.parseResets("resets 7:40pm (Asia/Singapore)", now: now)
        let expected = date(month: 10, day: 11, hour: 19, minute: 40)
        #expect(parsed == expected)
    }

    @Test func parsesWeekdayToNextOccurrence() {
        // 2026-10-10 是周六（weekday 7）；Monday 应落在 2026-10-12。
        let now = date(month: 10, day: 10, hour: 12, minute: 0)
        let parsed = ClaudeArmer.parseResets("resets Monday 7:40am", now: now)
        let expected = date(month: 10, day: 12, hour: 7, minute: 40)
        #expect(parsed == expected)
    }

    @Test func unparsableReturnsNil() {
        let now = date(month: 10, day: 10, hour: 12, minute: 0)
        #expect(ClaudeArmer.parseResets("no time here", now: now) == nil)
    }

    // MARK: - KeeperProvider

    @Test func providerMappingRoundTrip() {
        for keeper in KeeperProvider.allCases {
            #expect(KeeperProvider(keeper.providerID) == keeper)
        }
        #expect(KeeperProvider(ProviderID.deepseek) == nil)
        #expect(KeeperProvider.glm.defaultModel == "glm-4.5-air")
        #expect(KeeperProvider.kimi.defaultModel == "kimi-k2-turbo-preview")
        #expect(KeeperProvider.claude.defaultModel == "haiku")
    }
}
