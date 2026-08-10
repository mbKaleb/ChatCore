//
//  ChatCoreApp.swift
//  ChatCore
//
//  Created by Kaleb Franken on 6/15/26.
//

import SwiftUI
import SwiftData

@main
struct ChatCore: App {
	@State private var modelManager = ModelManager()
	@State private var themeManager = ThemeManager()

	init() {
		// Keep AutoFill from offering verification codes from Mail/Messages in
		// any text field. The trait lives on the shared field editor, so it has
		// to be reapplied each time editing begins.
		NotificationCenter.default.addObserver(
			forName: NSControl.textDidBeginEditingNotification, object: nil, queue: .main
		) { note in
			guard let editor = note.userInfo?["NSFieldEditor"] as? NSTextView else { return }
			editor.contentType = nil
			if #available(macOS 14.0, *) {
				editor.inlinePredictionType = .no
			}
			editor.isAutomaticTextCompletionEnabled = false
		}

		#if DEBUG
		TabBarProbe.armIfRequested()
		NewTabProbe.armIfRequested()
		ZoomProbe.armIfRequested()
		#endif
	}

	let sharedModelContainer: ModelContainer = {
		let schema = Schema([
			Conversation.self,
			Message.self,
		])

		#if DEBUG
		let seeding = DebugSeed.isRequested
		#else
		let seeding = false
		#endif
		let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: seeding)

		do {
			let container = try ModelContainer(for: schema, configurations: [modelConfiguration])
			#if DEBUG
			if seeding {
				MainActor.assumeIsolated { DebugSeed.populate(container.mainContext) }
			}
			#endif
			return container
		} catch {
			fatalError("Could not create ModelContainer: \(error)")
		}
	}()

	var body: some Scene {
		WindowGroup(id: "main") {
			AppView()
				.task {
					_ = Defaults.registered
					await modelManager.applyVendorSettings()
				}
		}
		.defaultSize(width: 1000, height: 700)
		.modelContainer(sharedModelContainer)
		.environment(modelManager)
		.environment(themeManager)
		.commands { ChatCommands(themes: themeManager) }

		Settings {
			SettingsView()
				.environment(modelManager)
				.environment(themeManager)
		}
		// A Settings scene defaults to `.contentSize`, which pins the window
		// to whatever the panes ask for. Only the minimum is binding here;
		// the ceiling is the screen.
		.windowResizability(.contentMinSize)
	}
}

private struct ChatCommands: Commands {
	let themes: ThemeManager

	@FocusedValue(\.newChat) private var newChat
	@FocusedValue(\.toggleSidebar) private var toggleSidebar
	@FocusedValue(\.findChat) private var findChat
	@FocusedValue(\.deleteConversations) private var deleteConversations
	@FocusedValue(\.refreshView) private var refreshView
	@Environment(\.openWindow) private var openWindow

	var body: some Commands {
		CommandGroup(after: .textEditing) {
			Button("Find Chat") { findChat?.perform() }
				.keyboardShortcut("f", modifiers: .command)
				.disabled(findChat == nil)
		}

		CommandGroup(replacing: .sidebar) {
			Button("Toggle Sidebar") { toggleSidebar?.perform() }
				.keyboardShortcut("b", modifiers: .command)
				.disabled(toggleSidebar == nil)
		}

		// Rebuilds the key window's two columns; a reply still streaming lands
		// in the transcript that replaces the one it started in. See
		// `AppView.refresh`.
		CommandGroup(after: .sidebar) {
			Divider()

			Button("Refresh") { refreshView?.perform() }
				.keyboardShortcut("r", modifiers: .command)
				.disabled(refreshView == nil)
		}

		// The same "Text size" the Appearance pane sets, stepped a point at a
		// time. `ThemeManager` clamps to `fontSizeRange`, so the buttons only
		// need to stop offering a step that would do nothing.
		CommandGroup(after: .toolbar) {
			Divider()

			Button("Increase Text Size") { themes.fontSize += 1 }
				.keyboardShortcut("+", modifiers: .command)
				.disabled(themes.fontSize >= ChatAppearance.fontSizeRange.upperBound)

			Button("Decrease Text Size") { themes.fontSize -= 1 }
				.keyboardShortcut("-", modifiers: .command)
				.disabled(themes.fontSize <= ChatAppearance.fontSizeRange.lowerBound)

			Button("Actual Size") { themes.fontSize = ChatAppearance.default.fontSize }
				.keyboardShortcut("0", modifiers: .command)
				.disabled(themes.fontSize == ChatAppearance.default.fontSize)
		}

		CommandGroup(replacing: .newItem) {
			Button("New Chat") { newChat?.perform() }
				.keyboardShortcut("n", modifiers: .command)
				.disabled(newChat == nil)

			// Three ways to get a surface, and they differ: ⌘N navigates the
			// current window, ⌘T opens a native window tab with a new chat in
			// it, ⌘⇧N opens an empty window that stays out of the tab group.
			// A tab is an `NSWindow` either way — what separates the last two is
			// `tabbingMode`, which `TabbingPolicy` sets.
			Button("New Tab") { NewTabIntent.open() }
				.keyboardShortcut("t", modifiers: .command)

			Button("New Window") { NewWindowIntent.open(openWindow) }
				.keyboardShortcut("n", modifiers: [.command, .shift])

			Divider()

			Button("Delete") { deleteConversations?.perform() }
				.keyboardShortcut(.delete, modifiers: .command)
				.disabled(deleteConversations?.isEnabled != true)
		}
	}
}
