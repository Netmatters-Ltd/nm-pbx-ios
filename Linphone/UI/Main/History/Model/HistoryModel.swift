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

class HistoryModel: ObservableObject, Identifiable {
	
	private var coreContext = CoreContext.shared
	
	static let TAG = "[History Model]"
	
	let id = UUID()
	
	var callLog: CallLog
	
	@Published var callLogId: String
	@Published var subject: String
	@Published var isConf: Bool
	@Published var addressLinphone: Address
	@Published var address: String
	@Published var addressName: String
	@Published var isOutgoing: Bool
	@Published var status: Call.Status
	@Published var startDate: time_t
	@Published var duration: Int
	@Published var isFriend: Bool = false
	@Published var avatarModel: ContactAvatarModel?

	// Number of views showing the avatar of the call, the row and its details. The avatar model is only
	// loaded while it is above 0, see appear() and disappear(). Only used on the main thread.
	private var shownCount = 0
	
	init(callLog: CallLog) {
		self.callLog = callLog
		self.callLogId = ""
		self.subject = ""
		self.isConf = false
		
		self.addressLinphone = callLog.dir == .Outgoing && callLog.toAddress != nil ? callLog.toAddress! : callLog.fromAddress!
		self.address = ""
		
		self.addressName = ""
		
		self.isOutgoing = false
		
		self.status = .Success
		
		self.startDate = 0
		
		self.duration = 0
		
		self.initValue(callLog: callLog)
	}
	
	func initValue(callLog: CallLog) {
		coreContext.doOnCoreQueue { _ in
			let callLogTmp = callLog
			let idTmp = callLog.callId ?? ""
			let confInfoTmp = callLog.conferenceInfo
			let subjectTmp = confInfoTmp != nil && confInfoTmp!.subject != nil ? confInfoTmp!.subject! : ""
			let isConfTmp = confInfoTmp != nil
			
			let addressLinphoneTmp = callLog.dir == .Outgoing && callLog.toAddress != nil ? callLog.toAddress! : callLog.fromAddress!
			
			let addressNameTmp = confInfoTmp != nil && confInfoTmp!.subject != nil
			? confInfoTmp!.subject!
			: (addressLinphoneTmp.displayName != nil ? addressLinphoneTmp.displayName ?? "" : addressLinphoneTmp.username ?? "")
			
			let addressTmp = addressLinphoneTmp.asStringUriOnly()
			
			let isOutgoingTmp = callLog.dir == .Outgoing
			
			let statusTmp = callLog.status
			
			let startDateTmp = callLog.startDate
			
			let durationTmp = callLog.duration
			
			DispatchQueue.main.async {
				self.callLog = callLogTmp
				self.callLogId = idTmp
				self.subject = subjectTmp
				self.isConf = isConfTmp
				
				self.addressLinphone = addressLinphoneTmp
				self.address = addressTmp
				
				self.addressName = addressNameTmp
				
				self.isOutgoing = isOutgoingTmp
				
				self.status = statusTmp
				
				self.startDate = startDateTmp
				
				self.duration = durationTmp
			}
			
			self.refreshAvatarModel()
		}
	}
	
	/// To be called when a view that shows the avatar of the call is about to appear. The avatar model is
	/// loaded until the last of those views has disappeared.
	func appear() {
		shownCount += 1
		if shownCount == 1 {
			avatarModel?.load()
		}
	}

	func disappear() {
		guard shownCount > 0 else {
			return
		}

		shownCount -= 1
		if shownCount == 0 {
			avatarModel?.unload()
		}
	}

	// Sets the avatar model, loading it if a view is showing it and unloading the one it replaces
	private func setAvatarModel(_ newAvatarModel: ContactAvatarModel) {
		let previousAvatarModel = avatarModel
		if shownCount > 0 {
			newAvatarModel.load()
		}

		avatarModel = newAvatarModel

		if shownCount > 0 {
			previousAvatarModel?.unload()
		}
	}

	func refreshAvatarModel() {
		guard let address = (self.callLog.dir == .Outgoing ? self.callLog.toAddress : self.callLog.fromAddress) else {
			DispatchQueue.main.async {
				self.setAvatarModel(ContactAvatarModel(friend: nil, name: self.addressName, address: self.address, withPresence: false, deferLoad: true))
			}
			return
		}
		
		let addressFriendTmp = ContactsManager.shared.getFriendWithAddress(address: address)
		if let addressFriendTmp = addressFriendTmp {
			let addressNameTmp = self.addressName
			
			let avatarModelTmp = ContactsManager.shared.avatarModel(forAddress: addressFriendTmp.address?.asStringUriOnly() ?? "") ?? ContactAvatarModel(
				friend: nil,
				name: self.addressName,
				address: self.address,
				withPresence: false,
				deferLoad: true
			)
			
			let addressFriendNameTmp = addressFriendTmp.name ?? addressNameTmp
			
			DispatchQueue.main.async {
				self.isFriend = true
				self.addressName = addressFriendNameTmp
				self.setAvatarModel(avatarModelTmp)
			}
		} else {
			DispatchQueue.main.async {
				self.setAvatarModel(ContactAvatarModel(friend: nil, name: self.addressName, address: self.address, withPresence: false, deferLoad: true))
			}
		}
	}
}
