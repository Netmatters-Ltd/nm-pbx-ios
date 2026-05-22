import SwiftUI

struct PresencePickerView: View {
	@ObservedObject var presenceVM = PresenceViewModel.shared
	@Environment(\.dismiss) private var dismiss
	@FocusState private var isNoteFieldFocused: Bool

	private let maxNoteLength = 80

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			Text("Status")
				.font(Font.custom("Poppins-SemiBold", size: 16))
				.foregroundStyle(Color.grayMain2c800)
				.padding(.horizontal, 16)
				.padding(.top, 16)
				.padding(.bottom, 8)

			ForEach(UserPresence.allCases.filter { $0 != .offline }, id: \.self) { presence in
				Button {
					presenceVM.setPresence(presence, note: presenceVM.customStatusNote)
					dismiss()
				} label: {
					HStack(spacing: 12) {
						Circle()
							.fill(presence.badgeColor)
							.overlay(Circle().stroke(Color.white, lineWidth: 1.5))
							.frame(width: 14, height: 14)

						Text(presence.label)
							.font(Font.custom("Poppins-Regular", size: 14))
							.foregroundStyle(Color.grayMain2c700)

						Spacer()

						if presenceVM.currentPresence == presence {
							Image(systemName: "checkmark")
								.font(.system(size: 13, weight: .semibold))
								.foregroundStyle(Color.orangeMain500)
						}
					}
					.padding(.horizontal, 16)
					.padding(.vertical, 14)
				}
				.buttonStyle(.plain)
			}

			Divider()
				.padding(.horizontal, 16)
				.padding(.vertical, 8)

			VStack(alignment: .leading, spacing: 8) {
				Text("Custom status message")
					.font(Font.custom("Poppins-Regular", size: 12))
					.foregroundStyle(Color.grayMain2c500)
					.padding(.horizontal, 16)

				ZStack(alignment: .topLeading) {
					// Placeholder text
					if presenceVM.customStatusNote.isEmpty {
						Text("What's your status?")
							.font(Font.custom("Poppins-Regular", size: 14))
							.foregroundStyle(Color.grayMain2c400)
							.padding(.horizontal, 21)
							.padding(.top, 10)
							.allowsHitTesting(false)
					}

					TextEditor(text: $presenceVM.customStatusNote)
						.font(Font.custom("Poppins-Regular", size: 14))
						.foregroundStyle(Color.grayMain2c700)
						.scrollContentBackground(.hidden)
						.focused($isNoteFieldFocused)
						.frame(minHeight: 88)
						.onChange(of: presenceVM.customStatusNote) { newValue in
							if newValue.count > maxNoteLength {
								presenceVM.customStatusNote = String(newValue.prefix(maxNoteLength))
							}
						}
						// TextEditor has no onSubmit; dismiss on Return via toolbar
						.toolbar {
							ToolbarItemGroup(placement: .keyboard) {
								Spacer()
								Button("Done") {
									isNoteFieldFocused = false
									presenceVM.setPresence(presenceVM.currentPresence, note: presenceVM.customStatusNote)
									dismiss()
								}
							}
						}

					// Clear button in top-right corner
					if !presenceVM.customStatusNote.isEmpty {
						VStack {
							HStack {
								Spacer()
								Button {
									presenceVM.customStatusNote = ""
									presenceVM.setPresence(presenceVM.currentPresence, note: "")
								} label: {
									Image(systemName: "xmark.circle.fill")
										.foregroundStyle(Color.grayMain2c400)
								}
								.buttonStyle(.plain)
								.padding(8)
							}
							Spacer()
						}
					}
				}
				.background(Color.grayMain2c100)
				.clipShape(RoundedRectangle(cornerRadius: 8))
				.padding(.horizontal, 16)

				// Character count
				Text("\(presenceVM.customStatusNote.count)/\(maxNoteLength)")
					.font(Font.custom("Poppins-Regular", size: 11))
					.foregroundStyle(Color.grayMain2c400)
					.frame(maxWidth: .infinity, alignment: .trailing)
					.padding(.horizontal, 16)
			}

			Spacer(minLength: 16)
		}
		.frame(maxWidth: .infinity)
		.onDisappear {
			presenceVM.setPresence(presenceVM.currentPresence, note: presenceVM.customStatusNote)
		}
	}
}
