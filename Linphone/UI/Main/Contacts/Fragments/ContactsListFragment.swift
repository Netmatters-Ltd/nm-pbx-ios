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

import SwiftUI
import linphonesw

struct ContactsListFragment: View {

	@EnvironmentObject var contactsListViewModel: ContactsListViewModel

	@Binding var showingSheet: Bool

	var displayedContacts: [ContactAvatarModel]
    var startCallFunc: (_ addr: Address) -> Void
	// Called when the last row is shown, for the list to ask for its next page
	var loadMore: (() -> Void)?
	// Whether the list is a picker's, see ContactRow.isPicker
	var isPicker = false

	var body: some View {
		ForEach(Array(displayedContacts.enumerated()), id: \.element.id) { index, contactAvatarModel in
			ContactRow(
				contactAvatarModel: contactAvatarModel,
				allContacts: displayedContacts,
				index: index,
				showingSheet: $showingSheet,
				startCallFunc: startCallFunc,
				isPicker: isPicker
			)
			.onAppear {
				if index == displayedContacts.count - 1 {
					loadMore?()
				}
			}
		}
	}
}

/// The contacts of a picker, such as the one to start a call: the extensions, then the contacts, each under its own
/// title, and a note when not all contacts are listed, see MagicSearchSingleton.updatePickerLists(text:digits:). Goes
/// in a ScrollView.
struct PickerContactsSections: View {
	@ObservedObject var magicSearch = MagicSearchSingleton.shared

	var startCallFunc: (_ addr: Address) -> Void

	var body: some View {
		if !magicSearch.pickerExtensions.isEmpty {
			PickerSectionTitle(title: "contacts_list_extensions_title")

			// Lazy, so only the rows on screen are drawn
			LazyVStack(spacing: 8) {
				ContactsListFragment(showingSheet: .constant(false), displayedContacts: magicSearch.pickerExtensions, startCallFunc: startCallFunc, isPicker: true)
			}
			.padding(.horizontal, 16)
		}

		if !magicSearch.pickerContacts.isEmpty {
			PickerSectionTitle(title: "contacts_list_contacts_title")

			LazyVStack(spacing: 8) {
				ContactsListFragment(showingSheet: .constant(false), displayedContacts: magicSearch.pickerContacts, startCallFunc: startCallFunc, isPicker: true)
			}
			.padding(.horizontal, 16)
		}

		if magicSearch.pickerContactsTruncated {
			PickerTruncatedNote()
		}
	}
}

/// The title of a section of a picker
struct PickerSectionTitle: View {
	var title: LocalizedStringKey

	var body: some View {
		HStack(alignment: .center) {
			Text(title)
				.default_text_style_800(styleSize: 16)

			Spacer()
		}
		.padding(.vertical, 10)
		.padding(.horizontal, 16)
	}
}

/// The note under the contacts of a picker when some were left out, which says to search for them, or to search more
/// precisely when they were left out of a search
struct PickerTruncatedNote: View {
	@ObservedObject var magicSearch = MagicSearchSingleton.shared

	var body: some View {
		Group {
			if magicSearch.currentFilter.isEmpty {
				Text("contacts_list_truncated_message")
			} else {
				Text("contacts_list_search_truncated_message")
			}
		}
		.default_text_style_300(styleSize: 14)
		.foregroundStyle(Color.grayMain2c500)
		.multilineTextAlignment(.center)
		.frame(maxWidth: .infinity)
		.padding(.vertical, 10)
		.padding(.horizontal, 16)
	}
}

struct ContactRow: View {
	@EnvironmentObject var contactsListViewModel: ContactsListViewModel

	@ObservedObject var contactAvatarModel: ContactAvatarModel
	var allContacts: [ContactAvatarModel]
	let index: Int

	@Binding var showingSheet: Bool

	var startCallFunc: (_ addr: Address) -> Void

	// Whether the row is in a picker, such as the one to start a call: a tap only hands the contact to startCallFunc, on
	// a phone number if it has no SIP address, and does not open the contact's details or actions as on the Extensions
	// and Contacts pages, which the picker can be open over
	var isPicker = false

	// The phone numbers to choose from, for a contact of a picker with no SIP address and several numbers
	@State private var phoneNumbersToChoose: [(label: String, phoneNumber: String)] = []
	@State private var isShowPhoneNumberChoice = false

	var body: some View {
		HStack {
			HStack {
				if index <= 0
					|| (index < allContacts.count && contactAvatarModel.name.lowercased().folding(
						options: .diacriticInsensitive,
						locale: .current
					).first
					!= allContacts[index-1].name.lowercased().folding(
						options: .diacriticInsensitive,
						locale: .current
					).first) {
					Text(
						String(
							(contactAvatarModel.name.uppercased().folding(
								options: .diacriticInsensitive,
								locale: .current
							).first) ?? "?"))
					.contact_text_style_500(styleSize: 20)
					.frame(width: 18)
					.padding(.leading, -5)
					.padding(.trailing, 10)
				} else {
					Text("")
						.contact_text_style_500(styleSize: 20)
						.frame(width: 18)
						.padding(.leading, -5)
						.padding(.trailing, 10)
				}
				
				Avatar(contactAvatarModel: contactAvatarModel, avatarSize: 50)

				VStack(alignment: .leading, spacing: 1) {
					Text(contactAvatarModel.name)
						.default_text_style(styleSize: 16)
						.frame(maxWidth: .infinity, alignment: .leading)
						.foregroundStyle(Color.orangeMain500)

					let status = contactAvatarModel.presenceUserStatus
					if status != .offline {
						HStack(spacing: 4) {
							Text(status.label)
								.font(Font.custom("Poppins-Regular", size: 11))
								.foregroundStyle(status.badgeColor)

							if !contactAvatarModel.presenceNote.isEmpty {
								Text("· \(contactAvatarModel.presenceNote)")
									.font(Font.custom("Poppins-Regular", size: 11))
									.foregroundStyle(Color.grayMain2c500)
									.lineLimit(1)
							}
						}
					}
				}
			}
		}
		.buttonStyle(.borderless)
		.listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
		.listRowSeparator(.hidden)
		.background(.white)
		.onTapGesture {
			if !isPicker && SharedMainViewModel.shared.indexView <= 1 {
				withAnimation {
					SharedMainViewModel.shared.displayedFriend = contactAvatarModel
				}
			}

			if contactAvatarModel.friend != nil
				&& contactAvatarModel.friend!.address != nil {
				startCallFunc(contactAvatarModel.friend!.address!)
			} else if isPicker {
				usePhoneNumber()
			}
		}
		.onLongPressGesture(minimumDuration: 0.2) {
			if !isPicker && SharedMainViewModel.shared.indexView <= 1 {
				contactsListViewModel.selectedFriend = contactAvatarModel
				showingSheet.toggle()
			}
		}
		.confirmationDialog(Text(contactAvatarModel.name), isPresented: $isShowPhoneNumberChoice, titleVisibility: .visible) {
			ForEach(phoneNumbersToChoose.indices, id: \.self) { index in
				let number = phoneNumbersToChoose[index]
				Button(number.label.isEmpty ? number.phoneNumber : "\(number.label): \(number.phoneNumber)") {
					usePhoneNumber(number.phoneNumber)
				}
			}

			Button("dialog_cancel", role: .cancel) {}
		}
	}

	// For a contact of a picker with no SIP address, as CardDAV contacts often are: hands its phone number to
	// startCallFunc if it has one, or lets the user choose one if it has several. The numbers are read on the core
	// queue, as the contact details screen does.
	private func usePhoneNumber() {
		guard let friend = contactAvatarModel.friend else {
			return
		}

		CoreContext.shared.doOnCoreQueue { _ in
			let numbers = friend.phoneNumbersWithLabel.map { (label: $0.label ?? "", phoneNumber: $0.phoneNumber) }

			DispatchQueue.main.async {
				if numbers.count == 1 {
					usePhoneNumber(numbers[0].phoneNumber)
				} else if numbers.count > 1 {
					phoneNumbersToChoose = numbers
					isShowPhoneNumberChoice = true
				}
			}
		}
	}

	// Hands the phone number to startCallFunc as an address, made as the contact details screen makes it
	private func usePhoneNumber(_ phoneNumber: String) {
		CoreContext.shared.doOnCoreQueue { core in
			guard let address = core.interpretUrl(url: phoneNumber, applyInternationalPrefix: LinphoneUtils.applyInternationalPrefix(core: core)) else {
				Log.error("[ContactRow] Unable to make an address from the phone number of \(contactAvatarModel.name)")
				return
			}

			DispatchQueue.main.async {
				startCallFunc(address)
			}
		}
	}
}

#Preview {
    ContactsListFragment(showingSheet: .constant(false), displayedContacts: [], startCallFunc: {_ in })
}
