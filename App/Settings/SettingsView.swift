//
//  SettingsView.swift
//  ChatCore
//

import SwiftUI

struct SettingsView: View {

	private enum Pane: String, CaseIterable, Identifiable {
		case general = "General"
		case appearance = "Appearance"
		case accounts = "Accounts"

		var id: String { rawValue }

		var icon: String {
			switch self {
			case .general:    "gearshape"
			case .appearance: "paintpalette"
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
		.frame(minWidth: 960, maxWidth: .infinity, minHeight: 560, maxHeight: .infinity)
		.background(TitleBarHider())
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
		case .appearance: AppearancePane()
		case .accounts:   AccountsPane()
		}
	}
}

// MARK: - Pane title

@ViewBuilder
func settingsPaneTitle(_ title: String) -> some View {
	Text(title)
		.font(.title2.bold())
		.frame(maxWidth: .infinity, alignment: .leading)
		.padding(.horizontal, 20)
		.padding(.top, 12)
}

// MARK: - General

private struct GeneralPane: View {

	@Environment(ModelManager.self) private var manager
	@AppStorage(Defaults.Key.defaultModelID) private var defaultModelID = GenerativeChatModel.onDevice.id

	private var appleModels: [GenerativeChatModel] {
		manager.chatModels.filter { $0.dataResidency != .cloud }
	}

	private var otherModels: [GenerativeChatModel] {
		manager.chatModels.filter { $0.dataResidency == .cloud }
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
						ForEach(appleModels, content: modelRow)

						if !otherModels.isEmpty {
							Divider()
							ForEach(otherModels, content: modelRow)
						}
					}
				} header: {
					Text("Models")
				} footer: {
					Text("Dimmed models can't be picked — no key configured, or the backend reported them unavailable.")
				}
			}
			.formStyle(.grouped)
		}
	}
}

// MARK: - Accounts

private struct AccountsPane: View {

	@Environment(ModelManager.self) private var manager
	@State private var apiKey: String = ""
	@State private var isValidating = false
	@State private var validationError: String?
	@State private var hasStoredKey: Bool = !(KeychainStore.read(KeychainStore.anthropicAPIKeyRef) ?? "").isEmpty

	private var showSavedState: Bool {
		hasStoredKey && !isValidating && validationError == nil
	}

	var body: some View {
		let _ = Self.printChanges()
		VStack(alignment: .leading, spacing: 0) {
			settingsPaneTitle("Accounts")

			Form {
				Section {
					if showSavedState {
						LabeledContent("API Key") {
							HStack(spacing: 8) {
								Label("Saved to Keychain", systemImage: "checkmark.circle.fill")
									.foregroundStyle(.green)
								Button("Remove", role: .destructive, action: remove)
							}
						}
						.transition(.opacity.combined(with: .move(edge: .top)))
					} else {
						LabeledContent("API Key") {
							HStack(spacing: 8) {
								SecureField("API Key", text: $apiKey)
									.labelsHidden()
									.textFieldStyle(.roundedBorder)
									.onSubmit(save)

								Button("Save", action: save)
									.disabled(apiKey.isEmpty || isValidating)

								if hasStoredKey {
									Button("Remove", role: .destructive, action: remove)
								}
							}
						}
						.transition(.opacity.combined(with: .move(edge: .top)))

						if isValidating {
							HStack(spacing: 6) {
								ProgressView().controlSize(.small)
								Text("Validating…")
									.font(.caption)
									.foregroundStyle(.secondary)
							}
						} else if let validationError {
							Text(validationError)
								.font(.caption)
								.foregroundStyle(.red)
						}
					}
				} header: {
					Label("Anthropic", image: "AnthropicSymbol")
				} footer: {
					VStack(alignment: .leading, spacing: 4) {
						Text("Used for Claude models. Stored in the Keychain — never leaves this Mac.")
						Link("Get an API Key ↗", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
					}
				}
			}
			.formStyle(.grouped)
			.animation(.easeInOut(duration: 0.2), value: showSavedState)
		}
	}

	private func save() {
		let keyToVerify = apiKey
		guard KeychainStore.save(keyToVerify, for: KeychainStore.anthropicAPIKeyRef) else {
			validationError = "Couldn't save the key to the Keychain."
			return
		}
		apiKey = ""
		hasStoredKey = true
		validationError = nil
		isValidating = true
		Task {
			if !(await AnthropicAPIKeyValidator.verify(apiKey: keyToVerify)) {
				validationError = "Key looks invalid — check it was copied correctly."
			}
			await manager.refresh(reprobing: true)
			isValidating = false
		}
	}

	private func remove() {
		guard KeychainStore.delete(KeychainStore.anthropicAPIKeyRef) else {
			validationError = "Couldn't remove the key — try again."
			return
		}
		apiKey = ""
		hasStoredKey = false
		validationError = nil
		Task { await manager.refresh(reprobing: true) }
	}
}

// MARK: - Title Bar Hider

private struct TitleBarHider: NSViewRepresentable {

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
		window.styleMask.insert(.fullSizeContentView)
		window.titlebarSeparatorStyle = .none
	}
}
