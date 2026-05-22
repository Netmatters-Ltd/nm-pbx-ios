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

struct ContactsInnerFragment: View {

	@ObservedObject var contactsManager = ContactsManager.shared
	@ObservedObject var magicSearch = MagicSearchSingleton.shared

	@EnvironmentObject var contactsListViewModel: ContactsListViewModel

	@State private var isFavoriteOpen = true

	@Binding var showingSheet: Bool
	@Binding var text: String
	var mode: ContactsFilterMode

	var filteredContacts: [ContactAvatarModel] {
		contactsManager.avatarListModel.filter { mode == .extensions ? $0.isInternal : !$0.isInternal }
	}

	var body: some View {
		ZStack {
			VStack(alignment: .leading) {
				if filteredContacts.contains(where: { $0.starred }) {
					HStack(alignment: .center) {
						Text("contacts_list_favourites_title")
							.default_text_style_800(styleSize: 16)
						
						Spacer()
						
						Image(isFavoriteOpen ? "caret-up" : "caret-down")
							.renderingMode(.template)
							.resizable()
							.foregroundStyle(Color.grayMain2c600)
							.frame(width: 25, height: 25, alignment: .leading)
							.padding(.all, 10)
					}
					.padding(.top, 10)
					.padding(.horizontal, 16)
					.background(.white)
					.onTapGesture {
						withAnimation {
							isFavoriteOpen.toggle()
						}
					}
					
					if isFavoriteOpen {
						FavoriteContactsListFragment(showingSheet: $showingSheet, displayedContacts: filteredContacts)
							.zIndex(-1)
							.transition(.move(edge: .top))
					}
					
					HStack(alignment: .center) {
						Text("contacts_list_all_contacts_title")
							.default_text_style_800(styleSize: 16)
						
						Spacer()
					}
					.padding(.top, 10)
					.padding(.horizontal, 16)
				}
				
				VStack {
					List {
						ContactsListFragment(showingSheet: $showingSheet, displayedContacts: filteredContacts, startCallFunc: {_ in })
						// Invisible full-height row added only when the list is empty so
						// the pull-to-refresh gesture still has something to grab onto,
						// without creating a blank scrollable gap when contacts are shown.
						if filteredContacts.isEmpty {
							Color.clear
								.frame(height: UIScreen.main.bounds.height)
								.listRowBackground(Color.clear)
								.listRowSeparator(.hidden)
								.listRowInsets(.init())
								.allowsHitTesting(false)
						}
					}
					.safeAreaInset(edge: .top, content: {
						Spacer()
							.frame(height: 12)
					})
					.listStyle(.plain)
					.refreshable {
						await contactsManager.refreshCardDavContacts()
					}
					.overlay(
						VStack {
							if filteredContacts.isEmpty {
								Spacer()
								if !text.isEmpty {
									Image("illus-belledonne")
										.resizable()
										.scaledToFit()
										.clipped()
										.padding(.all)
									Text("list_filter_no_result_found")
										.default_text_style_800(styleSize: 16)
								} else if contactsManager.isCardDavSyncing || magicSearch.isLoading {
									ProgressView()
										.controlSize(.large)
										.progressViewStyle(CircularProgressViewStyle(tint: .orangeMain500))
								} else {
									Image("illus-belledonne")
										.resizable()
										.scaledToFit()
										.clipped()
										.padding(.all)
									Text("contacts_list_empty")
										.default_text_style_800(styleSize: 16)
								}
								Spacer()
								Spacer()
							}
						}
							.padding(.all)
							// Let pull-to-refresh gestures pass through to the underlying list.
							.allowsHitTesting(false)
					)
				}
			}
			
			if magicSearch.isLoading {
				ProgressView()
					.controlSize(.large)
					.progressViewStyle(CircularProgressViewStyle(tint: .orangeMain500))
			}
		}
		.navigationBarHidden(true)
	}
}

#Preview {
	ContactsInnerFragment(showingSheet: .constant(false), text: .constant(""), mode: .contacts)
}
