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

// swiftlint:disable line_length
// swiftlint:disable function_parameter_count

import linphonesw
import Contacts
import SwiftUI
import ContactsUI
import Combine

final class ContactsManager: ObservableObject {
	
	static let TAG = "[ContactsManager]"
	
	static let shared = ContactsManager()
	
	private var coreContext = CoreContext.shared
	
	private let nativeAddressBookFriendList = "Native address-book"
	let linphoneAddressBookFriendList = "NMPBX address-book"
    let tempRemoteAddressBookFriendList = "TempRemoteDirectoryContacts address-book"
	
	var friendList: FriendList?
	var linphoneFriendList: FriendList?
    var tempRemoteFriendList: FriendList?
	
	@Published var lastSearch: [SearchResult] = []
	@Published var lastSearchSuggestions: [SearchResult] = []
	@Published var avatarListModel: [ContactAvatarModel] = [] {
		didSet {
			setupSubscriptions()
			// The lookup by address is made from this list, so it has to be made again
			let snapshot = avatarListModel
			avatarSnapshotLock.lock()
			avatarSnapshot = snapshot
			avatarSnapshotLock.unlock()
			LookupService.shared.markStale(ContactsManager.avatarLookupName)

			// The filtered list is made from this one, so it has to be made again
			// The pages already listed stay listed, so the list does not jump back to its first page
			MagicSearchSingleton.shared.updateViewAvatarListModel(page: MagicSearchSingleton.shared.loadedPage)
		}
	}
	
	// The models the screens list: the ones of avatarListModel that match the search filter, see
	// MagicSearchSingleton.updateViewAvatarListModel(). Must only be used on the main thread.
	@Published var viewAvatarListModel: [ContactAvatarModel] = []

	@Published var isCardDavSyncing: Bool = false
	@Published var starredChangeTrigger = UUID()
	private var cancellables = Set<AnyCancellable>()

	/// Prevents concurrent CardDAV syncs on the same FriendList.
	/// Must only be read/written on the core queue (doOnCoreQueue).
	private var cardDavSyncInProgress = false

	/// The friend lists that had a contact created, updated or deleted during their current sync. Only these need
	/// their presence subscriptions refreshing once the sync succeeds, as the refresh sends the whole list of a big
	/// address book again. Must only be used on the core queue.
	private var friendListsChangedDuringSync = Set<ObjectIdentifier>()
	
	private var coreDelegate: CoreDelegate?
	private var friendListDelegate: FriendListDelegate?

	// The search used by populateAvatarListModel(), it does not depend on MagicSearchSingleton
	private var populateMagicSearch: MagicSearch?
	private var populateMagicSearchDelegate: MagicSearchDelegate?

	// Hash of the friends the models were last made from, the models are only made again when it changes.
	// Only used on the core queue.
	private var lastPopulateHash: Int?

	// What the lists looked like, by contactsVersion(core:), when the models were last made and when the search that is
	// waiting for its results started. A populate with the same version as the last one has nothing new to find, so
	// it does not search. Only used on the core queue.
	private var lastPopulateVersion: String?
	private var populateVersion: String?
	private var magicSearchDelegate: MagicSearchDelegate?
	
	// avatarListModel as the LookupService searches it, by the addresses of its models. A copy, as the service
	// reads it on the core queue while avatarListModel is only used on the main thread.
	private static let avatarLookupName = "avatarListModel"
	private let avatarSnapshotLock = NSLock()
	private var avatarSnapshot: [ContactAvatarModel] = []
	
	private init() {
		LookupService.shared.register(
			ContactsManager.avatarLookupName,
			items: { self.currentAvatarSnapshot() },
			keys: { (model: ContactAvatarModel) in
				model.searchUris.map { LookupKey(property: .address, value: $0) }
			}
		)
	}
	
	/// avatarListModel as it was last set, for code that is not on the main thread, where avatarListModel itself
	/// must not be read as it is replaced there. Can be called from any thread.
	func currentAvatarSnapshot() -> [ContactAvatarModel] {
		avatarSnapshotLock.lock()
		defer { avatarSnapshotLock.unlock() }
		return avatarSnapshot
	}
	
	/// The model of avatarListModel that has this address (as asStringUriOnly() gives it) among its addresses,
	/// found through the LookupService instead of a scan of the list. Can be called from any thread.
	func avatarModel(forAddress uri: String) -> ContactAvatarModel? {
		guard !uri.isEmpty,
			  let model: ContactAvatarModel = LookupService.shared.item(in: ContactsManager.avatarLookupName, property: .address, value: uri) else {
			return nil
		}

		// The list may have been replaced since the index was made, so check the model is the right one
		guard model.searchUris.contains(uri) else {
			return nil
		}

		return model
	}
	
	func fetchContacts() {
		self.coreContext.doOnCoreQueue { core in
			if core.globalState == GlobalState.Shutdown || core.globalState == GlobalState.Off {
				print("\(#function) - Core is being stopped or already destroyed, abort")
			} else {
				do {
					self.friendList = try core.getFriendListByName(name: self.nativeAddressBookFriendList) ?? core.createFriendList()
					self.registerLookup(self.nativeAddressBookFriendList) { self.friendList }
				} catch let error {
					print("\(#function) - Failed to enumerate contacts: \(error)")
				}
				
				if let friendList = self.friendList {
					if friendList.displayName == nil || friendList.displayName!.isEmpty {
						print("\(#function) - Friend list '\(self.nativeAddressBookFriendList)' didn't exist yet, let's create it")
						friendList.databaseStorageEnabled = false // We don't want to store local address-book in DB
						friendList.displayName = self.nativeAddressBookFriendList
						core.addFriendList(list: friendList)
					} else {
						print("\(#function) - Friend list '\(friendList.displayName!) found, removing existing friends if any")
						friendList.friends.forEach { friend in
							_ = friendList.removeFriend(linphoneFriend: friend)
						}
						// Nothing else marks the list if no contact is added back
						LookupService.shared.markStale(self.nativeAddressBookFriendList)
					}
					// Local iPhone contacts are not registered on the presence server,
					// so suppress SIP SUBSCRIBE to avoid leaking phone numbers off-device.
					friendList.subscriptionsEnabled = false
				}

				do {
					self.linphoneFriendList = try core.getFriendListByName(name: self.linphoneAddressBookFriendList) ?? core.createFriendList()
					self.registerLookup(self.linphoneAddressBookFriendList) { self.linphoneFriendList }
				} catch let error {
					print("\(#function) - Failed to enumerate contacts: \(error)")
				}

				if let linphoneFriendList = self.linphoneFriendList {
					if linphoneFriendList.displayName == nil || linphoneFriendList.displayName!.isEmpty {
						print("\(#function) - Friend list \(self.linphoneAddressBookFriendList) didn't exist yet, let's create it")
						linphoneFriendList.databaseStorageEnabled = true
						linphoneFriendList.displayName = self.linphoneAddressBookFriendList
						core.addFriendList(list: linphoneFriendList)
					}
					// Manually-added NMPBX contacts are not on the presence server either;
					// only CardDAV-provisioned lists should send SUBSCRIBE.
					linphoneFriendList.subscriptionsEnabled = false
				}
                
                do {
                    self.tempRemoteFriendList = try core.getFriendListByName(name: self.tempRemoteAddressBookFriendList) ?? core.createFriendList()
                    self.registerLookup(self.tempRemoteAddressBookFriendList) { self.tempRemoteFriendList }
                } catch let error {
                    print("\(#function) - Failed to enumerate contacts: \(error)")
                }
                
                if let tempRemoteFriendList = self.tempRemoteFriendList {
                    if tempRemoteFriendList.displayName == nil || tempRemoteFriendList.displayName!.isEmpty {
                        print("\(#function) - Friend list \(self.tempRemoteAddressBookFriendList) didn't exist yet, let's create it")
                        tempRemoteFriendList.databaseStorageEnabled = true
                        tempRemoteFriendList.displayName = self.tempRemoteAddressBookFriendList
                        core.addFriendList(list: tempRemoteFriendList)
                    }
                }
				
				// The NMPBX and CardDAV contacts are already in their lists, so list them now instead of
				// waiting for the iPhone contacts to be imported. The search runs again once they have been.
				self.populateAvatarListModel()

				Task { await self.refreshCardDavContacts() }
			}
			
			let store = CNContactStore()
			store.requestAccess(for: .contacts) { (granted, error) in
				if let error = error {
					print("\(#function) - failed to request access", error)
					self.addFriendListDelegate()
					self.addCoreDelegate(core: core)
					MagicSearchSingleton.shared.searchForContacts()
					return
				}
				if granted {
					let keys = [CNContactEmailAddressesKey, CNContactPhoneNumbersKey,
								CNContactFamilyNameKey, CNContactGivenNameKey, CNContactNicknameKey,
								CNContactPostalAddressesKey, CNContactIdentifierKey,
								CNInstantMessageAddressUsernameKey, CNContactInstantMessageAddressesKey,
								CNContactOrganizationNameKey, CNContactImageDataAvailableKey, CNContactImageDataKey, CNContactThumbnailImageDataKey]
					
					let request = CNContactFetchRequest(keysToFetch: keys as [CNKeyDescriptor])
					
					let dispatchGroup = DispatchGroup()
					
					do {
						try store.enumerateContacts(with: request, usingBlock: { (contact, _) in
							
							dispatchGroup.enter()
							
							let newContact = Contact(
								identifier: contact.identifier,
								firstName: contact.givenName,
								lastName: contact.familyName,
								organizationName: contact.organizationName,
								jobTitle: "",
								displayName: contact.nickname,
								sipAddresses: contact.instantMessageAddresses.map { $0.value.service.lowercased() == "SIP".lowercased() ? $0.value.username : "" },
								phoneNumbers: contact.phoneNumbers.map { PhoneNumber(numLabel: $0.label ?? "", num: $0.value.stringValue)},
								imageData: ""
							)
							
							self.updateFriend(
								name: contact.givenName + contact.familyName,
								contact: newContact, linphoneFriend: self.nativeAddressBookFriendList, existingFriend: nil) { friend in
									// The thumbnail of the contact, as it is on the phone, is its photo
									if let friend = friend, let thumbnail = contact.thumbnailImageData {
										self.saveImage(data: thumbnail, friend: friend) {
											dispatchGroup.leave()
										}
									} else {
										dispatchGroup.leave()
									}
								}
						})
						
						dispatchGroup.notify(queue: .main) {
							self.addFriendListDelegate()
							self.addCoreDelegate(core: core)
							MagicSearchSingleton.shared.searchForContacts()
						}
					} catch let error {
						print("\(#function) - Failed to enumerate contact", error)
						self.addFriendListDelegate()
						self.addCoreDelegate(core: core)
						MagicSearchSingleton.shared.searchForContacts()
					}
				} else {
					print("\(#function) - access denied")
					self.addFriendListDelegate()
					self.addCoreDelegate(core: core)
					MagicSearchSingleton.shared.searchForContacts()
				}
			}
		}
	}
	
	func textToImage(firstName: String?, lastName: String?, useFullText: Bool = false) -> UIImage {
		let textToDisplay: String
		if useFullText {
			// Used for the active user's fallback avatar, where we want the whole
			// extension number (e.g. "123") rather than just the first character.
			textToDisplay = (firstName ?? "").uppercased()
		} else {
			let firstInitial = firstName?.first.map { String($0) } ?? ""
			let lastInitial = lastName?.first.map { String($0) } ?? ""
			textToDisplay = (firstInitial + lastInitial).uppercased()
		}

		let size = CGSize(width: 200, height: 200)
		let renderer = UIGraphicsImageRenderer(size: size)

		return renderer.image { _ in
			let rect = CGRect(origin: .zero, size: size)

			UIColor(Color.grayMain2c200).setFill()
			UIBezierPath(roundedRect: rect, cornerRadius: 10).fill()

			let paragraph = NSMutableParagraphStyle()
			paragraph.alignment = .center

			// Shrink the font when needed so longer strings (e.g. a full extension
			// number) still fit within the image, leaving a little horizontal padding.
			let maxFontSize: CGFloat = 80
			let availableWidth = size.width - 24
			var fontSize = maxFontSize
			var font = UIFont(name: "NotoSans-ExtraBold", size: fontSize) ?? UIFont.boldSystemFont(ofSize: fontSize)
			let measuredWidth = textToDisplay.size(withAttributes: [.font: font]).width
			if measuredWidth > availableWidth {
				fontSize = max(fontSize * (availableWidth / measuredWidth), 1)
				font = UIFont(name: "NotoSans-ExtraBold", size: fontSize) ?? UIFont.boldSystemFont(ofSize: fontSize)
			}

			let attributes: [NSAttributedString.Key: Any] = [
				.font: font,
				.foregroundColor: UIColor(Color.grayMain2c600),
				.paragraphStyle: paragraph
			]

			let textSize = textToDisplay.size(withAttributes: attributes)
			let textRect = CGRect(
				x: (size.width - textSize.width) / 2,
				y: (size.height - textSize.height) / 2,
				width: textSize.width,
				height: textSize.height
			)

			textToDisplay.draw(in: textRect, withAttributes: attributes)
		}
	}
	
	func updateFriend(name: String, contact: Contact, linphoneFriend: String, existingFriend: Friend?, editingFriend: Bool = false, completion: @escaping (Friend?) -> Void) {

		if existingFriend?.friendList?.type != .CardDAV
			|| (existingFriend?.friendList?.type == .CardDAV && linphoneFriend == self.linphoneAddressBookFriendList)
			|| (editingFriend && linphoneFriend == CorePreferences.friendListInWhichStoreNewlyCreatedFriends) {
			self.saveFriend(contact: contact, existingFriend: existingFriend) { resultFriend in
				self.coreContext.doOnCoreQueue { core in
					if let friend = resultFriend {
						if linphoneFriend != self.nativeAddressBookFriendList && existingFriend == nil {
							if let linphoneFL = self.linphoneFriendList, linphoneFriend == linphoneFL.displayName {
								_ = linphoneFL.addFriend(linphoneFriend: friend)
								LookupService.shared.markStale(linphoneFL.displayName ?? "")
							} else if let linphoneFL = core.friendsLists.first(where: { $0.type == .CardDAV && $0.displayName == CorePreferences.friendListInWhichStoreNewlyCreatedFriends }) {
								if linphoneFL.type == .CardDAV {
									_ = linphoneFL.addFriend(linphoneFriend: friend)
									LookupService.shared.markStale(linphoneFL.displayName ?? "")
								}
							} else if let linphoneFL = self.tempRemoteFriendList {
								if friend.friendList?.type != .CardDAV {
									_ = linphoneFL.addFriend(linphoneFriend: friend)
									LookupService.shared.markStale(linphoneFL.displayName ?? "")
								}
							}
						} else if existingFriend == nil {
							if let friendListTmp = self.friendList {
								_ = friendListTmp.addLocalFriend(linphoneFriend: friend)
								LookupService.shared.markStale(self.nativeAddressBookFriendList)
							}
						}
					}
					
					DispatchQueue.main.async {
						completion(resultFriend)
					}
				}
			}
		} else {
			DispatchQueue.main.async {
				completion(nil)
			}
		}
	}

	
	/// Sets the photo of the friend to the image, as a data URI like the ones a CardDAV server sends. The file for it is
	/// made when the avatar of the friend is loaded, see ContactAvatarModel.loadPhoto(). Without an image the photo is
	/// removed.
	func saveImage(image: UIImage?, friend: Friend, completion: @escaping () -> Void) {
		guard let image = image else {
			setPhoto("", friend: friend, completion: completion)
			return
		}

		if let data = image.jpegData(compressionQuality: 1) {
			saveImage(data: data, friend: friend, completion: completion)
		} else if let data = image.pngData() {
			saveImage(data: data, mimeType: "image/png", friend: friend, completion: completion)
		} else {
			DispatchQueue.main.async {
				completion()
			}
		}
	}

	/// The same for image data that is already encoded, such as the thumbnail of a contact of the phone, so it is saved
	/// as it is. The data is turned into the data URI off the main thread.
	func saveImage(data: Data, mimeType: String = "image/jpeg", friend: Friend, completion: @escaping () -> Void) {
		DispatchQueue.global(qos: .utility).async {
			self.setPhoto("data:\(mimeType);base64," + data.base64EncodedString(), friend: friend, completion: completion)
		}
	}

	// Sets the photo of the friend, an empty one removes it, and calls back on the main thread
	private func setPhoto(_ photo: String, friend: Friend, completion: @escaping () -> Void) {
		self.coreContext.doOnCoreQueue { _ in
			friend.edit()
			friend.photo = photo
			friend.done()

			LookupService.shared.markStale(friend.friendList?.displayName ?? "")

			DispatchQueue.main.async {
				completion()
			}
		}
	}

	func saveFriend(contact: Contact, existingFriend: Friend?, completion: @escaping (Friend?) -> Void) {
		self.coreContext.doOnCoreQueue { core in
			do {
				// Create or use existing friend
				let friend = try existingFriend ?? core.createFriend()
				
				// Strong capture in closure to avoid threading issues
				friend.edit()
				
				friend.nativeUri = contact.identifier
				try friend.setName(newValue: contact.firstName + " " + contact.lastName)
				
				// Safely update vCard
				if let vcard = friend.vcard {
					vcard.givenName = contact.firstName
					vcard.familyName = contact.lastName
				}
				
				friend.organization = contact.organizationName
				friend.jobTitle = contact.jobTitle
				
				// Clear existing addresses and add new ones
				friend.addresses.forEach { friend.removeAddress(address: $0) }
				for sipAddress in contact.sipAddresses where !sipAddress.isEmpty {
					// Build a canonical sip: URI without applying dial-plan transformations,
					// so numbers are stored exactly as the user entered them.
					let canonicalUri: String
					if sipAddress.hasPrefix("sip:") || sipAddress.hasPrefix("sips:") {
						canonicalUri = sipAddress
					} else if sipAddress.contains("@") {
						canonicalUri = "sip:" + sipAddress
					} else {
						canonicalUri = "sip:" + sipAddress + "@" + CorePreferences.defaultDomain
					}
					do {
						let address = try Factory.Instance.createAddress(addr: canonicalUri)
						if !friend.addresses.contains(where: { $0.asString() == address.asString() }) {
							friend.addAddress(address: address)
						}
					} catch {
						Log.error("[ContactsManager] Failed to create SIP address '\(canonicalUri)': \(error)")
					}
				}
				
				// Clear existing phone numbers and add new ones
				friend.phoneNumbersWithLabel.forEach { friend.removePhoneNumberWithLabel(phoneNumber: $0) }
				for phone in contact.phoneNumbers {
					do {
						let labelDrop = String(phone.numLabel.dropFirst(4).dropLast(4))
						let phoneNumber = try Factory.Instance.createFriendPhoneNumber(phoneNumber: phone.num, label: labelDrop)
						friend.addPhoneNumberWithLabel(phoneNumber: phoneNumber)
					} catch {
						print("saveFriend - Failed to create friend phone number for \(phone.numLabel):", error)
					}
				}
				
				// NMPBX subscription settings
				try friend.setSubscribesenabled(newValue: false)
				try friend.setIncsubscribepolicy(newValue: .SPDeny)
				
				// Commit changes
				friend.done()
				
				LookupService.shared.markStale(friend.friendList?.displayName ?? "")

				// Notify completion safely
				completion(friend)
			} catch {
				print("saveFriend - Failed to save friend:", error)
				completion(nil)
			}
		}
	}

	
	func getImagePath(friendPhotoPath: String) -> URL {
		let friendPath = String(friendPhotoPath.dropFirst(6))
		
		let imagePath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent(friendPath)
		
		return imagePath
	}
	
	func getFriendWithContact(contact: Contact) -> Friend? {
		if friendList != nil {
			let friend = friendList!.friends.first(where: {$0.nativeUri == contact.identifier})
			if friend == nil && friendList != nil {
				return linphoneFriendList!.friends.first(where: {$0.nativeUri == contact.identifier})
			}
			return friend
		} else {
			return nil
		}
	}
	
	// The searchable values of a friend for the LookupService
	private static func lookupKeys(for friend: Friend) -> [LookupKey] {
		return friend.addresses.map { LookupKey(property: .address, value: $0.asStringUriOnly()) }
			+ friend.phoneNumbers.map { LookupKey(property: .phoneNumber, value: $0) }
	}

	// Registers a friend list with the LookupService under its display name, the friends are read
	// again from the list on every rebuild of its index
	private func registerLookup(_ name: String, friendList: @escaping () -> FriendList?) {
		LookupService.shared.register(
			name,
			items: { friendList()?.friends ?? [] },
			keys: ContactsManager.lookupKeys
		)
	}

	// The friend of the list with this address, or with a phone number equal to its username, found
	// through the LookupService instead of a scan of the list. The service keeps the friends it indexed, so the
	// list is not read here. An index is rebuilt when the list is marked stale, or when it gives a friend that no
	// longer matches.
	private func friend(in friendList: FriendList?, address: Address, sipUri: String) -> Friend? {
		guard let friendList = friendList, let name = friendList.displayName else {
			return nil
		}

		let lookupService = LookupService.shared

		func find(_ property: LookupProperty, _ value: String) -> Friend? {
			return lookupService.item(in: name, property: property, value: value)
		}

		for _ in 0..<2 {
			guard let friend = find(.address, sipUri) ?? address.username.flatMap({ find(.phoneNumber, $0) }) else {
				return nil
			}

			if friend.addresses.contains(where: { $0.asStringUriOnly() == sipUri })
				|| friend.phoneNumbers.contains(where: { $0 == address.username }) {
				return friend
			}

			lookupService.markStale(name)
		}

		return nil
	}

	func getFriendWithAddress(address: Address?) -> Friend? {
		guard let address = address, let clonedAddress = address.clone() else {
			return nil
		}
		clonedAddress.clean()
		let sipUri = clonedAddress.asStringUriOnly()
		
		var friend = self.friend(in: self.friendList, address: address, sipUri: sipUri)
			?? self.friend(in: self.linphoneFriendList, address: address, sipUri: sipUri)
			?? self.friend(in: self.tempRemoteFriendList, address: address, sipUri: sipUri)

		CoreContext.shared.mCore.friendsLists.forEach { friendList in
			if friendList.type == .CardDAV, let name = friendList.displayName {
				if !LookupService.shared.isRegistered(name) {
					self.registerLookup(name) {
						CoreContext.shared.mCore.friendsLists.first(where: { $0.displayName == name })
					}
				}

				// A CardDAV list takes priority over the others, the last one with the friend wins
				if let cardDavFriend = self.friend(in: friendList, address: address, sipUri: sipUri) {
					friend = cardDavFriend
				}
			}
		}

		return friend
	}
	
	// What is waiting for the results of populateAvatarListModel(), see finishPopulate()
	private let pendingPopulateLock = NSLock()
	private var pendingPopulateCompletions: [() -> Void] = []
	
	/// Fills `avatarListModel` and `lastSearch` with the contacts a search with an empty filter returns, so they
	/// are listed without waiting for a search from a screen. It runs its own search, with every source, merged by
	/// friend and limited by the contacts domain setting. Suggestions are not part of it, see searchForSuggestions(filter:). The models are only made again if the
	/// contacts have changed since they were last made.
	///
	/// `completion` is called on the main thread once the results have been dealt with, whether or not the
	/// models were made again.
	func populateAvatarListModel(completion: (() -> Void)? = nil) {
		if let completion = completion {
			pendingPopulateLock.lock()
			pendingPopulateCompletions.append(completion)
			pendingPopulateLock.unlock()
			
			// The results may never come, for instance when the core is stopped, so what is waiting for them does not wait for good
			DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
				self.finishPopulate()
				MagicSearchSingleton.shared.isLoading = false
			}
		}
		
		coreContext.doOnCoreQueue { core in
			// None of the lists has changed since the models were made, so a search would find the same friends
			let version = self.contactsVersion(core: core)
			if version == self.lastPopulateVersion {
				DispatchQueue.main.async {
					MagicSearchSingleton.shared.isLoading = false
				}
				self.finishPopulate()
				return
			}
			self.populateVersion = version

			if self.populateMagicSearch == nil {
				guard let magicSearch = try? core.createMagicSearch() else {
					self.finishPopulate()
					return
				}
				
				magicSearch.limitedSearch = false
				
				self.populateMagicSearchDelegate = MagicSearchDelegateStub(onSearchResultsReceived: { (magicSearch: MagicSearch) in
					self.processPopulateSearchResults(core: core, results: magicSearch.lastSearch)
				})
				magicSearch.addDelegate(delegate: self.populateMagicSearchDelegate!)
				
				self.populateMagicSearch = magicSearch
			}
			
			guard let magicSearch = self.populateMagicSearch else {
				self.finishPopulate()
				return
			}
			
			magicSearch.resetSearchCache()
			magicSearch.getContactsListAsync(
				filter: "",
				domain: CorePreferences.contactsFilter,
				sourceFlags: MagicSearch.Source.All.rawValue,
				aggregation: MagicSearch.Aggregation.Friend
			)
		}
	}
	
	// The search for suggestions, which are the addresses that are not contacts, such as a number that was typed
	// in or one found in the call history or the chats. It has its own search, so it can run on every filter
	// without asking the sources of the contacts, which populateAvatarListModel() deals with.
	private var suggestionsMagicSearch: MagicSearch?
	private var suggestionsMagicSearchDelegate: MagicSearchDelegate?

	/// Fills `lastSearchSuggestions` with the results of a search for the filter that are not contacts. The
	/// friends, LDAP and remote CardDAV sources are left out, as they only give contacts, so no request is made
	/// to a server.
	func searchForSuggestions(filter: String) {
		coreContext.doOnCoreQueue { core in
			if self.suggestionsMagicSearch == nil {
				guard let magicSearch = try? core.createMagicSearch() else {
					return
				}

				magicSearch.limitedSearch = false

				self.suggestionsMagicSearchDelegate = MagicSearchDelegateStub(onSearchResultsReceived: { (magicSearch: MagicSearch) in
					self.processSuggestionResults(core: core, results: magicSearch.lastSearch)
				})
				magicSearch.addDelegate(delegate: self.suggestionsMagicSearchDelegate!)

				self.suggestionsMagicSearch = magicSearch
			}

			guard let magicSearch = self.suggestionsMagicSearch else {
				return
			}

			let contactSources = MagicSearch.Source.Friends.rawValue
				| MagicSearch.Source.LdapServers.rawValue
				| MagicSearch.Source.RemoteCardDAV.rawValue

			magicSearch.resetSearchCache()
			magicSearch.getContactsListAsync(
				filter: filter,
				domain: CorePreferences.contactsFilter,
				sourceFlags: MagicSearch.Source.All.rawValue & ~contactSources,
				aggregation: MagicSearch.Aggregation.Friend
			)
		}
	}

	// Keeps the results that are not contacts, by the same rule as populateAvatarListModel(), sorted by address
	// and without the user's own. Must be called on the core queue.
	private func processSuggestionResults(core: Core, results: [SearchResult]) {
		var suggestions = results.filter { result in
			let listName = result.friend?.friendList?.displayName
			let isContact = result.friend != nil && (
				listName == self.nativeAddressBookFriendList
				|| listName == self.linphoneAddressBookFriendList
				|| listName == self.tempRemoteAddressBookFriendList
				|| result.hasSourceFlag(source: .RemoteCardDAV)
				|| result.friend?.friendList?.type == .CardDAV
				|| result.hasSourceFlag(source: .LdapServers))
			return !isContact
		}

		suggestions.sort(by: {
			($0.address?.asStringUriOnly() ?? "") < ($1.address?.asStringUriOnly() ?? "")
		})

		if let defaultAccount = core.defaultAccount, let contactAddress = defaultAccount.params?.identityAddress {
			suggestions.removeAll {
				$0.address?.weakEqual(address2: contactAddress) ?? false
			}
		}

		DispatchQueue.main.async {
			self.lastSearchSuggestions = suggestions
		}
	}

	// Runs what is waiting for the results, on the main thread after they have been applied
	private func finishPopulate() {
		pendingPopulateLock.lock()
		let completions = pendingPopulateCompletions
		pendingPopulateCompletions = []
		pendingPopulateLock.unlock()
		
		DispatchQueue.main.async {
			completions.forEach { $0() }
		}
	}

	/// Releases the search used by populateAvatarListModel(), to be called before the core is stopped.
	/// Must be called on the core queue.
	func destroyMagicSearch() {
		lastPopulateVersion = nil
		populateVersion = nil
		populateMagicSearch = nil
		populateMagicSearchDelegate = nil
		suggestionsMagicSearch = nil
		suggestionsMagicSearchDelegate = nil
	}

	// Tells cheaply whether the friends may have changed: every list with how many times it was marked stale, which
	// every change to a list does, plus what else decides which models are made (the domain that makes a friend an
	// extension and the contacts domain setting). Must be called on the core queue.
	private func contactsVersion(core: Core) -> String {
		let lists = core.friendsLists.map { friendList -> String in
			let name = friendList.displayName ?? ""
			return "\(name):\(LookupService.shared.generation(of: name))"
		}

		return lists.joined(separator: "|")
			+ "|" + (core.defaultAccount?.params?.domain ?? "")
			+ "|" + CorePreferences.contactsFilter
	}

	// What stands in for the vCard when a friend has none, or it cannot be written out: the same fields, with each
	// address as its username and domain, as that is what identifies it and it is cheaper than the whole URI
	private static func signatureWithoutVcard(of friend: Friend) -> String {
		let addresses = friend.addresses.map { "\($0.username ?? "")@\($0.domain)" }

		return "\(friend.name ?? "")|\(addresses)|\(friend.phoneNumbers)|\(friend.organization ?? "")|\(friend.jobTitle ?? "")|\(friend.photo ?? "")"
	}

	// Turns the results of the search into the models and `lastSearch`, if the contacts have changed. Must be called
	// on the core queue.
	private func processPopulateSearchResults(core: Core, results: [SearchResult]) {
		// The results are of the lists as they were when the search started
		lastPopulateVersion = populateVersion

		var friendResults: [SearchResult] = []

		// A friend result is dropped when another one with the same address (ignoring tags and headers, as
		// weakEqual does) or phone number is already listed, whichever list it came from
		var listedAddresses: Set<String> = []
		var listedPhoneNumbers: Set<String> = []

		func addressKey(_ address: Address) -> String {
			return "\(address.username ?? "")@\(address.domain):\(address.port)"
		}

		func listFriendResult(_ result: SearchResult) {
			friendResults.append(result)
			if let address = result.address {
				listedAddresses.insert(addressKey(address))
			}
			if let phoneNumber = result.phoneNumber {
				listedPhoneNumbers.insert(phoneNumber)
			}
		}

		results.forEach { result in
			let listName = result.friend?.friendList?.displayName

			if result.friend != nil && (listName == self.nativeAddressBookFriendList || listName == self.linphoneAddressBookFriendList || listName == self.tempRemoteAddressBookFriendList) {
				if let address = result.address, !listedAddresses.contains(addressKey(address)) {
					listFriendResult(result)
				} else if let phoneNumber = result.phoneNumber, !listedPhoneNumbers.contains(phoneNumber) {
					listFriendResult(result)
				}
			} else if result.friend != nil && (result.hasSourceFlag(source: .RemoteCardDAV) || result.friend?.friendList?.type == .CardDAV || result.hasSourceFlag(source: .LdapServers)) {
				listFriendResult(result)
			}
		}



		let sortedFriendResults = friendResults.sorted {
			let name1 = $0.friend?.name?.lowercased()
				.folding(options: .diacriticInsensitive, locale: .current) ?? ""
			let name2 = $1.friend?.name?.lowercased()
				.folding(options: .diacriticInsensitive, locale: .current) ?? ""
			return name1 < name2
		}

		// A hash per friend of everything the models show: the vCard (name, addresses, numbers, organisation, job
		// title and the photo's path), plus what is not in it. Each one is kept on the friend's model, to tell
		// later whether the friend has changed.
		var friendHashes: [ObjectIdentifier: Int] = [:]
		let domain = core.defaultAccount?.params?.domain ?? ""
		sortedFriendResults.forEach { result in
			guard let friend = result.friend else {
				return
			}

			let vcard = friend.vcard.flatMap { try? $0.asVcard4String() }
				?? ContactsManager.signatureWithoutVcard(of: friend)

			var friendHasher = Hasher()
			friendHasher.combine(vcard)
			// Not part of the vCard, as far as is known, so a change to it would not be seen otherwise
			friendHasher.combine(friend.starred)
			friendHashes[ObjectIdentifier(result)] = friendHasher.finalize()
		}

		// The hashes are sorted before they are combined, so friends that come back in another order, as ones
		// with the same name can, do not change the result
		var hasher = Hasher()
		friendHashes.values.sorted().forEach { hasher.combine($0) }
		// What the models and the list also depend on, though it is not in the friends: the domain that makes a friend an
		// extension, and the contacts domain setting
		hasher.combine(core.defaultAccount?.params?.domain ?? "")
		hasher.combine(CorePreferences.contactsFilter)
		let hash = hasher.finalize()

		if hash == lastPopulateHash {
			// Nothing the models show has changed, so keep them
			DispatchQueue.main.async {
				MagicSearchSingleton.shared.isLoading = false
			}
			finishPopulate()
			return
		}
		lastPopulateHash = hash

		// The models that are still right are kept, matched by the hash of their friend and by being made from the same
		// friend object, so only the ones for new or changed friends are made. The ones left over are dropped.
		var existingModels: [Int: [ContactAvatarModel]] = [:]
		currentAvatarSnapshot().forEach { existingModels[$0.contentHash, default: []].append($0) }

		var avatarModels: [ContactAvatarModel] = []
		sortedFriendResults.forEach { result in
			guard let friend = result.friend else {
				return
			}

			let friendHash = friendHashes[ObjectIdentifier(result)] ?? 0
			if let index = existingModels[friendHash]?.firstIndex(where: { $0.friend === friend }) {
				avatarModels.append(existingModels[friendHash]!.remove(at: index))
				return
			}

			let listName = friend.friendList?.displayName
			let name = friend.name ?? ""
			let address = friend.address?.clone()?.asStringUriOnly() ?? ""

			if listName == self.nativeAddressBookFriendList || listName == self.linphoneAddressBookFriendList || listName == self.tempRemoteAddressBookFriendList {
				avatarModels.append(ContactAvatarModel(friend: friend, name: name, address: address, withPresence: true, contentHash: friendHash))
			} else if result.hasSourceFlag(source: .RemoteCardDAV) || friend.friendList?.type == .CardDAV {
				avatarModels.append(ContactAvatarModel(friend: friend, name: name, address: address, withPresence: true, contentHash: friendHash))
			} else if result.hasSourceFlag(source: .LdapServers) {
				avatarModels.append(ContactAvatarModel(friend: friend, name: name, address: address, withPresence: false, contentHash: friendHash))
			}
		}

		// The models that were not kept stop following the presence of their friends
		existingModels.values.forEach { $0.forEach { $0.removeFriendDelegate() } }

		DispatchQueue.main.async {
			self.lastSearch = sortedFriendResults
			// The contact whose details are open moves to its new model, as the old one has stopped following presence
			if let displayedFriend = SharedMainViewModel.shared.displayedFriend,
			   let newDisplayedFriend = avatarModels.first(where: { $0.address == displayedFriend.address }) {
				SharedMainViewModel.shared.displayedFriend = newDisplayedFriend
			}

			self.avatarListModel = avatarModels

			MagicSearchSingleton.shared.isLoading = false

			// The contacts have changed, so what shows their names and avatars has to be refreshed
			NotificationCenter.default.post(name: NSNotification.Name("ContactLoaded"), object: nil)
		}
		
		finishPopulate()
	}

	/// The model to show for the person with this address, called back on the core queue. A contact gets its model
	/// from avatarListModel (a model with no friend, named after the contact, if it is not there), and anyone else a
	/// model with no friend named from the address. The model is not loaded, the view that shows it loads it.
	func avatarModel(address: Address, completion: @escaping (ContactAvatarModel) -> Void) {
		coreContext.doOnCoreQueue { _ in
			guard let friend = self.getFriendWithAddress(address: address),
				  let friendAddress = friend.address?.asStringUriOnly() else {
				completion(ContactAvatarModel(address: address))
				return
			}

			let avatarModel = self.avatarModel(forAddress: friendAddress)
				?? ContactAvatarModel(friend: nil, name: friend.name ?? "", address: friendAddress, withPresence: false)
			completion(avatarModel)
		}
	}

	func getFriendWithAddressInCoreQueue(address: Address?, completion: @escaping (Friend?) -> Void) {
		self.coreContext.doOnCoreQueue { _ in
			completion(self.getFriendWithAddress(address: address))
		}
	}
	
	func addFriendListDelegate() {
		self.coreContext.doOnCoreQueue { _ in
			let allLists = CoreContext.shared.mCore.friendsLists
			Log.info("[PRESENCE-DEBUG] addFriendListDelegate: \(allLists.count) friend list(s) present")
			allLists.forEach { fl in
				Log.info("[PRESENCE-DEBUG]   list '\(fl.displayName ?? "nil")' type=\(fl.type) friends=\(fl.friends.count) subscriptionsEnabled=\(fl.subscriptionsEnabled) rlsUri=\(fl.rlsUri ?? "nil")")
			}

			if let friendListDelegateToDelete = self.friendListDelegate {
				Log.info("[PRESENCE-DEBUG] addFriendListDelegate: removing previous delegate")
				CoreContext.shared.mCore.friendsLists.forEach { friendList in
					friendList.removeDelegate(delegate: friendListDelegateToDelete)
				}
			}
			self.friendListDelegate = nil
			
			let friendListDelegateTmp = FriendListDelegateStub(
				onContactCreated: { (friendList: FriendList, linphoneFriend: Friend) in
					Log.info("\(ContactsManager.TAG) FriendListDelegateStub onContactCreated")
					self.friendListsChangedDuringSync.insert(ObjectIdentifier(friendList))
					LookupService.shared.markStale(friendList.displayName ?? "")
				},
				onContactDeleted: { (friendList: FriendList, linphoneFriend: Friend) in
					Log.info("\(ContactsManager.TAG) FriendListDelegateStub onContactDeleted")
					self.friendListsChangedDuringSync.insert(ObjectIdentifier(friendList))
					LookupService.shared.markStale(friendList.displayName ?? "")
				},
				onContactUpdated: { (friendList: FriendList, newFriend: Friend, oldFriend: Friend) in
					Log.info("\(ContactsManager.TAG) FriendListDelegateStub onContactUpdated")
					self.friendListsChangedDuringSync.insert(ObjectIdentifier(friendList))
					LookupService.shared.markStale(friendList.displayName ?? "")
				},
				onSyncStatusChanged: { (friendList: FriendList, status: FriendList.SyncStatus?, message: String?) in
					Log.info("\(ContactsManager.TAG) FriendListDelegateStub onSyncStatusChanged \(friendList.displayName ?? "No Display Name") -- Status: \(status != nil ? String(describing: status!) : "No Status")")
					Log.info("[PRESENCE-DEBUG] onSyncStatusChanged: list='\(friendList.displayName ?? "nil")' status=\(String(describing: status)) friends=\(friendList.friends.count)")
					LookupService.shared.markStale(friendList.displayName ?? "")
					if status == .Started || status == .Failure {
						self.friendListsChangedDuringSync.remove(ObjectIdentifier(friendList))
					}
					// Whether the sync changed the list, which is only known to be so while this delegate is on the list
					let changedDuringSync = status == .Successful && self.friendListsChangedDuringSync.remove(ObjectIdentifier(friendList)) != nil
					if status == .Successful {
                        if friendList.displayName != self.nativeAddressBookFriendList && friendList.displayName != self.linphoneAddressBookFriendList {
                            if let tempRemoteFriendList = self.tempRemoteFriendList {
								tempRemoteFriendList.friends.forEach { friend in
									if let friendAddress = friend.address,
									   friendList.friends.contains(where: { $0.address?.weakEqual(address2: friendAddress) == true }) {
										_ = tempRemoteFriendList.removeFriend(linphoneFriend: friend)
										LookupService.shared.markStale(self.tempRemoteAddressBookFriendList)
									}
                                }
                            }
                        }
                        
                        let dispatchGroup = DispatchGroup()
						friendList.friends.forEach { friend in
                            dispatchGroup.enter()
							let addressTmp = friend.address?.clone()?.asStringUriOnly() ?? ""
							
							let newContact = Contact(
								identifier: UUID().uuidString,
								firstName: friend.firstName ?? addressTmp,
								lastName: friend.lastName ?? "",
								organizationName: friend.organization ?? "",
								jobTitle: friend.jobTitle ?? "",
								displayName: friend.address?.displayName ?? "",
								sipAddresses: friend.addresses.map { $0.asStringUriOnly() },
								phoneNumbers: friend.phoneNumbersWithLabel.map { PhoneNumber(numLabel: $0.label ?? "", num: $0.phoneNumber)},
								imageData: ""
							)
							
							self.updateFriend(
								name: friend.name ?? addressTmp,
								contact: newContact, linphoneFriend: friendList.displayName ?? "No Display Name", existingFriend: friend.friendList?.type == .CardDAV ? friend : nil) { _ in
									dispatchGroup.leave()
								}
						}
                        
                        dispatchGroup.notify(queue: .main) {
							self.coreContext.doOnCoreQueue { _ in
								MagicSearchSingleton.shared.searchForContacts()
								// Refresh presence subscriptions for the list whose sync just
								// completed. On a fresh install the list was empty when
								// updateSubscriptions() ran during addFriendListDelegate(), so
								// no SUBSCRIBE requests were sent. Calling it here ensures
								// subscriptions are established once the contacts have arrived.
								// A sync that changed nothing is skipped: the subscriptions made at start-up
								// already cover the list, and sending a big one again costs the core thread time.
								if !changedDuringSync {
									Log.info("[PRESENCE-DEBUG] onSyncStatusChanged post-process: '\(friendList.displayName ?? "nil")' unchanged by the sync, keeping presence subscriptions")
									return
								}
								Log.info("[PRESENCE-DEBUG] onSyncStatusChanged post-process: calling updateSubscriptions() on '\(friendList.displayName ?? "nil")' (\(friendList.friends.count) friends)")
								friendList.updateSubscriptions()
								if let linphoneFL = self.tempRemoteFriendList {
									Log.info("[PRESENCE-DEBUG] onSyncStatusChanged post-process: calling updateSubscriptions() on tempRemote (\(linphoneFL.friends.count) friends)")
									linphoneFL.updateSubscriptions()
								}
							}
                        }
					}
				},
				onPresenceReceived: { (friendList: FriendList, friends: [Friend?]) in
					Log.info("\(ContactsManager.TAG) FriendListDelegateStub onPresenceReceived \(friends.count)")
					Log.info("[PRESENCE-DEBUG] onPresenceReceived: list='\(friendList.displayName ?? "nil")' bodyless=\(friendList.isSubscriptionBodyless) count=\(friends.count)")
					friends.forEach { f in
						if let f = f {
							Log.info("[PRESENCE-DEBUG]   friend '\(f.name ?? f.address?.asStringUriOnly() ?? "?")' consolidated=\(f.consolidatedPresence)")
						}
					}
					if (friendList.isSubscriptionBodyless) {
						Log.info("\(ContactsManager.TAG) Bodyless friendlist \(friendList.displayName ?? "No Display Name") presence received")
						
						if friendList.displayName != self.nativeAddressBookFriendList && friendList.displayName != self.linphoneAddressBookFriendList {
							if let tempRemoteFriendList = self.tempRemoteFriendList {
								tempRemoteFriendList.friends.forEach { friend in
									if let friendAddress = friend.address,
									   friends.contains(where: { $0?.address?.weakEqual(address2: friendAddress) == true }) {
										_ = tempRemoteFriendList.removeFriend(linphoneFriend: friend)
										LookupService.shared.markStale(self.tempRemoteAddressBookFriendList)
									}
								}
							}
						}
						
						let dispatchGroup = DispatchGroup()
						
						friends.forEach { friend in
							dispatchGroup.enter()
							if let friend = friend {
								let addressTmp = friend.address?.clone()?.asStringUriOnly() ?? ""
								Log.debug("\(ContactsManager.TAG) Newly discovered SIP Address \(addressTmp) for friend \(friend.name ?? "No Name") in bodyless list \(friendList.displayName ?? "No Display Name")")
								
								let newContact = Contact(
									identifier: UUID().uuidString,
									firstName: friend.name ?? addressTmp,
									lastName: "",
									organizationName: "",
									jobTitle: "",
									displayName: friend.address?.displayName ?? "",
									sipAddresses: friend.addresses.map { $0.asStringUriOnly() },
									phoneNumbers: [],
									imageData: ""
								)
								
								self.updateFriend(
									name: friend.name ?? addressTmp,
									contact: newContact, linphoneFriend: friendList.displayName ?? "No Display Name", existingFriend: nil) { _ in
										dispatchGroup.leave()
									}
							}
						}
						
						dispatchGroup.notify(queue: .main) {
							self.coreContext.doOnCoreQueue { _ in
								MagicSearchSingleton.shared.searchForContacts()
								if let linphoneFL = self.tempRemoteFriendList {
									linphoneFL.updateSubscriptions()
								}
							}
						}
					}
				},
				onNewSipAddressDiscovered: { (friendList: FriendList, linphoneFriend: Friend, sipUri: String) in
					Log.info("\(ContactsManager.TAG) FriendListDelegateStub onNewSipAddressDiscovered \(linphoneFriend.name ?? "")")
					var addedAvatarListModel: [ContactAvatarModel] = []
					if !self.currentAvatarSnapshot().contains(where: {$0.friend?.name == linphoneFriend.name}) {
						if let address = try? Factory.Instance.createAddress(addr: sipUri) {
							linphoneFriend.edit()
							linphoneFriend.addAddress(address: address)
							linphoneFriend.done()
							LookupService.shared.markStale(linphoneFriend.friendList?.displayName ?? "")
							
							let addressTmp = linphoneFriend.address?.clone()?.asStringUriOnly() ?? ""
							addedAvatarListModel.append(
								ContactAvatarModel(
									friend: linphoneFriend,
									name: linphoneFriend.name ?? "",
									address: addressTmp,
									withPresence: true
								)
							)
							
							
							DispatchQueue.main.async {
								// Added to the list here, as it is replaced on the main thread and a change made in between would be lost
								// Sorted by the name without case or accents, as populateAvatarListModel() sorts them, each name
								// prepared once
								self.avatarListModel = (addedAvatarListModel + self.avatarListModel)
									.map { (key: ContactAvatarModel.normalisedForSearch($0.name), model: $0) }
									.sorted { $0.key < $1.key }
									.map { $0.model }
								
								NotificationCenter.default.post(
									name: NSNotification.Name("ContactAdded"),
									object: nil,
									userInfo: ["address": addressTmp]
								)
							}
						}
					}
				}
			)
			
			self.friendListDelegate = friendListDelegateTmp

			CoreContext.shared.mCore.friendsLists.forEach { friendList in
				friendList.addDelegate(delegate: friendListDelegateTmp)
			}

			// Enable subscriptions and trigger SUBSCRIBE only after the new delegate
			// is registered, so any NOTIFY that arrives in response is handled by
			// the correct callback rather than the old one or falling on the floor.
			CoreContext.shared.mCore.friendListSubscriptionEnabled = true

			// Safety net: if a list was loaded from SQLite before provisioning set
			// the rlsUri (or if CardDavProvisioningManager hasn't run yet this
			// session), apply the provisioned RLS URI now so updateSubscriptions()
			// sends to the RLS rather than falling back to individual SUBSCRIBE.
			let configRlsUri = CoreContext.shared.mCore.config?.getString(
				section: "carddav_provision", key: "rls_uri", defaultString: "") ?? ""
			if !configRlsUri.isEmpty {
				CoreContext.shared.mCore.friendsLists.forEach { friendList in
					if friendList.rlsUri == nil {
						friendList.rlsUri = configRlsUri
						Log.info("[PRESENCE-DEBUG] addFriendListDelegate: applied rlsUri '\(configRlsUri)' to '\(friendList.displayName ?? "nil")'")
					}
				}
			}

			Log.info("[PRESENCE-DEBUG] addFriendListDelegate: calling updateSubscriptions() on all lists")
			CoreContext.shared.mCore.friendsLists.forEach { friendList in
				Log.info("[PRESENCE-DEBUG]   updateSubscriptions for '\(friendList.displayName ?? "nil")' (\(friendList.friends.count) friends, rlsUri=\(friendList.rlsUri ?? "nil"))")
				friendList.updateSubscriptions()
			}
		}
	}
	
	func addCoreDelegate(core: Core) {
		self.coreContext.doOnCoreQueue { _ in
			if let coreDelegate = self.coreDelegate {
				core.removeDelegate(delegate: coreDelegate)
				self.coreDelegate = nil
			}
			
			self.coreDelegate = CoreDelegateStub(
				onFriendListCreated: { (_: Core, friendList: FriendList) in
					Log.info("\(ContactsManager.TAG) Friend list \(friendList.displayName) created")
					if self.friendListDelegate != nil {
						friendList.addDelegate(delegate: self.friendListDelegate!)
					}
				}, onFriendListRemoved: { (_: Core, friendList: FriendList) in
					Log.info("\(ContactsManager.TAG) Friend list \(friendList.displayName) removed")
					if self.friendListDelegate != nil {
						friendList.removeDelegate(delegate: self.friendListDelegate!)
					}
				}, onDefaultAccountChanged: { (_: Core, _: Account?) in
					Log.info("\(ContactsManager.TAG) Default account changed, update all contacts' model showTrust value")
					//updateContactsModelDependingOnDefaultAccountMode()
				}
			)
			
			if self.coreDelegate != nil {
				core.addDelegate(delegate: self.coreDelegate!)
			}
		}
	}
	
	private func setupSubscriptions() {
		cancellables.removeAll()
		for contact in avatarListModel {
			contact.$starred
				// The first value is the current one, sent as soon as the subscription is made, not a change
				.dropFirst()
				.sink { [weak self] _ in
					self?.starredChangeTrigger = UUID()
				}
				.store(in: &cancellables)
		}
	}
	
	func updateSubscriptionsLinphoneList() {
		self.coreContext.doOnCoreQueue { _ in
			if let linphoneFL = self.linphoneFriendList {
				linphoneFL.updateSubscriptions()
			}
		}
	}
	
	func refreshCardDavContacts() async {
		await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
			self.coreContext.doOnCoreQueue { core in
				let cardDavLists = core.friendsLists.filter { $0.type == .CardDAV }
				guard !cardDavLists.isEmpty else {
					continuation.resume()
					return
				}

				// Guard against concurrent syncs on the same FriendList.
				//
				// fetchContacts() is called from both onAccountRegistrationStateChanged(.Ok)
				// and onDefaultAccountChanged, which fire in close sequence on startup. Each
				// call queues a refreshCardDavContacts() Task. Because doOnCoreQueue is serial,
				// the check-and-set below is atomic: the first call sets the flag and proceeds;
				// the second sees it set and returns without calling synchronizeFriendsFromServer.
				//
				// The liblinphone CardDAV engine has a single shared state machine per FriendList.
				// Calling synchronizeFriendsFromServer() concurrently on the same list corrupts
				// its internal URL tracking, causing the REPORT to go to the home-set path
				// (/carddav/addressbooks/1/) instead of the specific address book
				// (/carddav/addressbooks/1/contacts/). The server returns an empty 207, the SDK
				// stores the CTAG with 0 contacts, and every subsequent sync sees "CTAG unchanged"
				// and fetches nothing. (Diagnosed 2026-05-22 from card-related.log.)
				guard !self.cardDavSyncInProgress else {
					Log.warn("\(ContactsManager.TAG) refreshCardDavContacts() called while sync already in progress — skipping duplicate call")
					continuation.resume()
					return
				}
				self.cardDavSyncInProgress = true

				var remaining = cardDavLists.count
				var resumed = false

				DispatchQueue.main.async { self.isCardDavSyncing = true }

				for list in cardDavLists {
					Log.info("\(ContactsManager.TAG) Found CardDAV friend list \(list.displayName ?? ""), starting update")
					var selfDelegate: FriendListDelegate?
					let delegate = FriendListDelegateStub(
						onSyncStatusChanged: { (fl: FriendList, status: FriendList.SyncStatus, _: String?) in
							switch status {
							case .Successful, .Failure:
								// The friends of the list may have changed, whether or not the main delegate is on this list
								LookupService.shared.markStale(fl.displayName ?? "")
								if let d = selfDelegate {
									fl.removeDelegate(delegate: d)
									selfDelegate = nil
								}
								remaining -= 1
								if remaining == 0 && !resumed {
									resumed = true
									self.cardDavSyncInProgress = false
									DispatchQueue.main.async {
										// Raise isLoading *before* clearing isCardDavSyncing so the
										// combined spinner condition (isCardDavSyncing || isLoading)
										// in ContactsInnerFragment never drops to false while the
										// dispatchGroup in addFriendListDelegate is still processing
										// friends into avatarListModel. Both assignments land in the
										// same main-thread render pass, so SwiftUI sees them together.
										MagicSearchSingleton.shared.isLoading = true
										self.isCardDavSyncing = false
									}
									continuation.resume()
								}
							default: break
							}
						})
					selfDelegate = delegate
					list.addDelegate(delegate: delegate)
					list.synchronizeFriendsFromServer()
				}
			}
		}
	}
}

struct PhoneNumber {
	var numLabel: String
	var num: String
}

struct Contact: Identifiable {
	var id = UUID()
	var identifier: String
	var firstName: String
	var lastName: String
	var organizationName: String
	var jobTitle: String
	var displayName: String
	var sipAddresses: [String] = []
	var phoneNumbers: [PhoneNumber] = []
	var imageData: String
}

// swiftlint:enable line_length
// swiftlint:enable function_parameter_count
