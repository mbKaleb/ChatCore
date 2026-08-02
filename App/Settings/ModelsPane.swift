//
//  ModelsPane.swift
//  ChatCore
//

import SwiftUI

/// One section per vendor, each headed by the vendor and its switch.
///
/// The switch is the only thing that registers or unregisters a backend, so a
/// vendor that's off vends no models anywhere else in the app — the picker in
/// General and the chat's model menu both read the same list.
///
/// Inside a vendor, every model has a switch of its own. That one doesn't reach
/// the backend — the model is still discovered, still probed, still named by a
/// chat already on it — it decides whether anything offers the model to pick.
/// The vendor is what says which models exist; this is what says which of them
/// you want to see, and a vendor's back catalog starts out unwanted.
///
/// Vendors are split by `ModelVendor.Tier`: the frontier ones lead, and the
/// rest sit behind a disclosure at the bottom. Twelve equal-weight sections
/// read as a wall — this way the pane opens on the five anyone actually picks.
struct ModelsPane: View {

	@Environment(ModelManager.self) private var manager

	@AppStorage(Defaults.Key.showsAdditionalVendors) private var showsAdditional = false

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			settingsPaneTitle("Models")

			Form {
				ForEach(ModelVendor.vendors(in: .frontier)) { vendor in
					VendorSection(vendor: vendor)
				}

				// The divider is a section with a real row in it, not a bare header.
				// A header-only section reads as the *next* section's header to the
				// grouped form, which renders the vendor below it as a continuation
				// row — greyed, and without the gap every other section gets.
				Section {
					HStack(spacing: 12) {
						Text("Other Providers")
							.font(.headline)
						Spacer(minLength: 12)
						Button(showsAdditional ? "Hide" : "Show") {
							withAnimation { showsAdditional.toggle() }
						}
						.controlSize(.small)
					}
					.modelsRow()
				} footer: {
					if !showsAdditional {
						Text("\(ModelVendor.vendors(in: .additional).count) more vendors the app can hold a key for.")
					}
				}

				if showsAdditional {
					ForEach(ModelVendor.vendors(in: .additional)) { vendor in
						VendorSection(vendor: vendor)
					}
				}
			}
			.formStyle(.grouped)
		}
	}
}

// MARK: - Row metrics

private enum ModelsPaneMetrics {

	/// The height every row in this pane clears, whatever it happens to carry.
	///
	/// A vendor section swaps its entire body between states — a status line when
	/// the vendor is off, a disclosure summary when it's on, a spinner while it's
	/// still asking — and each of those has a different natural height: callout
	/// text at 16, a row with a small button at 20. Left to size themselves, the
	/// section grows and shrinks under the switch as you flip it and every vendor
	/// below it jumps. This is the floor they all clear instead.
	///
	/// Every state is a plain row now, so clearing the same floor is the whole of
	/// it — there's no `DisclosureGroup` chrome around one of them to measure and
	/// pay back. Set below the 24 a row carrying a switch comes to naturally:
	/// those rows keep their own height, and none of them is a state a section
	/// swaps into.
	static let rowHeight: CGFloat = 21

	static let rowPadding: CGFloat = 2

	static let rowCorner: CGFloat = 8

	/// What a grouped `Form` insets a row from the left edge of its section's
	/// card, and doesn't from the right.
	///
	/// A row can't opt out of it — `listRowInsets` is ignored here, the row frame
	/// stays where the Form puts it — so a row left at full width sits 9pt inside
	/// the card on one side and overhangs its rounded corner on the other. Taking
	/// the same 9pt off the trailing edge is what centres it.
	static let rowCardInset: CGFloat = 9

	/// Breathing room between a row's edge and what the row says, so text lands
	/// inside a fill rather than against it. Carried by the content, which is
	/// what leaves the row's own bounds free to be the fill and the hit target.
	static let rowTextInset: CGFloat = 4
}

private extension View {

	/// Everything this pane decides about a row from the outside: how tall it is,
	/// how it's tinted, and — where the row opens something — what you have to
	/// hit to open it.
	///
	/// All three belong at the row's outermost level, which is why they arrive
	/// together rather than as three modifiers a row can apply half of. A hit
	/// shape set further in covers the label and leaves the space beside it dead,
	/// so a row reading "12 models" opens from the text and nowhere else. A tint
	/// set further in colours the label while the accessories beside it stay at
	/// full strength. The row is what the user is aiming at and what they read as
	/// one thing, so the row is what carries both.
	///
	/// Grouped `Form` rows otherwise size to their content, and these carry icons
	/// and switches taller than the plain text the default insets were picked
	/// for — without the frame they sit flush against the section's edges.
	@ViewBuilder
	func modelsRow(dimmed: Bool = false, opens: (() -> Void)? = nil) -> some View {
		// The insets belong on the content: the row's own bounds are then exactly
		// what a fill covers and what a click lands on, with nothing left over to
		// take off the shape afterwards.
		let row = frame(minHeight: ModelsPaneMetrics.rowHeight, alignment: .leading)
			.padding(.horizontal, ModelsPaneMetrics.rowTextInset)
			.padding(.vertical, ModelsPaneMetrics.rowPadding)
			.frame(maxWidth: .infinity, alignment: .leading)
			.foregroundStyle(dimmed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))

		if let opens {
			// Only where there's something to open — an unconditional gesture puts
			// a tap target over rows whose only control is a switch.
			row.modifier(OpenableModelsRow(opens: opens))
				.modelsCardInset()
		} else {
			row.modelsCardInset()
		}
	}

	/// The gutter that squares a row up with its section's card.
	///
	/// Outside everything the row draws, so it shortens the row itself rather
	/// than being subtracted back off a fill — and every row takes it, drawn or
	/// not, so a column of switches lines up whatever each row is doing.
	func modelsCardInset() -> some View {
		padding(.trailing, ModelsPaneMetrics.rowCardInset)
	}
}

/// A row that opens something, drawn as the control it is.
///
/// The gesture goes on the fill, and the fill is the whole row: rounded, tinted
/// on hover, sitting evenly inside its section's card. That's the point of it —
/// a listener without a shape of its own leaves the user guessing where the
/// clickable part of a row ends, and a hit rect that overhangs the card's
/// rounded corner is a click that lands outside anything they can see.
private struct OpenableModelsRow: ViewModifier {

	let opens: () -> Void

	@State private var isHovering = false

	func body(content: Content) -> some View {
		content
			.background(
				Color.primary.opacity(isHovering ? 0.07 : 0),
				in: .rect(cornerRadius: ModelsPaneMetrics.rowCorner, style: .continuous)
			)
			.contentShape(.rect(cornerRadius: ModelsPaneMetrics.rowCorner))
			.onHover { isHovering = $0 }
			.onTapGesture(perform: opens)
			.animation(.easeInOut(duration: 0.12), value: isHovering)
	}
}

// MARK: - Vendor Section

private struct VendorSection: View {

	let vendor: ModelVendor

	@Environment(ModelManager.self) private var manager
	@AppStorage private var isEnabled: Bool
	@AppStorage private var isExpanded: Bool
	@AppStorage private var showsOlder: Bool

	init(vendor: ModelVendor) {
		self.vendor = vendor
		_isEnabled = AppStorage(wrappedValue: vendor.isEnabledByDefault, vendor.defaultsKey)
		_isExpanded = AppStorage(wrappedValue: false, Defaults.Key.vendorExpanded(vendor))
		_showsOlder = AppStorage(wrappedValue: false, Defaults.Key.vendorOlderExpanded(vendor))
	}

	private var models: [GenerativeChatModel] {
		manager.models(from: vendor)
	}

	/// What the vendor ships now, and everything a newer version of the same
	/// family replaced. A catalog is a back catalog too — Anthropic serves a
	/// dozen Claudes, four of which anyone would pick today — so the open list
	/// leads with those four and keeps the rest one disclosure further in.
	private var currentModels: [GenerativeChatModel] {
		models.filter { !manager.supersededModelIDs.contains($0.id) }
	}

	/// Newest first: the version just retired is the one still worth finding.
	private var olderModels: [GenerativeChatModel] {
		models
			.filter { manager.supersededModelIDs.contains($0.id) }
			.sorted { lhs, rhs in
				guard let left = lhs.release, let right = rhs.release else { return false }
				return right < left
			}
	}

	private var unavailableCount: Int {
		models.count(where: { manager.capabilities(of: $0).availabilityState != .available })
	}

	private var offeredCount: Int {
		models.count(where: { manager.isEnabled($0) })
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
				.modelsRow()
			} else if let failure = manager.discoveryError(for: vendor) {
				// The rows are gone either way; only this tells the two apart.
				// Without it, a rate limit and an empty catalog look identical.
				HStack(spacing: 6) {
					Label(failure, systemImage: "exclamationmark.arrow.triangle.2.circlepath")
						.foregroundStyle(.secondary)
						.font(.callout)
					Spacer(minLength: 12)
					Button("Retry") {
						Task { await manager.refresh(reprobing: true) }
					}
					.controlSize(.small)
				}
				.modelsRow()
			} else if models.isEmpty {
				statusRow(
					vendor.needsAPIKey
						? "No models yet — add an API key in Accounts."
						: "No models are available on this Mac.",
					symbol: "exclamationmark.triangle"
				)
			} else {
				// Drawn rather than a `DisclosureGroup`, so the row that opens the
				// list is one view: chevron, text, fill and gesture together. The
				// group's chrome went around its label and left the chevron outside
				// whatever the label drew — a control with its own indicator sitting
				// beside it rather than in it. It also made the open state 8pt taller
				// than every other state, which had to be measured and paid back.
				summaryRow

				if isExpanded {
					ForEach(currentModels, id: \.id) { model in
						modelRow(model)
					}

					if !olderModels.isEmpty {
						olderSummaryRow

						if showsOlder {
							ForEach(olderModels, id: \.id) { model in
								modelRow(model)
							}
						}
					}
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
			.modelsRow()
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

	/// What the section says with the list closed.
	///
	/// The count is the only part of a vendor's catalog worth reading at a
	/// glance — except a model the backend won't serve, which is the one thing
	/// a user would otherwise have to open the group to find out about.
	///
	/// It counts what's switched on rather than what exists, because the two
	/// differ out of the box: a vendor's back catalog arrives switched off, and
	/// a flat "12 models" over a picker showing four reads as a bug.
	private var summaryRow: some View {
		HStack(spacing: 6) {
			disclosureChevron(isOpen: isExpanded)
			Text(offeredCount == models.count
				 ? (models.count == 1 ? "1 model" : "\(models.count) models")
				 : "\(offeredCount) of \(models.count) models")
			Spacer(minLength: 12)
			if unavailableCount > 0 {
				Text("\(unavailableCount) unavailable")
					.foregroundStyle(.secondary)
			}
		}
		// The triangle is a small target, and the row beside it reads as part of
		// the same control — so the whole row opens the list.
		.modelsRow {
			withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
		}
	}

	/// The nested group's label. The count carries its weight here — it's the
	/// difference between a vendor with one superseded version and one with nine.
	private var olderSummaryRow: some View {
		let offered = olderModels.count(where: { manager.isEnabled($0) })
		return HStack(spacing: 6) {
			disclosureChevron(isOpen: showsOlder)
			Text("Other Models")
			Spacer(minLength: 12)
			Text(offered == 0 ? "\(olderModels.count)" : "\(offered) of \(olderModels.count)")
				.foregroundStyle(.secondary)
				.monospacedDigit()
		}
		.modelsRow {
			withAnimation(.snappy(duration: 0.2)) { showsOlder.toggle() }
		}
	}

	/// The indicator a row that opens something carries. Fixed width so a row
	/// with one lines its text up with the rows under it, which have none.
	private func disclosureChevron(isOpen: Bool) -> some View {
		Image(systemName: "chevron.right")
			.font(.caption2)
			.foregroundStyle(.secondary)
			.rotationEffect(.degrees(isOpen ? 90 : 0))
			.frame(width: 10, alignment: .leading)
	}

	private func statusRow(_ text: String, symbol: String) -> some View {
		Label(text, systemImage: symbol)
			.font(.callout)
			.modelsRow(dimmed: true)
	}

	/// One model, and the switch that decides whether anything offers it.
	///
	/// The row stays here whichever way the switch is set — this is the one list
	/// that shows a vendor's whole catalog, so it's the only place a model that's
	/// switched off can be switched back on.
	private func modelRow(_ model: GenerativeChatModel) -> some View {
		let caps = manager.capabilities(of: model)
		let isOffered = manager.isEnabled(model)
		return LabeledContent {
			HStack(spacing: 10) {
				Text(caps.availabilityState == .available
					 ? model.dataResidency.display
					 : caps.availabilityState.display)
					.foregroundStyle(.secondary)

				Toggle("Offer \(model.displayName)", isOn: offeredBinding(model))
					.toggleStyle(.switch)
					.controlSize(.mini)
					.labelsHidden()
					.help("Offer \(model.displayName) in the model pickers")
			}
		} label: {
			HStack(spacing: 6) {
				ModelIconView(icon: model.icon)
				Text(model.displayName)
			}
		}
		// A switched-off model reads as one of the rows rather than one of the
		// choices — the same weight the pickers give an unpickable model. Set on
		// the row so the residency beside the name goes with it; set on the label
		// it would leave half the row reading as current.
		.modelsRow(dimmed: !isOffered)
	}

	/// The switch goes through the manager rather than straight to defaults, so
	/// the lists that read `isEnabled` are looking at observed state and update
	/// with the row instead of on the next discovery.
	private func offeredBinding(_ model: GenerativeChatModel) -> Binding<Bool> {
		Binding(
			get: { manager.isEnabled(model) },
			set: { manager.setModel(model, enabled: $0) }
		)
	}
}
