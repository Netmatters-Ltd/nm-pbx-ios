import SwiftUI
import linphonesw

enum UserPresence: String, CaseIterable {
	case online
	case away
	case busy
	case doNotDisturb
	case offline
	// Shown only, never chosen, saved or published. The server's call-state bridge adds an <rpid:on-the-phone/>
	// activity while an extension is on a call, and Flexisip merges it with the user's own publication. Publishing it
	// would fight the bridge and only ever reflect this device's own calls.
	case onCall

	// Whether the user can choose this status for themselves, and so save and publish it
	var isUserSelectable: Bool {
		return self != .offline && self != .onCall
	}

	// The statuses the user can choose, in the order the picker lists them: the two that still take incoming calls
	// first, then Away and Do Not Disturb, which the phone server treats as unavailable
	static let selectable: [UserPresence] = [.online, .busy, .away, .doNotDisturb]

	var label: String {
		switch self {
		case .online: return "Available"
		case .away: return "Away"
		case .busy: return "Busy"
		case .doNotDisturb: return "Do Not Disturb"
		case .offline: return "Offline"
		case .onCall: return "On a call"
		}
	}

	var badgeColor: Color {
		switch self {
		case .online: return .greenSuccess500
		case .away: return .orangeAway
		case .busy: return .blueInfo500
		case .doNotDisturb: return .redDanger500
		case .offline: return .grayMain2c400
		case .onCall: return .yellowOnCall
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
		case .onCall: return nil // Never published, see the case
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

	// Whether the extension is on a call: any activity is the call-state bridge's on-the-phone, with an open basic
	// status (the bridge's tuple is always open). Every activity is checked, as Flexisip pools them in no stable order.
	// The consolidated presence of a call is Busy, which cannot tell a call from a chosen Busy.
	static func isOnCall(model: PresenceModel?) -> Bool {
		guard let model = model, model.basicStatus == .Open else { return false }
		return (0..<model.nbActivities).contains { model.getNthActivity(index: UInt($0))?.type == .OnThePhone }
	}

	// The user's own activity in a merged presence document: the first that is not the call-state bridge's
	// on-the-phone, which would otherwise read as Available whenever it came first
	static func userActivity(model: PresenceModel?) -> PresenceActivity? {
		guard let model = model else { return nil }
		for i in 0..<model.nbActivities {
			if let activity = model.getNthActivity(index: UInt(i)), activity.type != .OnThePhone {
				return activity
			}
		}
		return nil
	}

	// What an extension's presence shows instead of the status made from its consolidated presence and activity, or
	// nil to show that. Being on a call comes first, then the shared status, as on Android.
	static func displayOverride(model: PresenceModel?) -> (presence: UserPresence, note: String)? {
		let shared = SharedStatus.colleaguePresence(model: model)
		if isOnCall(model: model) {
			return (.onCall, shared?.note ?? model?.getNote(lang: nil)?.content ?? "")
		}
		return shared
	}
}

// MARK: - Shared status

// The status, message and time of choice that an extension's presence carries in a tuple id, as the phone server's
// status service and the NMPBX apps write them:
//   nmpbx-c.<status>.<chosen>.<device>  what one app's user chose, published by that app
//   nmpbx-s.<status>.<chosen>.<source>  the extension's shared status, published by the server
// The data travels in the id because the SDK keeps only the id, basic status, contact, timestamp and notes of a tuple.
// Flexisip pools every publisher's activities into one person in no stable order, so the status is always taken from
// the id and never from the activities.
struct SharedStatusTuple: Equatable {
	let presence: UserPresence
	// Unix time in seconds the status was chosen. 0 is "no choice yet", which never wins on the server.
	let chosen: Int
	// The device token (nmpbx-c) or the source (nmpbx-s: app-<device>, portal-<user id> or fc)
	let origin: String
	// The tuple's note, empty when it has none
	let note: String
}

enum SharedStatus {
	static let choicePrefix = "nmpbx-c."
	static let sharedPrefix = "nmpbx-s."

	// The longest custom message the Portal, the server and the apps accept
	static let maxNoteLength = 80

	// While a choice made on this device has not yet been taken up by the server, it is shown instead of the shared
	// status for at most this long
	static let pendingChoiceWindow: TimeInterval = 30

	private static let sharedRegex = try? NSRegularExpression(
		pattern: "^nmpbx-s\\.(available|away|busy|dnd)\\.(\\d{1,12})\\.([A-Za-z0-9-]{1,64})$")

	// The id of the tuple this app publishes for a choice
	static func choiceTupleId(presence: UserPresence, chosen: Int, device: String) -> String {
		return "\(choicePrefix)\(presence.sharedToken).\(max(chosen, 0)).\(device)"
	}

	// The shared status in a tuple id, or nil if the id is not the server's shared status tuple
	static func parseShared(id: String, note: String) -> SharedStatusTuple? {
		guard id.hasPrefix(sharedPrefix), let regex = sharedRegex else { return nil }
		let range = NSRange(id.startIndex..<id.endIndex, in: id)
		guard let match = regex.firstMatch(in: id, options: [], range: range), match.numberOfRanges == 4,
			  let statusRange = Swift.Range(match.range(at: 1), in: id),
			  let chosenRange = Swift.Range(match.range(at: 2), in: id),
			  let originRange = Swift.Range(match.range(at: 3), in: id),
			  let presence = UserPresence(sharedToken: String(id[statusRange])),
			  let chosen = Int(id[chosenRange]) else {
			return nil
		}
		return SharedStatusTuple(presence: presence, chosen: chosen, origin: String(id[originRange]), note: note)
	}

	// The shared status in a presence document, or nil when it has none (the customer is not switched on, or the
	// server has not published one for the extension yet). Should there be more than one, the newest choice is
	// taken.
	static func shared(in model: PresenceModel?) -> SharedStatusTuple? {
		guard let model = model else { return nil }
		var found: SharedStatusTuple?
		for i in 0..<model.nbServices {
			guard let service = model.getNthService(index: UInt(i)), let id = service.id,
				  id.hasPrefix(sharedPrefix) else { continue }
			let note = service.nbNotes > 0 ? (service.getNthNote(index: 0)?.content ?? "") : ""
			if let tuple = parseShared(id: id, note: note), tuple.chosen >= (found?.chosen ?? -1) {
				found = tuple
			}
		}
		return found
	}

	// What a colleague's presence shows when their document carries a shared status, or nil to show it as before.
	// The status and message are the shared ones. A shared Available is only shown as available while something else
	// of theirs is open (the server's own tuple is closed for Available). Being on a call is dealt with ahead of this,
	// see UserPresence.displayOverride(model:).
	static func colleaguePresence(model: PresenceModel?) -> (presence: UserPresence, note: String)? {
		guard let model = model, let shared = shared(in: model) else { return nil }
		if shared.presence != .online {
			return (shared.presence, shared.note)
		}

		var connected = false
		for i in 0..<model.nbServices {
			guard let service = model.getNthService(index: UInt(i)), service.basicStatus == .Open else { continue }
			if !(service.id ?? "").hasPrefix(sharedPrefix) {
				connected = true
			}
		}
		return (connected ? .online : .offline, shared.note)
	}

	// A message as it is published: on one line and at most maxNoteLength characters, counted as the server counts
	// them (Unicode code points), never cutting a character in two
	static func sanitisedNote(_ note: String) -> String {
		var oneLine = note.components(separatedBy: .newlines).joined(separator: " ")
		oneLine = String(oneLine.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
		return limitedNote(oneLine).trimmingCharacters(in: .whitespaces)
	}

	// The message cut to at most maxNoteLength code points, whole characters only
	static func limitedNote(_ note: String) -> String {
		guard note.unicodeScalars.count > maxNoteLength else { return note }
		var result = ""
		var count = 0
		for character in note {
			let scalars = character.unicodeScalars.count
			if count + scalars > maxNoteLength { break }
			result.append(character)
			count += scalars
		}
		return result
	}
}

extension UserPresence {
	// The status as the shared status tuple ids name it. Offline and On a call cannot be chosen, so they are
	// Available (neither is ever published).
	var sharedToken: String {
		switch self {
		case .online, .offline, .onCall: return "available"
		case .away: return "away"
		case .busy: return "busy"
		case .doNotDisturb: return "dnd"
		}
	}

	init?(sharedToken: String) {
		switch sharedToken {
		case "available": self = .online
		case "away": self = .away
		case "busy": self = .busy
		case "dnd": self = .doNotDisturb
		default: return nil
		}
	}
}
