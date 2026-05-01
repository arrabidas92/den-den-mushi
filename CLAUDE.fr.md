# CLAUDE.md

Contexte projet pour le développement assisté par IA sur le test technique iOS Senior BeReal.

Pour le détail du design system, voir `design.md`. Pour l'architecture et la structure de dossiers, voir `architecture.md`.

## Mission

Construire une fonctionnalité Stories type Instagram pour une évaluation technique BeReal. Le produit reproduit les patterns UX familiers d'Instagram avec une esthétique BeReal (brut, sombre, sans dégradés). L'évaluation priorise la finition UX, la qualité du code, l'architecture et la **couverture de tests** plutôt que la largeur de fonctionnalités.

## Hard rules

- **Langage** : Swift 5.10+, SwiftUI en primaire. UIKit uniquement quand SwiftUI est réellement insuffisant.
- **Cible iOS** : 18.0 minimum. Utiliser `@Observable`, framework `Observation`, `@Bindable`. Ne PAS utiliser `ObservableObject` / `@Published`. iOS 18 débloque trois APIs qu'on utilise directement : `.matchedTransitionSource` + `.navigationTransition(.zoom)` pour la transition tray-avatar→viewer header, `onScrollGeometryChange` pour le trigger de pagination N-3, et l'isolation `@MainActor`-par-défaut des Views relâchée sous Swift 6 strict concurrency. Cibler iOS 17 en 2026 sans raison de compensation est un signal "template pas mis à jour" en revue senior.
- **Concurrence** : Swift 6 strict mode activé. Tout est `Sendable` ou marqué explicitement. Les repositories et stores sont des `actor`s. Les ViewModels sont `@MainActor`.
- **Bibliothèques externes** : uniquement `Nuke` (chargement d'images) et `swift-snapshot-testing` (test target uniquement). Toute autre dépendance doit être justifiée à l'utilisateur avant ajout.
- **Persistence** : `actor` + Codable JSON via `FileManager`. Pas de SwiftData, pas d'`UserDefaults` pour l'état, pas de Core Data.
- **Pas de logique métier dans les Views**. Les Views lisent depuis des view models `@Observable` et dispatchent des intents.
- **Pas de singletons**. Dépendances passées via init.
- **Pas de force-unwraps** en dehors des previews et tests. Pas d'optionnels implicitement unwrappés.

## Comportement produit (non-négociable)

- Le contenu story d'un user est **stable entre sessions** (mêmes images pour le même user). Utiliser `picsum.photos/seed/{stableSeed}/{w}/{h}`.
- L'**état seen est par StoryItem**, pas par Story. Une story est "fully seen" quand tous ses items sont vus. Le ring reflète l'état fully-seen.
- **Règle du marquage seen.** Un item est marqué "vu" dans deux cas seulement : soit l'utilisateur l'a regardé au moins **1,5 seconde**, soit il a explicitement tapé "suivant" pour passer à l'item d'après avant ce délai. Ouvrir une story et la fermer en moins de 1,5s sans tap forward **ne la marque pas vue** — sinon le ring passerait au gris alors que l'utilisateur n'a rien vu, ce qui se ressent comme un bug. Le seuil 1,5s correspond au seuil perceptif de "j'ai vraiment eu le temps de voir quelque chose" ; la règle du tap explicite couvre les power-skimers qui parcourent vite les stories d'un même user et auxquels on accorde leur volonté d'avancer.
- Le **like est par StoryItem**. UI optimiste : l'état flippe instantanément, la persistence suit.
- **Pagination** : 10 users par page, déclenchée quand on scroll à l'index N-3. Utiliser `onScrollGeometryChange(for: Bool.self)` pour dériver un flag "near end" depuis `contentOffset` / `contentSize` / `containerSize` ; exposer le seuil comme une fonction pure sur `StoryListViewModel` pour qu'il soit unit-testable sans View. Recycle le JSON local avec des IDs suffixés (`alice-p1`, `alice-p2`...).
- **Auto-advance** : 5s par item. Les zones de tap se découpent **verticalement 1:2** (tiers gauche = previous, deux tiers droits = next, miroir d'Instagram — forward est l'action dominante). Long-press = pause. Swipe horizontal = next/prev user. Swipe down = dismiss.
- **Pause en background** : le timer se met en pause quand `scenePhase` n'est pas `.active`.
- **L'échec image est visible** : les items dont l'image a échoué affichent un cadre teinté `Surface` avec une petite icône, une caption "Couldn't load this story" et un bouton `Retry`. L'auto-advance se met en pause sur le frame d'échec ; le tap-forward continue de fonctionner. Pas d'haptique, pas d'alerte.

## Stratégie de tests

Le testing est une préoccupation de premier ordre, pas une étape finale. Les tests sont écrits **en parallèle** du code qu'ils couvrent.

### Tests unitaires & d'intégration (Swift Testing)

Les tests unitaires et d'intégration utilisent **Swift Testing**, pas XCTest. Swift Testing est stable depuis Xcode 16 (sept. 2024) ; en 2026 c'est le framework recommandé par Apple, XCTest étant en mode maintenance. Trois raisons pour lesquelles il colle particulièrement à ce projet :

- **Async-natif** — `await` directement dans les fonctions `@Test`, pas de `XCTestExpectation` / `wait(for:)`. Nos tests `PlaybackController` et `ViewerStateModel` pilotés par `Clock<Duration>` assertent avec un simple `await clock.advance(by:)`.
- **Tests paramétrés first-class** — `@Test(arguments:)` collapse la matrice du seuil seen-mark (0.5s / 1.4s / 1.5s / 3.0s) en un seul test, au lieu de quatre méthodes quasi-dupliquées.
- **`#expect` / `#require` montrent l'expression réelle** dans la sortie d'échec, contrairement aux opérandes left/right stringifiés de XCTest.

Choisir XCTest en 2026 sur un projet Swift 6 strict ferait passer un signal "template pas mis à jour" en revue senior, au même titre que cibler iOS 17.

**Doivent être testés** :
- `PersistedUserStateStore` : round-trip, écritures concurrentes, debounce, survie aux re-init.
- `LocalStoryRepository` : nombre de pages, unicité des IDs entre pages, sortie déterministe, parsing JSON.
- `PlaybackController` : avance des ticks, pause/resume préserve la progression, restart sur changement d'item reset à 0, scenePhase pause stoppe les ticks et reprend depuis le même offset.
- `ViewerStateModel` : toutes les transitions d'état (next/prev item, next/prev user, dismiss en fin), le marquage seen ne se déclenche qu'après 1.5s OU sur next-tap explicite, le like optimiste flippe l'état avant la fin de la persistence.
- `StoryListViewModel` : la pagination se déclenche à N-3 (tester la fonction pure `shouldLoadMore(contentOffset:contentSize:containerSize:)` — la View ne fait que forwarder la géométrie depuis `onScrollGeometryChange`), pas de double-load, états d'erreur.

**Non testé** (mentionné dans le README) :
- Pure View layouts (couvert par les snapshots).
- Internes du wrapper Nuke (faire confiance à la lib).
- Timings d'animations SwiftUI (hors scope).

### Snapshot tests (XCTest + swift-snapshot-testing)

Les snapshots restent sur **XCTest**. `swift-snapshot-testing` v1.x est conçu autour de `XCTestCase` — un companion Swift Testing existe mais le rendu des diffs et messages d'échec est moins lisse en 2026, et l'intégration moins propre. Huit fichiers de snapshots vs ramer contre l'outillage : pas rentable. L'hybride est le choix standard des projets iOS sérieux en 2026 — code nouveau en Swift Testing, snapshots sur XCTest.

Device fixé : iPhone 15 Pro. Versions Xcode/simulator pinnées dans le README. Dark mode uniquement.

**Snapshotté** :
- `StoryRing` — seen / unseen / loading, plusieurs tailles
- `StoryAvatar` — seen / unseen / loading / fallback image-fail
- `SegmentedProgressBar` — 1, 3, 5 segments × progress 0/50/100 × variations de currentIndex
- `LikeButton` — liked / not liked
- `StoryTrayItem` — seen / unseen / username long / username court
- `StoryViewerHeader` — timestamp récent / ancien
- `StoryViewerPage` — un snapshot d'intégration de la page viewer complète
- `StoryListView` — liste complète avec mix d'états seen/unseen

**Non snapshotté** : états d'animation transitoires, écrans dépendant du réseau.

### Test d'intégration (léger)

Un scénario VM end-to-end : charger la liste → ouvrir le user 3 → voir 2 items → dismiss → asserter l'état seen. Repositories en mémoire, pas d'UI.

### Cible de couverture

Viser ~80% sur Domain + ViewModels. Le code de View est intentionnellement non couvert.

### Test doubles

Fakes écrits à la main (`FakeStoryRepository`, `InMemoryUserStateStore`) dans le test target. Pas de framework de mocking.

## Polish explicitement skippé (documenté dans le README)

Échangé contre la couverture de tests :
- Dismiss interactif au swipe-down (le swipe binaire suffit)
- Transition custom entre users (transition page par défaut utilisée)
- Long-press cache toute l'UI (pause uniquement)
- Animation cœur qui pop sur double-tap
- Champ footer "Send message"
- Crossfade sur la transition seen du ring (swap instantané est suffisant et un test de moins à maintenir)

Conservé (faible coût, gain de qualité perçue élevé) :
- **Zoom transition tray avatar → viewer header** via `.matchedTransitionSource(id:in:)` + `.navigationTransition(.zoom(sourceID:in:))` (iOS 18 natif). La transition que les reviewers ressentent le plus. L'API native remplace le workaround `matchedGeometryEffect` d'iOS 17 — moins d'artefacts au dismiss, moins de code custom, et c'est la même primitive que Photos.app utilise.
- Pause sur ScenePhase
- Préchargement d'images via Nuke prefetch
- Support reduced-motion (faire de l'auto-advance sans le respecter est rédhibitoire à un niveau senior ; ~30 min via les tokens `Motion` de `design.md`)
- Haptiques sur le like
- Zones de tap pour next/previous (split vertical 1:2)

## Style de code

- Indentation 4 espaces, pas de tabs.
- Trailing commas dans les collections multilignes.
- Sections `// MARK:` dans les fichiers >100 lignes.
- Inférence de type préférée quand le type est évident.
- Préférer `guard` aux `if` imbriqués.
- Tous les types publics ont un commentaire de doc bref expliquant l'intention, pas l'implémentation.
- Previews SwiftUI pour chaque composant réutilisable, avec variantes seen/unseen.

## Ce qu'il NE faut PAS faire

- Ne pas ajouter de NavigationStack pour la présentation du viewer. Utiliser `.fullScreenCover`.
- Ne pas implémenter de transition cube entre users.
- Ne pas bundler les images en assets. URLs uniquement.
- Ne pas utiliser `AsyncImage` pour les images de stories. Utiliser Nuke.
- Ne pas utiliser `Timer.scheduledTimer`. Utiliser `Task` + `try await Task.sleep(for:)`.
- Ne pas implémenter de fonctionnalités au-delà du spec.
- Ne pas écrire de test qui ne fait que ré-asserter ce que le système de types impose déjà.
- Ne pas snapshotter d'états qui dépendent du réseau ou du timing d'animation.

## En cas de doute

Demander. L'utilisateur est un ingénieur iOS senior avec 8 ans d'expérience. Préférer les questions de clarification aux suppositions quand un choix de design comporte des trade-offs.
