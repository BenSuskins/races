import SwiftUI
import RacesKit

/// Says which clock the times on this screen are on.
///
/// Takes the note rather than deciding whether there is one, so a call site can
/// omit the whole row — an empty `Section` still costs a gap, and on a UK device
/// there is nothing to say. A notice that shows up when it is not needed is one
/// that stops being read when it is.
struct TimeZoneNote: View {
    let note: String

    var body: some View {
        Label(note, systemImage: "clock")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}
