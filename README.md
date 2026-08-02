# ChatCore

A native macOS chat client that talks to many families of language models —
Apple's on-device and Private Cloud models, and Anthropic's Claude — through
one interface.

The point of the project is the seam: the UI never knows which engine answered.
It asks `ModelManager` for a reply and gets a stream of text back. Adding a new
provider means writing one `ChatBackend` conformance, not touching the app.

---

## Contents

- [What it does](#what-it-does)
- [Requirements](#requirements)
- [Getting started](#getting-started)
- [Configuring Claude](#configuring-claude)
- [Architecture](#architecture)
- [Project layout](#project-layout)
- [Dependencies](#dependencies)
- [Debugging](#debugging)
- [Documentation](#documentation)

---

## What it does

**Multi-backend chat.** One conversation list, a model badge per chat, and a
picker that offers *placements* — On Device, Private Cloud, Claude Sonnet,
Claude Opus. The model is switchable mid-conversation; sessions rebuild on each
send, so the next reply just routes differently.

**Streaming responses.** Backends yield cumulative snapshots, and the UI renders
them incrementally through a virtualized message list built for long
conversations.

**Rich rendering.** Markdown via `swift-markdown-ui`, syntax-highlighted code
block cards with copy affordances, and LaTeX math rendered by `SwiftMath`.

**Image attachments.** Paste or drop images into the composer; they cross the
backend seam as wire-neutral `ChatImage` values and are re-encoded per provider.

**Live status.** A status light reports what actually happened downstream of your
choice — availability, data residency, real context window — rather than
promising model-level precision the API can't guarantee.

**Persistence.** Conversations and messages are SwiftData models. Only a model's
`id` string is ever persisted; everything else is resolved from it at runtime.

---

## Requirements

| | |
| --- | --- |
| macOS | 27.0 or later (deployment target) |
| Xcode | 27 beta — the `ClaudeForFoundationModels` package does not build on Xcode 26.x |
| Swift | 6.0, with `MainActor` default actor isolation and approachable concurrency |

Apple's Private Cloud route additionally depends on an iCloud account and is
subject to a per-user daily quota.

---

## Getting started

Clone and open the project:

```bash
git clone git@github.com:mbKaleb/coreChat.git
```

```bash
open ChatCore.xcodeproj
```

Swift Package Manager resolves the four dependencies on first open. Then build
and run the `ChatCore` scheme (⌘R).

If your default toolchain is not the beta, point Xcode's command-line tools at it
before building from the terminal:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -scheme ChatCore -destination 'platform=macOS' build
```

Without the beta toolchain the build fails inside `ClaudeForFoundationModels`.

---

## Configuring Claude

The Anthropic backend registers only when `ClaudeForFoundationModels` is
importable, and it vends models only when it finds an API key. It looks in two
places, in order:

1. **Keychain** — service `com.franken.ChatCore`, account `anthropic.api-key`.
   Set this from Settings › Accounts; the key is stored first, then checked
   against the vendor, so a dropped network can't lose a good key.
2. **Environment** — `ANTHROPIC_API_KEY`, useful for scheme-level development.

With no key, `availableModels()` returns nothing and the picker simply shows the
Apple routes. Nothing errors and nothing leaks — the secret itself never appears
in a `ProviderConfig`, only a Keychain reference.

### Other vendors

Settings › Accounts carries a field for every vendor in `ModelVendor` that needs
a key — OpenAI, Google, xAI, Meta, Mistral, DeepSeek, Alibaba Cloud, Moonshot,
Cohere, and Hugging Face — each stored under `<vendor>.api-key` in the same
service, and each verified against that vendor's own endpoint by
`APIKeyValidator`. Only Apple and Anthropic have backends behind them today; the
rest take a key now and say so in the footer, so nothing has to be re-entered
when a wire lands.

---

## Architecture

Four layers, with one protocol as the seam between the app and every engine.

```
        UI  ChatView · AppView · StatusIndicator
             │  (sees only ModelManager)
  SwiftData  Conversation · Message  ──emits──▶ [ChatTurn]
             │
   Manager   ModelManager        @Observable @MainActor
             │  reply(to:using:options:)  → AsyncThrowingStream
             │  query(_:using:options:)   → String (one-shot sugar over reply)
             ▼
      Seam   protocol ChatBackend: Sendable
             │
  Backends   AppleBackend      ClaudeBackend      VendorBackend / CustomBackend
             on-device + PCC   Anthropic API      (designed, not yet built)
```

`ModelManager` exposes exactly two operations. `reply` streams a multi-turn
conversation; `query` is one-shot sugar for titles, tags, and summaries that
drains the stream and returns the last snapshot — one code path to debug.

### Invariants

These are the rules the design is actually made of:

1. **The UI never imports an engine.** No `FoundationModels`, no `URLSession`,
   no MLX above `ModelManager`.
2. **Backends never import SwiftData.** They see `[ChatTurn]` and nothing else.
3. **Model descriptors are pure data.** `GenerativeChatModel` carries static
   facts; behavior lives in the backend that vended it, found via `BackendID`.
4. **A conversation's model is switchable mid-chat.** Generation parameters stay
   locked at creation. A model that vanishes resolves to `fallbackModel` at send
   time.
5. **Streams yield cumulative snapshots, not deltas.** This is the
   FoundationModels convention; HTTP adapters accumulate to match it.

### The value layer

Static facts live on the `GenerativeChatModel` descriptor. Live truth —
availability, quota, the real context window — arrives from
`backend.capabilities(of:)` and is cached as `ModelCapabilities`, keyed by model
ID. UI status is a pure function of the pair:

`(availabilityState, dataResidency) → StatusLevel → GlowDot color`

### Model ID namespace

The ID string is the only persistence token, stored in `Conversation.modelID`:

```text
apple.on-device                 apple.private-cloud
vendor.anthropic.<model-id>
vendor.<backend-uuid>.<provider-model-id>
custom.<backend-uuid>
```

IDs name *placements*, not weights — so a conversation stays truthful across OS
upgrades that silently swap the backing model.

---

## Project layout

```
App/
  App.swift              @main — SwiftData container, backend registration, ⌘-commands
  AppView.swift          window shell: sidebar + detail
  ChatView.swift         the conversation surface
  Backend/
    ChatBackend.swift    the seam: protocol, ChatTurn, ChatImage, ChatOptions
    ModelManager.swift   routing, capability cache, live streaming state
    AppleBackend.swift   on-device + Private Cloud routes
    ClaudeBackend.swift  Anthropic, via ClaudeForFoundationModels
    AnthropicModelsAPI.swift · AnthropicAPIKeyValidator.swift
    KeychainStore.swift  secrets by reference, never by value
    NetworkMonitor.swift · VendorTypes.swift
  Types/                 SwiftData models + wire-neutral values
    ModelTypes/GenerativeChatModel.swift
  Rendering/
    TranscriptRenderer.swift  which renderer draws the chat, and what one is given
  Compiled/              the compiled CoreText transcript: compiler, blocks, caches
  Markdown/              markdown, math, code cards, render cache
  Components/            message bubbles, the other two transcript lists, status, paste catcher
  Settings/              settings window and appearance
  Theme/                 fonts and theme manager
Documentation/
  Diagrams/              Backend-Design.md + architecture SVGs
  YAML/docs.yaml         the diagrams as structured data, for LLM context
Design/Icon/             app icon source layers
```

---

## Dependencies

| Package | Version | Used for |
| --- | --- | --- |
| [ClaudeForFoundationModels](https://github.com/anthropics/ClaudeForFoundationModels.git) | 0.1.2+ | Claude models behind a FoundationModels-shaped API |
| [swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui) | 2.4.1+ | rendering assistant markdown |
| [swift-markdown](https://github.com/swiftlang/swift-markdown) | 0.8.0+ | parsing and AST work |
| [SwiftMath](https://github.com/mgriebling/SwiftMath.git) | 1.7.3+ | LaTeX math rendering |

---

## Debugging

Seed a large in-memory conversation to exercise the virtualized list and
streaming path without touching your real store — pass the launch argument in the
scheme's run arguments:

```text
-seedLargeChat
```

This swaps the `ModelContainer` to `isStoredInMemoryOnly` and populates 250 turns
(500 messages). It is compiled out of release builds entirely.

`RenderDebug.swift` carries the instrumentation for markdown and layout
measurement.

---

## Documentation

- [Backend Design](Documentation/Diagrams/Backend-Design.md) — the full design
  document: the seam, all three backend families, selection semantics, and open
  questions.
- [Architecture.svg](Documentation/Diagrams/Architecture.svg) — layered runtime.
- [Model-Types.svg](Documentation/Diagrams/Model-Types.svg) — the value layer.
- [docs.yaml](Documentation/YAML/docs.yaml) — both diagrams as structured data,
  meant to be passed to an LLM in place of the raw SVGs.

### Not yet built

`VendorBackend` (generic HTTPS + SSE providers behind a `WireAdapter`) and
`CustomBackend` (local open weights via MLX) are designed in the backend document
but not implemented. The seam is shaped so they arrive as new conformances rather
than as changes to anything above them.
