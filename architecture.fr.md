# architecture.md

Architecture et décisions techniques pour le test BeReal Stories.

## Pattern architectural

**MVVM + Repository, modulaire par feature.** Pas de Clean Architecture intégrale, pas de TCA.

Rationale :
- TCA dans un test de 3 jours est risqué. C'est puissant mais introduit des concepts (reducers, effects, dependencies) qu'il faut savoir expliquer en revue. Si tu ne peux pas justifier chaque ligne, ça pénalise plus que ça n'aide.
- Clean Architecture (use cases, entities, interactors) est sur-dimensionnée à cette échelle et te ralentit.
- MVVM avec `@Observable` est le standard SwiftUI moderne, bien compris, et te laisse te concentrer sur la finition UX et les tests.

## Structure de dossiers

```
Stories/
├── App/
│   └── StoriesApp.swift              // entry, composition root
│
├── Features/
│   ├── StoryList/
│   │   ├── StoryListView.swift
│   │   └── StoryListViewModel.swift
│   │
│   └── StoryViewer/
│       ├── StoryViewerView.swift
│       ├── ViewerStateModel.swift          // quel user/item, seen, like, dismiss
│       ├── PlaybackController.swift        // timer, progress, pause/resume
│       └── Components/
│           ├── StoryViewerPage.swift
│           ├── StoryViewerHeader.swift
│           └── StoryViewerFooter.swift
│
├── Domain/
│   ├── Models/
│   │   ├── User.swift
│   │   ├── Story.swift
│   │   ├── StoryItem.swift
│   │   └── UserState.swift
│   └── Repositories/
│       ├── StoryRepository.swift         // protocol
│       └── UserStateRepository.swift     // protocol
│
├── Data/
│   ├── LocalStoryRepository.swift        // actor, JSON + pagination
│   ├── PersistedUserStateStore.swift     // actor, FileManager + debounce
│   ├── EphemeralUserStateStore.swift     // actor, fallback en mémoire (prod-safe)
│   ├── ImageLoader.swift                 // configuration du pipeline Nuke
│   ├── ImagePrefetchHandle.swift         // durée de vie de prefetch scopée à un écran
│   └── Resources/
│       └── stories.json
│
├── DesignSystem/
│   ├── Tokens/
│   │   ├── Colors.swift
│   │   ├── Typography.swift
│   │   └── Spacing.swift
│   └── Components/
│       ├── StoryRing.swift
│       ├── StoryAvatar.swift
│       ├── StoryTrayItem.swift           // compose StoryAvatar + label
│       ├── SegmentedProgressBar.swift
│       └── LikeButton.swift
│
└── Core/
    ├── Extensions/
    └── Haptics.swift

StoriesTests/
├── Unit/
│   ├── PersistedUserStateStoreTests.swift
│   ├── LocalStoryRepositoryTests.swift
│   ├── StoryListViewModelTests.swift
│   ├── PlaybackControllerTests.swift
│   └── ViewerStateModelTests.swift
├── Integration/
│   └── StoryFlowIntegrationTests.swift
└── TestSupport/
    ├── FakeStoryRepository.swift
    └── InMemoryUserStateStore.swift
```

## Responsabilités par couche

### App
Composition root. Construit les repositories, stores, ImageLoader. Les injecte dans le ViewModel racine. Configure Nuke une seule fois.

### Domain
Données et protocoles purs. Zéro import au-delà de Foundation. Pas de SwiftUI, pas de Nuke. C'est ce qui rend le codebase testable et portable.

### Features
MVVM par feature. La View consomme un ViewModel `@Observable` via `@Bindable`. Le ViewModel est `@MainActor`. Le ViewModel appelle dans des protocoles (StoryRepository, UserStateRepository), jamais dans des classes concrètes.

### Data
Implémentations concrètes. Chaque repository est un `actor` pour fournir la thread-safety par design du langage plutôt que par convention. Le chargement d'images est wrappé, pas exposé directement.

### DesignSystem
Pas de logique métier. Tokens + composants réutilisables. Indépendamment previewables. Pourrait être extrait en Swift Package dans un vrai projet (c'est la couche la plus naturellement réutilisable) ; voir *Modularité : pourquoi pas de SPM* plus bas pour le trade-off.

### Core
Helpers transverses. Haptiques, extensions. Garder petit.

## Modèle de concurrence

Swift 6 strict concurrency mode activé. C'est délibéré : ça force la correction au compile time et signale une fluence senior.

**Default Actor Isolation = MainActor** activé dans les build settings (Xcode 16+ / SwiftPM). Conséquence : tout le code non annoté du module est implicitement `@MainActor`. Les ViewModels ne portent donc pas de `@MainActor` explicite — ils l'héritent du module, comme les `View` SwiftUI l'héritent déjà du protocole `View` sous iOS 18. Seuls les types qui *dérogent* à ce défaut (les `actor` de la couche Data) ou qui rendent l'isolation explicite à cause d'une contrainte externe (`ImagePrefetchHandle`, parce que Nuke 12 marque `ImagePrefetcher` comme `@MainActor`) portent une annotation. Écrire `@MainActor` partout sur un projet iOS 18 / Swift 6 ressemble à du code Swift 5 strict porté tel quel — l'omission est le signal moderne.

```
Repositories          actor, les protocoles sont Sendable
State stores          actor, les protocoles sont Sendable
ViewModels            MainActor par défaut du module (annotation inutile)
Models                Sendable (struct + Codable + Hashable)
Image loader          pipeline Nuke configuré au démarrage de l'app ; les prefetch handles sont @MainActor (contrainte Nuke)
Tasks                 structured concurrency uniquement ; pas de DispatchQueue
Clock                 any Clock<Duration> injecté — ContinuousClock en prod, TestClock en tests
Timer                 Task + clock.sleep, jamais Timer.scheduledTimer, jamais Task.sleep direct
```

Les protocoles dont les instances sont partagées entre actors (ici : un ViewModel `MainActor` qui détient une référence vers un repository `actor`) sont déclarés `Sendable`. Cela force chaque conformeur à prouver qu'il peut être transféré safement entre contextes d'isolation — automatique pour un `actor`, explicite pour une `class` :

```swift
protocol StoryRepository: Sendable {
    func loadPage(_ pageIndex: Int) async throws -> [Story]
}

protocol UserStateRepository: Sendable {
    func markSeen(itemID: String) async
    func toggleLike(itemID: String) async -> Bool
    func isSeen(_ id: String) async -> Bool
    func isLiked(_ id: String) async -> Bool
    func flushNow() async    // force-flush du debounce en attente ; appelé sur background/dismiss
}
```

Pattern ViewModel — l'état du viewer est éclaté en deux collaborateurs plutôt qu'un gros `StoryViewerViewModel`. Le découpage suit la ligne de fracture naturelle : la progression time-driven d'un côté, la navigation/state user-driven de l'autre. Chacun est testable en isolation ; la View bind sur les deux.

```swift
// PlaybackController — possède le timer et la progression 0...1 de l'item courant.
// Ne sait rien de quel item est courant, qui est l'utilisateur, ni comment dismiss.
// MainActor hérité du default isolation du module ; pas d'annotation explicite.
@Observable
final class PlaybackController {
    private(set) var progress: Double = 0
    private(set) var isPaused = false

    var onItemEnd: (() -> Void)?    // câblé par ViewerStateModel ; MainActor par défaut du module

    private let clock: any Clock<Duration>
    private let itemDuration: Duration
    private let tickInterval: Duration = .milliseconds(50)   // 20 Hz : matche un update de progress bar smooth sans cramer le CPU ; 100 ticks par item de 5s
    private var task: Task<Void, Never>?

    init(clock: any Clock<Duration> = ContinuousClock(), itemDuration: Duration = .seconds(5)) { ... }

    func start() { ... }   // reset progress, lance la tick task
    func pause()  { isPaused = true }
    func resume() { isPaused = false }
    func reset()  { progress = 0 }   // appelé au changement d'item
}
```

```swift
// ViewerStateModel — possède la navigation, le seen, le like, le dismiss,
// et l'état transient des gestes (immersive, drag offset, heart pop).
// Pilote PlaybackController ; réagit à son `onItemEnd` pour avancer.
// MainActor hérité du default isolation du module ; pas d'annotation explicite.
@Observable
final class ViewerStateModel {
    private(set) var currentUserIndex: Int
    private(set) var currentItemIndex = 0
    private(set) var isLiked = false
    private(set) var shouldDismiss = false

    // État transient piloté par les gestes (la View bind là-dessus ; pure data, pas de types SwiftUI)
    private(set) var isImmersive = false              // chrome-hide du long-press
    private(set) var dragOffset: CGFloat = 0          // translation du swipe-down
    private(set) var dragProgress: Double = 0         // 0...1 progression du dismiss
    private(set) var pendingHeartPop: HeartPop?       // overlay double-tap ; nettoyé par tâche clock

    let playback: PlaybackController

    private let users: [Story]
    private let stateStore: any UserStateRepository
    private let clock: any Clock<Duration>
    private var seenMarkTask: Task<Void, Never>?
    private var heartPopClearTask: Task<Void, Never>?

    init(
        users: [Story],
        startUserIndex: Int,
        stateStore: any UserStateRepository,
        clock: any Clock<Duration> = ContinuousClock(),
        playback: PlaybackController? = nil
    ) {
        // construit playback s'il n'est pas injecté ; câble onItemEnd à nextItem()
    }

    func toggleLike()       { ... }       // update optimiste (bouton du footer)
    func doubleTapLike(at point: CGPoint) { ... }  // passe isLiked = true (idempotent), schedule pendingHeartPop
    func nextItem()         { ... }       // tap-forward explicite marque aussi seen maintenant
    func previousItem()     { ... }
    func nextUser()         { ... }
    func previousUser()     { ... }
    func dismiss()          { shouldDismiss = true }
    func onItemDidStart()   { ... }       // schedule seenMarkTask après 1.5s

    // Immersive (long-press)
    func beginImmersive()   { isImmersive = true; playback.pause() }
    func endImmersive()     { isImmersive = false; playback.resume() }

    // Swipe-down dismiss (drag-driven)
    func updateDrag(translationY: CGFloat, containerHeight: CGFloat)  { ... }
    func endDrag(translationY: CGFloat, velocityY: CGFloat, containerHeight: CGFloat) { ... }

    // Prédicat pur, unit-testable sans une View (miroir de shouldLoadMore)
    func shouldCommitDismiss(translationY: CGFloat, velocityY: CGFloat, containerHeight: CGFloat) -> Bool { ... }
}

struct HeartPop: Sendable, Equatable {
    let id: UUID
    let location: CGPoint
}
```

La règle du seen vit entièrement dans `ViewerStateModel` : à l'item-start, il schedule une tâche de 1.5s via le clock injecté ; si l'item est toujours courant après 1.5s OU si `nextItem()` se déclenche avant, il persiste `markSeen`. Annuler la tâche au changement d'item drop le mark pour les items que l'utilisateur a power-skimés en <1.5s sans avancer explicitement.

`PlaybackController.task` est le timer. Cancel + restart à chaque transition. Toujours cancellation-aware (`try Task.checkCancellation()` entre les sleeps). Pause flippe un flag que la boucle de tick respecte sans cancel la tâche — donc resume reprend depuis le même offset sans reconstruire l'état.

### Injection du Clock — pourquoi c'est important

Un timer basé sur `Task.sleep` est non-déterministe en tests : asserter "après 5s, currentItemIndex == 1" force des attentes en temps réel, ce qui rend la suite lente et flaky. En injectant `any Clock<Duration>` :

- Production : `ContinuousClock()` tick en wall time.
- Tests : un `TestClock` (custom ou style `swift-clocks`) avance à la demande. Les tests assertent "avance le clock de 5s, puis attend index == 1" sans aucun sleep réel.

Cela débloque les test plans de `PlaybackController` et `ViewerStateModel` listés dans CLAUDE.md (avance des ticks, pause/resume préserve la progression, scenePhase pause stoppe et reprend depuis l'offset, marquage seen respecte le seuil 1.5s, next/prev item, dismiss-on-end) comme des tests unitaires rapides et déterministes.

## Flux de données

```
View
  ↑ observe
@Observable ViewModel  (@MainActor)
  ↓ appelle
Protocoles Repository
  ↓ implémenté par
actor LocalStoryRepository / PersistedUserStateStore
  ↓ utilise
FileManager / Bundle / URLCache (via Nuke)
```

Actions utilisateur :
1. La View dispatch un intent (`viewModel.toggleLike()`).
2. Le ViewModel met à jour l'état `@Observable` immédiatement (optimiste).
3. Le ViewModel appelle dans le repository actor (`await store.toggleLike(itemID:)`).
4. Le repository persiste, finit par flush sur disque via debounce.

## Design de la persistence

`PersistedUserStateStore` est un actor avec la forme suivante :

```swift
actor PersistedUserStateStore: UserStateRepository {
    private var state: UserState
    private let fileURL: URL
    private var pendingFlush: Task<Void, Never>?

    init(fileURL: URL) async throws {
        // load existant ou crée vide
    }

    func markSeen(itemID: String) {
        state.seenItemIDs.insert(itemID)
        scheduleFlush()
    }

    func toggleLike(itemID: String) -> Bool {
        let now = !state.likedItemIDs.contains(itemID)
        if now { state.likedItemIDs.insert(itemID) }
        else { state.likedItemIDs.remove(itemID) }
        scheduleFlush()
        return now
    }

    func isSeen(_ id: String) -> Bool { state.seenItemIDs.contains(id) }
    func isLiked(_ id: String) -> Bool { state.likedItemIDs.contains(id) }

    private func scheduleFlush() {
        pendingFlush?.cancel()
        pendingFlush = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    private func flush() {
        // Snapshot l'état à l'entrée du flush. Entre le Task.sleep awaité et
        // ici, des mutations peuvent être arrivées ; encoder `self.state` est
        // safe *parce qu'on est dans l'actor*, mais on ne doit pas yield (pas
        // d'await) entre le snapshot et l'écriture disque pour éviter d'écrire
        // un état partiel mid-mutation.
        let snapshot = state
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            Logger.persistence.error("Flush failed: \(error)")
        }
    }
}
```

Discipline de re-entrance :
- `flush` tourne sur l'actor et ne fait jamais d'`await` mid-write. Le snapshot + l'atomic write se passent dans un seul tour d'actor (`JSONEncoder().encode` et `Data.write(to:options:)` sont tous deux synchrones), donc les mutations queuées pendant le flush attendent leur tour proprement.
- `pendingFlush` capture `[weak self]` pour qu'un store désalloué ne maintienne pas en vie sa propre tâche.
- **Pas de flush dans `deinit`.** Le `deinit` d'un `actor` ne peut pas hopper de manière fiable sur son executor pour lire `state`, et un `Task.detached` depuis le `deinit` ferait la course avec la désallocation. À la place, la View appelle `await store.flushNow()` depuis le `.onDisappear` du viewer racine quand on retransitionne vers la liste, et `ScenePhaseObserver` l'appelle sur `.background`. La fenêtre de debounce de 500 ms est le pire cas documenté de perte d'état sur un kill brutal. Ce trade-off est dans la table *Design de la persistence* et le README.

Pourquoi un actor :
- Plusieurs ViewModels lisent/écrivent en concurrence (la list et le viewer peuvent tous deux query/update).
- Les race conditions sur `Set<String>` sont réelles et silencieuses.
- Un actor rend ça impossible par construction.

Pourquoi un fichier JSON (pas SwiftData / UserDefaults) :
- **UserDefaults** : ergonomique mais pas de garanties de concurrence, awkward pour les collections, pas d'écritures atomiques.
- **SwiftData** : lourd pour `Set<String>`. Ajoute une couche de modèle pour aucun gain.
- **Codable JSON + actor** : précis, rapide pour notre taille de données (<1 KB), trivialement testable avec un répertoire temp, atomique via `Data.write(to:options: [.atomic])`.

Pourquoi le debounce :
- Un user ouvre le viewer, marque seen, scrolle 5 stories : 5 écritures disque en 5 secondes c'est du gaspillage.
- Un debounce de 500 ms coalesce les bursts. Trade-off : 500 ms de perte d'état max sur un kill d'app. Acceptable.

## Stratégie de pagination

Le spec dit "infini même si les données se répètent". `LocalStoryRepository` :

```swift
actor LocalStoryRepository: StoryRepository {
    private let baseStories: [Story]   // chargé depuis le JSON une fois
    private let pageSize = 10

    func loadPage(_ pageIndex: Int) async throws -> [Story] {
        let n = baseStories.count
        guard n > 0 else { return [] }
        return (0..<pageSize).map { i in
            let base = baseStories[(pageIndex * pageSize + i) % n]
            return base.withPageSuffix(pageIndex)   // suffixe story.id et item.ids
        }
    }
}
```

Le suffixage des IDs est critique : il garantit que l'état seen/liked pour `alice-p0` est distinct de `alice-p1`, sinon marquer page-1-Alice seen marquerait page-2-Alice seen.

Cas limites que la formule couvre explicitement :
- `n == 7`, `pageSize == 10`, `pageIndex == 0` → indices `0,1,2,3,4,5,6,0,1,2`. Le même user apparaît deux fois sur la page 0 mais avec le *même* suffixe de page `-p0`, donc l'état seen est partagé à l'intérieur de la page (acceptable — les répétitions ne deviennent indépendantes qu'entre pages).
- `pageIndex == 1` avec `n == 7` → indices `3,4,5,6,0,1,2,3,4,5`, tous suffixés `-p1`, totalement indépendants de la page 0.
- `n == 0` → page vide, le ViewModel surface un empty-state au lieu de boucler.

`Story.withPageSuffix(_:)` réécrit à la fois `story.id` (`"alice"` → `"alice-p1"`) et chaque `StoryItem.id` (`"alice-1"` → `"alice-1-p1"`). Les URLs d'images ne sont *pas* re-seedées — le même user doit montrer les mêmes images entre pages (hard rule de CLAUDE.md sur la stabilité).

Le ViewModel déclenche `loadPage(currentPage + 1)` quand l'utilisateur est à 3 items de la fin du contenu chargé. Garde via un flag `isLoadingMore` pour empêcher les double-loads. Une page qui échoue à charger surface une erreur non-bloquante et laisse `isLoadingMore = false` pour qu'un futur scroll retry (voir *Gestion d'erreur*).

Le trigger est câblé via `onScrollGeometryChange(for:of:action:)` d'iOS 18, qui expose `contentOffset`, `contentSize` et `containerSize` en temps réel — pas de plomberie `GeometryReader` + `PreferenceKey`, et pas de dépendance au `onAppear` d'une cellule "sentinelle" (qui est fragile sous le recyclage de cellules et se déclenche au re-entry sur scroll arrière). Le prédicat "near end" est une fonction pure sur le ViewModel pour que le test plan le couvre directement sans View :

```swift
// MainActor hérité du default isolation du module ; pas d'annotation explicite.
@Observable
final class StoryListViewModel {
    private(set) var pages: [Story] = []
    private(set) var isLoadingMore = false
    private let pageSize = 10
    private let triggerOffset = 3                          // N-3

    /// Fonction pure : true quand le viewport visible est à `triggerOffset`
    /// items de la fin du contenu chargé. Les inputs viennent directement de
    /// `ScrollGeometry` ; pas de types SwiftUI impliqués, donc les tests
    /// passent des géométries synthétiques et assertent le flag sans démarrer
    /// une View.
    func shouldLoadMore(contentOffset: CGFloat, contentSize: CGFloat, containerSize: CGFloat) -> Bool {
        guard contentSize > containerSize else { return false }
        let itemExtent = contentSize / CGFloat(max(pages.count, 1))
        let distanceToEnd = contentSize - (contentOffset + containerSize)
        return distanceToEnd < itemExtent * CGFloat(triggerOffset)
    }
}
```

La View devient un fin forwardeur :

```swift
ScrollView(.horizontal) { /* ... */ }
    .onScrollGeometryChange(for: Bool.self) { geo in
        viewModel.shouldLoadMore(
            contentOffset: geo.contentOffset.x,
            contentSize: geo.contentSize.width,
            containerSize: geo.containerSize.width,
        )
    } action: { _, nearEnd in
        if nearEnd { Task { await viewModel.loadMoreIfNeeded() } }
    }
```

Cela restaure la règle "pas de logique métier dans les Views" pour le trigger de pagination — dans l'idiome iOS 17 (`onAppear` sur une cellule sentinelle ou tracking d'offset roulé à la main via `GeometryReader` + `PreferenceKey`), la décision "should load" était structurellement intriquée avec le lifecycle de la View et ne pouvait pas être unit-testée sans scaffolding UI.

## Chargement d'images

`Nuke` est la seule dépendance runtime. Justification (pour le README) :

> Nuke gère le fetch HTTP des images, le caching multi-tier (memory + disk), le prefetch et la décompression. Aucun de ces aspects n'est la feature évaluée. Les implémenter à la main consommerait du temps mieux investi sur l'UX et les tests, pour un résultat de moindre qualité qu'une lib battle-tested utilisée par les apps iOS majeures. L'alternative `AsyncImage` n'a ni cache disque, ni prefetch, ni cancellation fiable, ce qui la rend inadaptée à une feature Stories de qualité production.

Wrapper :

```swift
enum ImageLoader {
    static func configure() {
        // Configure le pipeline Nuke une fois au démarrage de l'app (taille
        // du memory cache, TTL du disk cache, timeouts du DataLoader).
    }
}

// Tenu par les ViewModels pour la durée de vie d'un écran ; cancel sur deinit.
// Marqué @MainActor parce que ImagePrefetcher de Nuke est @MainActor en Nuke 12+.
@MainActor
final class ImagePrefetchHandle {
    private let prefetcher = ImagePrefetcher()

    func prefetch(_ urls: [URL]) {
        prefetcher.startPrefetching(with: urls)
    }

    func cancel() {
        prefetcher.stopPrefetching()
    }

    deinit {
        // Le propre deinit d'ImagePrefetcher cancel les prefetches in-flight ;
        // pas d'appel supplémentaire nécessaire ici, et on ne peut de toute
        // façon pas hopper sur MainActor depuis deinit.
    }
}
```

Pourquoi `@MainActor` et pas `Sendable` : Nuke 12 annote `ImagePrefetcher` comme `@MainActor`. Stamper `Sendable` sur un wrapper qui tient une property `@MainActor`-isolée nécessiterait soit `@unchecked Sendable` (mentir au compilateur), soit casserait la compilation sous Swift 6. Confiner le handle à `MainActor` est le choix honnête — et les ViewModels sont déjà `@MainActor`, donc les appels dans le handle ne traversent pas de hops d'actor.

Utiliser la View SwiftUI `LazyImage` de Nuke directement dans les composants design. Le wrapper existe uniquement pour (1) centraliser une configuration de pipeline one-shot et (2) tenir un prefetch handle dont la durée de vie est liée à un écran — toutes deux sont de vraies responsabilités, aucune ne fait fuiter les types Nuke dans le Domain.

Stratégie URL : `https://picsum.photos/seed/{stableSeed}/1080/1920` pour le contenu story, `/200/200` pour les avatars. Le param `seed` garantit la stabilité — même URL → même image — ce qui satisfait le "user a le même contenu à chaque fois" du spec.

## Gestion d'erreur & logging

Les erreurs sont typées à la frontière du domaine et jamais throw aveuglément à la View.

```swift
enum StoryError: Error, Sendable {
    case bundleResourceMissing(name: String)
    case decodingFailed(underlying: Error)
    case persistenceUnavailable(underlying: Error)
    case pageOutOfRange
}
```

Stratégie :
- Les **repositories** throw `StoryError`. Ils ne throw jamais de `DecodingError` ou `CocoaError` brut aux couches supérieures.
- Les **ViewModels** catch et traduisent en état affichable : un `loadingError: String?` (ou un petit enum retryable vs fatal) consommé par la View. Les ViewModels ne re-throw jamais à la View.
- Les **Views** rendent une erreur inline discrète avec tap-to-retry. Deux surfaces, selon l'origine de l'erreur :
  - **Erreur de pagination** (`loadPage` qui échoue) → la slot trailing du tray devient un `StoryTrayItem(.failed(retry:))` (glyphe d'avertissement + label "Retry", voir `design.md` § *États de loading & d'empty*). Même largeur et hauteur qu'un item normal, donc la géométrie du tray ne reflow jamais.
  - **Erreur fatale niveau liste** (JSON corrompu, repository indisponible au premier load, pas de `pages` à rendre) → empty-state plein écran sous le chrome de navigation (toujours visible), avec le même glyphe d'avertissement et un seul bouton "Retry". C'est le seul cas où le tray lui-même n'est pas rendu.
  - **Erreur niveau viewer** (échec de chargement d'image sur l'item courant) → voir *UI d'échec image* plus bas ; géré dans le chrome immersif, jamais comme une view séparée.
  Pas de dialogues d'alerte nulle part — ils cassent le feel immersif des Stories.

Le logging utilise `os.Logger`, un logger par subsystem :

```swift
private let subsystem = Bundle.main.bundleIdentifier ?? "Stories"

extension Logger {
    static let app         = Logger(subsystem: subsystem, category: "app")
    static let viewer      = Logger(subsystem: subsystem, category: "viewer")
    static let list        = Logger(subsystem: subsystem, category: "list")
    static let persistence = Logger(subsystem: subsystem, category: "persistence")
    static let images      = Logger(subsystem: subsystem, category: "images")
}
```

Le subsystem est dérivé du bundle identifier du candidat lui-même (e.g. `com.<candidat>.Stories`) — pas le namespace BeReal, ce qui ressemblerait à du squatting de bundle-ID en revue.

Discipline :
- `.debug` pour les transitions d'état (item start, like toggle), strippé des release builds par `Logger`.
- `.error` pour les exceptions caught et les fallbacks de corruption. Toujours logger avant d'avaler.
- Pas de `print`. Pas de dépendance de logging tierce.
- Les valeurs loggées sont non-PII (les IDs d'items sont synthétiques, les URLs sont des URLs picsum publiques).

C'est la couture où l'analytics se brancherait dans un vrai produit — un protocole `Tracker` injecté à côté du `Logger`. Hors scope ici ; mentionné dans le README.

## Lifecycle, prefetch & chemin de persistence

### scenePhase

Hard rule de CLAUDE.md : le timer se met en pause quand la scène n'est pas `.active`. Câblé à la couche View parce que `@Environment(\.scenePhase)` est une environment value SwiftUI :

```swift
struct StoryViewerView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var state: ViewerStateModel

    var body: some View {
        content
            .onChange(of: scenePhase) { _, phase in
                phase == .active ? state.playback.resume() : state.playback.pause()
            }
    }
}
```

La View est la seule couche qui connaît `scenePhase`, et elle pilote `playback` directement — `ViewerStateModel` n'a pas besoin d'un `pause()`/`resume()` pass-through puisque `playback` est publiquement accessible. Les deux collaborateurs restent agnostiques au framework pour les tests.

### Prefetch

`StoryListViewModel` et `ViewerStateModel` possèdent chacun un `ImagePrefetchHandle` (défini dans *Chargement d'images*) pour la durée de vie de l'écran et pilotent le prefetch sur les changements d'état :

- **List** : quand une page charge, prefetch les URLs d'avatars de la page plus la *première* image de l'item story de chaque user.
- **Viewer** : quand le user courant change (swipe horizontal dans le `HStack` paginé), prefetch l'URL du premier item story du user suivant. Quand `currentItemIndex` avance dans un user, prefetch l'URL de l'item suivant.

```swift
// Inside ViewerStateModel
private let prefetch = ImagePrefetchHandle()

func nextUser() {
    // ...avance l'index...
    prefetch.prefetch(urlsForUser(at: currentUserIndex + 1))
}
```

Comme `ImagePrefetchHandle` est `@MainActor` et que les ViewModels sont `@MainActor`, les appels sont directs sans hop d'actor. Deux handles (List + Viewer) qui tournent simultanément sur des URLs qui se chevauchent est sans danger : Nuke déduplique par clé de cache `ImageRequest`, donc le second `startPrefetching` est un no-op pour les entrées in-flight ou cachées. Chaque handle continue de canceller ses propres prefetches en cours quand son ViewModel propriétaire est désalloué, scopant la bande passante à l'écran qui en avait besoin.

### Emplacement du fichier de persistence

L'état vit dans `Application Support/`, *pas* dans `Documents/` :
- `Documents/` est exposé à Files.app et au backup iCloud Document — sémantique fausse pour de l'état app opaque.
- `Caches/` est purgeable par l'OS — on perdrait l'état seen/liked silencieusement.
- `Application Support/` est l'emplacement documenté pour de l'état privé d'app et persiste entre les launches.

```
~/Library/Application Support/Stories/state.json
```

Le répertoire est créé au premier lancement. L'URL du fichier set `URLResourceValues.isExcludedFromBackup = true` : bien qu'`Application Support/` soit inclus dans les backups device par défaut, cet état est reproductible (une fresh install démarre vide et se reconstruit organiquement), donc dépenser de la bande passante iCloud dessus serait du gaspillage.

Récupération sur corruption : si `JSONDecoder` throw à l'init, le store log `.error`, supprime le fichier, et démarre vide. Le fallback est préférable au crash au launch.

## Navigation

```
NavigationView                        ← non utilisé
.fullScreenCover(isPresented:)        ← utilisé pour le viewer
HStack paginé + offset (custom)       ← utilisé dans le viewer pour la pagination user
.matchedTransitionSource +            ← utilisé pour la zoom transition
.navigationTransition(.zoom)             tray-avatar → viewer-header (iOS 18)
```

Rationale :
- Le viewer est une expérience modale, pas une destination navigable. `.fullScreenCover` matche le comportement d'Instagram (slide up, bloque la navigation, dismiss au geste).
- La pagination user est un `HStack` paginé hand-rolled + `offset` piloté par un `DragGesture`, **pas** `TabView(.page)`. La transition custom (parallax + scale + opacity, voir `design.md` § *Animations spécifiques → Swipe entre users*) n'est pas exprimable via le page style de `TabView`, et le geste doit rester interruptible en plein vol quand l'utilisateur inverse la direction — `TabView` snap à la page la plus proche au release et ignore le drag en cours. L'implémentation tient en ~80 lignes de `GeometryReader` + arithmétique d'offset et est unit-testable via le même modèle d'état drag que le swipe-down dismiss.

### Zoom transition tray-avatar → viewer

L'avatar du tray est marqué comme source de transition avec un identifiant de namespace stable (l'ID stable du user, pas l'ID suffixé par page — l'élément visuel est la même personne entre les répétitions de page) :

```swift
@Namespace private var trayNamespace

StoryAvatar(user: user)
    .matchedTransitionSource(id: user.stableID, in: trayNamespace)
    .onTapGesture { viewModel.openViewer(at: index) }
```

Le viewer adopte la destination matching via `.navigationTransition(.zoom(sourceID:in:))`. L'animation est la même primitive que Photos.app utilise sur iOS 18 — elle interpole le frame, le scale et le corner radius de la View nativement, avec un dismiss interactif intégré. L'idiome iOS 17 précédent était `matchedGeometryEffect` à travers deux hiérarchies de view séparées par `.fullScreenCover`, ce qui est techniquement possible mais visiblement imparfait (flicker single-frame à la frontière, désynchronisation de layout pass au dismiss, pas de dismiss interactif natif). L'API native enlève à la fois le flicker et ~30-50 lignes de code de compensation, et c'est l'un des petits points de polish que les reviewers ressentent sans qu'on ait à leur dire de le chercher.

Reduced-motion : quand `accessibilityReduceMotion` est on, le zoom collapse en cross-fade automatiquement — pas de wiring supplémentaire nécessaire. Vérifié via la stratégie de tokens `Motion` dans `design.md`.

## Gestures & UI d'échec

### Zones de tap (split vertical 1:2)

Hard rule de CLAUDE.md : la page viewer est splittée en deux zones verticales — tiers gauche = previous, deux tiers droits = next. L'asymétrie matche Instagram et reflète que *forward* est l'action dominante ; en faire la cible la plus grande est une amélioration Fitts-law, pas un choix stylistique.

```swift
struct ViewerTapZones: View {
    let onPrevious: () -> Void
    let onNext: () -> Void

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                Color.clear
                    .frame(width: geo.size.width / 3)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onPrevious)
                    .accessibilityLabel("Previous")
                    .accessibilityAddTraits(.isButton)

                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onNext)
                    .accessibilityLabel("Next")
                    .accessibilityAddTraits(.isButton)
            }
        }
        .allowsHitTesting(true)
    }
}
```

Les zones vivent au-dessus de l'image et en dessous de l'UI interactive (bouton close du header, bouton like) en utilisant le z-order SwiftUI. Elles sont cachées de VoiceOver en tant que boutons (pas en tant que zones de tap) pour que les utilisateurs de screen reader aient des affordances explicites.

### Long-press (chrome hide + pause)

`LongPressGesture(minimumDuration: 0.2)` attaché à la page. Sur `onChanged`/`onEnded` la View bascule `state.isImmersive` (un flag `@MainActor` sur `ViewerStateModel`) ; le header, le footer, la progress bar et les affordances des zones de tap sont rendus conditionnellement avec une transition d'opacité via `Motion.fast`. L'image reste à pleine opacité tout du long — seule la chrome se cache.

Résolution de conflit du long-press : un long-press qui détecte une translation > 8pt dans n'importe quelle direction pendant sa fenêtre de grâce est annulé et le touch est routé vers le `DragGesture` environnant (user-swipe horizontal ou dismiss vertical). C'est câblé via `simultaneousGesture` + `exclusively(before:)` pour qu'un swipe qui commence comme une pression lente ne bloque jamais l'utilisateur du dismiss. `ViewerStateModel.beginImmersive()` / `endImmersive()` sont les deux intents que la View appelle ; les deux pilotent aussi `playback.pause()` / `playback.resume()`.

### Double-tap like (heart pop)

`TapGesture(count: 2)` vit sur la zone des deux tiers droits aux côtés du handler single-tap "next". L'arbitrage de gestes SwiftUI ne déclenche le single-tap que si le double-tap échoue à matcher — donc les deux ne se collisionnent jamais et il n'y a pas de délai perceptible sur le single-tap (le système utilise la fenêtre double-tap de la plateforme, ~0.25s).

Le double-tap dispatche `state.doubleTapLike(at: CGPoint)` ; le ViewModel expose `pendingHeartPop: HeartPop?` (un value type `Sendable` portant la position du tap et un ID unique) que la View observe et rend en overlay. L'overlay anime selon la spec design (scale 0 → 1.4 → 1.0, fade in/out sur `Motion.standard`) et reset `pendingHeartPop` à `nil` à la fin via une `Task` schedulée sur le clock injecté — ce qui garde le cleanup déterministe et unit-testable.

Important : le double-tap-like est **idempotent vers "liked"**, pas un toggle. Un deuxième double-tap sur un item déjà liké déclenche quand même le heart pop (pour que le geste reste toujours réactif) mais ne un-like pas. Le un-like n'est disponible que via le `LikeButton` du footer. Cela matche Instagram et évite le foot-gun "j'ai tapé deux fois rapidement et j'ai annulé mon like par accident".

### Swipe-down dismiss vertical (interactif)

Un `DragGesture(minimumDistance: 10)` sur la page pilote `state.dragOffset: CGFloat` et `state.dragProgress: Double` (0...1), mis à jour à chaque `onChanged`. La View bind :
- Le `.scaleEffect` de l'image à `1.0 - dragProgress * 0.15`
- Le `.opacity` du background du viewer à `1.0 - dragProgress`
- Le playback est mis en pause au premier `onChanged` non nul et reprend uniquement au snap-back

`onEnded` appelle `state.endDrag(translation:velocity:)` qui décide entre dismiss (commit, déclenche `shouldDismiss = true`) et snap-back (reset `dragOffset` avec les tokens spring de `design.md`). Les deux branches utilisent `withAnimation(Motion.standard)` depuis la View ; le ViewModel ne mute que de l'état brut.

Ce découpage garde la logique de seuil (translation > 30% du container OU velocity > 800pt/s) dans `ViewerStateModel` comme une fonction pure `func shouldCommitDismiss(translationY:velocityY:containerHeight:) -> Bool`, unit-testable sans une View — même pattern que `StoryListViewModel.shouldLoadMore`.

### Swipe horizontal entre users

Le `HStack` paginé custom dans le viewer (voir *Navigation*) attache son propre `DragGesture` pour le user-swipe. Désambiguation horizontal-vs-vertical : un drag est verrouillé sur son axe après les premiers 12pt de translation en comparant `|translation.x|` à `|translation.y|` — le plus grand axe gagne, le handler de geste ignore le mouvement sur l'autre axe jusqu'au release. Cela empêche un drag presque diagonal de déclencher à la fois un user-swipe et un dismiss.

### UI d'échec image

Hard rule de CLAUDE.md : les images d'items qui échouent rendent un frame d'échec visible, pas un placeholder silencieux. Le frame est teinté `Surface`, montre une petite icône + caption "Couldn't load this story", et expose un bouton `Retry`. Tant que le frame d'échec est à l'écran, `PlaybackController` est en pause (l'utilisateur doit agir) ; le tap-forward continue de naviguer vers l'item suivant.

Câblage :
- `StoryViewerPage` lit l'état de chargement depuis le callback `LazyImage` de Nuke (`onCompletion`) et forwarde `.failed(retry:)` à `ViewerStateModel`.
- `ViewerStateModel` appelle `playback.pause()` à l'entrée dans l'état d'échec et `playback.resume()` + `playback.reset()` au succès du retry.
- Le chemin retry pousse Nuke à drop la réponse en échec cachée (`pipeline.cache.removeCachedImage(for:)`) avant de re-requester, sinon l'échec caché court-circuite le retry.

C'est le seul endroit où une erreur est surfaced dans le chrome immersif du viewer. Les erreurs de pagination et de persistence restent dans la list (voir *Gestion d'erreur*).

## Injection de dépendance

Pas de container. Constructor injection uniquement. Composition root dans `StoriesApp.swift`.

`PersistedUserStateStore.init` est `async throws` (il charge ou crée le fichier JSON), donc il ne peut pas être appelé depuis `App.init`. Pattern : tenir le ViewModel racine comme `@State` optionnel, l'hydrater depuis un `.task` sur la View racine, et afficher un état de loading mince jusqu'à ready.

```swift
@main
struct StoriesApp: App {
    @State private var listViewModel: StoryListViewModel?

    init() {
        ImageLoader.configure()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let vm = listViewModel {
                    StoryListView(viewModel: vm)
                } else {
                    LoadingView()
                }
            }
            .task {
                guard listViewModel == nil else { return }
                await bootstrap()
            }
        }
    }

    private func bootstrap() async {
        let storyRepo = LocalStoryRepository.makeFromBundle()
        let stateStore: any UserStateRepository
        do {
            stateStore = try await PersistedUserStateStore.makeInApplicationSupport()
        } catch {
            Logger.persistence.error("State store init failed: \(error). Falling back to ephemeral.")
            stateStore = EphemeralUserStateStore()
        }
        listViewModel = StoryListViewModel(
            storyRepository: storyRepo,
            userStateStore: stateStore,
            clock: ContinuousClock()
        )
    }
}
```

Notes :
- `LoadingView` est intentionnellement triviale (fond noir + spinner). L'hydration prend <50ms en pratique ; la View n'est là que pour la correction, pas pour l'UX.
- Le chemin de récupération sur corruption fallback sur `EphemeralUserStateStore` (dans `Data/`, prod-safe) pour que l'app ne crash jamais sur un fichier d'état malformé. L'état est perdu pour la session courante uniquement ; le store persisté n'est pas réécrit par le fallback ephemeral. `InMemoryUserStateStore` (dans `TestSupport/`) est un fake de test séparé ; le code de production n'y fait jamais référence.
- `ContinuousClock` est injecté explicitement pour que les tests puissent substituer un `TestClock` (voir *Modèle de concurrence*).

Pourquoi pas de container :
- Moins de 5 dépendances. Un container c'est plus de code que le wiring qu'il remplace.
- Les reviewers peuvent lire la composition top-down en 30 secondes.
- Les tests injectent les fakes directement dans l'init. Pas de boilerplate d'enregistrement.

## Hooks d'accessibilité

L'accessibilité vit dans la View, pas dans le ViewModel — les labels et values sont des localized strings, le ViewModel expose les *faits* (`isLiked`, `currentItemIndex`, `itemCount`) et la View les compose en `accessibilityLabel` / `accessibilityValue`. Cela garde le ViewModel libre des appels `String(localized:)` qui casseraient la pureté des unit tests.

Concrètement :
- `LikeButton` : `.accessibilityLabel("Like")`, `.accessibilityValue(isLiked ? "liked" : "not liked")`.
- `StoryTrayItem` : `.accessibilityLabel("\(user.username), \(isFullySeen ? "viewed" : "new")")`, `.accessibilityHint("Opens story")`.
- `SegmentedProgressBar` : caché de l'accessibilité (`.accessibilityHidden(true)`) ; le header annonce "Item N of M" à la place.
- Les zones de tap dans le viewer exposent `.accessibilityLabel("Next") / "Previous"` avec `.accessibilityAddTraits(.isButton)`.

Reduced motion et Dynamic Type sont explicitement hors scope (CLAUDE.md).

## Entrée deep-link (hors scope, mentionné)

Un vrai produit Stories accepterait `bereal://story/{userID}/item/{itemID}` et ouvrirait le viewer pré-positionné. L'architecture le supporte à bas coût : le ViewModel viewer prend déjà `(users, startUserIndex, startItemIndex)`. Un handler `URL` dans `StoriesApp` mapperait le link à ces paramètres et présenterait le cover. Non implémenté pour le test ; flaggé dans le README comme un skip délibéré.

## Contrat visuel : previews à la place des snapshot tests

Les snapshot tests ont été envisagés (`swift-snapshot-testing`, harness XCTest, stub `DataLoader` Nuke en mémoire) puis abandonnés. Blocage mécanique : la lib écrit ses PNG de référence sur un chemin résolu via `#filePath` du fichier source, et la sandbox du simulateur iOS refuse les écritures host hors de son data container — donc les runs `xcodebuild test` ne peuvent pas enregistrer les baselines, et le contournement par variable d'env de scheme ajoutait plus de harness que le contrat ne le valait sur un projet mono-auteur.

Le contrat visuel est porté de deux façons à la place :
- Chaque fichier de composant dans `DesignSystem/Components/` embarque au moins un bloc `#Preview` qui exerce sa matrice d'états nommée (seen / unseen / loading / failed, variantes de density, liked / not-liked, etc.). Les reviewers parcourent les previews dans Xcode en quelques secondes.
- Les tests de stabilité de la couche Data (`LocalStoryRepositoryTests`, `PersistedUserStateStoreTests`) protègent les entrées que le visuel consomme — la divergence visuelle inter-sessions est éliminée à la source plutôt qu'après le pixel.

Si une itération future a besoin de regression pixel, la bonne piste en 2026 est l'API image-snapshot first-party de Swift Testing 6.2, pas un retour à `swift-snapshot-testing` et à ses conflits de sandbox.

## Modularité : pourquoi pas de SPM

La consigne mentionne "architecture modulaire". Le mot a deux lectures possibles :

1. **Modularité au sens découplage** — couches séparées, frontières explicites, dépendances unidirectionnelles, testable en isolation.
2. **Modularité au sens packaging** — chaque couche dans un Swift Package local, frontière imposée par le compilateur.

Cette implémentation choisit (1). Les couches sont des dossiers, pas des packages, mais les frontières sont réelles :
- `Domain/` n'importe que `Foundation` (vérifiable par grep, hard rule du projet).
- Toute communication inter-couche passe par des protocoles `Sendable` (`StoryRepository`, `UserStateRepository`).
- L'injection de dépendance est par constructor uniquement, sans container — la composition root tient en 30 lignes.
- Les ViewModels ne référencent jamais de types concrets de `Data/`.

**Pourquoi ne pas extraire en Swift Packages :**

| Coût SPM sur ce projet | Détail |
|---|---|
| Setup initial | ~2-3h pour 4-5 packages + manifests + resources (`stories.json` via `Bundle.module`) + test targets par package |
| Friction continue | Chaque type qui traverse une frontière doit être `public` ; multiplie les diffs et les chances d'oubli |
| Build times | Plus lent en clean build à cette échelle ; le gain de parallélisation SPM ne devient visible qu'au-delà de ~50k LOC |
| Risque de démo | Un package qui ne résout pas en local le jour de la revue = bloquant pour zéro bénéfice évalué |
| Previews SwiftUI | Comportement variable entre Xcode/SPM ; source de friction sans valeur ajoutée pour le reviewer |

Le bénéfice unique d'un SPM ici serait *forcer mécaniquement* qu'aucun import `SwiftUI` ne fuit dans `Domain/`. Avec un Domain de quatre fichiers écrits par une seule personne, c'est une discipline triviale qui ne justifie pas le coût.

**À partir de quand ça vaudrait le coup :** plusieurs équipes touchant le même codebase, ou un `DesignSystem` réellement consommé par plusieurs apps. Aucun des deux n'est vrai dans le scope du test. L'extraction reste un refactoring d'environ une journée si le projet grandit — la frontière logique est déjà là.

## Récap des trade-offs

| Décision | Choisi | Alternative | Pourquoi |
|---|---|---|---|
| Architecture | MVVM + Repository | TCA, Clean Arch | Meilleur ratio structure/cérémonie pour cette échelle |
| Modularité | Dossiers + protocoles `Sendable` aux frontières | Swift Packages locaux par couche | Frontière logique déjà explicite (Domain pur, DI par init, protocoles Sendable) ; le packaging SPM ajoute ~4-6h de plomberie + risque de démo pour un bénéfice non évalué à cette échelle. Voir § *Modularité* ci-dessus. |
| State mgmt | `@Observable` | `ObservableObject` | iOS 17+ natif, pas de boilerplate `@Published`, signale un stack moderne |
| Deployment target | iOS 18 | iOS 17 | Débloque `.navigationTransition(.zoom)` (la transition phare du produit), `onScrollGeometryChange` (trigger de pagination testable), et les simplifications d'isolation de View Swift 6. Le coût est négligeable 20 mois après la sortie. |
| Trigger de pagination | `onScrollGeometryChange` → prédicat VM pur | sentinelle `onAppear` / `GeometryReader` + `PreferenceKey` | La décision sort de la View dans une fonction unit-testable ; matche la règle "pas de logique métier dans les Views" sur ce chemin de code |
| Transition tray → viewer | `.navigationTransition(.zoom)` | `matchedGeometryEffect` à travers `.fullScreenCover` | API native, pas de flicker au dismiss, dismiss interactif natif, ~30-50 lignes en moins |
| Pagination user dans le viewer | `HStack` paginé hand-rolled + `DragGesture` | `TabView(.page)` | La transition custom parallax+scale n'est pas exprimable avec le page style de `TabView` ; le geste doit rester interruptible en plein vol au moment d'une inversion de direction |
| Swipe-down dismiss | Drag interactif (translation + velocity, rubber-banded, scale + opacity) | Swipe binaire avec seuil | Le reviewer ressent le geste plutôt qu'un déclencheur one-shot ; la logique de seuil reste fonction pure et unit-testable |
| Comportement long-press | Pause + chrome hide (header/footer/progress qui fadent) | Pause uniquement | Matche Instagram ; laisse l'utilisateur s'attarder sur le frame ; la chrome est rendue conditionnellement, pas layout-conditionnellement, donc la géométrie reste stable |
| Double-tap sur image | Heart pop overlay + like idempotent (pas de un-like) | Pas de double-tap ou toggle | Micro-interaction de qualité perçue élevée ; l'idempotence évite le foot-gun "j'ai tapé deux fois rapidement et j'ai perdu mon like" |
| Persistence | actor + fichier JSON | SwiftData, UserDefaults | Thread-safe par construction, rapide, testable, bien dimensionné |
| Pagination | recyclage local avec suffixes d'ID | mock réseau | Spec-conforme, pas de tests flaky |
| Images | Nuke | AsyncImage, custom | Caching/prefetch de qualité production sans avoir à l'écrire |
| Concurrence | Swift 6 strict | défaut | Correction au compile time, signal senior |
| DI | constructor | container (Factory, Resolver) | Bien dimensionné pour une app de cette échelle |
| Navigation | `.fullScreenCover` | NavigationStack | La sémantique modale matche le use case |
| Framework de test | Swift Testing (unit/intégration), pas de harness snapshot | XCTest seul, Quick/Nimble | Async-natif et paramétré — signal senior moderne. Snapshot tests abandonnés sur le blocage sandbox simulateur iOS ; la revue visuelle pilotée par `#Preview` couvre la surface à la place (cf. *Contrat visuel* plus haut) |

## Ce que cette architecture N'essaie PAS d'être

- Un framework réutilisable pour les stories. C'est une implémentation focalisée.
- Un monolithe modulaire grade microservices. Les dossiers, pas les Swift Packages, sont la frontière — choix défendu en § *Modularité : pourquoi pas de SPM*. Le mot "modulaire" de la consigne est interprété comme découplage logique (Domain pur, protocoles aux frontières, DI par init), pas packaging physique.
- Une abstraction agnostique au platform. iOS-first, SwiftUI-first.
- Une démonstration de chaque pattern iOS. Montre les bons pour le job.
