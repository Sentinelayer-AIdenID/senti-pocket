#if canImport(SwiftUI)
import SwiftUI

/// What the room's People sheet shows that the app owns: Invite people at the top, for whoever may invite, and the
/// agent requests at the foot, for the room's owner or an admin. The sheet's order is its own: Invite people, who is
/// in the room, Agent requests (Carter, #62868: Invite was a hunt, and the icon that looked like it opened agent
/// requests).
public struct RoomPeopleExtras: Equatable {
    let invite: (() -> AnyView)?
    let requests: (() -> AnyView)?
    /// Told which sections the sheet shows, in order ("invite", "members", "requests"), as it appears.
    let shown: (([String]) -> Void)?

    public init(invite: (() -> AnyView)? = nil, requests: (() -> AnyView)? = nil, shown: (([String]) -> Void)? = nil) {
        self.invite = invite
        self.requests = requests
        self.shown = shown
    }

    /// Every one the room screen makes is the room's own: a new one each time the screen draws changes nothing shown.
    public static func == (lhs: RoomPeopleExtras, rhs: RoomPeopleExtras) -> Bool {
        (lhs.invite == nil) == (rhs.invite == nil) && (lhs.requests == nil) == (rhs.requests == nil)
    }
}

private struct RoomPeopleExtrasKey: EnvironmentKey {
    static let defaultValue: RoomPeopleExtras? = nil
}

extension EnvironmentValues {
    /// Set by the room screen for its People sheet (see `RoomPeopleExtras`).
    public var roomPeopleExtras: RoomPeopleExtras? {
        get { self[RoomPeopleExtrasKey.self] }
        set { self[RoomPeopleExtrasKey.self] = newValue }
    }
}
#endif
