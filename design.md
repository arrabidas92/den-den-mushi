# design.md

Design system for the BeReal Stories test. Dark mode only. Hybrid approach: Instagram structural patterns (tray, viewer, progress bars, gestures) with BeReal aesthetic codes (raw, mono, no gradients, typographic).

## Aesthetic direction

The product is recognizably Instagram in structure but BeReal in tone. Where Instagram uses pink-orange-purple gradients and a polished feel, this implementation uses:

- Solid white rings instead of gradient rings
- Pure black background (OLED-friendly)
- Tight, almost industrial spacing
- No skeumorphism, no soft shadows
- High-contrast typography
- System red for the like accent (not pink)

The single most visible signature is the **solid white unseen ring**. It tells the reviewer immediately: "I understood the brief, I'm not just cloning Instagram."

## Color tokens

```
// Backgrounds
Background          #000000   // canvas, OLED-optimized
Surface             #0E0E0E   // cards, sheets
Surface elevated    #1A1A1A   // modals over modals
Border              #2A2A2A   // hairlines, separators

// Text
Text primary        #FFFFFF
Text secondary      #A0A0A0   // timestamps, secondary usernames
Text tertiary       #5A5A5A   // placeholders, disabled

// Story rings
Ring unseen         #FFFFFF   // solid 2pt
Ring seen           #404040   // 1.5pt — distinct from Border, visible on #000
Ring loading        #FFFFFF + opacity pulse animation

// Accents
Accent like         #FF3B30   // iOS system red, NOT pink
Progress active     #FFFFFF
Progress inactive   #FFFFFF @ 30% opacity
```

`Border` and `Ring seen` are **separate tokens** even though their values are close. They mean different things: `Border` is a hairline divider on a surface, `Ring seen` is a foreground state indicator over the OLED background. Keep them distinct so they can drift independently if needed. `Ring seen` was bumped from `#2A2A2A` to `#404040` to clear the WCAG 1.07:1 contrast floor against the canvas — at the lower value the seen ring disappeared into the page on the third tray row.

Implementation: extension `Color` with named static properties. Use `Color(.sRGB, ...)` to keep colors stable across iOS versions.

## Typography

SF Pro system font, no custom faces.

```
Username (tray)        SF Pro Text 12pt   .medium     tracking -0.2
Username (header)      SF Pro Text 15pt   .semibold
Timestamp              SF Pro Text 13pt   .regular    opacity 70%
Section title          SF Pro Display 22pt .bold
Body                   SF Pro Text 15pt   .regular
Caption                SF Pro Text 11pt   .regular    opacity 70%
```

Implementation: extension `Font` with named static properties. Always use the named tokens, never raw `Font.system(size:)` in views.

## Spacing scale

Powers-of-two-ish, predictable:

```
Spacing.xs  =  4
Spacing.s   =  8
Spacing.m   = 12
Spacing.l   = 16
Spacing.xl  = 24
Spacing.xxl = 32
```

Use these constants exclusively in views. No magic numbers in layouts.

## Component dimensions

```
// Tray
Avatar diameter         64pt
Ring gap (avatar↔ring)   3pt
Tray item spacing       14pt   // regular density (default)
Tray padding (h, v)     16pt, 12pt

// Viewer
Progress bar height      3pt
Progress bar gap         2pt
Viewer header height    56pt
Viewer footer height    64pt
Viewer padding (h, v)   16pt, 12pt

// Buttons
Like icon               28pt
Close icon              24pt
Touch target minimum    44pt   // Apple HIG, never below

// Corner radii
Cards                   12pt
Avatars                 full (geometry-based)
Buttons                 full
```

### Tray density

Three densities, switchable via a single environment value (`TrayDensity.compact|regular|comfy`). Only the inter-item spacing changes; avatar size stays 64pt so the ring signature remains constant.

```
compact   item spacing 10pt   // dense, more users in viewport
regular   item spacing 14pt   // default
comfy    item spacing 18pt   // breathable, fewer users in viewport
```

Default is `regular`. The two others exist as a single-line override — useful for accessibility scenarios (compact for users who scan many users at once) and as a knob the reviewer can flip without touching layout code.

### Tap zones (viewer)

Vertical split, **1:2 ratio** (left third = previous, right two-thirds = next). Forward is the dominant action so its zone is larger; this matches Instagram's actual behaviour and reduces accidental "previous" taps when users are flicking through. Both zones are full-height excluding the 56pt header and 64pt footer. Long-press on either zone pauses.

### Image failure (viewer)

A failed item image is **not silent** — silence reads as a bug. The fallback frame:
- Surface `#0E0E0E` background (not pure black, so the user perceives a frame, not a void)
- Centered glyph: small offline/broken-image icon, `Text tertiary` color
- Single line of caption, `SF Pro Text 13pt`, `Text secondary`: "Couldn't load this story"
- A `Retry` button, 44pt min, low-emphasis (text-only, white at 70%)
- Auto-advance is paused while the failure frame is visible. Tap-forward still works.

No haptic on failure (HIG: don't punish the user for network conditions).

## Motion principles

Motion reveals quality. The reviewer will feel these even unconsciously.

### Duration tokens

All durations route through named tokens. No hardcoded `0.2`/`0.3`/`0.4` in views. This buys two things: a coherent feel across components, and a one-line override for `accessibilityReduceMotion` (collapse all three to `0` and set transitions to `.identity`).

```
Motion.fast      = 0.2s   // micro-feedback: pause overlay fade, tap state
Motion.standard  = 0.3s   // primary affordances: like spring, header fade
Motion.slow      = 0.4s   // ring state crossfade, dismiss
Motion.itemPlay  = 5.0s   // single item duration (progress bar fill)
```

Implementation: extension `Animation` (or a `Motion` enum returning `Animation`) with named static properties. Always reference tokens from views, never literal seconds.

### Reduced motion

`@Environment(\.accessibilityReduceMotion)` is honoured globally:
- Progress bar animation: replaced by discrete tick at item end. Auto-advance still fires; the bar simply doesn't animate.
- Ring crossfade on seen transition: replaced by instant swap.
- Like spring: replaced by instant color/fill swap (no scale pop).
- Pause overlay fade: instant.

Auto-advance is **kept on** under reduced motion — disabling it would break the product. The user can still tap forward/back; the time-driven advance just no longer has an animated bar to telegraph it.

### Timing & curves

- **Linear** for progress bars only. Anything else looks broken.
- **Ease-out** (default SwiftUI) for UI fades, opacity changes, dismissals.
- **Spring** for affordances that respond to user touch (like, tap feedback).
- Never use `easeIn` alone — feels sluggish.

### Specific animations

```
Open viewer (tray → fullscreen)
    Default fullScreenCover, no custom transition
    Rationale: matched geometry costs ~1.5h, marginal visual gain

Like tap
    spring(response: 0.3, dampingFraction: 0.6)
    scale: 0.8 → 1.2 → 1.0
    haptic: .impact(.medium) at tap moment
    color: stroke white → fill #FF3B30, crossfade 0.2s

Progress bar fill
    .linear(duration: itemDuration)
    Reset instantly on item change (no animation backwards)

Pause (long press)
    UI overlay opacity 1 → 0, ease-out 0.2s
    Progress bar timer pauses, visual progress freezes

Swipe between users
    Default TabView page style transition
    Rationale: cube transition costs ~1d, default works fine

Seen ring transition
    Unseen → seen on dismiss
    Crossfade between ring colors, 0.4s ease-out
    Never snap, never pop

Dismiss swipe down
    Binary: threshold 100pt OR velocity > 500pt/s → dismiss
    Rationale: interactive dismiss skipped for time
```

### Haptics

Subtle. Apple HIG: never spam haptics. Use only at decisive moments.

```
Like                .impact(.medium)
User change         .impact(.soft)
Dismiss             .impact(.light)
Image fail/error    none (don't punish the user)
```

Wrap UIKit haptics in a small `Haptics` enum in `Core/`.

## Component catalog

These live in `DesignSystem/Components/`. Each must have a SwiftUI preview showing all relevant states.

### `StoryRing`

```swift
StoryRing(state: .seen | .unseen | .loading, size: CGFloat)
```

Renders only the ring (no avatar). Composable. The 3pt gap between ring and avatar is enforced internally.

States:
- `.unseen` — solid white, 2pt
- `.seen` — solid #2A2A2A, 1.5pt
- `.loading` — white with opacity pulse animation

### `StoryAvatar`

```swift
StoryAvatar(url: URL, ring: StoryRingState, size: CGFloat)
```

Combines avatar image (loaded via Nuke) and `StoryRing`. Three internal states: loading (ring pulses, inner is `Surface elevated`), loaded (image fills inner), failed (initials glyph on `Surface elevated`, no haptic, no log spam).

### `SegmentedProgressBar`

```swift
SegmentedProgressBar(
    count: Int,
    currentIndex: Int,
    progress: Double  // 0...1, only applies to currentIndex
)
```

Pure rendering, no animation logic. The viewer ViewModel drives `progress` over time. Segments before currentIndex are full, after are empty.

### `LikeButton`

```swift
LikeButton(isLiked: Bool, action: @MainActor () -> Void)
```

Heart icon, 28pt. Unfilled white when not liked, filled #FF3B30 when liked. Triggers haptic and spring animation internally on tap.

### `StoryTrayItem`

```swift
enum StoryTrayItemState {
    case loaded(user: User, isFullySeen: Bool)
    case loading                                  // skeleton: pulsing ring + Surface elevated avatar + greyed-out username placeholder
    case failed(retry: () -> Void)                // tap to retry pagination
}

StoryTrayItem(state: StoryTrayItemState, density: TrayDensity = .regular, onTap: () -> Void = {})
```

Composes `StoryAvatar` + username label. Truncates long usernames with `.lineLimit(1)` and `.truncationMode(.tail)`. The `density` only affects the parent `HStack` spacing inside the tray, not the item itself; passing it here keeps the prop colocated with the consumer.

The three states share the exact same outer geometry (avatar diameter, ring gap, label height) — switching state must never reflow neighbouring items. Loading and failed states render no haptic. Failed state replaces the ring with a `Text tertiary` warning glyph and the username with the word "Retry"; a tap calls `retry`.

### `StoryViewerHeader`

```swift
StoryViewerHeader(user: User, timestamp: Date, onClose: () -> Void)
```

Avatar (small, no ring) + username + relative timestamp + close button.

## Loading & empty states

Three places in the product can show "loading"; each has a defined treatment so they never collide visually.

### 1. App bootstrap

`StoriesTestApp` hydrates `StoryListViewModel` from a `.task` (the persisted state store init is `async throws`). While that runs, render `LoadingView`:

- `Background` (`#000000`) full-screen
- A 24pt white `ProgressView` centred — no logo, no copy, no fade

In practice the hydration completes in <50ms, so the view exists for correctness, not as a designed surface. Keeping it minimal is intentional: a designed splash would flash visibly for ~3 frames and feel like a glitch.

### 2. Initial tray load (page 0 not yet ready)

When `StoryListViewModel.pages` is empty and `isLoading == true`, render a **skeleton tray**:

- 8 `StoryTrayItem` instances in `.loading` state in the `HStack`
- Each shows a pulsing ring (the existing `Ring loading` token) + a `Surface elevated` circle in place of the avatar + a 32pt × 8pt rounded `Text tertiary @ 30% opacity` rectangle in place of the username
- The pulse animation cycles at `Motion.slow` (0.4s) on opacity 0.4 → 1.0 → 0.4 — `accessibilityReduceMotion` collapses to a static 70% opacity (no pulse)
- No global spinner above the tray — the skeleton **is** the indicator

Skeleton beats spinner here because the user sees the *shape* of what is arriving (a horizontal carousel of stories), so the transition to loaded content is a content swap, not a screen replacement.

### 3. Pagination (page N+1 while scrolling)

When `isLoadingMore == true`, append a single trailing `StoryTrayItem(.loading)` to the tray. It uses the same skeleton treatment as the initial load. Removed when the new page arrives.

The N-3 trigger means in practice the user rarely reaches the end before the next page is appended; the trailing skeleton is only visible on slow networks. The trade-off (a) "no indicator" was rejected because of the pagination-failure edge case below: with no skeleton, a failed pagination silently leaves the user at the end of a tray that won't extend, with no signal of why.

### 4. Pagination failure

When `loadPage(currentPage + 1)` throws and `isLoadingMore` flips back to `false`, the trailing skeleton transitions to `StoryTrayItem(.failed(retry:))`:

- Ring replaced by an SF Symbol `exclamationmark.triangle` glyph in `Text tertiary`
- Username replaced by the word "Retry" in `Text secondary`
- Tap calls `viewModel.loadMoreIfNeeded()` — same path as the auto-trigger, so success collapses the failed item to a fresh page silently
- No haptic, no toast, no alert — consistent with the rest of the product's error chrome

This is the only failure surface in the tray. List-level errors (corrupt JSON, repository unavailable) escalate to a full-screen empty-state with the same retry affordance, not an inline row.

## Preview discipline

Every reusable component has a `#Preview` block that shows:

1. The component in its primary state
2. All meaningful variants in a `VStack` or `Group`
3. Both with realistic data and edge cases (empty, max length, etc.)

Previews are documentation. A reviewer scrolling files should understand the system from the previews alone.

## Accessibility

The cheap, high-signal wins are in scope:

- All interactive elements have `.accessibilityLabel`
- Like button has `.accessibilityValue("liked" / "not liked")`
- Tap targets ≥ 44pt
- VoiceOver labels for the close button
- **Reduced motion**: respected globally via `Motion.fast/standard/slow` collapsing to `0` and ring/like transitions becoming instant. Auto-advance still fires on a discrete tick (no animated bar), tap-through always works. See *Motion principles → Reduced motion*.

Skipped (mention in README):
- Dynamic Type support (story UI is intentionally fixed-size; matches Instagram).
- VoiceOver navigation through items (no rotor item; tap forward/back is the only flow).
