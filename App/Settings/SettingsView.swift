//
//  SettingsView.swift
//  ChatCore
//

import SwiftUI

struct SettingsView: View {

	private enum Pane: String, CaseIterable, Identifiable {
		case general = "General"
		case models = "Models"
		case appearance = "Appearance"
		case rendering = "Rendering"
		case accounts = "Accounts"

		var id: String { rawValue }

		var icon: String {
			switch self {
			case .general:    "gearshape"
			case .models:     "cpu"
			case .appearance: "paintpalette"
			case .rendering:  "square.text.square"
			case .accounts:   "person.crop.circle"
			}
		}
	}

	@State private var selection: Pane = .general

	var body: some View {
		let _ = Self.printChanges()
		HStack(spacing: 0) {
			sidebar
			paneContent
				.frame(maxWidth: .infinity, maxHeight: .infinity)
		}
		// A floor, not a shape. The window opens at the ideal size and the user
		// takes it anywhere from the minimum to the whole screen; the panes are
		// scrolling forms, so both directions are theirs to spend.
		.frame(
			minWidth: 620, idealWidth: 980, maxWidth: .infinity,
			minHeight: 400, idealHeight: 680, maxHeight: .infinity
		)
		.background(SettingsWindowConfigurator())
		.background { CloseShortcuts() }
	}

	// MARK: - Sidebar

	private var sidebar: some View {
		VStack(alignment: .leading, spacing: 2) {
			ForEach(Pane.allCases) { pane in
				sidebarRow(pane)
			}
			Spacer(minLength: 0)
		}
		.padding(.horizontal, 8)
		.padding(.bottom, 8)
		.padding(.top, 4)
		.frame(width: 170)
		.frame(maxHeight: .infinity, alignment: .top)
		.background(.thinMaterial)
	}

	private func sidebarRow(_ pane: Pane) -> some View {
		let selected = selection == pane
		return Button {
			selection = pane
		} label: {
			HStack(spacing: 8) {
				ZStack {
					Image(systemName: pane.icon)
						.symbolVariant(selected ? .fill : .none)
						.id(selected)
						.transition(.blurReplace)
				}
				.font(.system(size: 12, weight: .medium))
				.foregroundStyle(selected ? .white : .secondary)
				.frame(width: 22, height: 22)
				.background(selected ? Color.accentColor : Color.secondary.opacity(0.15))
				.clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

				Text(pane.rawValue)
					.font(.system(size: 13))
					.foregroundStyle(.primary)

				Spacer(minLength: 0)
			}
			.padding(.horizontal, 8)
			.padding(.vertical, 5)
			.background(selected ? Color.accentColor.opacity(0.15) : .clear)
			.clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
			.contentShape(Rectangle())
			.animation(.easeInOut(duration: 0.25), value: selected)
		}
		.buttonStyle(.plain)
	}

	// MARK: - Body

	@ViewBuilder
	private var paneContent: some View {
		switch selection {
		case .general:    GeneralPane()
		case .models:     ModelsPane()
		case .appearance: AppearancePane()
		case .rendering:  RenderingPane()
		case .accounts:   AccountsPane()
		}
	}
}

/// ⌘W and Esc close the settings window. Esc has no menu item at all, and
/// claiming ⌘W here keeps the window closable whatever the File menu's Close
/// is doing; shortcuts in the key window's hierarchy are consulted before
/// menu key equivalents. Same hidden-twin shape as `TextSizeShortcuts` in
/// `AppView`.
private struct CloseShortcuts: View {

	var body: some View {
		ZStack {
			Button("Close") { NSApp.keyWindow?.performClose(nil) }
				.keyboardShortcut("w", modifiers: .command)

			Button("Close") { NSApp.keyWindow?.performClose(nil) }
				.keyboardShortcut(.cancelAction)
		}
		.opacity(0)
		.accessibilityHidden(true)
	}
}

// MARK: - Pane chrome

@ViewBuilder
func settingsPaneTitle(_ title: String) -> some View {
	Text(title)
		.font(.title2.bold())
		.frame(maxWidth: .infinity, alignment: .leading)
		.padding(.horizontal, 20)
		.padding(.top, 12)
}

/// A section's name, and one line under it saying what the section covers.
/// Shared, so two panes can't drift into differently shaped headers.
@ViewBuilder
func settingsSectionHeader(_ title: String, _ subtitle: String) -> some View {
	VStack(alignment: .leading, spacing: 2) {
		Text(title)
		Text(subtitle)
			.font(.caption)
			.foregroundStyle(.secondary)
			.fixedSize(horizontal: false, vertical: true)
	}
}

/// Footer prose. The `fixedSize` is the whole point: a footer left to itself
/// truncates to one line rather than wrapping.
@ViewBuilder
func settingsFooterText(_ text: String) -> some View {
	Text(text)
		.fixedSize(horizontal: false, vertical: true)
}

// MARK: - General

private struct GeneralPane: View {

	@Environment(ModelManager.self) private var manager
	@AppStorage(Defaults.Key.defaultModelID) private var defaultModelID = GenerativeChatModel.onDevice.id

	private var appleModels: [GenerativeChatModel] {
		manager.enabledChatModels.filter { $0.dataResidency != .cloud }
	}

	private var cloudModels: [GenerativeChatModel] {
		manager.enabledChatModels.filter { $0.dataResidency == .cloud }
	}

	/// Cloud models a newer version of the same family has replaced.
	///
	/// A vendor keeps serving its back catalog, so the list arrives with every
	/// Opus and Sonnet ever shipped in it — most of a menu nobody scrolls past
	/// the top of. The ones switched on in Models stay pickable, just not in the
	/// way of what's current.
	///
	/// Read from the manager rather than derived here: this list has already been
	/// filtered, and supersession asked of a filtered list answers about that
	/// list. With the current Opus switched off, the newest one still *here* is
	/// last year's, and deriving it locally would file it under what's current.
	private var supersededIDs: Set<GenerativeChatModel.ID> {
		manager.supersededModelIDs
	}

	private var currentModels: [GenerativeChatModel] {
		cloudModels.filter { !supersededIDs.contains($0.id) }
	}

	/// Newest first — the last version of a family a user was on is the one they
	/// are most likely to be coming back for.
	private var olderModels: [GenerativeChatModel] {
		let superseded = supersededIDs
		return cloudModels
			.filter { superseded.contains($0.id) }
			.sorted { lhs, rhs in
				guard let left = lhs.release, let right = rhs.release else { return false }
				return right < left
			}
	}

	/// The picker trades in whole model descriptors — the same values the
	/// backends vend — so a row can't drift from what the manager knows.
	/// Persistence stays an id; the binding is the only place they meet.
	private var selectedModel: Binding<GenerativeChatModel?> {
		Binding(
			get: { manager.model(withID: defaultModelID) },
			set: { model in
				guard let model else { return }
				defaultModelID = model.id
			}
		)
	}

	private func isSelectable(_ model: GenerativeChatModel) -> Bool {
		manager.capabilities(of: model).availabilityState == .available
	}

	/// Whether the stored default names a model the catalog no longer has.
	///
	/// The stored id outlives the catalog — a key removed, a fetch that failed,
	/// a model the vendor retired — and a selection matching no row leaves the
	/// picker showing nothing at all, which reads as "no default" rather than
	/// "your default is gone". The row below is what it selects instead.
	private var defaultIsMissing: Bool {
		manager.model(withID: defaultModelID) == nil
	}

	/// Whether the default names a model the catalog still has but the Models
	/// pane isn't offering. It resolves, so it isn't missing — it's just not on
	/// the list any more, which leaves the picker showing nothing just the same.
	private var defaultIsOff: Bool {
		guard let model = manager.model(withID: defaultModelID) else { return false }
		return !manager.isEnabled(model)
	}

	@ViewBuilder
	private var missingDefaultRow: some View {
		HStack(spacing: 6) {
			ModelIconView(icon: .symbol("exclamationmark.triangle"))
			if let model = manager.model(withID: defaultModelID) {
				Text("\(model.displayName) — switched off")
			} else {
				Text("\(ModelManagerError.readable(defaultModelID)) — unavailable")
			}
		}
		.foregroundStyle(.secondary)
		.tag(GenerativeChatModel?.none)
	}

	@ViewBuilder
	private func modelRow(_ model: GenerativeChatModel) -> some View {
		let selectable = isSelectable(model)
		HStack(spacing: 6) {
			ModelIconView(icon: model.icon)
			Text(model.displayName)
		}
		.foregroundStyle(selectable ? .primary : .secondary)
		.tag(GenerativeChatModel?.some(model))
		.disabled(!selectable)
	}

	var body: some View {
		let _ = Self.printChanges()
		VStack(alignment: .leading, spacing: 0) {
			settingsPaneTitle("General")

			Form {
				Section {
					Picker("Default model for new chats", selection: selectedModel) {
						if defaultIsMissing || defaultIsOff {
							missingDefaultRow
							Divider()
						}

						ForEach(appleModels, content: modelRow)

						if !currentModels.isEmpty {
							Divider()
							ForEach(currentModels, content: modelRow)
						}

						// A section rather than another divider: the rows below it
						// are a different kind of choice, not just further down the
						// same list, and the header is what says so.
						if !olderModels.isEmpty {
							Section("Other Models") {
								ForEach(olderModels, content: modelRow)
							}
						}
					}
				} header: {
					Text("Models")
				} footer: {
					if defaultIsOff {
						Text("The saved default is switched off in Models, so it isn't on this list. Turn it back on there, or pick another model.")
					} else if defaultIsMissing {
						Text("The saved default isn't in the catalog right now, so new chats can't start with it. Pick another model.")
					} else {
						Text("Only models switched on in Models appear here. Dimmed ones can't be picked — no key configured, or the backend reported them unavailable.")
					}
				}
			}
			.formStyle(.grouped)
		}
	}
}

// MARK: - Accounts

/// One section per vendor that needs a key, in the order the Models pane lists
/// them. Both panes are the same vendor list seen from opposite ends, so
/// neither gets to keep its own — a vendor added to `ModelVendor` shows up here
/// with a field the moment it says it needs one.
private struct AccountsPane: View {

	private let vendors = ModelVendor.allCases.filter(\.needsAPIKey)

	var body: some View {
		let _ = Self.printChanges()
		VStack(alignment: .leading, spacing: 0) {
			settingsPaneTitle("Accounts")

			Form {
				ForEach(vendors) { vendor in
					VendorAccountSection(vendor: vendor)
				}
			}
			.formStyle(.grouped)
		}
	}
}

/// One vendor's key field, and whatever the vendor said about the key.
private struct VendorAccountSection: View {

	let vendor: ModelVendor

	/// A line under the field. Errors send the user back to the field; the rest
	/// are caveats on a key that is stored and probably fine.
	private struct Note: Equatable {
		var text: String
		var isError: Bool
	}

	@Environment(ModelManager.self) private var manager

	@State private var apiKey = ""
	@State private var isVerifying = false
	@State private var note: Note?
	@State private var hasStoredKey: Bool

	init(vendor: ModelVendor) {
		self.vendor = vendor
		_hasStoredKey = State(initialValue: !(KeychainStore.read(vendor.keychainRef) ?? "").isEmpty)
	}

	/// The field and the saved row share one slot. A key is in the Keychain the
	/// moment Save succeeds, so verification only decides what the row *says* —
	/// except for an outright rejection, which puts the field back to be retyped.
	private var showsField: Bool {
		!hasStoredKey || note?.isError == true
	}

	private var trimmedKey: String {
		apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	var body: some View {
		Section {
			Group {
				if showsField {
					keyField
				} else {
					savedRow
				}

				if let note {
					Label(note.text, systemImage: note.isError ? "exclamationmark.triangle" : "info.circle")
						.font(.caption)
						.foregroundStyle(note.isError ? Color.red : Color.secondary)
				}
			}
			.animation(.easeInOut(duration: 0.2), value: showsField)
		} header: {
			HStack(spacing: 8) {
				ModelIconView(icon: vendor.icon)
				Text(vendor.displayName)
			}
		} footer: {
			VStack(alignment: .leading, spacing: 4) {
				Text(footerText)
				if let console = vendor.apiKeyConsole {
					Link("Get an API Key ↗", destination: console)
				}
			}
		}
	}

	private var keyField: some View {
		LabeledContent("API Key") {
			HStack(spacing: 8) {
				SecureField(vendor.keyPlaceholder, text: $apiKey)
					.labelsHidden()
					.textFieldStyle(.roundedBorder)
					.onSubmit(save)

				Button("Save", action: save)
					.disabled(trimmedKey.isEmpty || isVerifying)

				if hasStoredKey {
					Button("Remove", role: .destructive, action: remove)
				}
			}
		}
		.transition(.opacity.combined(with: .move(edge: .top)))
	}

	private var savedRow: some View {
		LabeledContent("API Key") {
			HStack(spacing: 8) {
				if isVerifying {
					ProgressView().controlSize(.small)
					Text("Checking with \(vendor.displayName)…")
						.foregroundStyle(.secondary)
				} else {
					Label("Saved to Keychain", systemImage: "checkmark.circle.fill")
						.foregroundStyle(.green)
				}

				Button("Remove", role: .destructive, action: remove)
					.disabled(isVerifying)
			}
		}
		.transition(.opacity.combined(with: .move(edge: .top)))
	}

	/// A key for a vendor the app can't talk to yet is still worth taking — it
	/// verifies against the vendor now, and there's nothing to redo later.
	private var footerText: String {
		var text = "\(vendor.keyPurpose) Stored in the Keychain — never leaves this Mac."
		if !vendor.isSupported {
			text += " ChatCore has no wire to \(vendor.displayName) yet; the key waits here until it does."
		}
		return text
	}

	// MARK: - Actions

	private func save() {
		let keyToVerify = trimmedKey
		guard !keyToVerify.isEmpty else { return }

		guard KeychainStore.save(keyToVerify, for: vendor.keychainRef) else {
			note = Note(text: "Couldn't save the key to the Keychain.", isError: true)
			return
		}

		apiKey = ""
		hasStoredKey = true
		note = nil
		isVerifying = true

		Task {
			note = message(for: await APIKeyValidator.verify(keyToVerify, for: vendor))
			await manager.refresh(reprobing: true)
			isVerifying = false
		}
	}

	private func remove() {
		guard KeychainStore.delete(vendor.keychainRef) else {
			note = Note(text: "Couldn't remove the key — try again.", isError: true)
			return
		}
		apiKey = ""
		hasStoredKey = false
		note = nil
		Task { await manager.refresh(reprobing: true) }
	}

	/// A rejection is the only verdict worth taking the key back for. The key
	/// stays in the Keychain either way — a vendor we couldn't reach has said
	/// nothing about it, and deleting on silence loses a working key.
	private func message(for verdict: APIKeyVerdict) -> Note? {
		switch verdict {
		case .valid:
			return nil
		case .rejected:
			return Note(
				text: "\(vendor.displayName) rejected this key — check it was copied in full.",
				isError: true
			)
		case .forbidden(let message):
			// The key is fine; the account isn't cleared for this. Only the
			// vendor knows why, so its sentence is the note — retyping advice
			// here would just be wrong.
			return Note(
				text: message.map { "\(vendor.displayName): \($0)" }
					?? "\(vendor.displayName) accepted this key but won't serve this account yet.",
				isError: true
			)
		case .unreachable:
			return Note(
				text: "Couldn't reach \(vendor.displayName) to check this key. It's saved anyway.",
				isError: false
			)
		case .unchecked:
			return Note(text: "Saved, but not verified with \(vendor.displayName).", isError: false)
		}
	}
}

// MARK: - Window

/// The Settings scene vends a window that behaves like a panel: fixed to its
/// content, no zoom, no full screen. This makes it an ordinary window — same
/// title bar treatment as before, but resizable by the grip, the zoom button
/// and the full-screen tile like any other.
private struct SettingsWindowConfigurator: NSViewRepresentable {

	func makeNSView(context: Context) -> NSView {
		let view = NSView()
		DispatchQueue.main.async {
			configure(view.window)
		}
		return view
	}

	func updateNSView(_ nsView: NSView, context: Context) {
		DispatchQueue.main.async {
			configure(nsView.window)
		}
	}

	private func configure(_ window: NSWindow?) {
		guard let window else { return }
		window.titlebarAppearsTransparent = true
		window.titleVisibility = .hidden
		window.styleMask.formUnion([.fullSizeContentView, .resizable])
		window.titlebarSeparatorStyle = .none

		// The green button wants both: `.resizable` above for zoom, and no
		// opt-out here for the full-screen tile.
		window.collectionBehavior.remove(.fullScreenNone)
		window.collectionBehavior.insert(.fullScreenPrimary)

		// AppKit's own no-limit value. SwiftUI should arrive at the same thing
		// from the scene's resizability, but a panel that kept a maximum would
		// stop the drag short of the screen edge with nothing on screen to say
		// why — so the ceiling is lifted here regardless.
		window.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
								height: CGFloat.greatestFiniteMagnitude)
	}
}
