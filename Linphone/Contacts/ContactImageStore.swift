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
import CryptoKit

/// Keeps the photos of contacts as files in the Documents folder, named after a hash of the photo itself
/// (`<hash>.png`), so a photo has one file whoever has it and a changed photo has a new one.
///
/// A photo comes from a vCard as a data URI, which can be hundreds of kilobytes. The store is given the photo of a
/// friend as it is, and does the rest on a slow queue: it hashes the string, writes the file if there is not one, and
/// calls back with the path. It does not keep the string. It keeps a list of the photos it knows to be on disk, which
/// is only held in memory and fills as photos are asked for.
///
/// Can be used from any thread.
final class ContactImageStore {

	static let shared = ContactImageStore()

	// Everything happens on this queue, one photo at a time, so the same photo is never written twice at once
	private let queue = DispatchQueue(label: "org.linphone.ContactImageStore", qos: .utility)

	// The path of the photos known to be on disk, by hash, in the form the photo of a model has: "file:/<hash>.png".
	// Only used on the queue.
	private var paths: [String: String] = [:]

	private init() {}

	/// Calls `completion` with the path to show for the photo of a friend. An empty photo has no path, so it gives
	/// an empty string, and a file path is given back as it is. A data URI is written to a file named after its
	/// hash, unless that file is there already, and gives nil if it could not be written.
	func path(for photo: String, completion: @escaping (String?) -> Void) {
		if photo.isEmpty || !photo.hasPrefix("data:") {
			completion(photo)
			return
		}

		queue.async {
			// A hash of the photo that is the same on every launch, unlike Swift's Hasher, as it names a file
			let hash = SHA256.hash(data: Data(photo.utf8)).map { String(format: "%02x", $0) }.joined()

			if let path = self.paths[hash] {
				completion(path)
				return
			}

			let path = ContactImageStore.makeFileIfNeeded(hash: hash) {
				// The data URI is "data:image/jpeg;base64,<data>", only the data is wanted
				let base64 = photo.range(of: "base64,").map { String(photo[$0.upperBound...]) } ?? photo
				return Data(base64Encoded: base64, options: .ignoreUnknownCharacters)
			}
			if let path = path {
				self.paths[hash] = path
			}
			completion(path)
		}
	}

	/// Calls `completion` with the path of a file holding the image data, for a picture chosen in the app. The file is
	/// named after the hash of the data, so choosing the same picture again gives the same file. Gives nil if the file
	/// could not be written.
	func path(for data: Data, completion: @escaping (String?) -> Void) {
		queue.async {
			let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

			if let path = self.paths[hash] {
				completion(path)
				return
			}

			let path = ContactImageStore.makeFileIfNeeded(hash: hash) { data }
			if let path = path {
				self.paths[hash] = path
			}
			completion(path)
		}
	}

	// Writes the file for the photo unless it is there already, and returns its path. The data is only asked for if
	// the file has to be written.
	private static func makeFileIfNeeded(hash: String, data: () -> Data?) -> String? {
		guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
			return nil
		}

		let fileName = hash + ".png"
		let fileURL = directory.appendingPathComponent(fileName)

		if !FileManager.default.fileExists(atPath: fileURL.path) {
			guard let data = data() else {
				print("[ContactImageStore] Failed to decode the photo with hash \(hash)")
				return nil
			}

			do {
				try data.write(to: fileURL, options: .atomic)
			} catch {
				print("[ContactImageStore] Failed to write the photo with hash \(hash): \(error)")
				return nil
			}
		}

		return "file:/" + fileName
	}
}
