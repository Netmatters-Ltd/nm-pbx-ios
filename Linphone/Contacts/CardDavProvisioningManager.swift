/*
 * Copyright (c) 2010-2025 Belledonne Communications SARL.
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
import linphonesw

enum CardDavProvisioningManager {
	static let TAG = "[CardDAV Provisioning]"
	private static let fallbackDisplayName = "NMPBX Contacts"
	/// Realm advertised by the NMPBX portal's CardDAV endpoint. Used when the
	/// provisioning XML doesn't specify one, matching what a user would enter
	/// in the manual Settings → Contacts → CardDAV form for this server.
	private static let defaultRealm = "NMPBX CardDAV"

	static func applyIfPresent(core: Core) {
		guard let config = core.config else {
			Log.error("\(TAG) core.config is nil, skipping")
			return
		}

		let serverUrl = config.getString(section: "carddav_provision", key: "server_url", defaultString: "")
		guard !serverUrl.isEmpty else {
			Log.info("\(TAG) No carddav_provision section (or empty server_url), skipping")
			return
		}

		let username = config.getString(section: "carddav_provision", key: "username", defaultString: "")
		let password = config.getString(section: "carddav_provision", key: "password", defaultString: "")
		let configuredName = config.getString(section: "carddav_provision", key: "display_name", defaultString: "")
		let configuredRealm = config.getString(section: "carddav_provision", key: "realm", defaultString: "")
		let rlsUri = config.getString(section: "carddav_provision", key: "rls_uri", defaultString: "")
		let resolvedRealm = configuredRealm.isEmpty ? defaultRealm : configuredRealm

		let normalisedUri: String = {
			if serverUrl.hasPrefix("http://") || serverUrl.hasPrefix("https://") {
				return serverUrl
			}
			return "https://\(serverUrl)"
		}()

		guard let serverHost = URL(string: normalisedUri)?.host, !serverHost.isEmpty else {
			Log.error("\(TAG) server_url '\(serverUrl)' is not a valid URL, skipping")
			return
		}

		let resolvedName: String = {
			if !configuredName.isEmpty { return configuredName }
			return serverHost
		}()

		// CardDAV servers fronted by the NMPBX portal use HTTP Basic, which requires
		// the plaintext password on the client. The SDK default converts plaintext to
		// HA1 on save, which would break Basic auth. Disable that for this Core.
		config.setInt(section: "sip", key: "store_ha1_passwd", value: 0)

		// Pre-register an AuthInfo with the realm the server is known to advertise
		// (see `defaultRealm`). The SDK's CardDAV HTTP auth does not invoke the
		// app-level onAuthenticationRequested callback for Basic challenges — it
		// relies on find_auth_info returning a stored entry before the request
		// goes out. Matching this mirrors what a user would enter in the manual
		// CardDAV form (CardDavViewModel.addAddressBook).
		if !username.isEmpty && !password.isEmpty {
			// domain = serverHost so CardDavViewModel.loadcardDav can find this
			// AuthInfo back from the FriendList URI. Doesn't affect Basic auth
			// matching (the realm is what the SDK keys on for HTTP 401 lookup).
			if let existing = core.findAuthInfo(realm: resolvedRealm, username: username, sipDomain: serverHost) {
				Log.info("\(TAG) Replacing existing auth info for \(username) realm=\(resolvedRealm) domain=\(serverHost)")
				core.removeAuthInfo(info: existing)
			}
			if let info = try? Factory.Instance.createAuthInfo(
				username: username,
				userid: nil,
				passwd: password,
				ha1: nil,
				realm: resolvedRealm,
				domain: serverHost
			) {
				core.addAuthInfo(info: info)
				Log.info("\(TAG) Added auth info for \(username) realm=\(resolvedRealm) domain=\(serverHost)")
			} else {
				Log.error("\(TAG) Failed to create auth info for \(username) realm=\(resolvedRealm)")
			}
		} else {
			Log.warn("\(TAG) Missing username or password, creating CardDAV list without auth")
		}

		let friendList: FriendList
		if let existing = core.friendsLists.first(where: { $0.type == .CardDAV && $0.uri == normalisedUri }) {
			existing.displayName = resolvedName
			friendList = existing
			Log.info("\(TAG) Updating existing CardDAV friend list at \(normalisedUri) (name=\(resolvedName))")
		} else {
			guard let created = try? core.createFriendList() else {
				Log.error("\(TAG) Failed to create CardDAV friend list for \(normalisedUri)")
				return
			}
			created.type = .CardDAV
			created.uri = normalisedUri
			created.displayName = resolvedName
			created.databaseStorageEnabled = true
			core.addFriendList(list: created)
			friendList = created
			Log.info("\(TAG) Created CardDAV friend list at \(normalisedUri) (name=\(resolvedName))")
		}

		// The Flexisip presence server uses a Resource List Server (RLS) to aggregate
		// subscriptions. Without an rlsUri on the friend list the SDK falls back to
		// individual per-friend SUBSCRIBE, which the RLS-only server silently ignores,
		// meaning no NOTIFY ever arrives. Set it from the provisioned value if present.
		if !rlsUri.isEmpty {
			friendList.rlsUri = rlsUri
			Log.info("\(TAG) Set rlsUri=\(rlsUri) on '\(friendList.displayName ?? normalisedUri)'")
		} else {
			Log.warn("\(TAG) No rls_uri in [carddav_provision] — presence subscriptions will fall back to individual SUBSCRIBE (add rls_uri to provisioning XML to fix)")
		}

		// Do NOT call synchronizeFriendsFromServer() here.
		//
		// applyIfPresent() is called twice per session: once at GlobalState.On
		// (with the cached config) and again at ConfiguringState.Successful
		// (after the remote XML is downloaded). Each call was previously starting
		// its own sync on the same FriendList, and ContactsManager.fetchContacts()
		// also calls refreshCardDavContacts() → synchronizeFriendsFromServer().
		// That produced 2-3 concurrent syncs on the same list.
		//
		// The liblinphone CardDAV engine has a shared state machine per FriendList,
		// so concurrent syncs corrupt its internal URL tracking. The symptom is the
		// addressbook-query REPORT being sent to the home-set path
		// (/carddav/addressbooks/1/) instead of the specific address book
		// (/carddav/addressbooks/1/contacts/). The server returns an empty 207
		// (no auth challenge) for that path, the SDK stores the CTAG, and every
		// subsequent sync sees "CTAG unchanged" and fetches nothing.
		//
		// The sync is triggered exactly once by ContactsManager.fetchContacts() →
		// refreshCardDavContacts(), which runs after RegistrationState.Ok.
		// ConfiguringState.Successful always precedes RegistrationState.Ok, so the
		// friend list created/updated here will be found and synced by that path.
	}

	/// Called from `CoreContext.onAuthenticationRequested` when the SDK asks the
	/// app to supply credentials for an HTTP Basic challenge (which CardDAV
	/// servers use). Populates the supplied `authInfo` from the provisioning
	/// config and registers it with the core so the in-flight request can retry
	/// successfully. Returns true if credentials were applied.
	@discardableResult
	static func fulfillHttpBasicChallenge(core: Core, authInfo: AuthInfo) -> Bool {
		guard let config = core.config else { return false }

		let username = config.getString(section: "carddav_provision", key: "username", defaultString: "")
		let password = config.getString(section: "carddav_provision", key: "password", defaultString: "")
		guard !username.isEmpty, !password.isEmpty else {
			Log.warn("\(TAG) Basic auth challenged but no carddav_provision credentials configured")
			return false
		}

		let challengeRealm = authInfo.realm
		let challengeDomain = authInfo.domain

		authInfo.username = username
		authInfo.password = password
		core.addAuthInfo(info: authInfo)

		Log.info("\(TAG) Fulfilled Basic auth challenge (realm=\(challengeRealm ?? "<nil>"), domain=\(challengeDomain ?? "<nil>")) for \(username)")
		return true
	}

}
