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
		case .away: return .orangeAway
		case .busy: return .blueInfo500
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
	static let callStatePrefix = "nmpbx-callstate"

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
	// The status and message are the shared ones. A shared Available is only shown as available while something of
	// theirs is connected (the server's own tuple is closed for Available), and being on a call still shows as it
	// did before (busy) when the shared status would otherwise be Available.
	static func colleaguePresence(model: PresenceModel?) -> (presence: UserPresence, note: String)? {
		guard let model = model, let shared = shared(in: model) else { return nil }
		if shared.presence != .online {
			return (shared.presence, shared.note)
		}

		var connected = false
		var onThePhone = false
		for i in 0..<model.nbServices {
			guard let service = model.getNthService(index: UInt(i)), service.basicStatus == .Open else { continue }
			let id = service.id ?? ""
			if id.hasPrefix(callStatePrefix) {
				onThePhone = true
			} else if !id.hasPrefix(sharedPrefix) {
				connected = true
			}
		}
		for i in 0..<model.nbPersons {
			guard let person = model.getNthPerson(index: UInt(i)) else { continue }
			for j in 0..<person.nbActivities where person.getNthActivity(index: UInt(j))?.type == .OnThePhone {
				onThePhone = true
			}
		}

		if onThePhone {
			return (.busy, shared.note)
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
	// The status as the shared status tuple ids name it. There is no Offline status to choose, so it is Available.
	var sharedToken: String {
		switch self {
		case .online, .offline: return "available"
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
