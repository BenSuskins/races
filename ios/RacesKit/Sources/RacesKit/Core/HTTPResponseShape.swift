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

    /// The field that could not be read, when the failure was a decode rather
    /// than a transport problem. Optional because a shape is also built where
    /// there is no `DecodingError` to describe.
    public let failure: DecodingFailure?

    public static let snippetLimit = 160

    /// Unbroken letter/digit runs this long are tokens, ids or hashes rather
    /// than prose, and none of them help identify a page. Redacting them means a
    /// diagnostic can be pasted into an issue without anyone having to think
    /// about what might be in it.
    static let redactRunsOfAtLeast = 20

    /// `failure` defaults to nil so a caller with nothing to add says nothing,
    /// rather than every call site growing an argument it cannot fill.
    public init(
        statusCode: Int,
        contentType: String?,
        body: Data,
        failure: DecodingFailure? = nil
    ) {
        self.statusCode = statusCode
        self.contentType = Self.normalise(contentType)
        self.byteCount = body.count
        self.snippet = Self.makeSnippet(from: body)
        self.failure = failure
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
        let head = "HTTP \(statusCode), \(contentType ?? "no content type"), \(byteCount) bytes"
        guard let failure else { return "\(head): \(snippet)" }
        // The path leads, because it is the finding. The body still follows: it
        // is what distinguishes a card with one odd runner from a login page.
        return "\(head), \(failure). Body: \(snippet)"
    }
}

/// Which field could not be read, and why.
///
/// `HTTPResponseShape` says what arrived. This says what we could not make sense
/// of in it, and the two answer genuinely different questions — the second is
/// usually the actionable one.
///
/// The case that earned it: a 418KB Betfair catalogue, HTTP 200,
/// `application/json`, beginning with a perfectly well-formed market. Every fact
/// the response shape could offer said the reply was fine, because it *was*
/// fine; one runner some way down carried one `null` where a string was
/// expected, and that single value cost the whole day's card. From the body
/// alone that is indistinguishable from a payload wrong from its first byte, and
/// a 160-character snippet can never show it. The coding path names it outright.
public struct DecodingFailure: Hashable, Sendable, CustomStringConvertible {

    /// Dotted and bracketed, in the shape a reader would use to find the value:
    /// `[0].runners[3].metadata.SIRE_NAME`.
    public let path: String

    /// Foundation's own explanation, collapsed to one line and redacted exactly
    /// as a body snippet is — `dataCorrupted` occasionally quotes the offending
    /// value, and this string is built to be pasted into an issue unread.
    public let reason: String

    static let reasonLimit = 120

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }

    /// Fails for anything that is not a `DecodingError`, so a caller can offer
    /// it for every error and get a payload only where there is one to give.
    public init?(_ error: Error) {
        guard let error = error as? DecodingError else { return nil }

        let context: DecodingError.Context
        var trailing: (any CodingKey)?
        switch error {
        case .typeMismatch(_, let found), .valueNotFound(_, let found):
            context = found
        case .keyNotFound(let key, let found):
            context = found
            // The absent key is not in the container's path, and it is the one
            // thing worth naming.
            trailing = key
        case .dataCorrupted(let found):
            context = found
        @unknown default:
            return nil
        }

        let fullPath: [any CodingKey] = context.codingPath + (trailing.map { [$0] } ?? [])
        self.path = Self.describe(fullPath)
        self.reason = Self.tidy(context.debugDescription, fallback: Self.name(of: error))
    }

    static func describe(_ codingPath: [any CodingKey]) -> String {
        var rendered = ""
        for key in codingPath {
            // An array index has an `intValue`; a JSON object key does not. The
            // distinction is what makes the result readable as a path rather
            // than a list.
            if let index = key.intValue {
                rendered += "[\(index)]"
            } else {
                rendered += rendered.isEmpty ? key.stringValue : ".\(key.stringValue)"
            }
        }
        // The root is a real answer: "the top-level value was the wrong type"
        // is exactly what an HTML error page decodes to.
        return rendered.isEmpty ? "(the whole response)" : rendered
    }

    static func tidy(_ raw: String, fallback: String) -> String {
        let collapsed = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let redacted = HTTPResponseShape.redacting(collapsed)
        guard !redacted.isEmpty else { return fallback }
        if redacted.count > reasonLimit {
            return String(redacted.prefix(reasonLimit)) + "…"
        }
        return redacted
    }

    static func name(of error: DecodingError) -> String {
        switch error {
        case .typeMismatch: return "wrong type"
        case .valueNotFound: return "value missing"
        case .keyNotFound: return "key missing"
        case .dataCorrupted: return "not valid JSON"
        @unknown default: return "could not be decoded"
        }
    }

    public var description: String { "at \(path): \(reason)" }
}
