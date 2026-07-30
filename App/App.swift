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
		.commands { ChatCommands() }

		Settings {
			SettingsView()
				.environment(modelManager)
				.environment(themeManager)
		.environment(themeManager)
		}
	}
}

private struct ChatCommands: Commands {
	@FocusedValue(\.newChat) private var newChat
	@FocusedValue(\.toggleSidebar) private var toggleSidebar
	@FocusedValue(\.findChat) private var findChat
	@FocusedValue(\.deleteConversations) private var deleteConversations
	@Environment(\.openWindow) private var openWindow

	var body: some Commands {
		CommandGroup(after: .textEditing) {
			Button("Find Chat") { findChat?() }
				.keyboardShortcut("f", modifiers: .command)
				.disabled(findChat == nil)
		}

		CommandGroup(replacing: .sidebar) {
			Button("Toggle Sidebar") { toggleSidebar?() }
				.keyboardShortcut("b", modifiers: .command)
				.disabled(toggleSidebar == nil)
		}

		CommandGroup(replacing: .newItem) {
			Button("New Chat") { newChat?() }
				.keyboardShortcut("n", modifiers: .command)
				.disabled(newChat == nil)

			Button("New Window") { openWindow(id: "main") }
				.keyboardShortcut("n", modifiers: [.command, .shift])

			Divider()

			Button("Delete") { deleteConversations?.perform() }
				.keyboardShortcut(.delete, modifiers: .command)
				.disabled(deleteConversations?.isEnabled != true)
		}
	}
}
