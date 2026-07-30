//
//  ModelsPane.swift
//  ChatCore
//

import SwiftUI

/// One section per frontier vendor, each headed by the vendor and its switch.
///
/// The switch is the only thing that registers or unregisters a backend, so a
/// vendor that's off vends no models anywhere else in the app — the picker in
/// General and the chat's model menu both read the same list.
struct ModelsPane: View {

	@Environment(ModelManager.self) private var manager

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			settingsPaneTitle("Models")

			Form {
				ForEach(ModelVendor.allCases) { vendor in
					VendorSection(vendor: vendor)
				}
			}
			.formStyle(.grouped)
		}
	}
}

// MARK: - Vendor Section

private struct VendorSection: View {

	let vendor: ModelVendor

	@Environment(ModelManager.self) private var manager
	@AppStorage private var isEnabled: Bool

	init(vendor: ModelVendor) {
		self.vendor = vendor
		_isEnabled = AppStorage(wrappedValue: vendor.isEnabledByDefault, vendor.defaultsKey)
	}

	private var models: [GenerativeChatModel] {
		manager.models(from: vendor)
	}

	var body: some View {
		Section {
			if !vendor.isSupported {
				statusRow("Support for \(vendor.displayName) isn't available yet.", symbol: "clock")
			} else if !isEnabled {
				statusRow("Turn on \(vendor.toggleTitle.lowercased()) to use them in chats.", symbol: "power")
			} else if manager.isRefreshing && models.isEmpty {
				HStack(spacing: 6) {
					ProgressView().controlSize(.small)
					Text("Looking for models…")
						.foregroundStyle(.secondary)
				}
			} else if models.isEmpty {
				statusRow(
					vendor.needsAPIKey
						? "No models yet — add an API key in Accounts."
						: "No models are available on this Mac.",
					symbol: "exclamationmark.triangle"
				)
			} else {
				ForEach(models, id: \.id) { model in
					modelRow(model)
				}
			}
		} header: {
			HStack(spacing: 8) {
				ModelIconView(icon: vendor.icon)
				Text(vendor.displayName)
				Spacer(minLength: 12)
				Toggle(vendor.toggleTitle, isOn: toggleBinding)
					.toggleStyle(.switch)
					.controlSize(.small)
					.labelsHidden()
					.disabled(!vendor.isSupported)
					.help(vendor.toggleTitle)
			}
		} footer: {
			Text(vendor.residencyNote)
		}
	}

	/// Persistence happens through `setVendor`, not through the binding's own
	/// write — otherwise the value would land in defaults before the manager
	/// had a chance to register or drop the backend behind it.
	private var toggleBinding: Binding<Bool> {
		Binding(
			get: { isEnabled },
			set: { newValue in
				Task { await manager.setVendor(vendor, enabled: newValue) }
			}
		)
	}

	private func statusRow(_ text: String, symbol: String) -> some View {
		Label(text, systemImage: symbol)
			.foregroundStyle(.secondary)
			.font(.callout)
	}

	private func modelRow(_ model: GenerativeChatModel) -> some View {
		let caps = manager.capabilities(of: model)
		return LabeledContent {
			Text(caps.availabilityState == .available
				 ? model.dataResidency.display
				 : caps.availabilityState.display)
				.foregroundStyle(.secondary)
		} label: {
			HStack(spacing: 6) {
				ModelIconView(icon: model.icon)
				Text(model.displayName)
			}
		}
	}
}
