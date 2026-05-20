/*
 * Copyright (c) 2010-2024 Belledonne Communications SARL.
 * Copyright (c) 2024-2026 Netmatters Ltd.
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

struct AboutFragment: View {

	@Environment(\.dismiss) var dismiss

	private let sourceCodeURL = "https://github.com/Netmatters-Ltd/nm-pbx-ios"

	private var licenseText: String {
		guard let url = Bundle.main.url(forResource: "LICENSE", withExtension: "txt"),
			  let text = try? String(contentsOf: url, encoding: .utf8) else {
			return NSLocalizedString("about_license_unavailable", comment: "")
		}
		return text
	}

	var body: some View {
		ZStack {
			VStack(spacing: 1) {
				Rectangle()
					.foregroundColor(Color.orangeMain500)
					.edgesIgnoringSafeArea(.top)
					.frame(height: 0)

				HStack {
					Image("caret-left")
						.renderingMode(.template)
						.resizable()
						.foregroundStyle(Color.orangeMain500)
						.frame(width: 25, height: 25, alignment: .leading)
						.padding(.all, 10)
						.padding(.top, 4)
						.padding(.leading, -10)
						.onTapGesture {
							dismiss()
						}

					Text("settings_about_title")
						.default_text_style_orange_800(styleSize: 16)
						.frame(maxWidth: .infinity, alignment: .leading)
						.padding(.top, 4)
						.lineLimit(1)

					Spacer()
				}
				.frame(maxWidth: .infinity)
				.frame(height: 50)
				.padding(.horizontal)
				.padding(.bottom, 4)
				.background(.white)

				ScrollView {
					VStack(spacing: 0) {
						VStack(alignment: .leading, spacing: 20) {

							// MARK: – Copyright notices

							Text("settings_about_copyright_heading")
								.default_text_style_800(styleSize: 16)
								.frame(maxWidth: .infinity, alignment: .leading)

							VStack(alignment: .leading, spacing: 3) {
								Text("settings_about_copyright_original_title")
									.default_text_style_700(styleSize: 14)
								Text("settings_about_copyright_original_detail")
									.default_text_style(styleSize: 14)
									.foregroundColor(Color.grayMain2c500)
							}

							VStack(alignment: .leading, spacing: 3) {
								Text("settings_about_copyright_netmatters_title")
									.default_text_style_700(styleSize: 14)
								Text("settings_about_copyright_netmatters_detail")
									.default_text_style(styleSize: 14)
									.foregroundColor(Color.grayMain2c500)
							}

							// MARK: – Source code link

							Button {
								if let url = URL(string: sourceCodeURL) {
									UIApplication.shared.open(url)
								}
							} label: {
								HStack {
									Image("open-source")
										.renderingMode(.template)
										.resizable()
										.foregroundStyle(Color.orangeMain500)
										.frame(width: 30, height: 30)

									VStack(alignment: .leading, spacing: 2) {
										Text("settings_about_source_title")
											.default_text_style_700(styleSize: 14)
											.frame(maxWidth: .infinity, alignment: .leading)
										Text("settings_about_source_subtitle")
											.default_text_style(styleSize: 14)
											.foregroundColor(Color.grayMain2c500)
											.frame(maxWidth: .infinity, alignment: .leading)
									}
									.padding(.horizontal, 5)

									Image("arrow-square-out")
										.renderingMode(.template)
										.resizable()
										.foregroundStyle(Color.grayMain2c600)
										.frame(width: 25, height: 25)
								}
							}
						}
						.padding(.all, 20)
						.frame(maxWidth: .infinity)
						.background(.white)
						.cornerRadius(15)
						.padding(.horizontal, 16)
						.padding(.top, 16)

						// MARK: – Licence

						Text("settings_about_license_heading")
							.default_text_style_800(styleSize: 16)
							.frame(maxWidth: .infinity, alignment: .leading)
							.padding(.horizontal, 20)
							.padding(.top, 24)
							.padding(.bottom, 10)

						ScrollView {
							Text(licenseText)
								.font(.system(size: 11, design: .monospaced))
								.frame(maxWidth: .infinity, alignment: .leading)
								.padding(12)
						}
						.frame(height: 340)
						.background(.white)
						.cornerRadius(15)
						.padding(.horizontal, 16)
						.padding(.bottom, 24)
					}
					.frame(maxWidth: SharedMainViewModel.shared.maxWidth)
				}
				.frame(maxWidth: .infinity)
				.background(Color.gray100)
			}
			.background(Color.gray100)
		}
		.navigationTitle("")
		.navigationBarHidden(true)
	}
}
