import SwiftUI

private extension View {
	/// Hides the intrinsic scroll/form background of a `TextEditor`.
	/// - iOS 16+: uses the native `scrollContentBackground(.hidden)` modifier.
	/// - iOS 15 and earlier: clears `UITextView.appearance().backgroundColor`
	///   for the duration this view is on screen, then restores it on disappear
	///   to minimise global side-effects.
	@ViewBuilder
	func clearTextEditorBackground() -> some View {
		if #available(iOS 16.0, *) {
			self.scrollContentBackground(.hidden)
		} else {
			self
				.onAppear  { UITextView.appearance().backgroundColor = .clear }
				.onDisappear { UITextView.appearance().backgroundColor = nil }
		}
	}
}

struct PresencePickerView: View {
	@ObservedObject var presenceVM = PresenceViewModel.shared
	@Environment(\.dismiss) private var dismiss
	@FocusState private var isNoteFieldFocused: Bool

	// The message as it is being typed. Kept apart from the view model's, which follows the shared status, so a
	// status arriving from elsewhere does not overwrite what is being typed. Published when a status is picked, on
	// Done, on clearing it and when the picker closes. Until it is edited it follows the view model's message, so
	// closing the picker never republishes a message that has since been replaced elsewhere.
	@State private var draftNote: String = ""
	// The view model's message the draft was last in step with
	@State private var baseNote: String = ""
	@State private var draftLoaded = false

	private let maxNoteLength = SharedStatus.maxNoteLength

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			Text("Status")
				.font(Font.custom("Poppins-SemiBold", size: 16))
				.foregroundStyle(Color.grayMain2c800)
				.padding(.horizontal, 16)
				.padding(.top, 16)
				.padding(.bottom, 8)

			ForEach(UserPresence.selectable, id: \.self) { presence in
				Button {
					presenceVM.setPresence(presence, note: draftNote)
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
					if draftNote.isEmpty {
						Text("What's your status?")
							.font(Font.custom("Poppins-Regular", size: 14))
							.foregroundStyle(Color.grayMain2c400)
							.padding(.horizontal, 21)
							.padding(.top, 10)
							.allowsHitTesting(false)
					}

					TextEditor(text: $draftNote)
						.font(Font.custom("Poppins-Regular", size: 14))
						.foregroundStyle(Color.grayMain2c700)
						.clearTextEditorBackground()
						.focused($isNoteFieldFocused)
						.frame(minHeight: 88)
						.onChange(of: draftNote) { newValue in
							// One line of at most maxNoteLength characters, counted as the server counts them
							let limited = SharedStatus.limitedNote(
								newValue.components(separatedBy: .newlines).joined(separator: " "))
							if limited != newValue {
								draftNote = limited
							}
						}
						// TextEditor has no onSubmit; dismiss on Return via toolbar
						.toolbar {
							ToolbarItemGroup(placement: .keyboard) {
								Spacer()
								Button("Done") {
									isNoteFieldFocused = false
									presenceVM.setPresence(presenceVM.currentPresence, note: draftNote)
									dismiss()
								}
							}
						}

					// Clear button in top-right corner
					if !draftNote.isEmpty {
						VStack {
							HStack {
								Spacer()
								Button {
									draftNote = ""
									baseNote = ""
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
				Text("\(draftNote.unicodeScalars.count)/\(maxNoteLength)")
					.font(Font.custom("Poppins-Regular", size: 11))
					.foregroundStyle(Color.grayMain2c400)
					.frame(maxWidth: .infinity, alignment: .trailing)
					.padding(.horizontal, 16)
			}

			Spacer(minLength: 16)
		}
		.frame(maxWidth: .infinity)
		.onAppear {
			if !draftLoaded {
				draftLoaded = true
				draftNote = presenceVM.customStatusNote
				baseNote = presenceVM.customStatusNote
			}
		}
		.onChange(of: presenceVM.customStatusNote) { newValue in
			// A message from elsewhere (the shared status) replaces the draft only if it has not been edited
			if draftNote == baseNote {
				draftNote = newValue
			}
			baseNote = newValue
		}
		.onDisappear {
			// Only a changed status or message is a new choice, see setPresence
			presenceVM.setPresence(presenceVM.currentPresence, note: draftNote)
		}
	}
}
