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
	@Published var addressName: String {
		didSet {
			searchName = ContactAvatarModel.normalisedForSearch(addressName)
		}
	}
	// The name as the filter of the list compares it, lowercase and without accents, kept up to date as the name
	// changes so a search does not have to prepare every name again. Only used on the main thread.
	private(set) var searchName = ""
	@Published var isOutgoing: Bool
	@Published var status: Call.Status
	@Published var startDate: time_t
	@Published var duration: Int
	@Published var isFriend: Bool = false
	@Published var avatarModel: ContactAvatarModel?

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
	
	func refreshAvatarModel() {
		guard let address = (self.callLog.dir == .Outgoing ? self.callLog.toAddress : self.callLog.fromAddress) else {
			DispatchQueue.main.async {
				self.avatarModel = ContactAvatarModel(friend: nil, name: self.addressName, address: self.address, withPresence: false)
			}
			return
		}

		ContactsManager.shared.avatarModel(address: address) { avatarModel in
			DispatchQueue.main.async {
				self.isFriend = avatarModel.friend != nil
				if avatarModel.friend != nil {
					self.addressName = avatarModel.name
				}
				self.avatarModel = avatarModel
			}
		}
	}
}
