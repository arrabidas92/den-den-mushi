# den-den-mushi

Test technique iOS Senior pour BeReal — implémentation d'une fonctionnalité Stories type Instagram, avec une direction esthétique BeReal (sobre, brut, sans dégradés).

## Stack

- **Swift** 5.10+, **SwiftUI** en primaire (UIKit uniquement si SwiftUI est insuffisant)
- **iOS 18.0** minimum — `@Observable` / `Observation` / `@Bindable`, `.navigationTransition(.zoom)` pour la transition tray→viewer, `onScrollGeometryChange` pour le trigger de pagination, isolation `@MainActor` simplifiée des Views sous Swift 6
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
- `PlaybackController` — avance des ticks, pause/resume conserve la progression, reset sur changement d'item, scenePhase pause stoppe et reprend depuis le même offset
- `ViewerStateModel` — toutes les transitions d'état, marquage seen au seuil de 1.5s OU sur next-tap explicite, like optimiste, dismiss en fin de stories
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

- Dismiss interactif au swipe (binaire suffit)
- Transition cube entre users (page transition par défaut)
- Long-press cache toute l'UI (pause uniquement)
- Animation de coeur sur double-tap
- Champ "envoyer un message" en footer
- Crossfade sur la transition seen/unseen du ring (swap instantané, un test de moins à maintenir)

Conservés (faible coût, gain de qualité perçue):

- **Zoom transition tray avatar → header du viewer** via `.matchedTransitionSource` + `.navigationTransition(.zoom)` (iOS 18 natif) — la transition que les reviewers ressentent le plus, dismiss interactif fourni gratuitement, sans le flicker du `matchedGeometryEffect` à travers `.fullScreenCover` qu'aurait imposé iOS 17
- Pause sur `scenePhase` non actif
- Préchargement images via `Nuke prefetch`
- Support *reduced motion* (auto-advancing content sans le respecter est rédhibitoire à un niveau senior; ~30 min via les tokens `Motion` du design system)
- Haptiques sur le like
- Zones de tap (split vertical 1:2, gauche=previous, droite=next — ratio Instagram, forward étant l'action dominante)

## Choix de dépendances

Règle appliquée: **une dépendance se justifie si (1) elle résout un problème non-trivial, (2) ce problème n'est pas la feature évaluée, (3) la réimplémenter coûterait un budget temps qui ferait perdre plus de qualité ailleurs (UX, tests), (4) elle est mature et ne devient pas elle-même un risque.** Deux dépendances cochent les quatre. Toute autre demande devra être justifiée explicitement avant ajout.

### Nuke (runtime)

**Pourquoi le chargement d'images est non-trivial pour Stories.** Une feature Stories exige six choses que la moindre approche naïve manque:

1. **Cache disque** — un retour sur la même story doit être instantané, sans re-download.
2. **Prefetch** — l'item N+1 doit être décodé avant le tap forward, sinon flash de placeholder à chaque transition de 5s.
3. **Annulation fiable** — sur swipe vers le user suivant, les téléchargements en cours pour le user courant doivent s'annuler immédiatement (sinon saturation bande passante).
4. **Décompression hors main thread** — décoder un JPEG 1080×1920 sur le main thread = stutter visible. L'image doit arriver prête à dessiner.
5. **Dédup de requêtes** — list et viewer peuvent demander la même URL en parallèle (avatar du tray + header du viewer). Une seule requête réseau, deux callbacks.
6. **Memory cache + disk cache à deux niveaux** — memory pour la fluidité immédiate, disk pour la persistance entre sessions.

**Alternatives écartées:**

| Option | Verdict | Raison |
|---|---|---|
| `AsyncImage` (built-in) | ❌ | Pas de cache disque, pas de prefetch, annulation peu fiable, décompression sur main thread dans certaines configs. Acceptable pour un avatar isolé, inadapté à un viewer auto-advance. |
| Kingfisher | ⚠️ Comparable | API plus orientée UIKit, `KFImage` moins idiomatique que `LazyImage`, annotations Sendable / Swift 6 historiquement à la traîne. Marche en 2026, mais le code SwiftUI + Swift 6 est plus propre avec Nuke. |
| SDWebImage | ❌ | Lib Obj-C historique, header pollution, intégration Swift 6 strict pénible. Aucune raison de la choisir pour un projet 100% Swift moderne. |
| Custom (`URLSession` + `URLCache` + `CGImageSource`) | ❌ | Estimation honnête: 2-3 jours pour atteindre ~80% de la qualité de Nuke, avec en prime un prefetch coordonné, un memory pressure handling, et une dédup de requêtes à concevoir from scratch. C'est 60-80% du budget d'un test technique de 3 jours brûlés sur de l'infrastructure que personne n'évalue. |

**Pourquoi Nuke spécifiquement (et pas seulement "une lib d'images"):**

- **Maturité** — 9+ ans, utilisé en production par des apps iOS de premier plan, battle-tested sur exactement notre type de charge (carousels, feeds).
- **API SwiftUI native** — `LazyImage` est une vraie `View`, pas un `UIViewRepresentable` bricolé. Lifecycle, transitions et modifiers fonctionnent comme attendu.
- **`ImagePrefetcher` first-class** — pilotage propre depuis le ViewModel, pas un détail d'implémentation.
- **`@MainActor` annoté correctement** (Nuke 12+) — colle à notre modèle Swift 6 strict sans `@unchecked Sendable` ni warnings à supprimer.
- **Pipeline configurable** — un `DataLoader` stub injecté côté tests pour des snapshots hermétiques (cf. `architecture.md` § *Snapshot determinism*).
- **Petit footprint** — ~200 KB binaire, pas de dépendances Obj-C, build rapide.

**Ce qu'on évite côté usage de Nuke:**

- Pas de gros wrapper "anti-corruption layer au cas où on changerait de lib" — YAGNI. `LazyImage` est utilisé directement dans les composants design.
- Le wrapper qu'on a (`ImageLoader.configure()` + `ImagePrefetchHandle`) ne fait que deux choses: (1) configurer le pipeline une seule fois, (2) tenir un handle de prefetch dont la durée de vie est liée à un écran (cancellation propre).
- Pas de bundling d'images en assets — le spec exige `picsum.photos/seed/{stableSeed}` pour la stabilité inter-sessions, ce qui implique le réseau et donc une vraie pipeline.

### swift-snapshot-testing (test target uniquement)

Référence dans l'écosystème iOS pour les snapshots. Permet de figer l'apparence des composants et de détecter les régressions visuelles sans tooling maison.

**Alternatives écartées:**

| Option | Verdict | Raison |
|---|---|---|
| iOS 16+ `ImageRenderer` à la main | ❌ | Permet de générer un PNG depuis une `View`, mais il faut écrire soi-même: la comparaison pixel-à-pixel, le rapport de diff visuel, la gestion des références par device/scale, l'intégration XCTest. C'est précisément ce que la lib offre prêt à l'emploi. |
| Tests UI XCUITest avec captures | ❌ | Trop lent (boot simulator, navigation), trop fragile (timing, animations), inadapté à des composants isolés. |
| Pas de snapshot tests | ❌ | Casserait l'objectif "test coverage first-class" du brief. Les composants design (rings, progress bar, like button) sont pile le profil où le snapshot vaut une page de tests d'unitaires sur du layout. |

`swift-snapshot-testing` est au test target uniquement — aucune surface de production n'en dépend, donc le risque "lib abandonnée" est nul: au pire on freeze la version, les tests continuent de tourner.

## Choix de persistence

> **TL;DR** — `actor` + `Codable` JSON via `FileManager`, dans `Application Support/`. Pas de SwiftData, pas d'`UserDefaults` pour l'état, pas de Core Data.

### Ce qu'on persiste, exactement

```swift
struct UserState: Codable, Sendable {
    var seenItemIDs: Set<String>     // ~quelques centaines de strings max
    var likedItemIDs: Set<String>    // idem
}
```

**Deux `Set<String>`**, taille mesurée en kilooctets, pas de relations, pas de requêtes, pas de tri, pas de filtrage. La seule opération coûteuse est "écrire sans race condition". Ce constat est décisif: c'est un cas où **n'importe quel outil sur-dimensionné devient un coût net**.

### La solution choisie

Quatre primitives Foundation suffisent:

| Préoccupation | Outil | Mécanisme |
|---|---|---|
| Concurrence (list + viewer écrivent en parallèle) | `actor` | Sérialisation par construction du langage — pas de `NSLock`, pas de queue à maintenir |
| Sérialisation | `Codable` + `JSONEncoder` | Trois lignes, lisible à la main, diffable, migration via `init(from decoder:)` standard |
| Atomicité | `Data.write(to:options: [.atomic])` | Écrit dans un temp + rename atomique. Process tué pendant le write = ancien fichier intact, jamais corrompu |
| Emplacement | `Application Support/` | État privé app, persistant, exclu d'iCloud Document. Pas `Documents/` (visible Files.app), pas `Caches/` (purgeable OS) |

Résultat: ~80 lignes de code, zéro dépendance ajoutée, testable avec un `tmpDir` jetable, alignée avec le modèle d'`actor`s du reste du projet.

### Alternatives écartées

| Option | Verdict | Raison |
|---|---|---|
| **SwiftData** | ❌ | C'est un ORM. Pour `Set<String>`, il faut soit un `@Model class UserStateRecord` artificiel, soit un `@Model class UserState` avec relations vers un `@Model class Item` qu'on n'a pas — on **introduit un modèle de données là où il n'y en a pas**. Pire, `ModelContext` n'est pas `Sendable`: pour rester compatible avec nos repositories `actor`, il faudrait un `ModelActor` par-dessus, soit une double couche d'isolation pour le même problème. Et SwiftData a un historique documenté de bugs de threading sous Swift 6 strict (saves perdus, contextes désynchronisés). Coût élevé, gain nul, risque réel. |
| **`UserDefaults`** | ❌ | Thread-safe sur les accès individuels mais pas sur les séquences read-modify-write (`array → modify → set` depuis deux threads = écritures perdues silencieusement). Pas d'atomicité fichier sur le `.plist` interne. `Set<String>` n'est pas un type natif (bricolage `[String]` à chaque accès). Et sémantiquement, `UserDefaults` est *préférences utilisateur* — y stocker "quelles stories ont été vues" est un abus qu'un reviewer va souligner. |
| **Core Data** | ❌ | En 2026, sur un nouveau projet, aucune justification: SwiftData le supplante pour les nouveaux modèles, et tous les arguments anti-SwiftData s'appliquent en pire (API Obj-C sous-jacente, plus de boilerplate, threading encore plus capricieux). Mentionné dans CLAUDE.md uniquement pour fermer la porte explicitement. |
| **Fichier custom binaire / SQLite à la main** | ❌ | Travail non-trivial pour une donnée qui n'a ni schéma ni requêtes. JSON est lisible, debuggable, et la perf n'est pas un facteur à <1KB. |

### Trade-off explicite assumé

**Debounce 500ms** sur les écritures disque (`PersistedUserStateStore` coalesce les bursts). Conséquence: en cas de crash hard pendant la fenêtre de debounce, on perd au pire 500ms d'état. Borné, documenté, acceptable pour une feature où "j'ai marqué cette story seen il y a 200ms" n'est pas critique. Forçage explicite via `flushNow()` sur passage en background et sur dismiss du viewer — voir `architecture.md` § *Persistence design*.

### Pourquoi c'est aussi un signal de jugement

Choisir SwiftData pour `Set<String>` × 2 est un anti-pattern reconnaissable: "j'utilise l'outil le plus récent parce qu'il est le plus récent". Choisir `actor` + Codable JSON et **savoir expliquer pourquoi pas SwiftData** est le signal inverse — dimensionnement adapté à la donnée, démonstration directe d'un store concurrent thread-safe écrit avec les primitives modernes du langage, plus impressionnant en review qu'un `@Model class` qui cache la complexité réelle derrière un framework.

## Comportement produit

- Le contenu d'un user est **stable entre les sessions** (mêmes images pour le même user) via `picsum.photos/seed/{stableSeed}`.
- L'état **seen est par StoryItem**, pas par Story. Le ring reflète l'état "fully seen".
- Le **seen est marqué après 1.5s de lecture OU sur next-tap explicite**. Un tap-and-dismiss immédiat ne marque rien (sinon le ring grise sans qu'aucun contenu n'ait été vu).
- Le **like est par StoryItem**. UI optimiste: l'état flippe immédiatement, la persistence suit.
- **Pagination**: 10 users par page, déclenchée quand on est à 3 items de la fin du contenu chargé. Le trigger lit la géométrie via `onScrollGeometryChange` et délègue la décision à une fonction pure du ViewModel (`shouldLoadMore(contentOffset:contentSize:containerSize:)`), testée en unitaire sans UI. Recyclage local du JSON avec IDs suffixés (`alice-p1`, `alice-p2`...).
- **Auto-advance**: 5s par item. Zones de tap **verticales 1:2** (tiers gauche = previous, deux tiers droits = next, ratio Instagram), long-press = pause, swipe horizontal = next/prev user, swipe down = dismiss.
- **Pause en background**: le timer s'interrompt quand `scenePhase` n'est pas `.active`.
- **Échec d'image**: cadre `Surface` avec icône, légende "Couldn't load this story" et bouton `Retry`. L'auto-advance se met en pause sur le cadre d'échec; le tap-forward reste actif. Pas d'haptique, pas d'alerte.

## Accessibilité

Wins peu coûteux implémentés:

- `.accessibilityLabel` sur tous les éléments interactifs
- `.accessibilityValue("liked" / "not liked")` sur le bouton like
- Tap targets ≥ 44pt (Apple HIG)
- Labels VoiceOver sur le bouton de fermeture
- **Reduced motion** respecté globalement: `Motion.fast/standard/slow` collapsent à `0`, le ring et le like flippent instantanément, l'auto-advance reste actif via un tick discret (sans barre animée). Voir `design.md` → *Motion principles → Reduced motion*.

Skippé (hors scope du test): support *Dynamic Type* (l'UI Stories est volontairement à taille fixe, comme Instagram), navigation VoiceOver entre items.

## Usage de l'IA

L'usage de l'IA est autorisé pour ce test. Le fichier [`CLAUDE.md`](./CLAUDE.md) documente les règles de collaboration avec l'assistant: hard rules techniques, comportement produit non-négociable, stratégie de tests, style de code, et liste explicite des choses à ne pas faire. C'est un artefact de la démarche, au même titre que `architecture.md` et `design.md`.
