# plan.fr.md

Plan d'implémentation pour le test BeReal Stories. Compagnon de `architecture.fr.md` et `design.fr.md` — les deux doivent être lus d'abord ; ce fichier traduit les specs validées en une séquence de build ordonnée et gatée.

## Principes directeurs

- **Tranches verticales, tests écrits en même temps que le code.** Chaque phase livre du code *et* ses tests dans le même gate. Pas de « on écrit les tests à la fin ».
- **Bottom-up sur les fondations, top-down sur les features.** Domain → Data → DesignSystem sont des couches stables et sans dépendances, construites en premier. StoryList → StoryViewer les consomment.
- **Gating explicite.** Chaque phase se termine par une condition de validation concrète (tests verts, démo manuelle, ou check console). On ne démarre pas une phase tant que la précédente n'est pas verte.
- **Pas de scaffolding jetable.** Tout ce qui est écrit a sa place dans le livrable final. Pas de « placeholder à remplacer plus tard ».

## Phase 0 — Bootstrap projet (~30 min)

**But :** un projet Xcode qui compile, tests inclus, dépendances ajoutées, CI locale verte.

1. Créer le projet Xcode `Stories` (iOS app, SwiftUI, iOS 18 minimum, Swift 6 strict mode, **Default Actor Isolation = MainActor**).
2. Créer les targets : `Stories` (app) et `StoriesTests` (Swift Testing uniquement — pas de couche XCTest une fois les snapshot tests retirés).
3. Ajouter `Nuke` via SPM (target app uniquement).
4. *(retiré : `swift-snapshot-testing` — voir CLAUDE.fr.md "Stratégie de tests" / architecture.fr.md "Contrat visuel" pour la raison.)*
5. Créer la structure de dossiers exacte d'`architecture.fr.md` § *Structure des dossiers* (vide, avec un `.gitkeep` au besoin).
6. Configurer Xcode coverage **uniquement** sur `Domain/` et les ViewModels (`StoryListViewModel`, `ViewerStateModel`, `PlaybackController`) au niveau du scheme.
7. Ajouter un `stories.json` minimal (5–7 utilisateurs, 2–4 items chacun, URLs `picsum.photos/seed/...`) dans `Data/Resources/`.

**Gate :** `cmd-B` compile, `cmd-U` lance la suite vide sans erreur, le projet s'ouvre dans Xcode 16.

## Phase 1 — Domain (~45 min)

**But :** modèles et protocoles immuables, importés partout ensuite.

1. `Domain/Models/User.swift` — `struct User: Sendable, Hashable, Codable` avec `id`, `stableID`, `username`, `avatarURL`.
2. `Domain/Models/StoryItem.swift` — `id`, `imageURL`, `createdAt`.
3. `Domain/Models/Story.swift` — `id`, `user: User`, `items: [StoryItem]`. Méthode `withPageSuffix(_ pageIndex: Int) -> Story`.
4. `Domain/Models/UserState.swift` — `seenItemIDs: Set<String>`, `likedItemIDs: Set<String>`, Codable.
5. `Domain/Models/HeartPop.swift` — `Sendable, Equatable`, `id: UUID`, `location: CGPoint` (importer `CoreGraphics`, pas SwiftUI).
6. `Domain/Models/StoryError.swift` — l'enum complet de l'architecture.
7. `Domain/Repositories/StoryRepository.swift` — protocole `Sendable`.
8. `Domain/Repositories/UserStateRepository.swift` — protocole `Sendable` avec `flushNow()`.

**Gate :** Domain compile en isolation (vérifier uniquement `import Foundation` et `import CoreGraphics` — pas de `SwiftUI`, pas de `Nuke`).

## Phase 2 — Couche Data + tests (~2h)

**But :** repositories concrets, persistance fiable, prêts à être consommés. Tests unitaires écrits **en même temps**.

1. `Data/LocalStoryRepository.swift` — actor, charge `stories.json` du bundle, implémente la formule de pagination + suffixage.
2. `LocalStoryRepositoryTests.swift` (Swift Testing) :
   - le JSON parse correctement
   - `loadPage(0)` retourne 10 items
   - unicité des IDs cross-pages
   - sortie déterministe
   - edge case `n=0` → tableau vide, pas de crash
   - edge case `n < pageSize` (e.g. `n=7`) → wrap correct, suffixe partagé intra-page
3. `Data/PersistedUserStateStore.swift` — actor, `Application Support/`, `isExcludedFromBackup`, debounce 500ms, `flushNow()`, recovery sur corruption.
4. `Data/EphemeralUserStateStore.swift` — actor en mémoire (fallback prod-safe, pas test-only).
5. `PersistedUserStateStoreTests.swift` :
   - round-trip seen/like
   - écritures concurrentes via `withTaskGroup` (vérifie l'absence de races par construction)
   - le debounce coalesce les bursts (avec `TestClock` ou `Task.sleep` court)
   - survie cross-init (recréer un store sur le même fichier)
   - corruption → fichier supprimé, le store repart vide
6. `Data/ImageLoader.swift` — `enum` avec `static func configure()` (pipeline Nuke : memory cache, disk cache TTL, timeouts).
7. `Data/ImagePrefetchHandle.swift` — `@MainActor final class` (contrainte Nuke 12).
8. `TestSupport/FakeStoryRepository.swift` — pages programmables, erreurs injectables.
9. `TestSupport/InMemoryUserStateStore.swift` — fake test-only (séparé d'`EphemeralUserStateStore`).

**Gate :** tous les tests Data verts ; coverage Domain + Data ≥ 80% sur les chemins critiques.

## Phase 3 — DesignSystem (tokens + composants) (~1h30)

**But :** kit visuel complet, previewable dans Xcode. Aucune dépendance aux ViewModels.

1. `DesignSystem/Tokens/Colors.swift` — extension `Color` avec tous les tokens de `design.fr.md`.
2. `DesignSystem/Tokens/Typography.swift` — extension `Font` avec les 6 styles nommés.
3. `DesignSystem/Tokens/Spacing.swift` — `enum Spacing { static let xs = 4 ... }`.
4. `DesignSystem/Tokens/Motion.swift` — `enum Motion` avec `.fast`, `.standard`, `.slow`, `.itemPlay`, `.skeletonPulse`, retournant `Animation`. Honorer `accessibilityReduceMotion` (collapse à 0).
5. `DesignSystem/Tokens/TrayDensity.swift` — `enum`, environment value.
6. `DesignSystem/Components/StoryRing.swift` — états `.seen|.unseen|.loading`. Preview.
7. `DesignSystem/Components/StoryAvatar.swift` — utilise `LazyImage` de Nuke + `StoryRing`. États : loading, loaded, failed (initiales). Preview.
8. `DesignSystem/Components/SegmentedProgressBar.swift` — pure rendering. Preview avec 1, 3, 5 segments.
9. `DesignSystem/Components/LikeButton.swift` — heart, spring + haptic interne au tap. Preview.
10. `DesignSystem/Components/StoryTrayItem.swift` — enum `StoryTrayItemState`, density. Preview avec les 3 états.
11. `Core/Haptics.swift` — wrapper UIKit minimal.
12. **Matrice `#Preview`** — chaque fichier de composant embarque au moins un bloc `#Preview` qui exerce sa matrice d'états (`.unseen | .seen | .loading` pour le ring, `.notLiked | .liked` pour le like button, `.loaded | .loading | .failed` pour le tray item, etc.). Cela remplace la suite snapshot initialement prévue ; rationale dans CLAUDE.fr.md "Stratégie de tests" et architecture.fr.md "Contrat visuel".

**Gate :** chaque composant apparaît dans les previews avec ses variantes et s'affiche correctement en dark mode dans le canvas de previews Xcode.

## Phase 4 — Feature StoryList (~2h)

**But :** tray fonctionnel, paginé, viewer pas encore câblé.

1. `Features/StoryList/StoryListViewModel.swift` :
   - `pages: [Story]`, `isLoading`, `isLoadingMore`, `loadingError`
   - `loadInitial()`, `loadMoreIfNeeded()` avec garde `isLoadingMore`
   - `shouldLoadMore(contentOffset:contentSize:containerSize:) -> Bool` (pure, testable)
   - prefetch avatars + premier item via `ImagePrefetchHandle`
   - lit `isSeen` du store pour calculer `isFullySeen` par story
2. `StoryListViewModelTests.swift` :
   - `shouldLoadMore` à différents états géométriques (avant N-3, à N-3, après)
   - pas de double-load (deux appels concurrents → une seule page chargée)
   - état d'erreur retryable (`isLoadingMore` repasse à false, retry possible)
   - état initial → skeleton
3. `Features/StoryList/StoryListView.swift` :
   - `ScrollView(.horizontal)` + `LazyHStack` de `StoryTrayItem`
   - skeleton tray sur état initial
   - `.onScrollGeometryChange(for: Bool.self)` → `viewModel.shouldLoadMore(...)`
   - skeleton trailing sur `isLoadingMore`, failure trailing sur erreur
   - `@Namespace` pour les `matchedTransitionSource`
4. *(retiré : suite snapshot abandonnée — les états de la liste sont exercés via `#Preview` dans `StoryListView.swift`.)*

**Gate :** l'app affiche le tray, scrolle, charge les pages 1/2/3, montre le skeleton pendant le chargement, le retry fonctionne sur erreur (forcer une erreur dans `FakeStoryRepository` pour vérifier visuellement). Tests verts.

## Phase 5 — StoryViewer : Playback + ViewerStateModel (~2h30)

**But :** moteur du viewer entièrement testé avant d'écrire la moindre View.

1. `Features/StoryViewer/PlaybackController.swift` :
   - `@Observable`, `progress`, `isPaused`, `onItemEnd`
   - `start()`, `pause()`, `resume()`, `reset()`
   - boucle `Task` + `clock.sleep(for: tickInterval)`, cancellation-aware
   - pause = flag respecté par la boucle, n'annule jamais le Task
2. `PlaybackControllerTests.swift` (avec `TestClock`) :
   - le tick fait avancer `progress` linéairement
   - pause stoppe l'avancement, resume reprend depuis l'offset
   - reset remet à 0
   - `onItemEnd` fire à 1.0
   - cancel propre au deinit
3. `Features/StoryViewer/ViewerStateModel.swift` (toute la surface décrite dans l'architecture) :
   - navigation : `nextItem/previousItem/nextUser/previousUser/dismiss`
   - seen marking : task 1.5s + branche tap-forward
   - like optimiste + `doubleTapLike` idempotent
   - immersive : `beginImmersive/endImmersive` synchros avec playback
   - drag : `updateDrag/endDrag/shouldCommitDismiss` (pure)
   - `pendingHeartPop` clear via `clock.sleep`
   - prefetch suivant
4. `ViewerStateModelTests.swift` (parametrized le plus possible) :
   - transitions next/prev item, next/prev user (incl. bornes)
   - dismiss à la fin du dernier user
   - `@Test(arguments:)` règle 1.5s : 0.5s/1.4s/1.5s/3.0s + branche tap-forward
   - like optimiste : flip avant complétion de `await store.toggleLike`
   - matrice `shouldCommitDismiss` (translation, velocity, container)
   - `updateDrag` pause + snap-back resume
   - `doubleTapLike` idempotent (déjà liked reste liked, pop refire)
   - `beginImmersive/endImmersive` ↔ `playback.isPaused` lockstep
   - `pendingHeartPop` cleared après la fenêtre d'animation (avancer le clock)

**Gate :** moteur du viewer entièrement testé, 100% des branches du seen rule + dismiss + double-tap couvertes. Aucune View écrite à ce stade.

## Phase 6 — StoryViewer : Views + gestures (~3h)

**But :** assembler le viewer sur le moteur déjà validé.

1. `Components/StoryViewerHeader.swift` (avec `#Preview` pour les variantes de timestamp recent / old).
2. `Components/StoryViewerFooter.swift` (LikeButton + éventuellement input field désactivé/skip).
3. `Components/StoryViewerPage.swift` :
   - `LazyImage` Nuke avec `onCompletion` → `.failed(retry:)`
   - frame d'échec (Surface, glyph, caption, Retry)
   - tap zones 1:2 (`ViewerTapZones`)
   - long-press → `beginImmersive/endImmersive`, conflict resolution > 8pt
   - double-tap → `doubleTapLike`, overlay heart-pop
   - drag-down → `updateDrag/endDrag`, scale + opacity bindées sur `dragProgress`
   - chrome conditionnellement opacifié sur `isImmersive`
4. `StoryViewerView.swift` :
   - paged `HStack` + `DragGesture` horizontal pour la nav user (parallax + scale + opacity selon `design.fr.md`)
   - axis lock à 12pt
   - `SegmentedProgressBar` lié à `playback.progress`
   - `.onChange(of: scenePhase)` → `playback.pause/resume`
   - `.onDisappear` → `await store.flushNow()`
   - `.navigationTransition(.zoom(sourceID:in:))`
5. Câblage `.fullScreenCover` depuis `StoryListView` au tap d'un item.
6. *(retiré : test snapshot de page viewer abandonné — le viewer complet est exercé via `#Preview` dans `StoryViewerView.swift`.)*

**Gate :** démo manuelle complète — transition zoom à l'ouverture, auto-advance, tap forward/back, long-press chrome hide, double-tap heart, swipe-down dismiss interactif, swipe horizontal user, scenePhase pause (Home → retour), persistance seen/like (kill app → relaunch).

## Phase 7 — Composition root + intégration (~45 min)

1. `App/StoriesApp.swift` selon le pattern exact de l'architecture : ViewModel optionnel `@State`, bootstrap via `.task`, fallback `EphemeralUserStateStore`.
2. `LoadingView` (24pt ProgressView sur Background).
3. Extension `Logger` dans `Core/`.
4. `Integration/StoryFlowIntegrationTests.swift` : load list → open user 3 → view 2 items → dismiss → assert seen.

**Gate :** l'app boot proprement, le test d'intégration passe.

## Phase 8 — Polish, README, vérifications finales (~1h30)

1. Vérifier la couverture **par target** (Domain ≥ 80%, ViewModels ≥ 80%) — afficher dans le README.
2. README : section *Polish skipped*, justifications des dépendances, version Xcode/simulateur pinnée, instructions de run.
3. Pass d'accessibilité : labels/values sur tous les éléments interactifs (cf. architecture § *Hooks d'accessibilité*).
4. Pass reduced-motion : forcer le toggle, vérifier que `Motion` collapse, transitions de ring instantanées.
5. Pass haptics manuel sur device si disponible.
6. `git log` propre — squash si besoin.

**Gate final :** `cmd-U` tout vert, app lancée OK en simulateur, README à jour.

## Estimation totale

~14h de travail focalisé. Tient sur 2 sessions denses ou 3 normales. La phase 5 (moteur testé avant View) est le pivot : si ça déraille là, tout le reste s'effondre — d'où le gate strict.

## Risques identifiés

- **`onScrollGeometryChange` + `LazyHStack` horizontal.** L'API est stable mais la dérivation `nearEnd` peut tirer trop tôt selon l'`itemExtent`. Plan B documenté : repli sur le dernier `StoryTrayItem.onAppear` si l'API se montre capricieuse en pratique.
- **`.navigationTransition(.zoom)` hors `NavigationStack`.** La combinaison avec `.fullScreenCover` est supportée mais à vérifier tôt (phase 6) ; si KO, repli sur `matchedGeometryEffect` (~30 lignes en plus, accepté en trade-off documenté).
- *(risque snapshot retiré en même temps que la suite — la revue visuelle pilotée par `#Preview` n'a aucun prérequis de déterminisme.)*
