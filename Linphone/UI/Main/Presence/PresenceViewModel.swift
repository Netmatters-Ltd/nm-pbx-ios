import Foundation
import SwiftUI
import linphonesw

class PresenceViewModel: ObservableObject {
	static let shared = PresenceViewModel()

	@Published var currentPresence: UserPresence = .online
	@Published var customStatusNote: String = ""

	private let configSection = "app"
	private let configKeyStatus = "presence_status"
	private let configKeyNote = "presence_note"

	// Delegate and guard for the subscribe-to-self sync on registration
	private var selfFriend: Friend?
	private var selfFriendDelegate: FriendDelegate?
	private var didSyncFromServer = false

	// Called on startup — just warms the UI state, does not publish.
	// Actual publishing is deferred to restoreOrGoOnline() after registration.
	func loadSavedPresence() {
		CoreContext.shared.doOnCoreQueue { core in
			let savedStatus = core.config?.getString(section: self.configSection, key: self.configKeyStatus, defaultString: UserPresence.online.rawValue) ?? UserPresence.online.rawValue
			let savedNote = core.config?.getString(section: self.configSection, key: self.configKeyNote, defaultString: "") ?? ""
			let presence = UserPresence(rawValue: savedStatus) ?? .online
			DispatchQueue.main.async {
				self.currentPresence = presence
				self.customStatusNote = savedNote
			}
		}
	}

	func setPresence(_ presence: UserPresence, note: String) {
		// Update UI state immediately (called from main thread via UI)
		currentPresence = presence
		customStatusNote = note
		CoreContext.shared.doOnCoreQueue { core in
			core.config?.setString(section: self.configSection, key: self.configKeyStatus, value: presence.rawValue)
			core.config?.setString(section: self.configSection, key: self.configKeyNote, value: note)
			self.publish(presence: presence, note: note, core: core)
		}
	}

	// Called after registration. Subscribes to our own presence so that a status set
	// on another device (e.g. the desktop) is picked up automatically. Falls back to
	// local config if no NOTIFY arrives within 2 seconds.
	func restoreOrGoOnline() {
		didSyncFromServer = false
		CoreContext.shared.doOnCoreQueue { core in
			guard let ownAddress = core.defaultAccount?.params?.identityAddress else {
				self.publishLocalConfig(core: core)
				return
			}

			// Remove any leftover delegate from a previous registration cycle
			if let prevDelegate = self.selfFriendDelegate, let prevFriend = self.selfFriend {
				prevFriend.removeDelegate(delegate: prevDelegate)
			}

			if let selfFriend = core.findFriend(address: ownAddress) {
				// Our own extension is in the contact directory — subscribe to it
				// to receive whatever was last published by any device.
				let delegate = FriendDelegateStub(onPresenceReceived: { [weak self] (friend: Friend) in
					guard let self = self, !self.didSyncFromServer else { return }
					self.didSyncFromServer = true
					// Remove delegate immediately so subsequent own-presence updates
					// (from other contacts' views of us) don't re-trigger this path.
					if let d = self.selfFriendDelegate {
						friend.removeDelegate(delegate: d)
						self.selfFriendDelegate = nil
					}
					self.applyServerPresence(from: friend, core: core)
				})
				self.selfFriend = selfFriend
				self.selfFriendDelegate = delegate
				selfFriend.addDelegate(delegate: delegate)
			} else {
				// Own address not in contacts — fall back immediately.
				self.publishLocalConfig(core: core)
				return
			}

			// Fallback: if no NOTIFY arrives within 2 seconds, publish local config.
			DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
				CoreContext.shared.doOnCoreQueue { core in
					guard !self.didSyncFromServer else { return }
					self.didSyncFromServer = true
					self.publishLocalConfig(core: core)
				}
			}
		}
	}

	// MARK: - Private

	// Reads the server's current presence for our own identity and publishes the same
	// status so the aggregated state seen by other extensions is unchanged.
	private func applyServerPresence(from friend: Friend, core: Core) {
		let activityKind = friend.presenceModel?.activity?.type
		let note = friend.presenceModel?.getNote(lang: nil)?.content ?? ""
		let presence = UserPresence.from(
			activityKind: activityKind,
			description: activityKind == .Other ? UserPresence.dndDescription : nil
		)

		if presence != .offline {
			// Server has an active published status — mirror it.
			core.config?.setString(section: configSection, key: configKeyStatus, value: presence.rawValue)
			core.config?.setString(section: configSection, key: configKeyNote, value: note)
			DispatchQueue.main.async {
				self.currentPresence = presence
				self.customStatusNote = note
			}
			publish(presence: presence, note: note, core: core)
		} else {
			// No active PUBLISH on the server (all devices offline) — use local config.
			publishLocalConfig(core: core)
		}
	}

	private func publishLocalConfig(core: Core) {
		let savedStatus = core.config?.getString(section: configSection, key: configKeyStatus, defaultString: UserPresence.online.rawValue) ?? UserPresence.online.rawValue
		let savedNote = core.config?.getString(section: configSection, key: configKeyNote, defaultString: "") ?? ""
		let presence = UserPresence(rawValue: savedStatus) ?? .online
		DispatchQueue.main.async {
			self.currentPresence = presence
			self.customStatusNote = savedNote
		}
		publish(presence: presence, note: savedNote, core: core)
	}

	private func publish(presence: UserPresence, note: String, core: Core) {
		guard core.config?.getBool(section: configSection, key: "publish_presence", defaultValue: true) == true else { return }

		do {
			let model: PresenceModel
			if let kind = presence.activityKind {
				if !note.isEmpty {
					model = try core.createPresenceModelWithActivityAndNote(
						acttype: kind,
						description: presence == .doNotDisturb ? UserPresence.dndDescription : nil,
						note: note,
						lang: Locale.current.languageCode
					)
				} else {
					model = try core.createPresenceModelWithActivity(
						acttype: kind,
						description: presence == .doNotDisturb ? UserPresence.dndDescription : nil
					)
				}
			} else {
				// Online: plain open presence, no activity
				model = try core.createPresenceModel()
				if !note.isEmpty {
					try model.addNote(noteContent: note, lang: Locale.current.languageCode)
				}
			}

			core.presenceModel = model

			// Disable friend list subscriptions when offline (matches desktop behaviour)
			core.friendListSubscriptionEnabled = presence != .offline
		} catch {
			Log.error("[PresenceViewModel] Failed to create presence model: \(error)")
		}
	}
}
