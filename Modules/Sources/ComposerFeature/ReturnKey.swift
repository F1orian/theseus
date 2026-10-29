/// Return on a hardware keyboard sends, ⇧Return starts a new line (PLAT-05, iPad and Mac). The
/// text view always types the line break first; the composer takes it out again and sends when
/// a hardware keyboard is attached and Shift isn't held. The on-screen keyboard's Return keeps
/// typing a new line.
public enum ComposerReturnKey {
    /// `old`, when `new` is `old` with exactly one line break typed into it; otherwise `nil`.
    public static func textBeforeTypedReturn(old: String, new: String) -> String? {
        guard new.count == old.count + 1 else { return nil }
        let prefix = zip(old, new).prefix { $0 == $1 }.count
        let index = new.index(new.startIndex, offsetBy: prefix)
        guard new[index] == "\n" else { return nil }
        var stripped = new
        stripped.remove(at: index)
        return stripped == old ? old : nil
    }

    /// Whether a typed line break means "send" rather than "new line".
    public static func sends(hardwareKeyboard: Bool, shift: Bool) -> Bool {
        hardwareKeyboard && !shift
    }
}
