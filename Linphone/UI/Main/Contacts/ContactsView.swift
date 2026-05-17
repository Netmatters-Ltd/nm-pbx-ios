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

struct ContactsView: View {

	@EnvironmentObject var contactsListViewModel: ContactsListViewModel

	@Binding var isShowEditContactFragment: Bool
	@Binding var isShowDeletePopup: Bool
	@Binding var text: String
	var mode: ContactsFilterMode

	var body: some View {
		NavigationView {
			ContactsFragment(isShowDeletePopup: $isShowDeletePopup, text: $text, mode: mode)
		}
		.navigationViewStyle(.stack)
	}
}

#Preview {
	ContactsView(
		isShowEditContactFragment: .constant(false),
		isShowDeletePopup: .constant(false),
		text: .constant(""),
		mode: .contacts
	)
}
