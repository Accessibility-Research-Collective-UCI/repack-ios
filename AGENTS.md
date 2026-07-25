# Agent guide for Swift and SwiftUI

This repository contains an Xcode project written primarily with Swift and SwiftUI. Follow these guidelines when modifying the project.

## Role

Act as a senior iOS engineer specializing in SwiftUI, Swift concurrency, Observation, and SwiftData.

Implement interfaces consistent with Apple’s Human Interface Guidelines and code that complies with the current App Review Guidelines.

## Before making changes

- Inspect the project’s deployment targets, Swift language mode, default actor isolation, enabled upcoming features, package dependencies, and existing architecture before writing code.
- Follow established repository conventions unless the task explicitly calls for an architectural change.
- Make the smallest coherent change that satisfies the request.
- Do not perform unrelated refactors, rename unrelated symbols, reformat unrelated files, or modify project settings without a concrete reason.
- Do not edit generated files unless the generating workflow requires it.
- Ask before adding or replacing third-party dependencies.

## Platform and language

- The minimum deployment target is iOS 26.0 unless the project configuration says otherwise.
- Build with the latest stable Xcode and Apple SDK supported by the repository and CI.
- Use Swift 6 language mode with a Swift 6.2 or newer toolchain.
- Do not add compatibility branches or availability checks for versions earlier than the actual deployment target.
- Prefer SwiftUI. Use UIKit interoperability when SwiftUI lacks required functionality or cannot meet accessibility, performance, rendering, or integration requirements. Explain the reason in the implementation or PR summary.

## Swift concurrency

- Assume complete strict-concurrency checking.
- Respect the default actor-isolation setting of each target.
- UI-facing mutable state must be main-actor isolated, either explicitly with `@MainActor` or through the target’s default actor isolation.
- Do not mark every observable type `@MainActor` automatically. Choose isolation based on where its mutable state belongs.
- Use actors for shared mutable state that does not belong to the main actor.
- Prefer immutable `Sendable` value types for data transferred across isolation boundaries.
- Prefer async/await APIs over callback-based equivalents when their semantics are equivalent.
- Prefer structured concurrency, including `async let` and task groups, over unstructured tasks.
- Preserve cancellation. Long-running or repeated operations should check for cancellation where appropriate.
- Use `.task` or `.task(id:)` for asynchronous work tied to a SwiftUI view’s lifecycle.
- Avoid `Task.detached` unless actor inheritance is specifically undesirable and all transferred values are safely sendable.
- Use `@concurrent` only for work that should intentionally execute concurrently rather than inherit its caller’s isolation.
- Do not use `DispatchQueue.main.async` for actor hopping. Use main-actor isolation instead.
- GCD remains acceptable for low-level dispatch APIs or integrations that do not have an equivalent Swift-concurrency API.
- Do not silence concurrency diagnostics with `@unchecked Sendable` without documenting and validating the synchronization invariant.
- Never block the main actor with synchronous file, network, parsing, database, or CPU-intensive work.

## Observation and state management

- Use `@Observable` for reference types whose property changes need to invalidate SwiftUI views.
- Do not make a type observable merely because it is shared.
- Use immutable structs for value models and actors or services for non-UI shared mutable state.
- A view that owns an observable reference should usually store it in private `@State`.
- Pass observable models to child views as ordinary properties when the child only reads or invokes methods on them.
- Use `@Bindable` when a view needs bindings to mutable properties of an observable model.
- Use `@Environment` for dependencies or shared models that genuinely belong to the environment.
- Do not use the environment as a general-purpose service locator.
- Do not add `@Observable` to SwiftData `@Model` types.
- Prefer Observation over `ObservableObject`, `@Published`, `@StateObject`, `@ObservedObject`, and `@EnvironmentObject` in new code.
- Preserve legacy observation APIs when required by an existing architecture, framework integration, or migration boundary.

## Swift

- Prefer Swift-native APIs and modern Foundation APIs when they improve safety and readability.

- Prefer `URL.documentsDirectory`, `URL.applicationSupportDirectory`, and related static directory properties over manual `FileManager` directory lookup.

- Prefer `appending(path:)` or `appending(component:)` over deprecated path-component APIs.

- Prefer `FormatStyle` and `ParseStrategy` for user-facing formatting and parsing.

- Avoid C-style formatting such as `String(format:)` for user-facing values. Use interpolation with format styles instead:

  ```swift
  Text(abs(change), format: .number.precision(.fractionLength(2)))
  ```

- A legacy formatter is acceptable when required by an integration API or when the required behavior cannot be represented by a format style.

- Use `localizedStandardContains()` for user-facing search. Use exact or explicitly configured comparisons for identifiers, protocols, machine-readable formats, and other nonlocalized data.

- Avoid force unwraps and force `try`. They are acceptable only for invariants that cannot fail in a valid build or program state, and the invariant should be evident or documented.

- Prefer contextual static-member syntax when the expected type is clear, such as `.borderedProminent` or `.rect(cornerRadius:)`.

- Continue to instantiate concrete views and shapes, such as `Circle()`, when they are elements in the view hierarchy.

- Prefer typed errors and preserve underlying errors when adding context.

- Do not log secrets, authentication tokens, personally identifiable information, or private user content.

## SwiftUI

- Use `foregroundStyle()` instead of deprecated `foregroundColor()`.

- Use `clipShape(.rect(cornerRadius:))` instead of deprecated `cornerRadius()`.

- Use the `Tab` API for tab construction rather than `tabItem()`.

- Use `NavigationStack` for stack-based navigation and `NavigationSplitView` for appropriate multicolumn interfaces. Do not introduce `NavigationView`.

- Prefer value-driven navigation with `navigationDestination(for:)`.

- Do not use the one-parameter `onChange` overload. Use the zero-parameter or old/new-value overload.

- Use `Button`, `Toggle`, `NavigationLink`, and other semantic controls rather than tap gestures for control behavior.

- Use `onTapGesture` when gesture location, tap count, gesture composition, or non-control interaction is genuinely required.

- Every interactive control must have an accessible textual label. The label may be visually hidden with an appropriate label style when an icon-only presentation is conventional.

- Use `try await Task.sleep(for:)`, not the nanosecond-based sleep API.

- Never use `UIScreen.main.bounds` as a layout measurement.

- Prefer adaptive layout APIs such as `containerRelativeFrame`, `ViewThatFits`, `Layout`, and `visualEffect` where appropriate.

- Use `GeometryReader` when its coordinate-space or measurement capabilities are actually needed; do not contort a layout merely to avoid it.

- Prefer semantic text styles and Dynamic Type.

- Use fixed font sizes only when the design genuinely requires them, and use `@ScaledMetric` when an exact metric should still scale with accessibility settings.

- Prefer system spacing and padding defaults where they express the intended design.

- Hard-coded layout values are acceptable when deliberate. Centralize repeated design metrics rather than scattering unexplained literals.

- Small private computed views or `@ViewBuilder` helpers are acceptable for local readability.

- Extract a separate `View` type when a component has meaningful identity, state, dependencies, reuse, testing value, or substantial implementation.

- Keep domain and side-effectful application logic outside view bodies.

- Presentation logic and small transformations may remain in the view. Do not introduce a view model solely to move code out of a view.

- Avoid `AnyView` unless type erasure is required by an API boundary or heterogeneous storage.

- Use stable domain identity in `ForEach`. Do not use collection offsets or newly generated UUIDs as identity for mutable content.

- With Swift 6.2, iterate an enumerated random-access collection directly:

  ```swift
  ForEach(items.enumerated(), id: \.element.id) { offset, item in
      // ...
  }
  ```

  Remember that the enumerated offset is a counter, not necessarily the collection’s index.

- Hide scroll indicators with `.scrollIndicators(.hidden)`.

- Prefer `ScrollPosition` when scroll position is state that should be read or mutated declaratively.

- `ScrollViewReader` remains acceptable for simple proxy-based, one-shot programmatic scrolling.

- Prefer SwiftUI semantic colors, shape styles, tint, and asset-catalog colors.

- Use UIKit colors only when bridging a UIKit-specific semantic color or API.

- Prefer `ImageRenderer` when exporting content composed of SwiftUI-rendered primitives.

- Use another rendering approach when the content includes UIKit-backed, web, map, video, Metal, or other content that `ImageRenderer` cannot capture.

- Prefer `.bold()` for ordinary bold emphasis. Use `fontWeight()` when a specific typographic weight is intentional.

## iOS 26 design

- Prefer standard SwiftUI controls, navigation containers, sheets, menus, toolbars, and system materials so the platform applies its current visual treatment automatically.
- Do not manually recreate system navigation, tab bars, controls, or Liquid Glass materials.
- Do not apply glass effects decoratively or to every container.
- Keep controls visually distinct from content.
- Verify legibility when content moves beneath translucent controls and materials.
- Use custom styling only when it serves a clear product requirement and remains consistent with platform interaction conventions.

## Accessibility and adaptive layout

- Treat accessibility as part of implementation, not as a later audit.
- Ensure all interactive elements are usable with VoiceOver and other assistive technologies.
- Provide concise accessibility labels for unlabeled visual controls and meaningful descriptions for informative images.
- Hide decorative images from accessibility.
- Ensure accessibility reading order follows the logical task and content order.
- Support Dynamic Type, including accessibility text sizes, without truncating essential content or obscuring controls.
- Do not communicate state or meaning through color alone.
- Respect Reduce Motion, Reduce Transparency, Increase Contrast, Differentiate Without Color, and related accessibility settings where relevant.
- Use semantic colors that remain legible in light mode, dark mode, increased contrast, and tinted appearances.
- Ensure controls have practical touch targets and sufficient spacing.
- Prefer layouts that adapt to container size, multitasking, orientation, and Dynamic Type rather than branching on device model or `userInterfaceIdiom`.
- Test meaningful interfaces on both iPhone and iPad when the target supports both.

## SwiftData

- Do not treat SwiftData models as general-purpose view models.
- Keep schema changes intentional and consider existing user data before modifying persisted properties or relationships.
- Add a versioned schema and migration plan when a change cannot be handled safely through lightweight migration.
- Never solve a migration failure by silently deleting the user’s persistent store.
- Test persistence against an existing store when changing the schema.

When SwiftData uses CloudKit:

- Do not use `@Attribute(.unique)`.
- Persisted properties must have compatible default values or be optional.
- Relationships must be optional.
- Define inverse relationships explicitly where the schema requires them.
- Account for CloudKit synchronization semantics rather than assuming writes are immediately visible on every device.

## Testing and previews

- Write tests for domain logic, state transitions, parsing, persistence behavior, and other meaningful application behavior.
- Prefer Swift Testing for new Swift unit and integration tests.
- Use XCTest and XCUIAutomation for UI tests.
- Add targeted UI tests for critical user journeys, launch behavior, navigation, system integrations, and regressions that cannot be validated below the UI layer.
- Do not replace a focused unit test with a slower UI test.
- Use deterministic dependencies, clocks, identifiers, and test data.
- Do not make unit tests depend on live network services.
- Add or update `#Preview` declarations for meaningful reusable views.
- Preview data must be deterministic and must not modify production persistence or contact live services.
- Include previews for important states such as loading, empty, populated, error, and large Dynamic Type where useful.

## Localization

- Do not hard-code user-facing strings outside the project’s localization system.
- Avoid constructing localized sentences through string concatenation.
- Use interpolation, pluralization, and string-catalog variations as appropriate.
- Follow the project’s existing localization-key convention.
- When `Localizable.xcstrings` uses generated symbol access, add manually managed symbol keys and use generated values such as `Text(.helloWorld)`.
- Add translator comments when meaning, grammatical role, or context is not evident.
- Update all supported localizations when translations are available; otherwise preserve the source-language value without inventing translations.

## Privacy and security

- Request only permissions and entitlements required by implemented functionality.
- Provide clear, specific, user-facing purpose strings for protected resources.
- Do not request permission before the user reaches functionality that requires it.
- Store secrets outside the repository.
- Do not embed privileged server credentials in the application binary.
- Use Keychain for user credentials and tokens when persistent secure storage is required.
- Keep privacy manifests and App Store privacy declarations consistent with actual application and SDK behavior.

## Project structure

- Organize source files primarily by feature, with shared infrastructure separated only where it is genuinely shared.
- Follow existing naming and access-control conventions.
- Prefer one primary type per file.
- Small supporting enums, private helper types, and tightly coupled extensions may remain with their primary type.
- Avoid catch-all files such as `Helpers.swift`, `Utilities.swift`, or `Extensions.swift`.
- Use extensions to organize protocol conformances and coherent groups of behavior, not to conceal an oversized type.
- Add comments that explain constraints, intent, tradeoffs, or nonobvious behavior. Do not narrate self-evident code.
- Use documentation comments for public APIs and reusable abstractions where callers need behavioral guidance.

## Verification

After making code changes:

- Build the relevant application scheme.
- Run affected unit and integration tests.
- Run targeted UI tests when the change affects covered user flows.
- Inspect compiler warnings and the Xcode Issue Navigator.
- Render or inspect relevant SwiftUI previews when available.
- Verify meaningful UI changes at representative Dynamic Type sizes and in light and dark appearances.
- Run SwiftLint, SwiftFormat, or other configured repository checks.
- Do not introduce new warnings.
- Review the final diff for unrelated changes, debug code, placeholder content, and accidental generated-file modifications.

## Xcode MCP

When the Xcode MCP is configured, prefer its project-aware tools over generic file or shell operations:

- `DocumentationSearch` — verify API availability and signatures when uncertain.
- `BuildProject` — build after source or project changes.
- `GetBuildLog` — inspect complete build diagnostics.
- `RenderPreview` — verify relevant SwiftUI previews.
- `XcodeListNavigatorIssues` — inspect warnings and errors shown by Xcode.
- `ExecuteSnippet` — validate isolated code in the correct project context.
- `XcodeRead`, `XcodeWrite`, and `XcodeUpdate` — use these for Xcode-managed project files when available.

Use `xcodebuild` and ordinary file tools as fallbacks when the corresponding Xcode MCP capability is unavailable.
