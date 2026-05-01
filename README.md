# den-den-mushi

Test technique iOS Senior pour BeReal — implémentation d'une fonctionnalité Stories type Instagram, avec une direction esthétique BeReal (sobre, brut, sans dégradés).

## Stack

- **Swift** 5.10+, **SwiftUI** en primaire (UIKit uniquement si SwiftUI est insuffisant)
- **iOS 17.0** minimum — `@Observable`, framework `Observation`, `@Bindable`
- **Swift 6** strict concurrency activé
- **XCTest** + **swift-snapshot-testing** pour les tests
- **Nuke** pour le chargement d'images

## Lancer le projet

```bash
open StoriesTest.xcodeproj
```

Puis lancer la cible `StoriesTest` sur un simulateur iPhone 15 Pro (cible recommandée pour la cohérence des snapshots).

Pour lancer les tests:

```bash
xcodebuild test -scheme StoriesTest -destination 'platform=iOS Simulator,name=iPhone 15 Pro'
```

## Documentation

- [`architecture.md`](./architecture.md) — pattern architectural, structure de dossiers, modèle de concurrence, persistence, pagination, trade-offs
- [`design.md`](./design.md) — design system, tokens, typographie, motion, catalogue de composants
- [`CLAUDE.md`](./CLAUDE.md) — règles de collaboration avec l'IA utilisée pour ce test (voir section *Usage de l'IA* ci-dessous)

## Architecture en bref

**MVVM + Repository, modulaire par feature.**

```
View (SwiftUI)
  ↑ observe
@Observable ViewModel (@MainActor)
  ↓ appelle
Repository (protocol)
  ↓ implémente
actor LocalStoryRepository / PersistedUserStateStore
```

- **Domain** pur (Foundation only), protocoles + modèles `Sendable`
- **Repositories** sont des `actor`s (thread-safety par construction)
- **ViewModels** `@MainActor`, pas de logique métier dans les Views
- **Composition root** dans `StoriesTestApp.swift`, injection par init, pas de container DI

Pour le détail des décisions et alternatives écartées (TCA, Clean Arch, SwiftData, UserDefaults, AsyncImage), voir [`architecture.md`](./architecture.md).

## Stratégie de tests

Les tests sont une préoccupation de premier ordre, écrits **en parallèle** du code qu'ils couvrent. Cible: **~80%** sur Domain + ViewModels.

### Tests unitaires (XCTest)

- `PersistedUserStateStore` — round-trip, écritures concurrentes, debounce, survie aux re-init
- `LocalStoryRepository` — pagination, unicité des IDs, déterminisme, parsing JSON
- `StoryViewerViewModel` — toutes les transitions d'état, marquage seen au démarrage de l'item, like optimiste, pause/resume
- `StoryListViewModel` — déclenchement pagination à N-3, pas de double-load, états d'erreur

### Snapshot tests (swift-snapshot-testing)

Périphérique fixé: **iPhone 15 Pro**, dark mode uniquement.

Couvre `StoryRing`, `StoryAvatar`, `SegmentedProgressBar`, `LikeButton`, `StoryTrayItem`, `StoryViewerHeader`, `StoryViewerPage`, `StoryListView`.

### Test d'intégration

Un scénario end-to-end (in-memory, sans UI): charger la liste → ouvrir user 3 → voir 2 items → fermer → vérifier l'état seen.

### Doubles de test

Fakes écrits à la main (`FakeStoryRepository`, `InMemoryUserStateStore`). Pas de framework de mocking.

## Trade-offs assumés

Volontairement échangés contre une meilleure couverture de tests:

- Matched geometry effect avatar → header viewer
- Dismiss interactif au swipe (binaire suffit)
- Transition cube entre users (page transition par défaut)
- Long-press cache toute l'UI (pause uniquement)
- Animation de coeur sur double-tap
- Champ "envoyer un message" en footer

Conservés (faible coût, gain de qualité perçue):

- Pause sur `scenePhase` non actif
- Préchargement images via `Nuke prefetch`
- Crossfade sur la transition seen/unseen du ring
- Haptiques sur le like
- Zones de tap left/right pour navigation

## Choix de dépendances

**Nuke** (runtime) — Gère le fetch HTTP, le cache multi-niveaux (mémoire + disque), le prefetch et la décompression. Aucun de ces aspects n'est la feature évaluée. Réimplémenter cela à la main consommerait du temps mieux investi sur l'UX et les tests, pour un résultat de moindre qualité. `AsyncImage` ne dispose ni de cache disque, ni de prefetch, ni d'annulation fiable.

**swift-snapshot-testing** (test target uniquement) — Référence dans l'écosystème iOS pour les snapshots. Permet de figer l'apparence des composants et de détecter les régressions visuelles sans tooling maison.

## Comportement produit

- Le contenu d'un user est **stable entre les sessions** (mêmes images pour le même user) via `picsum.photos/seed/{stableSeed}`.
- L'état **seen est par StoryItem**, pas par Story. Le ring reflète l'état "fully seen".
- Le **seen est marqué au démarrage de la lecture** d'un item (comportement Instagram).
- Le **like est par StoryItem**. UI optimiste: l'état flippe immédiatement, la persistence suit.
- **Pagination**: 10 users par page, déclenchée à l'index N-3. Recyclage local du JSON avec IDs suffixés (`alice-p1`, `alice-p2`...).
- **Auto-advance**: 5s par item. Tap droit = next, tap gauche = previous, long-press = pause, swipe horizontal = next/prev user, swipe down = dismiss.
- **Pause en background**: le timer s'interrompt quand `scenePhase` n'est pas `.active`.

## Accessibilité

Wins peu coûteux implémentés:

- `.accessibilityLabel` sur tous les éléments interactifs
- `.accessibilityValue("liked" / "not liked")` sur le bouton like
- Tap targets ≥ 44pt (Apple HIG)
- Labels VoiceOver sur le bouton de fermeture

Skippé (hors scope du test): alternative *reduced motion*, support *Dynamic Type* (l'UI Stories est volontairement à taille fixe).

## Usage de l'IA

L'usage de l'IA est autorisé pour ce test. Le fichier [`CLAUDE.md`](./CLAUDE.md) documente les règles de collaboration avec l'assistant: hard rules techniques, comportement produit non-négociable, stratégie de tests, style de code, et liste explicite des choses à ne pas faire. C'est un artefact de la démarche, au même titre que `architecture.md` et `design.md`.
