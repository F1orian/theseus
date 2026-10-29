public import Foundation

/// The new-chat home's serif greeting (HOME-01). It follows the time of day and welcomes the
/// user back after a few days away; the wording varies from day to day but stays put within one.
public enum Greeting {
    /// How long away counts as "returning".
    public static let returningAfter: TimeInterval = 3 * 24 * 60 * 60

    public static func text(name: String?, now: Date, lastVisit: Date?, calendar: Calendar = .current) -> String {
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let day = calendar.ordinality(of: .day, in: .era, for: now) ?? 0
        if let name, let lastVisit, now.timeIntervalSince(lastVisit) >= returningAfter {
            return day.isMultiple(of: 2) ? "Welcome back, \(name)" : "\(name) is back!"
        }
        let hour = calendar.component(.hour, from: now)
        let options: [String]
        switch hour {
        case 5..<12:
            options = name.map { ["Good morning, \($0)", "Morning, \($0)"] } ?? ["Good morning"]
        case 12..<17:
            options = name.map { ["Good afternoon, \($0)", "Afternoon, \($0)"] } ?? ["Good afternoon"]
        case 17..<22:
            options = name.map { ["Good evening, \($0)", "Evening, \($0)"] } ?? ["Good evening"]
        default:
            options = name.map { ["Up late, \($0)?", "Hello, night owl"] } ?? ["Up late?"]
        }
        return options[day % options.count]
    }

    /// The name to greet: the nickname (PERS-01), else the first word of the Account's name.
    public static func name(nickname: String?, fullName: String?) -> String? {
        if let nickname = nickname?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty { return nickname }
        return fullName?.split(whereSeparator: \.isWhitespace).first.map(String.init)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
