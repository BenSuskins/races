import Foundation

/// What actually came back, when a response could not be decoded.
///
/// `APIError.decoding` renders as "We received an unexpected response. Please
/// try again." and discards the only three facts that would say *why*: the
/// status, the content type, and what the body looked like. For a racecard that
/// is tolerable — it will be asked for again in a minute.
///
/// It is not tolerable for the Betfair login, which is the one question this
/// provider exists to answer: *does interactive login work for this account?*
/// A reply of "unexpected response, try again" answers nothing, cannot be acted
/// on, and stalls every feature downstream of a session token. This type is what
/// turns that dead end into a finding.
///
/// It carries the **shape** of the body, never its contents verbatim.
public struct HTTPResponseShape: Hashable, Sendable, CustomStringConvertible {

    public let statusCode: Int

    /// The declared content type, lowercased and stripped of parameters —
    /// `text/html` rather than `text/html; charset=utf-8`. This is usually the
    /// whole diagnosis on its own.
    public let contentType: String?

    public let byteCount: Int

    /// A short, redacted look at the body: enough to tell an HTML landing page
    /// from an empty reply from JSON of an unexpected shape.
    public let snippet: String

    public static let snippetLimit = 160

    /// Unbroken letter/digit runs this long are tokens, ids or hashes rather
    /// than prose, and none of them help identify a page. Redacting them means a
    /// diagnostic can be pasted into an issue without anyone having to think
    /// about what might be in it.
    static let redactRunsOfAtLeast = 20

    public init(statusCode: Int, contentType: String?, body: Data) {
        self.statusCode = statusCode
        self.contentType = Self.normalise(contentType)
        self.byteCount = body.count
        self.snippet = Self.makeSnippet(from: body)
    }

    static func normalise(_ raw: String?) -> String? {
        guard let raw else { return nil }
        // `map(String.init)` here is ambiguous across String's initialisers;
        // a closure has nothing to resolve.
        let head = raw.split(separator: ";").first.map { String($0) } ?? raw
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    static func makeSnippet(from body: Data) -> String {
        if body.isEmpty { return "(empty body)" }

        // Decode the whole body rather than a prefix: truncating first can cut a
        // multi-byte character in half and fail for a reason that has nothing to
        // do with the response. These bodies are a page at most.
        guard let text = String(data: body, encoding: .utf8) else {
            return "(not UTF-8)"
        }

        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let redacted = redacting(collapsed)

        if redacted.count > snippetLimit {
            return String(redacted.prefix(snippetLimit)) + "…"
        }
        return redacted
    }

    /// Replace long alphanumeric runs with an ellipsis, character by character.
    ///
    /// Deliberately a plain scan rather than a regular expression: the rule is
    /// two lines either way, and this one cannot behave differently on Linux.
    static func redacting(_ text: String) -> String {
        var output = ""
        var run = ""

        func flushRun() {
            output += (run.count >= redactRunsOfAtLeast ? "…" : run)
            run = ""
        }

        for character in text {
            if character.isLetter || character.isNumber {
                run.append(character)
            } else {
                flushRun()
                output.append(character)
            }
        }
        flushRun()
        return output
    }

    /// A web page where JSON was expected. Nearly always means the request was
    /// answered by something other than the API — a redirect to a landing page,
    /// a consent wall, or a jurisdiction block.
    public var looksLikeHTML: Bool {
        if let contentType, contentType.contains("html") { return true }
        let start = snippet.lowercased()
        return start.hasPrefix("<!doctype") || start.hasPrefix("<html")
    }

    public var description: String {
        "HTTP \(statusCode), \(contentType ?? "no content type"), \(byteCount) bytes: \(snippet)"
    }
}
