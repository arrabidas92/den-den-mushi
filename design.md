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
Ring seen           #2A2A2A   // 1.5pt
Ring loading        #FFFFFF + opacity pulse animation

// Accents
Accent like         #FF3B30   // iOS system red, NOT pink
Progress active     #FFFFFF
Progress inactive   #FFFFFF @ 30% opacity
```

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
Tray item spacing       14pt
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

## Motion principles

Motion reveals quality. The reviewer will feel these even unconsciously.

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

Combines avatar image (loaded via Nuke) and `StoryRing`. Handles loading and failure states with a placeholder.

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
StoryTrayItem(user: User, isFullySeen: Bool, onTap: () -> Void)
```

Composes `StoryAvatar` + username label. Truncates long usernames with `.lineLimit(1)` and `.truncationMode(.tail)`.

### `StoryViewerHeader`

```swift
StoryViewerHeader(user: User, timestamp: Date, onClose: () -> Void)
```

Avatar (small, no ring) + username + relative timestamp + close button.

## Preview discipline

Every reusable component has a `#Preview` block that shows:

1. The component in its primary state
2. All meaningful variants in a `VStack` or `Group`
3. Both with realistic data and edge cases (empty, max length, etc.)

Previews are documentation. A reviewer scrolling files should understand the system from the previews alone.

## Accessibility

Not a primary focus for the test, but the cheap wins:

- All interactive elements have `.accessibilityLabel`
- Like button has `.accessibilityValue("liked" / "not liked")`
- Tap targets ≥ 44pt
- VoiceOver labels for the close button

Skipped (mention in README):
- Reduced motion alternative (would replace progress bar animation)
- Dynamic Type support (story UI is intentionally fixed-size)
