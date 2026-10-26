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

enum LookupProperty: Hashable {
	case address
	case phoneNumber
}

struct LookupKey: Hashable {
	let property: LookupProperty
	let value: String
}

/// Index of registered lists by property value, so finding the record with a given address or phone
/// number is a dictionary access instead of a scan of every record. The service keeps the records it
/// indexed, so a lookup returns the record itself and the caller never reads the list again:
///
///     LookupService.shared.register("linphoneFriendList", items: { linphoneFriendList.friends }, keys: { friend in ... })
///     let friend: Friend? = LookupService.shared.item(in: "linphoneFriendList", property: .address, value: uri)
///
/// The service does not rank the lists, the caller searches them in the order it wants.
///
/// A list is indexed the first time it is searched and marked stale when its records change, it is
/// rebuilt by the next search. Until then a lookup gives the records as they were when it was indexed.
///
/// Safe to use from any thread: the state is only touched on a private serial queue, in short steps
/// that never call out. A rebuild calls `items` and `keys`, which read the SDK, so it runs on the core
/// queue (CoreContext.doOnCoreQueue), and a search that needs one waits for it when it is called from
/// another thread. A search from the core queue rebuilds inline.
final class LookupService {

	static let shared = LookupService()

	private let queue = DispatchQueue(label: "org.linphone.LookupService")

	// Everything below is only read or written on `queue`
	private var builders: [String: () -> (index: [LookupKey: Int], items: [Any])] = [:]
	private var indexes: [String: [LookupKey: Int]] = [:]
	// The records each index was built from, the positions in the index are positions in these
	private var itemLists: [String: [Any]] = [:]
	private var staleLists: Set<String> = []
	// Changes whenever a list is registered or marked stale, so a rebuild that was running while that
	// happened does not clear the stale mark it has not taken into account
	private var generations: [String: Int] = [:]

	private init() {}

	/// Registers a list by name, registering the same name again replaces it. `items` returns the
	/// current records of the list, it is called again on every rebuild. `keys` returns the searchable
	/// values of one record, it is called for every record of the list.
	func register<Item>(_ name: String, items: @escaping () -> [Item], keys: @escaping (Item) -> [LookupKey]) {
		let builder: () -> (index: [LookupKey: Int], items: [Any]) = {
			var index: [LookupKey: Int] = [:]
			let list = items()
			for (position, item) in list.enumerated() {
				for key in keys(item) where index[key] == nil {
					// The first record wins when several share a value, as with first(where:)
					index[key] = position
				}
			}
			return (index, list)
		}

		queue.sync {
			builders[name] = builder
			indexes[name] = nil
			itemLists[name] = nil
			staleLists.insert(name)
			generations[name, default: 0] += 1
		}
	}

	func isRegistered(_ name: String) -> Bool {
		return queue.sync { builders[name] != nil }
	}

	func unregister(_ name: String) {
		queue.sync {
			builders[name] = nil
			indexes[name] = nil
			itemLists[name] = nil
			staleLists.remove(name)
			generations[name, default: 0] += 1
		}
	}

	/// To be called whenever a record of the list is added, removed or changed
	func markStale(_ name: String) {
		// An empty name is a list without a display name, there is nothing registered under it
		guard !name.isEmpty else {
			return
		}

		queue.sync {
			staleLists.insert(name)
			generations[name, default: 0] += 1
		}
	}

	/// A number that changes whenever the list is registered or marked stale, so a caller can tell cheaply whether
	/// the records may have changed since it last looked
	func generation(of name: String) -> Int {
		return queue.sync { generations[name, default: 0] }
	}

	/// Rebuilds the index of the list now
	func refresh(_ name: String) {
		rebuild(name)
	}

	/// The record whose property has this value, as it was when the list was last indexed. Nil if there is none, or
	/// if the records are not of type `Item`.
	func item<Item>(in name: String, property: LookupProperty, value: String) -> Item? {
		let needsRebuild = queue.sync { staleLists.contains(name) || indexes[name] == nil }
		if needsRebuild {
			rebuild(name)
		}

		return queue.sync { () -> Item? in
			guard let position = indexes[name]?[LookupKey(property: property, value: value)],
				  let list = itemLists[name],
				  list.indices.contains(position) else {
				return nil
			}

			return list[position] as? Item
		}
	}

	// Builds the index on the core queue, as it reads the SDK, and stores it on `queue`
	private func rebuild(_ name: String) {
		let (builder, generation) = queue.sync { (builders[name], generations[name, default: 0]) }
		guard let build = builder else {
			return
		}

		var built: (index: [LookupKey: Int], items: [Any])?
		CoreContext.shared.doOnCoreQueue(synchronous: true) { _ in
			built = build()
		}

		// Nothing was built when the core is off, the list stays as it was
		guard let built = built else {
			return
		}

		queue.sync {
			// The list was unregistered while it was being built
			guard builders[name] != nil else {
				return
			}

			indexes[name] = built.index
			itemLists[name] = built.items

			// Only clear the stale mark when nothing changed since the build started
			if generations[name, default: 0] == generation {
				staleLists.remove(name)
			}
		}
	}
}
