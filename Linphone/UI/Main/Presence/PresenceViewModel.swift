import Foundation
import SwiftUI
import linphonesw

// The user's own status and message.
//
// Every publication says what the user chose and when, in its tuple id (see SharedStatus):
// nmpbx-c.<status>.<chosen>.<device>. Where the customer is switched on for shared status, the phone server keeps one
// shared status per extension and publishes it as an nmpbx-s. tuple; this app watches its own extension and follows
// that tuple, so a status chosen on another app, the Portal or by a feature code shows here too. Where there is no
// nmpbx-s. tuple the app keeps the status saved on this device, as before.
//
// The app only ever publishes a status the user chose on this device, or the shared status it is following, with the
// time it was chosen. It never changes the status by itself.
class PresenceViewModel: ObservableObject {
	static let shared = PresenceViewModel()

	@Published var currentPresence: UserPresence = .online
	@Published var customStatusNote: String = ""

	private let configSection = "app"
	private let configKeyStatus = "presence_status"
	private let configKeyNote = "presence_note"
	// Unix time in seconds the saved status was chosen. 0 (and missing, on a new installation or one upgraded from a
	// version without it) means no choice yet, which never wins on the server.
	private let configKeyChosen = "presence_chosen"
	// Device token used only if the core has no +sip.instance to take it from
	private let configKeyDeviceFallback = "presence_device"

	// The hidden friend list holding the account's own extension, so its presence is watched whether or not it is in
	// the contacts. Not stored in the database, and of a kind and name the contacts lists ignore.
	static let ownPresenceFriendListName = "NMPBX own presence"

	// A status chosen on this device that the server's shared status may not show yet. Core queue only.
	private struct PendingChoice {
		let saved: SavedStatus
		let madeAt: Date
	}

	private struct SavedStatus: Equatable {
		var presence: UserPresence
		var note: String
		var chosen: Int
	}

	// Core queue only
	private var pendingChoice: PendingChoice?
	private var ownFriendList: FriendList?
	private var ownFriend: Friend?
	private var ownFriendDelegate: FriendDelegate?
	private var pendingChoiceRecheck: DispatchWorkItem?

	// MARK: - Called by the app

	// Called on startup: shows the saved status and sets it as the core's presence model, so the PUBLISH the SDK
	// sends on registration carries the saved choice with its original time.
	func loadSavedPresence() {
		CoreContext.shared.doOnCoreQueue { core in
			let saved = self.savedStatus(core: core)
			Log.info("[PRESENCE] loadSavedPresence: status=\(saved.presence.rawValue) chosen=\(saved.chosen) note='\(saved.note)'")
			self.showOnMain(saved)
			self.publish(saved, core: core)
		}
	}

	// Called from the UI (main thread) when the user picks a status or edits the message. A change of status or of
	// message is a new choice, with the time it was made. Picking what is already shown is not a choice.
	func setPresence(_ presence: UserPresence, note: String) {
		guard presence.isUserSelectable else {
			Log.warn("[PRESENCE] setPresence: \(presence.rawValue) cannot be chosen, ignored")
			return
		}
		let note = SharedStatus.sanitisedNote(note)
		currentPresence = presence
		customStatusNote = note

		CoreContext.shared.doOnCoreQueue { core in
			let previous = self.savedStatus(core: core)
			if previous.presence == presence && previous.note == note {
				return
			}

			// Strictly newer than the previous choice, so two choices in the same second are told apart by the server
			let now = Int(Date().timeIntervalSince1970)
			let choice = SavedStatus(presence: presence, note: note, chosen: max(now, previous.chosen + 1))
			Log.info("[PRESENCE] setPresence: new choice status=\(presence.rawValue) chosen=\(choice.chosen) note='\(note)'")
			self.pendingChoice = PendingChoice(saved: choice, madeAt: Date())
			self.save(choice, core: core)
			self.publish(choice, core: core)
		}
	}

	// Called each time the default account registers (start-up, returning to the foreground, refresh, network
	// change): publishes the saved choice with its original time, and makes sure the own extension is watched. If the
	// server holds a newer shared status it ignores this publication, and the next NOTIFY brings the status to follow.
	func onAccountRegistered() {
		CoreContext.shared.doOnCoreQueue { core in
			let saved = self.savedStatus(core: core)
			Log.info("[PRESENCE] onAccountRegistered: republishing saved status=\(saved.presence.rawValue) chosen=\(saved.chosen)")
			// A choice not taken up yet may not have reached the server (made while the network was down, for
			// instance): its window starts again now that it is sent, so the older shared status that may come first
			// does not replace it
			if let pending = self.pendingChoice, pending.saved == saved {
				self.pendingChoice = PendingChoice(saved: saved, madeAt: Date())
			}
			self.publish(saved, core: core)
			self.watchOwnExtension(core: core)
		}
	}

	// MARK: - Following the shared status

	// Subscribes to the account's own extension through a hidden friend list, and keeps it subscribed for as long as
	// the account is there. Done again on each registration, which only changes something if the account changed.
	private func watchOwnExtension(core: Core) {
		guard let identity = core.defaultAccount?.params?.identityAddress?.clone() else {
			Log.warn("[PRESENCE] watchOwnExtension: no identity address on the default account")
			return
		}
		identity.clean()
		let ownUri = identity.asStringUriOnly()

		let friendList: FriendList
		if let existing = ownFriendList ?? core.getFriendListByName(name: Self.ownPresenceFriendListName) {
			friendList = existing
		} else {
			guard let created = try? core.createFriendList() else {
				Log.error("[PRESENCE] watchOwnExtension: could not create the own presence friend list")
				return
			}
			created.displayName = Self.ownPresenceFriendListName
			created.databaseStorageEnabled = false
			core.addFriendList(list: created)
			friendList = created
			Log.info("[PRESENCE] watchOwnExtension: created the own presence friend list")
		}
		ownFriendList = friendList

		// The presence server only answers subscriptions through its resource list server
		let rlsUri = core.config?.getString(section: "carddav_provision", key: "rls_uri", defaultString: "") ?? ""
		if !rlsUri.isEmpty && friendList.rlsUri != rlsUri {
			friendList.rlsUri = rlsUri
		}

		if ownFriend?.address?.asStringUriOnly() == ownUri, friendList.findFriendByUri(uri: ownUri) != nil {
			// Already watching this account
			if !friendList.subscriptionsEnabled {
				friendList.subscriptionsEnabled = true
			}
			return
		}

		// A different account, or the first time: watch the account's extension instead of whatever was before
		if let friend = ownFriend, let delegate = ownFriendDelegate {
			friend.removeDelegate(delegate: delegate)
		}
		ownFriendDelegate = nil
		ownFriend = nil
		friendList.friends.forEach { _ = friendList.removeFriend(linphoneFriend: $0) }
		pendingChoice = nil

		do {
			let friend = try core.createFriend()
			try friend.setAddress(newValue: identity)
			try friend.setSubscribesenabled(newValue: true)
			try friend.setIncsubscribepolicy(newValue: .SPDeny)

			let delegate = FriendDelegateStub(onPresenceReceived: { [weak self] (friend: Friend) in
				self?.onOwnPresenceReceived(model: friend.presenceModel, core: core)
			})
			friend.addDelegate(delegate: delegate)
			_ = friendList.addFriend(linphoneFriend: friend)

			ownFriend = friend
			ownFriendDelegate = delegate
			friendList.subscriptionsEnabled = true
			core.friendListSubscriptionEnabled = true
			friendList.updateSubscriptions()
			Log.info("[PRESENCE] watchOwnExtension: watching \(ownUri) (rls=\(friendList.rlsUri ?? "none"))")
		} catch {
			Log.error("[PRESENCE] watchOwnExtension: could not watch \(ownUri): \(error)")
		}
	}

	// A NOTIFY for the own extension. Must be called on the core queue.
	private func onOwnPresenceReceived(model: PresenceModel?, core: Core) {
		guard let shared = SharedStatus.shared(in: model) else {
			// Not switched on (or no shared status yet): the status saved on this device stays as it is
			Log.info("[PRESENCE] own presence received: no shared status tuple, keeping the saved status")
			return
		}

		let saved = savedStatus(core: core)
		let sharedStatus = SavedStatus(presence: shared.presence, note: shared.note, chosen: shared.chosen)

		if let pending = pendingChoice {
			let age = Date().timeIntervalSince(pending.madeAt)
			if sharedStatus == pending.saved {
				// The server has taken up the choice made here
				pendingChoice = nil
			} else if age < SharedStatus.pendingChoiceWindow && shared.chosen <= pending.saved.chosen {
				// The server has not taken up the choice made here yet, and holds nothing newer: keep showing it, and
				// look again once the window is over in case no other NOTIFY comes
				Log.info("[PRESENCE] own presence received: shared status=\(shared.presence.rawValue) chosen=\(shared.chosen) does not show the choice made \(Int(age))s ago yet, keeping it")
				scheduleRecheck(after: SharedStatus.pendingChoiceWindow - age, core: core)
				return
			} else {
				pendingChoice = nil
			}
		}

		if sharedStatus == saved {
			// Already showing and publishing it, as this NOTIFY may be our own publication coming back
			showOnMain(saved)
			return
		}

		// Follow the shared status, whatever this device's saved time says: the server decides what is newest.
		// Republished with the shared time, so the server sees it as nothing new.
		Log.info("[PRESENCE] own presence received: following shared status=\(shared.presence.rawValue) chosen=\(shared.chosen) source=\(shared.origin) note='\(shared.note)' (saved was \(saved.presence.rawValue) chosen=\(saved.chosen))")
		save(sharedStatus, core: core)
		showOnMain(sharedStatus)
		publish(sharedStatus, core: core)
	}

	private func scheduleRecheck(after delay: TimeInterval, core: Core) {
		pendingChoiceRecheck?.cancel()
		let work = DispatchWorkItem { [weak self] in
			CoreContext.shared.doOnCoreQueue { core in
				guard let self = self, let pending = self.pendingChoice,
					  Date().timeIntervalSince(pending.madeAt) >= SharedStatus.pendingChoiceWindow else { return }
				Log.info("[PRESENCE] pending choice window over, following the server")
				self.pendingChoice = nil
				self.onOwnPresenceReceived(model: self.ownFriend?.presenceModel, core: core)
			}
		}
		pendingChoiceRecheck = work
		DispatchQueue.main.asyncAfter(deadline: .now() + max(delay, 0) + 0.5, execute: work)
	}

	// MARK: - Saved status

	private func savedStatus(core: Core) -> SavedStatus {
		let config = core.config
		let raw = config?.getString(section: configSection, key: configKeyStatus, defaultString: UserPresence.online.rawValue) ?? UserPresence.online.rawValue
		var presence = UserPresence(rawValue: raw) ?? .online
		if !presence.isUserSelectable {
			// There is no Offline status to choose, and On a call is only ever shown
			presence = .online
		}
		let note = config?.getString(section: configSection, key: configKeyNote, defaultString: "") ?? ""
		// Kept as a string: the config's integers are 32 bits
		let chosen = Int(config?.getString(section: configSection, key: configKeyChosen, defaultString: "0") ?? "0") ?? 0
		return SavedStatus(presence: presence, note: note, chosen: max(chosen, 0))
	}

	private func save(_ status: SavedStatus, core: Core) {
		core.config?.setString(section: configSection, key: configKeyStatus, value: status.presence.rawValue)
		core.config?.setString(section: configSection, key: configKeyNote, value: status.note)
		core.config?.setString(section: configSection, key: configKeyChosen, value: String(status.chosen))
	}

	private func showOnMain(_ status: SavedStatus) {
		DispatchQueue.main.async {
			if self.currentPresence != status.presence {
				self.currentPresence = status.presence
			}
			if self.customStatusNote != status.note {
				self.customStatusNote = status.note
			}
		}
	}

	// MARK: - Publishing

	// This installation's token in the tuple id: the account's +sip.instance UUID with only letters, digits and
	// hyphens kept, so the Portal can match a status to the device that registered. It differs for every
	// installation, which it must, as two publications with the same tuple id hide each other.
	private func deviceToken(core: Core) -> String {
		let instance = core.config?.getString(section: "misc", key: "uuid", defaultString: "") ?? ""
		let token = Self.tokenCharacters(instance.replacingOccurrences(of: "urn:uuid:", with: ""))
		if !token.isEmpty && instance != "0" {
			return token
		}

		// The core has no +sip.instance (it can be turned off with uuid=0): use one made for this installation
		let saved = Self.tokenCharacters(core.config?.getString(section: configSection, key: configKeyDeviceFallback, defaultString: "") ?? "")
		if !saved.isEmpty {
			return saved
		}
		let generated = UUID().uuidString.lowercased()
		core.config?.setString(section: configSection, key: configKeyDeviceFallback, value: generated)
		Log.warn("[PRESENCE] no +sip.instance in the config, generated device token \(generated)")
		return generated
	}

	private static func tokenCharacters(_ value: String) -> String {
		let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-")
		var scalars = String.UnicodeScalarView()
		for scalar in value.unicodeScalars where allowed.contains(scalar) {
			scalars.append(scalar)
		}
		return String(String(scalars).prefix(64))
	}

	// Sets the core's presence model to the given choice. The model always has a service carrying the choice tuple id
	// (the SDK makes a random id only for a model with no service, or one whose service has no id), the message in
	// that tuple's note, and the RPID activity as before (none for Available), which older readers and the DND
	// rules depend on. Must be called on the core queue.
	private func publish(_ status: SavedStatus, core: Core) {
		guard core.config?.getBool(section: configSection, key: "publish_presence", defaultValue: true) == true else {
			Log.warn("[PRESENCE] publish: skipped, publish_presence is disabled in the config")
			return
		}

		let tupleId = SharedStatus.choiceTupleId(presence: status.presence, chosen: status.chosen, device: deviceToken(core: core))
		do {
			let model = try core.createPresenceModel()

			// Empty contact: the SDK writes the account's identity, as before
			let service = try core.createPresenceService(id: tupleId, basicStatus: .Open, contact: "")
			if !status.note.isEmpty {
				let note = try core.createPresenceNote(content: status.note, lang: Locale.current.languageCode)
				try service.addNote(note: note)
			}
			try model.addService(service: service)

			if let kind = status.presence.activityKind {
				let activity = try core.createPresenceActivity(
					acttype: kind,
					description: status.presence == .doNotDisturb ? UserPresence.dndDescription : nil
				)
				try model.addActivity(activity: activity)
			}

			core.presenceModel = model
			Log.info("[PRESENCE] publish: tuple=\(tupleId) note='\(status.note)' activity=\(String(describing: status.presence.activityKind)) publishEnabled=\(core.defaultAccount?.params?.publishEnabled == true)")

			// Receiving others' presence is independent of what we publish
			core.friendListSubscriptionEnabled = true
		} catch {
			Log.error("[PRESENCE] publish: failed to create the presence model for \(tupleId): \(error)")
		}
	}
}
