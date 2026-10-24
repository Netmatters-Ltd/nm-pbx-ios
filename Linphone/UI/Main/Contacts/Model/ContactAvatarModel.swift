/*
 * Copyright (c) 2010-2023 Belledonne Communications SARL.
 *
 * This file is part of NMPBX
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <http://www.gnu.org/licenses/>.
 */

import Foundation
import linphonesw
import Combine

class ContactAvatarModel: ObservableObject, Identifiable {
	let id = UUID()

	// A hash of everything the model shows from its friend when it was made, to tell whether the friend has changed
	// since. Only means something within the run of the app, it is not the same from one run to the next.
	private(set) var contentHash: Int = 0

	// Written on the core queue and read from any thread, so it is behind stateLock
	var friend: Friend? {
		get {
			stateLock.lock()
			defer { stateLock.unlock() }
			return storedFriend
		}
		set {
			stateLock.lock()
			storedFriend = newValue
			stateLock.unlock()
		}
	}
	private var storedFriend: Friend?

	@Published var name: String = ""
	@Published var address: String = ""
	@Published var addresses: [String] = []

	var withPresence: Bool?
	var isInternal: Bool = false

	@Published var starred: Bool = false

	// Cheap to read, so these are read when the model is made, see loadSummary(friend:)
	var nativeUri: String = ""
	var editable: Bool = true
	var organization: String = ""
	var jobTitle: String = ""
	// Read with the others, as screens read it once as they are drawn, to choose what to offer, and would get the wrong
	// answer from a value that arrives later
	@Published var isReadOnly = false

	// The path of the photo, "file:/<hash>.png". Empty until the model is loaded and the photo is on disk, so the
	// avatar shows initials until then, and empty for a contact without a photo. See loadPhoto().
	@Published var photo: String = ""

	// The details that are costly to read are lazy. The first time one of them is read, all of them are read
	// from the friend, on the core queue, and published when they are ready, so they are empty until then.
	// See requestDetails().
	@Published private var storedPhoneNumbersWithLabel: [(label: String, phoneNumber: String)] = []
	@Published private var storedVcard: Vcard?

	var phoneNumbersWithLabel: [(label: String, phoneNumber: String)] {
		requestDetails()
		return storedPhoneNumbersWithLabel
	}

	var vcard: Vcard? {
		requestDetails()
		return storedVcard
	}

	@Published var presenceStatus: ConsolidatedPresence = .Offline
	@Published var presenceActivity: PresenceActivity.Kind? = nil
	@Published var presenceNote: String = ""

	var presenceUserStatus: UserPresence {
		switch presenceStatus {
		case .Online:
			// Person-level activity (e.g. <p2:busy/>) can arrive with the same or newer
			// timestamp than the tuple's basic=open; honour it even when the SDK's
			// consolidated presence is .Online.  nil activity → plain Available.
			switch presenceActivity {
			case .Away: return .away
			case .Busy: return .busy
			case .Other: return .doNotDisturb
			default: return .online
			}
		case .Busy:
			switch presenceActivity {
			case .Away: return .away
			case .Busy: return .busy
			case .Other: return .doNotDisturb
			default: return .busy
			}
		default:
			return .offline
		}
	}

	private var friendDelegate: FriendDelegate?

	// What load() reads the model from, kept as plain values so it can be called from any thread
	private var loadName = ""
	private var loadAddress = ""
	private var presenceWanted: Bool?

	// What the search filter compares, prepared when the model is created so a search only has to look for
	// the text in them, and so it can be done before the model is loaded. Written on the core queue and read from
	// any thread, so they are kept together behind stateLock and replaced as one.
	private struct SearchValues {
		var name = ""
		var uris: [String] = []
		var usernames: [String] = []
		var numbers: [String] = []
	}
	private let stateLock = NSLock()
	private var searchValues = SearchValues()

	var searchUris: [String] {
		stateLock.lock()
		defer { stateLock.unlock() }
		return searchValues.uris
	}

	/// Whether the search text is in the name or in the number of one of the SIP addresses (the extension), or the digits
	/// are in one of the phone numbers. The text is normalised by normalisedForSearch(_:), the digits are only digits.
	func matches(text: String, digits: String) -> Bool {
		stateLock.lock()
		let values = searchValues
		stateLock.unlock()

		if values.name.contains(text) {
			return true
		}

		if values.usernames.contains(where: { $0.contains(text) }) {
			return true
		}

		return !digits.isEmpty && values.numbers.contains { $0.contains(digits) }
	}

	// Whether the presence of the friend is being followed, and the job that will stop following it. The presence
	// is only followed while views keep the model loaded, see keepLoaded(). The costly details do not depend on
	// it, they are read when they are first needed.
	private let loadLock = NSLock()
	private var loaded = false
	// When the model stops following the presence if nothing keeps it loaded, and whether a timer is waiting for that
	// time. Both are behind loadLock.
	private var unloadDeadline = Date.distantPast
	private var unloadTimerScheduled = false

	private var isLoaded: Bool {
		loadLock.lock()
		defer { loadLock.unlock() }
		return loaded
	}

	// Whether the costly details have been asked for, so they are only read once
	private let detailsLock = NSLock()
	private var detailsRequested = false

	// Whether the photo has been looked at, so it is only read once, see loadPhoto(). Only used on the core queue.
	private var photoRequested = false

	init(friend: Friend?, name: String, address: String, withPresence: Bool?, contentHash: Int = 0) {
		self.name = name
		self.address = address
		self.withPresence = withPresence
		self.contentHash = contentHash

		modelUpdate(friend: friend, name: name, address: address, withPresence: withPresence)
	}

	/// Replaces the friend of the model, and its name and address, for instance after the contact has been edited.
	/// Everything read from the friend is read again.
	func update(friend: Friend?, name: String, address: String, withPresence: Bool?) {
		CoreContext.shared.doOnCoreQueue { _ in
			self.modelUpdate(friend: friend, name: name, address: address, withPresence: withPresence)

			// The presence and photo of the new friend are followed if a view is showing the model
			if self.isLoaded {
				self.loadPresence()
				self.loadPhoto()
			}

			DispatchQueue.main.async {
				self.name = name
				self.address = address
				self.withPresence = withPresence
			}
		}
	}

	/// Points the model at a friend: stops following the previous friend, reads the summary of the new one, marks the
	/// costly details and the photo to be read again the next time they are needed. Must be called on the core queue, except from init, where there is nothing to stop or
	/// follow yet and the summary moves to the core queue itself.
	private func modelUpdate(friend: Friend?, name: String, address: String, withPresence: Bool?) {
		// The presence of the previous friend is no longer followed
		self.removeFriendDelegate()

		self.friend = friend
		self.loadName = name
		self.loadAddress = address
		self.presenceWanted = withPresence
		self.loadSummary(friend: friend)

		// The costly details are read again the next time one of them is asked for
		self.detailsLock.lock()
		self.detailsRequested = false
		self.detailsLock.unlock()

		// The photo is looked at again the next time the model is loaded, or now if it is loaded
		self.photoRequested = false
	}

	/// A model for someone who is not a contact, named from the address: its display name, or else its username
	/// or the username part of the URI
	convenience init(address: Address) {
		let name = address.displayName ?? address.username ?? address.asStringUriOnly().sipUsername
		self.init(friend: nil, name: name, address: address.asStringUriOnly(), withPresence: false)
	}

	/// Lowercase and without accents, which is how names and the search text are compared
	static func normalisedForSearch(_ text: String) -> String {
		return text.lowercased().folding(options: .diacriticInsensitive, locale: .current)
	}

	// The username of a SIP address, which is the extension: "sip:101@domain" gives "101"
	private static func username(ofSipUri uri: String) -> String {
		var rest = Substring(uri)
		if let colon = rest.firstIndex(of: ":") {
			rest = rest[rest.index(after: colon)...]
		}

		let username = rest.split(separator: "@", maxSplits: 1).first.map(String.init) ?? ""
		return normalisedForSearch(username)
	}

	// What is cheap to read, and is needed before the model is loaded: the addresses and numbers for the
	// search filter, whether it is an extension for the Extensions and Contacts split, and the plain details a
	// row shows. Read when the model is created, and again whenever it is updated.
	private func loadSummary(friend: Friend?) {
		CoreContext.shared.doOnCoreQueue { core in
			let friendAddresses = friend?.addresses ?? []
			let addressesTmp = friendAddresses.map { $0.asStringUriOnly() }

			var searchValuesTmp = SearchValues()
			searchValuesTmp.uris = addressesTmp
			searchValuesTmp.name = ContactAvatarModel.normalisedForSearch(self.loadName)
			searchValuesTmp.usernames = addressesTmp.map { ContactAvatarModel.username(ofSipUri: $0) }
			// Only the digits of a phone number are compared, ignoring spaces and punctuation
			searchValuesTmp.numbers = (friend?.phoneNumbers ?? []).map { $0.filter { $0.isNumber } }.filter { !$0.isEmpty }

			self.stateLock.lock()
			self.searchValues = searchValuesTmp
			self.stateLock.unlock()

			let domain = core.defaultAccount?.params?.domain ?? ""
			let isInternalTmp = !domain.isEmpty && friendAddresses.contains { $0.domain == domain }

			let starredTmp = friend?.starred ?? false
			let nativeUriTmp = friend?.nativeUri ?? ""
			let editableTmp = friend?.friendList?.type == .CardDAV || nativeUriTmp.isEmpty
			let organizationTmp = friend?.organization ?? ""
			let jobTitleTmp = friend?.jobTitle ?? ""
			let isReadOnlyTmp = (friend?.isReadOnly == true) || (friend?.inList() == false)

			DispatchQueue.main.async {
				self.addresses = addressesTmp
				self.isInternal = isInternalTmp
				self.starred = starredTmp
				self.nativeUri = nativeUriTmp
				self.editable = editableTmp
				self.organization = organizationTmp
				self.jobTitle = jobTitleTmp
				self.isReadOnly = isReadOnlyTmp
			}
		}
	}

	// Starts reading the costly details the first time one of them is read. Only starts the read, which is done
	// on the core queue and published when it is finished, so it can be called while a view is drawn.
	private func requestDetails() {
		detailsLock.lock()
		let isFirst = !detailsRequested
		detailsRequested = true
		detailsLock.unlock()

		if isFirst {
			CoreContext.shared.doOnCoreQueue { _ in
				self.readDetails()
			}
		}
	}

	// Reads the costly details from the friend. Must be called on the core queue.
	private func readDetails() {
		let friend = self.friend

		var phoneNumbersWithLabelTmp: [(label: String, phoneNumber: String)] = []
		if let friend = friend {
			friend.phoneNumbersWithLabel.forEach { phoneNum in
				phoneNumbersWithLabelTmp.append((label: phoneNum.label ?? "", phoneNumber: phoneNum.phoneNumber))
			}
		}
		let vcardTmp = friend?.vcard ?? nil

		DispatchQueue.main.async {
			self.storedPhoneNumbersWithLabel = phoneNumbersWithLabelTmp
			self.storedVcard = vcardTmp
		}
	}

	// How long after the last call to keepLoaded() the model stops following the presence
	private static let keepLoadedDuration: TimeInterval = 100

	/// Keeps the presence of the friend followed for another 100 seconds, and starts following it if it is not.
	/// Views call this when they appear and again every 30 seconds while they show the model, and a search calls
	/// it for the models it lists. The model stops following the presence 100 seconds after the last call, so
	/// nothing has to say when a view has gone. Can be called from any thread.
	func keepLoaded() {
		loadLock.lock()
		unloadDeadline = Date().addingTimeInterval(ContactAvatarModel.keepLoadedDuration)
		let needsLoad = !loaded
		loaded = true
		let needsTimer = !unloadTimerScheduled
		unloadTimerScheduled = true
		loadLock.unlock()

		if needsLoad {
			load()
		}

		if needsTimer {
			scheduleUnloadCheck(after: ContactAvatarModel.keepLoadedDuration)
		}
	}

	// One timer per model, however often keepLoaded() is called. When it goes off, the model is unloaded if nothing
	// kept it loaded since, and if something did, the timer is set again for the time that is left.
	private func scheduleUnloadCheck(after delay: TimeInterval) {
		DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
			guard let self = self else {
				return
			}

			self.loadLock.lock()
			let remaining = self.unloadDeadline.timeIntervalSinceNow
			if remaining > 0 {
				self.loadLock.unlock()
				self.scheduleUnloadCheck(after: remaining)
				return
			}

			// Unloaded and the timer cleared under one lock, so a keepLoaded() in between starts a new timer
			self.loaded = false
			self.unloadTimerScheduled = false
			self.loadLock.unlock()

			self.unload()
		}
	}

	// Starts following the presence of the friend, and finds its photo
	private func load() {
		// The values are read on the core queue, where update writes them
		CoreContext.shared.doOnCoreQueue { _ in
			self.loadPresence()
			self.loadPhoto()
		}
	}

	// Finds the photo of the friend, the first time the model is loaded, and publishes its path. The photo is read
	// from the friend here and not when the model is made, as it can be a string of hundreds of kilobytes and most
	// models are never shown. Must be called on the core queue.
	private func loadPhoto() {
		if photoRequested {
			return
		}
		photoRequested = true

		let photo = friend?.photo ?? ""

		// No photo: the avatar shows initials. Clears a photo from before, if the friend had one.
		// The store gives the path to show: none for no photo, a file path as it is (a contact made in the app), and
		// the file it writes for a data URI (as a CardDAV server sends it). The string is not kept.
		ContactImageStore.shared.path(for: photo) { path in
			guard let path = path else {
				return
			}

			DispatchQueue.main.async {
				if self.photo != path {
					self.photo = path
				}
			}
		}
	}

	// Stops following the presence. The values already read are kept, so keeping the model loaded again only has
	// to start following the presence.
	private func unload() {
		CoreContext.shared.doOnCoreQueue { _ in
			// Kept loaded again before this ran
			if !self.isLoaded {
				self.removeFriendDelegate()
			}
		}
	}

	// Reads what the presence of the friend is, and follows it if the model is made to. Must be called on the core
	// queue.
	private func loadPresence() {
		let friend = self.friend

		var presenceStatusTmp: ConsolidatedPresence = .Offline
		var presenceActivityTmp: PresenceActivity.Kind? = nil
		var presenceNoteTmp = ""

		if let friend = friend, presenceWanted == true {

			// Each property of the friend is read once, as every read goes to the SDK
			let presenceModel = friend.presenceModel

			presenceStatusTmp = friend.consolidatedPresence
			presenceActivityTmp = presenceModel?.activity?.type
			presenceNoteTmp = presenceModel?.getNote(lang: nil)?.content ?? ""

			if let delegate = self.friendDelegate {
				friend.removeDelegate(delegate: delegate)
				self.friendDelegate = nil
			}

			self.addFriendDelegate(friend: friend, presence: presenceStatusTmp)
		}

		DispatchQueue.main.async {
			self.presenceStatus = presenceStatusTmp
			self.presenceActivity = presenceActivityTmp
			self.presenceNote = presenceNoteTmp
		}
	}

	private func addFriendDelegate(friend: Friend, presence: ConsolidatedPresence) {
		Log.info("[PRESENCE-DEBUG] ContactAvatarModel.addFriendDelegate: '\(loadAddress)' currentPresence=\(presence)")

		friendDelegate = FriendDelegateStub(onPresenceReceived: { (friend: Friend) in
			let presenceModel = friend.presenceModel
			let consolidatedPresenceTmp = friend.consolidatedPresence
			let presenceActivityTmp = presenceModel?.activity?.type
			let presenceNoteTmp = presenceModel?.getNote(lang: nil)?.content ?? ""
			Log.info("[PRESENCE-DEBUG] ContactAvatarModel.onPresenceReceived: '\(loadAddress)' consolidated=\(consolidatedPresenceTmp) activity=\(String(describing: presenceActivityTmp))")
			
			DispatchQueue.main.async {
				self.presenceStatus = consolidatedPresenceTmp
				self.presenceActivity = presenceActivityTmp
				self.presenceNote = presenceNoteTmp
			}
		})

		if friendDelegate != nil {
			friend.addDelegate(delegate: friendDelegate!)
		}
	}

	func removeFriendDelegate() {
		if let delegate = friendDelegate {
			DispatchQueue.main.async {
				self.presenceStatus = .Offline
			}
			if let friendTmp = friend {
				friendTmp.removeDelegate(delegate: delegate)
			}
			friendDelegate = nil
		}
	}

}
