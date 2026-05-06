import SwiftUI
import linphonesw

enum UserPresence: String, CaseIterable {
	case online
	case away
	case busy
	case doNotDisturb
	case offline

	var label: String {
		switch self {
		case .online: return "Available"
		case .away: return "Away"
		case .busy: return "Busy"
		case .doNotDisturb: return "Do Not Disturb"
		case .offline: return "Offline"
		}
	}

	var badgeColor: Color {
		switch self {
		case .online: return .greenSuccess500
		case .away: return .orangeWarning600
		case .busy: return .orangeAway
		case .doNotDisturb: return .redDanger500
		case .offline: return .grayMain2c400
		}
	}

	// Maps to Linphone SDK PresenceActivity.Kind (nil = plain Open, no activity)
	var activityKind: PresenceActivity.Kind? {
		switch self {
		case .online: return nil
		case .away: return .Away
		case .busy: return .Busy
		case .doNotDisturb: return .Other
		case .offline: return .PermanentAbsence
		}
	}

	// Used for .doNotDisturb — the activity description the desktop also uses
	static let dndDescription = "dnd"

	static func from(activityKind: PresenceActivity.Kind?, description: String?) -> UserPresence {
		guard let kind = activityKind else { return .online }
		switch kind {
		case .Away: return .away
		case .Busy: return .busy
		case .Other where description == dndDescription: return .doNotDisturb
		case .PermanentAbsence: return .offline
		default: return .online
		}
	}
}
