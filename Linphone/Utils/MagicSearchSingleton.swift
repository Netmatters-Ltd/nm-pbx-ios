/*
 * Copyright (c) 2010-2023 Belledonne Communications SARL.
 *
 * This file is part of linphone-iphone
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
import Combine

final class MagicSearchSingleton: ObservableObject {

	static let shared = MagicSearchSingleton()
	private var contactsManager = ContactsManager.shared

	// A different filter starts again from the first page, wherever the search for it is made from. Must only be set
	// on the main thread.
	var currentFilter: String = "" {
		didSet {
			if currentFilter != oldValue {
				loadedPage = 0
			}
		}
	}

	@Published var isLoading = false

	// True when the last search matched more than the pages listed so far, in any of the lists, so the next page can
	// be asked for, see loadNextPage(). Must only be used on the main thread.
	@Published private(set) var hasMore = false

	/// The kinds of record a search lists: only the extensions, only the contacts, or both.
	enum Kinds {
		case extensions
		case contacts
		case all
	}

	// What the searches list. A search says it when it is made, see searchForContacts(kinds:), and until another one
	// does the searches that do not say, such as the ones after a sync, list the same. Other kinds start again from
	// the first page. Must only be used on the main thread.
	private(set) var kinds: Kinds = .all {
		didSet {
			if kinds != oldValue {
				loadedPage = 0
			}
		}
	}

	// Delay after the last keystroke before a search starts. Must only be used on the main thread.
	private let searchDebounceDelay: TimeInterval = 0.3
	private var searchDebounceWorkItem: DispatchWorkItem?

	private init() {}

	/// Searches once typing has paused, for search boxes that search on every keystroke. A search
	/// still waiting is replaced, so only the last text of a burst of keystrokes is searched.
	func searchForContactsDebounced(kinds: Kinds? = nil) {
		DispatchQueue.main.async {
			if let kinds = kinds {
				self.kinds = kinds
			}
			self.searchDebounceWorkItem?.cancel()

			let workItem = DispatchWorkItem {
				self.updateViewAvatarListModel()
				ContactsManager.shared.searchForSuggestions(filter: self.currentFilter)
			}
			self.searchDebounceWorkItem = workItem
			DispatchQueue.main.asyncAfter(deadline: .now() + self.searchDebounceDelay, execute: workItem)
		}
	}

	/// Checks whether the contacts have changed since the models were made, makes them again if they have, and
	/// then lists the models that match the current filter in contactsManager.viewAvatarListModel, see
	/// updateViewAvatarListModel(). `kinds` says what the screen lists, extensions, contacts or both, and is kept for
	/// the searches that do not say.
	func searchForContacts(kinds: Kinds? = nil) {
		DispatchQueue.main.async {
			if let kinds = kinds {
				self.kinds = kinds
			}
			// A search is starting now, so one still waiting would only repeat it
			self.searchDebounceWorkItem?.cancel()
			self.searchDebounceWorkItem = nil
		}
		
		ContactsManager.shared.populateAvatarListModel {
			// The pages already listed stay listed, as the contacts may not have changed
			self.updateViewAvatarListModel(page: self.loadedPage)
		}
		
		ContactsManager.shared.searchForSuggestions(filter: currentFilter)
	}

	/// Filters avatarListModel by the current filter against the name, the phone numbers and the number of the
	/// SIP address (the extension) of each model, and lists the matches in contactsManager.viewAvatarListModel,
	/// each of them loaded while it is in that list. An empty filter matches every model.
	///
	/// What is listed depends on `kinds`: only the extensions, only the contacts, or both. Each kind listed is paged on
	/// its own, in pages of CorePreferences.pageSize. Page 0 lists the first page. A page above 0 adds that page to
	/// what is listed, which is the same as listing the first pages up to it, so the order is kept and nothing is
	/// listed twice if the models have changed in the meantime. hasMore says whether there is a page after the last
	/// one listed, see loadNextPage(). Other kinds than the last search listed, or another filter, start again from
	/// page 0.
	///
	/// Must be called on the main thread.
	func updateViewAvatarListModel(page: Int = 0) {
		loadedPage = page

		let (text, digits) = searchTerms()

		let pageSize = CorePreferences.pageSize
		let limit = pageSize > 0 ? (page + 1) * pageSize : Int.max

		var found: [ContactAvatarModel] = []
		var contactsCount = 0
		var extensionsCount = 0
		var moreContacts = false
		var moreExtensions = false

		let (listsExtensions, listsContacts) = listedKinds()

		for model in contactsManager.avatarListModel {
			if model.isInternal ? !listsExtensions : !listsContacts {
				continue
			}

			if !text.isEmpty && !model.matches(text: text, digits: digits) {
				continue
			}

			if model.isInternal {
				if extensionsCount >= limit {
					moreExtensions = true
				} else {
					extensionsCount += 1
					found.append(model)
				}
			} else {
				if contactsCount >= limit {
					moreContacts = true
				} else {
					contactsCount += 1
					found.append(model)
				}
			}

			// Nothing more is needed once every list shown is full and knows there is more
			if (!listsContacts || moreContacts) && (!listsExtensions || moreExtensions) {
				break
			}
		}

		// The models in the list follow their presence, and the ones that leave it stop after a while
		found.forEach { $0.keepLoaded() }
		hasMore = moreContacts || moreExtensions
		contactsManager.viewAvatarListModel = found

		isLoading = false
	}

	// The current filter as models are compared with it: the text normalised, and its digits if it looks like a phone
	// number (ignoring spaces and punctuation), as phone numbers are only compared then
	private func searchTerms() -> (text: String, digits: String) {
		let text = ContactAvatarModel.normalisedForSearch(currentFilter.trimmingCharacters(in: .whitespaces))

		let digits = text.filter { $0.isNumber }
		let isNumberFilter = !digits.isEmpty && text.allSatisfy { $0.isNumber || " +-().".contains($0) }

		return (text, isNumberFilter ? digits : "")
	}

	// Whether the extensions, and whether the contacts, are listed
	private func listedKinds() -> (extensions: Bool, contacts: Bool) {
		return (kinds != .contacts, kinds != .extensions)
	}

	/// Lists other kinds of record now, from the contacts already made, for when the screen changes. Must be called on
	/// the main thread.
	func showKinds(_ kinds: Kinds) {
		self.kinds = kinds
		updateViewAvatarListModel(page: loadedPage)
	}

	/// The starred models of the kinds listed that match the current filter, taken from the whole of avatarListModel
	/// and not only the pages listed, so a favourite is shown whatever page it would be on. For the favourites of the
	/// Extensions and Contacts pages. Must be called on the main thread.
	func favourites() -> [ContactAvatarModel] {
		let (text, digits) = searchTerms()
		let (listsExtensions, listsContacts) = listedKinds()

		return contactsManager.avatarListModel.filter { model in
			model.starred
				&& (model.isInternal ? listsExtensions : listsContacts)
				&& (text.isEmpty || model.matches(text: text, digits: digits))
		}
	}

	/// The last page that was listed, 0 for the first one. Must only be used on the main thread.
	private(set) var loadedPage = 0

	/// Lists the next page, if there is one. For a list to call when its end is reached. Must be called on the main
	/// thread.
	func loadNextPage() {
		guard hasMore else {
			return
		}

		updateViewAvatarListModel(page: loadedPage + 1)
	}

}
