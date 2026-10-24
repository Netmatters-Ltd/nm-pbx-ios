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

import linphonesw
import Combine
import SwiftUI

class HistoryListViewModel: ObservableObject {
	
	private var coreContext = CoreContext.shared
	
	// The call logs listed: the first pages of the ones that match the filter, see updateCallLogs(page:)
	@Published var callLogs: [HistoryModel] = []
	// Every call log, whatever the filter or the page
	var callLogsTmp: [HistoryModel] = []

	// True when more call logs match the filter than the pages listed, so the next page can be asked for
	@Published private(set) var hasMore = false
	private var loadedPage = 0
	private var currentFilter = ""

	// A search is made once typing has paused
	private let filterDebounceDelay: TimeInterval = 0.3
	private var filterWorkItem: DispatchWorkItem?

	// The models made for the call logs, so a call log that is still there keeps its model when the others change.
	// Only used on the core queue.
	private var modelCache: [ObjectIdentifier: HistoryModel] = [:]
	
	var callLogsAddressToDelete = ""
	var callLogCoreDelegate: CoreDelegate?
	
	@Published var selectedCall: HistoryModel?
	
	@Published var displayedConversation: ConversationModel?
	
	private var historyChatRoomDelegate: ChatRoomDelegate?
	
	init() {
		computeCallLogsList()
        SharedMainViewModel.shared.updateMissedCallsCount()
	}
	
	func computeCallLogsList() {
		coreContext.doOnCoreQueue { core in
			self.updateModels(core: core, updatedCallLog: nil)

			self.callLogCoreDelegate = CoreDelegateStub(onCallLogUpdated: { (_: Core, callLog: CallLog) in
				self.updateModels(core: core, updatedCallLog: callLog)

                SharedMainViewModel.shared.updateMissedCallsCount()
			})
			core.addDelegate(delegate: self.callLogCoreDelegate!)
		}
	}

	// Makes the models of the call logs, and lists them. A call log that already has a model keeps it, so a change to
	// one call log does not make a model for every other. Only the call log that was updated is read again. Must be
	// called on the core queue.
	private func updateModels(core: Core, updatedCallLog: CallLog?) {
		// Fetch all call logs if only one account to workaround no history issue
		// TODO FIXME: remove workaround later
		let logs = (core.accountList.count > 1)
			? (core.defaultAccount?.callLogs ?? core.callLogs)
			: core.callLogs

		var models: [HistoryModel] = []
		var cache: [ObjectIdentifier: HistoryModel] = [:]

		logs.forEach { log in
			let key = ObjectIdentifier(log)
			let model: HistoryModel
			if let existing = modelCache[key] {
				model = existing
				if log === updatedCallLog {
					model.initValue(callLog: log)
				}
			} else {
				model = HistoryModel(callLog: log)
			}

			cache[key] = model
			models.append(model)
		}

		modelCache = cache

		DispatchQueue.main.async {
			self.callLogsTmp = models
			// The pages already listed stay listed
			self.updateCallLogs(page: self.loadedPage)
		}
	}

	/// Lists the call logs that match the filter, the first pages of them up to `page`, in callLogs. Page 0 lists the
	/// first page, a page above 0 adds that page to what is listed. Must be called on the main thread.
	private func updateCallLogs(page: Int = 0) {
		loadedPage = page

		// Compared lowercase and without accents, like the contacts search
		let filter = ContactAvatarModel.normalisedForSearch(currentFilter)
		let matching = filter.isEmpty ? callLogsTmp : callLogsTmp.filter { $0.searchName.contains(filter) }

		let pageSize = CorePreferences.pageSize
		let limit = pageSize > 0 ? (page + 1) * pageSize : Int.max

		hasMore = matching.count > limit
		callLogs = Array(matching.prefix(limit))
	}

	/// Lists the next page of call logs, if there is one. For the list to call when its end is reached. Must be called
	/// on the main thread.
	func loadNextPage() {
		guard hasMore else {
			return
		}

		updateCallLogs(page: loadedPage + 1)
	}
	
	func getCallIconResId(callStatus: Call.Status, isOutgoing: Bool) -> String {
		switch callStatus {
		case Call.Status.Missed:
			if isOutgoing {
				"outgoing-call-missed"
			} else {
				"incoming-call-missed"
			}
			
		case Call.Status.Success:
			if isOutgoing {
				"outgoing-call"
			} else {
				"incoming-call"
			}
			
		default:
			if isOutgoing {
				"outgoing-call-rejected"
			} else {
				"incoming-call-rejected"
			}
		}
	}
	
	func getCallText(callStatus: Call.Status, isOutgoing: Bool) -> String {
		switch callStatus {
		case Call.Status.Missed:
			if isOutgoing {
				String(localized: "call_outgoing")
			} else {
				String(localized: "notification_missed_call_title")
			}
			
		case Call.Status.Success:
			if isOutgoing {
				String(localized: "call_outgoing")
			} else {
				String(localized: "call_audio_incoming")
			}
			
		default:
			if isOutgoing {
				String(localized: "call_outgoing")
			} else {
				String(localized: "call_audio_incoming")
			}
		}
	}
	
	func getCallTime(startDate: time_t) -> String {
		let timeInterval = TimeInterval(startDate)
		
		let myNSDate = Date(timeIntervalSince1970: timeInterval)
		
		if Calendar.current.isDateInToday(myNSDate) {
			let formatter = DateFormatter()
			formatter.dateFormat = Locale.current.identifier == "fr_FR" ? "HH:mm" : "h:mm a"
			return "Today | " + formatter.string(from: myNSDate)
		} else if Calendar.current.isDateInYesterday(myNSDate) {
			let formatter = DateFormatter()
			formatter.dateFormat = Locale.current.identifier == "fr_FR" ? "HH:mm" : "h:mm a"
			return "Yesterday | " + formatter.string(from: myNSDate)
		} else if Calendar.current.isDate(myNSDate, equalTo: .now, toGranularity: .year) {
			let formatter = DateFormatter()
			formatter.dateFormat = Locale.current.identifier == "fr_FR" ? "dd/MM | HH:mm" : "MM/dd | h:mm a"
			return formatter.string(from: myNSDate)
		} else {
			let formatter = DateFormatter()
			formatter.dateFormat = Locale.current.identifier == "fr_FR" ? "dd/MM/yy | HH:mm" : "MM/dd/yy | h:mm a"
			return formatter.string(from: myNSDate)
		}
	}
	
	/// Lists the call logs whose name has the filter in it, once typing has paused. A search still waiting is replaced,
	/// so only the last text of a burst of keystrokes is searched. Must be called on the main thread.
	func filterCallLogs(filter: String) {
		filterWorkItem?.cancel()

		let workItem = DispatchWorkItem { [weak self] in
			self?.currentFilter = filter
			self?.updateCallLogs()
		}
		filterWorkItem = workItem
		DispatchQueue.main.asyncAfter(deadline: .now() + filterDebounceDelay, execute: workItem)
	}

	func resetFilterCallLogs() {
		filterWorkItem?.cancel()
		filterWorkItem = nil

		currentFilter = ""
		updateCallLogs()
	}
	
	func removeCallLogs() {
		if callLogsAddressToDelete.isEmpty {
			coreContext.doOnCoreQueue { core in
				let account = core.defaultAccount
				if account != nil {
					account!.clearCallLogs()
				} else {
					core.clearCallLogs()
				}
				
				DispatchQueue.main.async {
					self.callLogs.removeAll()
					self.callLogsTmp.removeAll()
					self.hasMore = false
				}
			}
		} else {
			removeCallLogsWithAddress()
			callLogsAddressToDelete = ""
		}
	}
	
	func removeCallLogsWithAddress() {
		// Every call log of the address, not only the ones in the pages listed
		self.callLogsTmp.filter { $0.address == callLogsAddressToDelete }.forEach { historyModel in
			removeCallLog(historyModel: historyModel)
		}
	}

	func removeCallLog(historyModel: HistoryModel) {
		if let index = self.callLogs.firstIndex(where: {$0.id == historyModel.id}) {
			self.callLogs.remove(at: index)
		}

		if let indexTmp = self.callLogsTmp.firstIndex(where: {$0.id == historyModel.id}) {
			self.callLogsTmp.remove(at: indexTmp)
		}

		coreContext.doOnCoreQueue { core in
			core.removeCallLog(callLog: historyModel.callLog)
		}
	}
	
	/// Finds the avatar models of the call logs again, for when the contacts have changed. Must be called on the main
	/// thread.
	func refreshHistoryAvatarModel() {
		// Every call log, as the ones outside the pages listed are listed later with the model they have now
		let models = callLogsTmp
		coreContext.doOnCoreQueue { _ in
			models.forEach { historyModel in
				historyModel.refreshAvatarModel()
			}
		}
	}
	
	func createOneToOneChatRoomWith(remote: Address) {
		CoreContext.shared.doOnCoreQueue { core in
			let account = core.defaultAccount
			if account == nil {
				Log.error(
					"\(ConversationForwardMessageViewModel.TAG) No default account found, can't create conversation with \(remote.asStringUriOnly())"
				)
				return
			}
			
			DispatchQueue.main.async {
				SharedMainViewModel.shared.operationInProgress = true
			}
			
			do {
				let params = try core.createConferenceParams(conference: nil)
				params.chatEnabled = true
				params.groupEnabled = false
				params.subject = NSLocalizedString("conversation_one_to_one_hidden_subject", comment: "")
				params.account = account
				
				guard let chatParams = params.chatParams else { return }
				chatParams.ephemeralLifetime = 0 // Make sure ephemeral is disabled by default
				
				let sameDomain = remote.domain == CorePreferences.defaultDomain && remote.domain == account!.params?.domain
				if account!.params != nil && (account!.params!.instantMessagingEncryptionMandatory && sameDomain) {
					Log.info("\(ConversationForwardMessageViewModel.TAG) Account is in secure mode & domain matches, creating an E2E encrypted conversation")
					chatParams.backend = ChatRoom.Backend.FlexisipChat
					params.securityLevel = Conference.SecurityLevel.EndToEnd
				} else if account!.params != nil && (!account!.params!.instantMessagingEncryptionMandatory) {
					if LinphoneUtils.isEndToEndEncryptedChatAvailable(core: core) {
						Log.info(
							"\(ConversationForwardMessageViewModel.TAG) Account is in interop mode but LIME is available, creating an E2E encrypted conversation"
						)
						chatParams.backend = ChatRoom.Backend.FlexisipChat
						params.securityLevel = Conference.SecurityLevel.EndToEnd
					} else {
						Log.info(
							"\(ConversationForwardMessageViewModel.TAG) Account is in interop mode but LIME isn't available, creating a SIP simple conversation"
						)
						chatParams.backend = ChatRoom.Backend.Basic
						params.securityLevel = Conference.SecurityLevel.None
					}
				} else {
					Log.error(
						"\(ConversationForwardMessageViewModel.TAG) Account is in secure mode, can't chat with SIP address of different domain \(remote.asStringUriOnly())"
					)
					
					DispatchQueue.main.async {
						SharedMainViewModel.shared.operationInProgress = false
						ToastViewModel.shared.show("Failed_to_create_conversation_error")
					}
					return
				}
				
				let participants = [remote]
				let localAddress = account?.params?.identityAddress
				let existingChatRoom = core.searchChatRoom(params: params, localAddr: localAddress, remoteAddr: nil, participants: participants)
				if existingChatRoom == nil {
					Log.info(
						"\(ConversationForwardMessageViewModel.TAG) No existing 1-1 conversation between local account \(localAddress?.asStringUriOnly() ?? "") and remote \(remote.asStringUriOnly()) was found for given parameters, let's create it"
					)
					
					do {
						let chatRoom = try core.createChatRoom(params: params, participants: participants)
						if chatParams.backend == ChatRoom.Backend.FlexisipChat {
							let state = chatRoom.state
							if state == ChatRoom.State.Created {
								let chatRoomId = LinphoneUtils.getConversationId(chatRoom: chatRoom)
								Log.info("\(ConversationForwardMessageViewModel.TAG) 1-1 conversation \(chatRoomId) has been created")
								
								let model = ConversationModel(chatRoom: chatRoom)
								DispatchQueue.main.async {
									self.displayedConversation = model
									SharedMainViewModel.shared.operationInProgress = false
								}
							} else {
								Log.info("\(ConversationForwardMessageViewModel.TAG) Conversation isn't in Created state yet (state is \(state)), wait for it")
								self.chatRoomAddDelegate(core: core, chatRoom: chatRoom)
							}
						} else {
							let chatRoomId = LinphoneUtils.getConversationId(chatRoom: chatRoom)
							Log.info("\(ConversationForwardMessageViewModel.TAG) Conversation successfully created \(chatRoomId)")
							
							let model = ConversationModel(chatRoom: chatRoom)
							DispatchQueue.main.async {
								self.displayedConversation = model
								SharedMainViewModel.shared.operationInProgress = false
							}
						}
					} catch {
						Log.error("\(ConversationForwardMessageViewModel.TAG) Failed to create 1-1 conversation with \(remote.asStringUriOnly())")
						
						DispatchQueue.main.async {
							SharedMainViewModel.shared.operationInProgress = false
							ToastViewModel.shared.show("Failed_to_create_conversation_error")
						}
					}
				} else {
					Log.warn(
						"\(ConversationForwardMessageViewModel.TAG) A 1-1 conversation between local account \(localAddress?.asStringUriOnly() ?? "") and remote \(remote.asStringUriOnly()) for given parameters already exists!"
					)
					let model = ConversationModel(chatRoom: existingChatRoom!)
					DispatchQueue.main.async {
						self.displayedConversation = model
						SharedMainViewModel.shared.operationInProgress = false
					}
				}
			} catch {
			}
		}
	}
	
	func chatRoomAddDelegate(core: Core, chatRoom: ChatRoom) {
		historyChatRoomDelegate = ChatRoomDelegateStub(onStateChanged: { (chatRoom: ChatRoom, state: ChatRoom.State) in
			let state = chatRoom.state
			let id = LinphoneUtils.getChatRoomId(room: chatRoom)
			if state == ChatRoom.State.CreationFailed {
				Log.error("\(StartConversationViewModel.TAG) Conversation \(id) creation has failed!")
				if let delegate = self.historyChatRoomDelegate {
					chatRoom.removeDelegate(delegate: delegate)
					self.historyChatRoomDelegate = nil
				}
				DispatchQueue.main.async {
					SharedMainViewModel.shared.operationInProgress = false
					ToastViewModel.shared.show("Failed_to_create_conversation_error")
				}
			}
		}, onConferenceJoined: { (chatRoom: ChatRoom, _: EventLog) in
			let state = chatRoom.state
			let id = LinphoneUtils.getChatRoomId(room: chatRoom)
			Log.info("\(StartConversationViewModel.TAG) Conversation \(id) \(chatRoom.subject ?? "") state changed: \(state)")
			if state == ChatRoom.State.Created {
				Log.info("\(StartConversationViewModel.TAG) Conversation \(id) successfully created")
				if let delegate = self.historyChatRoomDelegate {
					chatRoom.removeDelegate(delegate: delegate)
					self.historyChatRoomDelegate = nil
				}
				let model = ConversationModel(chatRoom: chatRoom)
				if 	SharedMainViewModel.shared.operationInProgress == false {
					DispatchQueue.main.async {
						SharedMainViewModel.shared.operationInProgress = true
					}
					
					DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
						SharedMainViewModel.shared.operationInProgress = false
						self.displayedConversation = model
					}
				} else {
					DispatchQueue.main.async {
						SharedMainViewModel.shared.operationInProgress = false
						self.displayedConversation = model
					}
				}
			} else if state == ChatRoom.State.CreationFailed {
				Log.error("\(StartConversationViewModel.TAG) Conversation \(id) creation has failed!")
				
				if let delegate = self.historyChatRoomDelegate {
					chatRoom.removeDelegate(delegate: delegate)
					self.historyChatRoomDelegate = nil
				}
				DispatchQueue.main.async {
					SharedMainViewModel.shared.operationInProgress = false
					ToastViewModel.shared.show("Failed_to_create_conversation_error")
				}
			}
		})
		chatRoom.addDelegate(delegate: historyChatRoomDelegate!)
	}
}
