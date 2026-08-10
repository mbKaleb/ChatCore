//
//  TabBarProbe.swift
//  ChatCore
//

#if DEBUG

import AppKit
import ObjectiveC.runtime

/// Prints the window frame's view tree with the tab bar up, then quits.
///
/// `-tabBarProbe` arms it. The dump is the ground truth for the tab-bar
/// styling work: which titlebar container hosts the tab bar, what its frames
/// are, and which view in that stack actually draws a background. Runs
/// headless from a terminal — the app introspects itself, no screen capture
/// involved.
@MainActor
enum TabBarProbe {

	static var isRequested: Bool {
		ProcessInfo.processInfo.arguments.contains("-tabBarProbe")
	}

	static func armIfRequested() {
		guard isRequested else { return }
		waitForWindow(attemptsLeft: 50)
	}

	private static func waitForWindow(attemptsLeft: Int) {
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
			guard let window = NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) }) else {
				if attemptsLeft > 0 {
					waitForWindow(attemptsLeft: attemptsLeft - 1)
				} else {
					emit("no visible window appeared; giving up")
					NSApp.terminate(nil)
				}
				return
			}
			if (window.tabGroup?.windows.count ?? 1) < 2 {
				// A bare second window rather than `newWindowForTab:`: the
				// action needs a responder chain that only exists once the
				// scene is fully up, and all this needs is a second tab to
				// make the *unselected* tab chrome appear.
				let extra = NSWindow(
					contentRect: window.frame,
					styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
					backing: .buffered,
					defer: false
				)
				extra.title = "Second Tab"
				window.addTabbedWindow(extra, ordered: .above)
				window.makeKeyAndOrderFront(nil)
			}
			// Give the sibling tab time to order in and the tab bar to lay out.
			DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
				let subject = NSApp.keyWindow ?? window
				dump(subject)
				NSApp.terminate(nil)
			}
		}
	}

	private static func dump(_ window: NSWindow) {
		emit("window: \(type(of: window)) frame=\(window.frame)")
		emit("styleMask.fullSizeContentView=\(window.styleMask.contains(.fullSizeContentView))")
		emit("titlebarAppearsTransparent=\(window.titlebarAppearsTransparent)")
		emit("titlebarSeparatorStyle=\(window.titlebarSeparatorStyle.rawValue)")
		emit("contentLayoutRect=\(window.contentLayoutRect)")
		emit("tabGroup windows=\(window.tabGroup?.windows.count ?? 0) tabBarVisible=\(window.tabGroup?.isTabBarVisible ?? false)")
		if let content = window.contentView {
			emit("contentView frame=\(content.frame) safeAreaInsets=\(content.safeAreaInsets)")
		}
		for (index, accessory) in window.titlebarAccessoryViewControllers.enumerated() {
			emit("accessory[\(index)]: \(type(of: accessory)) layout=\(accessory.layoutAttribute.rawValue) view=\(type(of: accessory.view)) frame=\(accessory.view.frame) hidden=\(accessory.isHidden)")
		}
		guard let frameView = window.contentView?.superview else {
			emit("no frame view")
			return
		}
		walk(frameView, depth: 0, window: window)
		inspectTabBarChrome(in: frameView)
	}

	/// The private classes between the accessory and the tab buttons, in
	/// detail.
	///
	/// The tree dump says *where* the chrome is; this says what it is made of —
	/// superclass chain, layer class, and which of the public appearance knobs
	/// the class actually answers to. That is the difference between "hide the
	/// backdrop" and "hide the view that also happens to contain every tab".
	private static func inspectTabBarChrome(in root: NSView) {
		guard let tabBar = firstView(in: root, matching: { NSStringFromClass(type(of: $0)) == "NSTabBar" }) else {
			emit("chrome: no NSTabBar found")
			return
		}
		emit("chrome: --- ancestry from NSTabBar up ---")
		var ancestor: NSView? = tabBar
		while let view = ancestor {
			describe(view, label: "  up")
			ancestor = view.superview
		}
		emit("chrome: --- glass-ish views under NSTabBar ---")
		forEachView(in: tabBar) { view in
			let name = NSStringFromClass(type(of: view))
			guard name.contains("Glass") || name.contains("Backdrop") || name.contains("Material")
				|| view is NSVisualEffectView else { return }
			describe(view, label: "  down")
		}
	}

	private static func describe(_ view: NSView, label: String) {
		var chain: [String] = []
		var cls: AnyClass? = type(of: view)
		while let current = cls {
			chain.append(NSStringFromClass(current))
			cls = class_getSuperclass(current)
		}
		emit("\(label) \(chain.joined(separator: " < ")) frame=\(view.frame) subviews=\(view.subviews.count)")
		if let layer = view.layer {
			emit("\(label)     layer=\(NSStringFromClass(type(of: layer))) sublayers=\(layer.sublayers?.count ?? 0) contents=\(layer.contents != nil) filters=\(layer.filters?.count ?? 0) bgFilters=\(layer.backgroundFilters?.count ?? 0)")
		}
		// The knobs worth trying before resorting to hiding anything.
		let probes = ["setHidden:", "setAlphaValue:", "setMaterial:", "setState:", "setStyle:",
					  "setTintColor:", "setBlendingMode:", "setCornerRadius:", "isEmphasized"]
		let answered = probes.filter { view.responds(to: NSSelectorFromString($0)) }
		emit("\(label)     responds=[\(answered.joined(separator: ", "))]")
	}

	private static func firstView(in root: NSView, matching predicate: (NSView) -> Bool) -> NSView? {
		if predicate(root) { return root }
		for sub in root.subviews {
			if let found = firstView(in: sub, matching: predicate) { return found }
		}
		return nil
	}

	private static func forEachView(in root: NSView, _ body: (NSView) -> Void) {
		body(root)
		for sub in root.subviews { forEachView(in: sub, body) }
	}

	private static func walk(_ view: NSView, depth: Int, window: NSWindow) {
		let indent = String(repeating: "  ", count: depth)
		var line = "\(indent)\(NSStringFromClass(type(of: view))) frame=\(view.frame)"
		if view.isHidden { line += " HIDDEN" }
		if view.alphaValue < 1 { line += " alpha=\(view.alphaValue)" }
		if let layer = view.layer {
			if let background = layer.backgroundColor, background.alpha > 0 {
				line += " layerBG=\(background)"
			}
			if layer.isOpaque { line += " layerOpaque" }
		}
		if view.isOpaque { line += " opaque" }
		if let effect = view as? NSVisualEffectView {
			line += " material=\(effect.material.rawValue) blending=\(effect.blendingMode.rawValue) state=\(effect.state.rawValue)"
		}
		emit(line)
		for sub in view.subviews {
			walk(sub, depth: depth + 1, window: window)
		}
	}

	private static func emit(_ message: String) {
		print("[TabBarProbe] \(message)")
	}
}

#endif
