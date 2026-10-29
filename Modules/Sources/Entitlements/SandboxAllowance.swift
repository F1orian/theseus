public import Foundation
public import Observation

/// The free tier's daily allowance of code execution runs (ADR 0173): how many Responses may run
/// code per local calendar day without Theseus Pro, so people see code execution and file creation
/// work before they pay. The Server's sandbox and its Jupyter code interpreter share the one count.
///
/// A run counts only when a Response really ran code (a terminal tool call, or the code
/// interpreter's output), not every message sent while Code execution is on. It's kept on this
/// device, across Accounts, in plain `UserDefaults`: nothing leaves the device.
@MainActor
@Observable
public final class SandboxAllowance {
    /// Free code execution runs per day.
    public nonisolated static let dailyLimit = 5

    public let limit: Int
    /// The day `used` counts, as `yyyy-MM-dd` in the device's calendar.
    private var day: String
    private var used: Int

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let calendar: Calendar

    static let dayKey = "theseus.pro.sandbox.day"
    static let usedKey = "theseus.pro.sandbox.used"

    /// - Parameters:
    ///   - defaults: `nil` keeps the count in a throwaway suite (tests, previews).
    ///   - now: The clock, for tests.
    public init(
        defaults: UserDefaults? = nil,
        limit: Int = SandboxAllowance.dailyLimit,
        calendar: Calendar = .current,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        let defaults = defaults ?? UserDefaults(suiteName: "theseus.pro.ephemeral.\(UUID().uuidString)") ?? .standard
        self.defaults = defaults
        self.limit = limit
        self.calendar = calendar
        self.now = now
        day = defaults.string(forKey: Self.dayKey) ?? ""
        used = defaults.integer(forKey: Self.usedKey)
    }

    /// Runs used today.
    public var usedToday: Int {
        day == today ? min(used, limit) : 0
    }

    /// Free runs left today.
    public var remaining: Int {
        max(0, limit - usedToday)
    }

    public var isExhausted: Bool { remaining == 0 }

    /// Counts one Response that ran code.
    public func recordUse() {
        let today = today
        if day != today {
            day = today
            used = 0
        }
        used += 1
        defaults.set(day, forKey: Self.dayKey)
        defaults.set(used, forKey: Self.usedKey)
    }

    /// When the allowance refills: the next local midnight.
    public var refillsAt: Date {
        let start = calendar.startOfDay(for: now())
        return calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
    }

    /// "4 of 5 free runs left today", under the Code execution switch.
    public var summary: String {
        remaining == 0 ? "No free runs left today" : "\(remaining) of \(limit) free runs left today"
    }

    private var today: String {
        let parts = calendar.dateComponents([.year, .month, .day], from: now())
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
