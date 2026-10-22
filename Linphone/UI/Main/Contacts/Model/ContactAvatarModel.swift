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
	
	var friend: Friend?
	
	@Published var name: String = ""
	@Published var address: String = ""
	@Published var addresses: [String] = []
	@Published var phoneNumbersWithLabel: [(label: String, phoneNumber: String)] = []
	
	var nativeUri: String = ""
	var editable: Bool = true
	var isReadOnly: Bool = false
	var withPresence: Bool?
	var isInternal: Bool = false
	
	@Published var starred: Bool = false
	
	var vcard: Vcard?
	var organization: String = ""
	var jobTitle: String = ""
	
	@Published var photo: String = ""
	@Published var lastPresenceInfo: String = ""
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
	// the text in them, and so it can be done before the model is loaded. Written on the core queue.
	private(set) var searchName = ""
	private(set) var searchUris: [String] = []
	private(set) var searchUsernames: [String] = []
	private(set) var searchNumbers: [String] = []

	// Number of views showing the model. The details and the presence are only read and followed while
	// it is above 0, see load() and unload().
	private let loadLock = NSLock()
	private var loadCount = 0

	private var isLoaded: Bool {
		loadLock.lock()
		defer { loadLock.unlock() }
		return loadCount > 0
	}
	
	init(friend: Friend?, name: String, address: String, withPresence: Bool?, deferLoad: Bool = false) {
		self.name = name
	 	self.address = address
		self.friend = friend
		self.loadName = name
		self.loadAddress = address
		self.presenceWanted = withPresence

		// A model that is not deferred is loaded for good, a deferred one waits for a view to load it
		if !deferLoad {
			load()
		} else {
			loadAddresses(friend: friend)
		}
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

	// The part of the model that is needed before it is loaded: its addresses and numbers, for the search
	// filter, and whether it is an extension, for the Extensions and Contacts split. Read when the model is
	// created if it is deferred, and again whenever it is reset.
	private func loadAddresses(friend: Friend?) {
		CoreContext.shared.doOnCoreQueue { core in
			let friendAddresses = friend?.addresses ?? []
			let addressesTmp = friendAddresses.map { $0.asStringUriOnly() }
			
			self.searchUris = addressesTmp
			self.searchName = ContactAvatarModel.normalisedForSearch(self.loadName)
			self.searchUsernames = addressesTmp.map { ContactAvatarModel.username(ofSipUri: $0) }
			// Only the digits of a phone number are compared, ignoring spaces and punctuation
			self.searchNumbers = (friend?.phoneNumbers ?? []).map { $0.filter { $0.isNumber } }.filter { !$0.isEmpty }
			
			let domain = core.defaultAccount?.params?.domain ?? ""
			let isInternalTmp = !domain.isEmpty && friendAddresses.contains { $0.domain == domain }
			
			DispatchQueue.main.async {
				self.addresses = addressesTmp
				self.isInternal = isInternalTmp
			}
		}
	}
	

	/// Reads everything from the friend and starts following its presence. Counted, so every call must
	/// be matched by an unload() when the view stops showing the model.
	func load() {
		loadLock.lock()
		loadCount += 1
		let isFirst = loadCount == 1
		loadLock.unlock()

		if isFirst {
			// The values are read on the core queue, where resetContactAvatarModel writes them
			CoreContext.shared.doOnCoreQueue { _ in
				self.resetContactAvatarModel(friend: self.friend, name: self.loadName, address: self.loadAddress, withPresence: self.presenceWanted)
			}
		}
	}

	/// Stops following the presence once the last view that loaded the model has unloaded it. The values
	/// already read are kept, so loading the model again only has to start following the presence.
	func unload() {
		loadLock.lock()
		guard loadCount > 0 else {
			loadLock.unlock()
			return
		}
		loadCount -= 1
		let isLast = loadCount == 0
		loadLock.unlock()

		if isLast {
			CoreContext.shared.doOnCoreQueue { _ in
				// Loaded again before this ran
				if !self.isLoaded {
					self.removeFriendDelegate()
				}
			}
		}
	}

	func resetContactAvatarModel(friend: Friend?, name: String, address: String, withPresence: Bool?) {
		CoreContext.shared.doOnCoreQueue { core in
			self.friend = friend
			self.loadName = name
			self.loadAddress = address
			self.presenceWanted = withPresence
			self.loadAddresses(friend: friend)
			let nameTmp = name
			let addressTmp = address
			var phoneNumbersWithLabelTmp: [(label: String, phoneNumber: String)] = []
			if let friend = friend {
				friend.phoneNumbersWithLabel.forEach { phoneNum in
					phoneNumbersWithLabelTmp.append((label: phoneNum.label ?? "", phoneNumber: phoneNum.phoneNumber))
				}
			}
			let nativeUriTmp = friend?.nativeUri ?? ""
			let editableTmp = friend?.friendList?.type == .CardDAV || nativeUriTmp.isEmpty
			let isReadOnlyTmp = (friend?.isReadOnly == true) || (friend?.inList() == false)
			let withPresenceTmp = withPresence
			let starredTmp = friend?.starred ?? false
			let vcardTmp = friend?.vcard ?? nil
			let organizationTmp = friend?.organization ?? ""
			let jobTitleTmp = friend?.jobTitle ?? ""
			var photoTmp = friend?.photo ?? ""
			
			if friend?.friendList?.type == .CardDAV && friend?.photo?.isEmpty == false {
				let fileName = "file:/" + name + ".png"
				photoTmp = fileName.replacingOccurrences(of: " ", with: "")
			}
			
			var lastPresenceInfoTmp = ""
			var presenceStatusTmp: ConsolidatedPresence = .Offline
			var presenceActivityTmp: PresenceActivity.Kind? = nil
			var presenceNoteTmp = ""

			if let friend = friend, withPresence == true {

				lastPresenceInfoTmp = ""

				presenceStatusTmp = friend.consolidatedPresence
				presenceActivityTmp = friend.presenceModel?.activity?.type
				presenceNoteTmp = friend.presenceModel?.getNote(lang: nil)?.content ?? ""

				if friend.consolidatedPresence == .Online || friend.consolidatedPresence == .Busy {
					if friend.consolidatedPresence == .Online || friend.presenceModel?.latestActivityTimestamp != -1 {
						lastPresenceInfoTmp = (friend.consolidatedPresence == .Online) ?
						"Online" : self.getCallTime(startDate: friend.presenceModel!.latestActivityTimestamp)
					} else {
						lastPresenceInfoTmp = "Away"
					}
				}
				
				if let delegate = self.friendDelegate {
					self.friend?.removeDelegate(delegate: delegate)
					self.friendDelegate = nil
				}
				
				self.addFriendDelegate()
			}
			
			DispatchQueue.main.async {
				self.name = nameTmp
				self.address = addressTmp
				self.phoneNumbersWithLabel = phoneNumbersWithLabelTmp
				self.nativeUri = nativeUriTmp
				self.editable = editableTmp
				self.isReadOnly = isReadOnlyTmp
				self.withPresence = withPresenceTmp
				self.starred = starredTmp
				self.vcard = vcardTmp
				self.organization = organizationTmp
				self.jobTitle = jobTitleTmp
				self.photo = photoTmp
				self.lastPresenceInfo = lastPresenceInfoTmp
				self.presenceStatus = presenceStatusTmp
				self.presenceActivity = presenceActivityTmp
				self.presenceNote = presenceNoteTmp
			}
		}
	}
	
	func addFriendDelegate() {
		let friendAddr = friend?.address?.asStringUriOnly() ?? friend?.name ?? "unknown"
		Log.info("[PRESENCE-DEBUG] ContactAvatarModel.addFriendDelegate: '\(friendAddr)' currentPresence=\(friend?.consolidatedPresence ?? .Offline)")
		friendDelegate = FriendDelegateStub(onPresenceReceived: { (friend: Friend) in
			let latestActivityTimestamp = friend.presenceModel?.latestActivityTimestamp ?? -1
			let consolidatedPresenceTmp = friend.consolidatedPresence
			let presenceActivityTmp = friend.presenceModel?.activity?.type
			let presenceNoteTmp = friend.presenceModel?.getNote(lang: nil)?.content ?? ""
			Log.info("[PRESENCE-DEBUG] ContactAvatarModel.onPresenceReceived: '\(friend.address?.asStringUriOnly() ?? friend.name ?? "?")' consolidated=\(consolidatedPresenceTmp) activity=\(String(describing: presenceActivityTmp))")
			DispatchQueue.main.async {
				self.presenceStatus = consolidatedPresenceTmp
				self.presenceActivity = presenceActivityTmp
				self.presenceNote = presenceNoteTmp
				if consolidatedPresenceTmp == .Online || consolidatedPresenceTmp == .Busy {
					if consolidatedPresenceTmp == .Online || latestActivityTimestamp != -1 {
						self.lastPresenceInfo = consolidatedPresenceTmp == .Online ?
						"Online" : self.getCallTime(startDate: latestActivityTimestamp)
					} else {
						self.lastPresenceInfo = "Away"
					}
				} else {
					self.lastPresenceInfo = ""
				}
			}
		})

		if friend != nil && friendDelegate != nil {
			friend!.addDelegate(delegate: friendDelegate!)
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
	
	func getCallTime(startDate: time_t) -> String {
		let timeInterval = TimeInterval(startDate)
		
		let myNSDate = Date(timeIntervalSince1970: timeInterval)
		
		if Calendar.current.isDateInToday(myNSDate) {
			let formatter = DateFormatter()
			formatter.dateFormat = Locale.current.identifier == "fr_FR" ? "HH:mm" : "h:mm a"
			return "Online today at " + formatter.string(from: myNSDate)
		} else if Calendar.current.isDateInYesterday(myNSDate) {
			let formatter = DateFormatter()
			formatter.dateFormat = Locale.current.identifier == "fr_FR" ? "HH:mm" : "h:mm a"
			return "Online yesterday at " + formatter.string(from: myNSDate)
		} else if Calendar.current.isDate(myNSDate, equalTo: .now, toGranularity: .year) {
			let formatter = DateFormatter()
			formatter.dateFormat = Locale.current.identifier == "fr_FR" ? "dd/MM | HH:mm" : "MM/dd | h:mm a"
			return "Online on " + formatter.string(from: myNSDate)
		} else {
			let formatter = DateFormatter()
			formatter.dateFormat = Locale.current.identifier == "fr_FR" ? "dd/MM/yy | HH:mm" : "MM/dd/yy | h:mm a"
			return "Online on " + formatter.string(from: myNSDate)
		}
	}
	
	static func getAvatarModelFromAddress(address: Address, completion: @escaping (ContactAvatarModel) -> Void) {
		ContactsManager.shared.getFriendWithAddressInCoreQueue(address: address) { resultFriend in
			if let addressFriend = resultFriend {
				if addressFriend.address != nil {
					var avatarModel = ContactsManager.shared.avatarListModel.first(where: {
						$0.friend != nil && $0.friend!.name == addressFriend.name && $0.friend!.address != nil
						&& $0.friend!.address!.asStringUriOnly() == addressFriend.address!.asStringUriOnly()
					})
					
					if avatarModel == nil {
						avatarModel = ContactAvatarModel(friend: nil, name: addressFriend.name!, address: addressFriend.address!.asStringUriOnly(), withPresence: false)
					}
					avatarModel!.load()
					completion(avatarModel!)
				} else {
					var name = ""
					if address.displayName != nil {
						name = address.displayName!
					} else if address.username != nil {
						name = address.username!
					} else {
						name = address.asStringUriOnly().sipUsername
					}
					completion(ContactAvatarModel(friend: nil, name: name, address: address.asStringUriOnly(), withPresence: false))
				}
			} else {
				var name = ""
				if address.displayName != nil {
					name = address.displayName!
				} else if address.username != nil {
					name = address.username!
				} else {
					name = address.asStringUriOnly().sipUsername
				}
				completion(ContactAvatarModel(friend: nil, name: name, address: address.asStringUriOnly(), withPresence: false))
			}
		}
	}
}
