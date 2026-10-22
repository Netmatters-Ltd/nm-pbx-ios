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

	var currentFilter: String = ""

	@Published var isLoading = false

	// Delay after the last keystroke before a search starts. Must only be used on the main thread.
	private let searchDebounceDelay: TimeInterval = 0.3
	private var searchDebounceWorkItem: DispatchWorkItem?

	private init() {}

	/// Searches once typing has paused, for search boxes that search on every keystroke. A search
	/// still waiting is replaced, so only the last text of a burst of keystrokes is searched.
	func searchForContactsDebounced() {
		DispatchQueue.main.async {
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
	/// updateViewAvatarListModel().
	func searchForContacts() {
		DispatchQueue.main.async {
			// A search is starting now, so one still waiting would only repeat it
			self.searchDebounceWorkItem?.cancel()
			self.searchDebounceWorkItem = nil
		}
		
		ContactsManager.shared.populateAvatarListModel {
			self.updateViewAvatarListModel()
		}
		
		ContactsManager.shared.searchForSuggestions(filter: currentFilter)
	}

	/// Filters avatarListModel by the current filter against the name, the phone numbers and the number of the
	/// SIP address (the extension) of each model, and lists the matches in contactsManager.viewAvatarListModel,
	/// each of them loaded while it is in that list. An empty filter matches every model.
	///
	/// The matches are split into extensions and contacts before any limit is applied: only the contacts are
	/// limited, to CorePreferences.maxContactsDisplayed, so the limit never hides an extension. Extensions are
	/// never limited, the app needs to see them all to track their presence.
	///
	/// Must be called on the main thread.
	func updateViewAvatarListModel() {
		let text = ContactAvatarModel.normalisedForSearch(currentFilter.trimmingCharacters(in: .whitespaces))

		// Phone numbers are only compared when the filter looks like a number, ignoring spaces and punctuation
		let digits = text.filter { $0.isNumber }
		let isNumberFilter = !digits.isEmpty && text.allSatisfy { $0.isNumber || " +-().".contains($0) }

		let maxContacts = CorePreferences.maxContactsDisplayed

		var found: [ContactAvatarModel] = []
		var contactsCount = 0
		var truncated = false
		for model in contactsManager.avatarListModel {
			if !text.isEmpty && !isMatch(model, text: text, digits: isNumberFilter ? digits : "") {
				continue
			}

			if !model.isInternal {
				if maxContacts > 0 && contactsCount >= maxContacts {
					truncated = true
					continue
				}

				contactsCount += 1
			}

			found.append(model)
		}

		// Load the new models before unloading the previous ones, so a model in both lists stays loaded
		let previous = contactsManager.viewAvatarListModel
		found.forEach { $0.load() }
		contactsManager.contactsListTruncated = truncated
		contactsManager.viewAvatarListModel = found
		previous.forEach { $0.unload() }

		isLoading = false
	}

	private func isMatch(_ model: ContactAvatarModel, text: String, digits: String) -> Bool {
		if model.searchName.contains(text) {
			return true
		}

		if model.searchUsernames.contains(where: { $0.contains(text) }) {
			return true
		}

		return !digits.isEmpty && model.searchNumbers.contains { $0.contains(digits) }
	}
}
