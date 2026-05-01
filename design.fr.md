# design.md

Design system pour le test BeReal Stories. Dark mode uniquement. Approche hybride : patterns structurels d'Instagram (tray, viewer, progress bars, gestures) avec les codes esthétiques de BeReal (brut, mono, sans dégradés, typographique).

## Direction esthétique

Le produit est reconnaissablement Instagram dans sa structure mais BeReal dans son ton. Là où Instagram utilise des dégradés rose-orange-violet et un rendu poli, cette implémentation utilise :

- Des rings blancs pleins au lieu de rings en dégradé
- Un fond noir pur (OLED-friendly)
- Un spacing serré, presque industriel
- Pas de skeumorphisme, pas d'ombres douces
- Une typographie à fort contraste
- Le rouge système pour l'accent like (pas du rose)

La signature la plus visible est le **ring unseen blanc plein**. Il dit immédiatement au reviewer : "j'ai compris le brief, je ne suis pas en train de cloner Instagram bêtement."

## Color tokens

```
// Backgrounds
Background          #000000   // canvas, optimisé OLED
Surface             #0E0E0E   // cards, sheets
Surface elevated    #1A1A1A   // modaux par-dessus modaux
Border              #2A2A2A   // hairlines, séparateurs

// Text
Text primary        #FFFFFF
Text secondary      #A0A0A0   // timestamps, usernames secondaires
Text tertiary       #5A5A5A   // placeholders, disabled

// Story rings
Ring unseen         #FFFFFF   // 2pt plein
Ring seen           #404040   // 1.5pt — distinct de Border, visible sur #000
Ring loading        #FFFFFF + animation pulse d'opacité

// Accents
Accent like         #FF3B30   // rouge système iOS, PAS rose
Progress active     #FFFFFF
Progress inactive   #FFFFFF @ 30% opacity
```

`Border` et `Ring seen` sont des **tokens distincts** même si leurs valeurs sont proches. Ils signifient des choses différentes : `Border` est un séparateur fin sur une surface, `Ring seen` est un indicateur d'état au premier plan par-dessus le fond OLED. On les garde distincts pour qu'ils puissent diverger indépendamment si besoin. `Ring seen` a été remonté de `#2A2A2A` à `#404040` pour passer le seuil de contraste WCAG 1.07:1 par rapport au canvas — à la valeur précédente, le ring seen disparaissait dans la page sur la troisième ligne du tray.

Implémentation : extension `Color` avec des propriétés statiques nommées. Utiliser `Color(.sRGB, ...)` pour garder les couleurs stables entre versions iOS.

## Typographie

Police système SF Pro, pas de typographies custom.

```
Username (tray)        SF Pro Text 12pt   .medium     tracking -0.2
Username (header)      SF Pro Text 15pt   .semibold
Timestamp              SF Pro Text 13pt   .regular    opacity 70%
Section title          SF Pro Display 22pt .bold
Body                   SF Pro Text 15pt   .regular
Caption                SF Pro Text 11pt   .regular    opacity 70%
```

Implémentation : extension `Font` avec des propriétés statiques nommées. Toujours utiliser les tokens nommés, jamais `Font.system(size:)` brut dans les views.

## Échelle d'espacement

Puissances de deux à peu près, prédictible :

```
Spacing.xs  =  4
Spacing.s   =  8
Spacing.m   = 12
Spacing.l   = 16
Spacing.xl  = 24
Spacing.xxl = 32
```

Utiliser ces constantes exclusivement dans les views. Pas de magic numbers dans les layouts.

## Dimensions des composants

```
// Tray
Avatar diameter         64pt
Ring gap (avatar↔ring)   3pt
Tray item spacing       14pt   // densité regular (par défaut)
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
Touch target minimum    44pt   // Apple HIG, jamais en dessous

// Skeleton (loading) placeholders
Skeleton label width    32pt   // rect placeholder du username — même empreinte horizontale qu'un username de 5 chars
Skeleton label height    8pt   // matche Spacing.s ; lit visuellement comme "le texte n'est pas encore là"
Skeleton glyph size     28pt   // taille du SF Symbol pour l'état failed du tray, centré dans la slot ring 64pt

// Corner radii
Cards                   12pt
Avatars                 plein (basé sur la géométrie)
Buttons                 plein
```

### Densité du tray

Trois densités, switchables via une seule valeur d'environnement (`TrayDensity.compact|regular|comfy`). Seul l'espacement entre items change ; la taille de l'avatar reste à 64pt pour que la signature du ring reste constante.

```
compact   item spacing 10pt   // dense, plus de users dans le viewport
regular   item spacing 14pt   // par défaut
comfy    item spacing 18pt   // aéré, moins de users dans le viewport
```

La valeur par défaut est `regular`. Les deux autres existent comme override d'une seule ligne — utile pour des scénarios d'accessibilité (compact pour les utilisateurs qui scannent beaucoup de users à la fois) et comme un knob que le reviewer peut basculer sans toucher au code de layout.

### Zones de tap (viewer)

Split vertical, **ratio 1:2** (tiers gauche = previous, deux tiers droits = next). Forward est l'action dominante donc sa zone est plus grande ; cela correspond au comportement réel d'Instagram et réduit les taps "previous" accidentels quand les utilisateurs feuillettent. Les deux zones sont pleine hauteur en excluant le header de 56pt et le footer de 64pt. Long-press sur l'une ou l'autre zone met en pause.

### Échec d'image (viewer)

Une image d'item ayant échoué n'est **pas silencieuse** — le silence se lit comme un bug. Le frame de fallback :
- Fond `Surface` `#0E0E0E` (pas du noir pur, pour que l'utilisateur perçoive un cadre, pas un vide)
- Glyphe centré : petite icône offline/broken-image, couleur `Text tertiary`
- Une seule ligne de caption, `SF Pro Text 13pt`, `Text secondary` : "Couldn't load this story"
- Un bouton `Retry`, 44pt minimum, low-emphasis (texte uniquement, blanc à 70%)
- L'auto-advance est en pause tant que le frame d'échec est visible. Le tap-forward fonctionne toujours.

Pas d'haptique sur l'échec (HIG : ne pas punir l'utilisateur pour les conditions réseau).

## Principes de motion

Le motion révèle la qualité. Le reviewer le ressentira même inconsciemment.

### Tokens de durée

Toutes les durées passent par des tokens nommés. Pas de `0.2`/`0.3`/`0.4` hardcodés dans les views. Cela achète deux choses : un feel cohérent entre composants, et un override d'une seule ligne pour `accessibilityReduceMotion` (faire collapser les trois à `0` et passer les transitions à `.identity`).

```
Motion.fast            = 0.2s   // micro-feedback : fade overlay pause, état tap
Motion.standard        = 0.3s   // affordances primaires : spring du like, fade header
Motion.slow            = 0.4s   // crossfade d'état du ring, dismiss
Motion.itemPlay        = 5.0s   // durée d'un item (remplissage progress bar)
Motion.skeletonPulse   = 1.2s   // un cycle complet d'opacité du tray skeleton (loading)
```

`itemPlay` et `skeletonPulse` sont listés à côté des tokens de transition one-shot délibérément : le même enum/extension est la source de vérité unique pour n'importe quelle durée dans le codebase. Les éclater dans un enum "cyclique" séparé rendrait l'override reduced-motion (collapse-to-zero) à deux endroits au lieu d'un.

Implémentation : extension `Animation` (ou un enum `Motion` retournant `Animation`) avec des propriétés statiques nommées. Toujours référencer les tokens depuis les views, jamais des secondes en littéral.

### Reduced motion

`@Environment(\.accessibilityReduceMotion)` est respecté globalement :
- Animation de la progress bar : remplacée par un tick discret en fin d'item. L'auto-advance se déclenche toujours ; la barre ne s'anime simplement plus.
- Crossfade du ring sur transition seen : remplacé par un swap instantané.
- Spring du like : remplacé par un swap couleur/fill instantané (pas de scale pop).
- Fade overlay pause : instantané.

L'auto-advance est **conservé** sous reduced motion — le désactiver casserait le produit. L'utilisateur peut toujours taper forward/back ; l'avance time-driven n'a juste plus de barre animée pour la télégraphier.

### Timing & courbes

- **Linear** pour les progress bars uniquement. Tout autre courbe a l'air cassé.
- **Ease-out** (défaut SwiftUI) pour les fades UI, changements d'opacité, dismissals.
- **Spring** pour les affordances qui répondent au touch utilisateur (like, feedback de tap).
- Ne jamais utiliser `easeIn` seul — feel mou.

### Animations spécifiques

```
Open viewer (tray → fullscreen)
    fullScreenCover par défaut, pas de transition custom
    Rationale : matched geometry coûte ~1.5h, gain visuel marginal

Like tap
    spring(response: 0.3, dampingFraction: 0.6)
    scale : 0.8 → 1.2 → 1.0
    haptic : .impact(.medium) au moment du tap
    couleur : stroke white → fill #FF3B30, crossfade 0.2s

Progress bar fill
    .linear(duration: itemDuration)
    Reset instantané au changement d'item (pas d'animation arrière)

Pause (long press)
    UI overlay opacity 1 → 0, ease-out 0.2s
    Le timer de progress bar se met en pause, la progression visuelle gèle

Swipe entre users
    Transition par défaut du TabView page style
    Rationale : transition cube coûte ~1j, le défaut fonctionne très bien

Transition seen du ring
    Unseen → seen au dismiss
    Crossfade entre les couleurs de ring, 0.4s ease-out
    Jamais de snap, jamais de pop

Swipe down dismiss
    Binaire : seuil 100pt OU vélocité > 500pt/s → dismiss
    Rationale : dismiss interactif skippé pour le temps
```

### Haptiques

Subtiles. Apple HIG : ne jamais spammer les haptiques. Utiliser uniquement aux moments décisifs.

```
Like                .impact(.medium)
Changement user     .impact(.soft)
Dismiss             .impact(.light)
Échec/erreur image  aucune (ne pas punir l'utilisateur)
```

Wrapper les haptiques UIKit dans un petit enum `Haptics` dans `Core/`.

## Catalogue de composants

Ils vivent dans `DesignSystem/Components/`. Chacun doit avoir une preview SwiftUI montrant tous les états pertinents.

### `StoryRing`

```swift
StoryRing(state: .seen | .unseen | .loading, size: CGFloat)
```

Rend uniquement le ring (pas l'avatar). Composable. Le gap de 3pt entre ring et avatar est imposé en interne.

États :
- `.unseen` — blanc plein, 2pt
- `.seen` — `#2A2A2A` plein, 1.5pt
- `.loading` — blanc avec animation pulse d'opacité

### `StoryAvatar`

```swift
StoryAvatar(url: URL, ring: StoryRingState, size: CGFloat)
```

Combine l'image avatar (chargée via Nuke) et `StoryRing`. Trois états internes : loading (le ring pulse, l'intérieur est `Surface elevated`), loaded (l'image remplit l'intérieur), failed (glyphe d'initiales sur `Surface elevated`, pas d'haptique, pas de spam de log).

### `SegmentedProgressBar`

```swift
SegmentedProgressBar(
    count: Int,
    currentIndex: Int,
    progress: Double  // 0...1, ne s'applique qu'à currentIndex
)
```

Rendu pur, pas de logique d'animation. Le ViewModel du viewer pilote `progress` dans le temps. Les segments avant currentIndex sont pleins, après sont vides.

### `LikeButton`

```swift
LikeButton(isLiked: Bool, action: @MainActor () -> Void)
```

Icône cœur, 28pt. Blanc non rempli quand non liké, rempli `#FF3B30` quand liké. Déclenche haptique et animation spring en interne au tap.

### `StoryTrayItem`

```swift
enum StoryTrayItemState {
    case loaded(user: User, isFullySeen: Bool)
    case loading                                  // skeleton : ring qui pulse + avatar Surface elevated + placeholder username grisé
    case failed(retry: () -> Void)                // tap pour retry la pagination
}

StoryTrayItem(state: StoryTrayItemState, density: TrayDensity = .regular, onTap: () -> Void = {})
```

Compose `StoryAvatar` + label de username. Tronque les usernames longs avec `.lineLimit(1)` et `.truncationMode(.tail)`. La `density` n'affecte que le spacing du `HStack` parent dans le tray, pas l'item lui-même ; passer la prop ici la garde colocalisée avec son consommateur.

Les trois états partagent exactement la même géométrie extérieure (diamètre d'avatar, gap du ring, hauteur du label) — changer d'état ne doit jamais reflow les items voisins. Les états loading et failed ne déclenchent aucun haptique. L'état failed remplace le ring par un glyphe d'avertissement `Text tertiary` et le username par le mot "Retry" ; un tap appelle `retry`.

### `StoryViewerHeader`

```swift
StoryViewerHeader(user: User, timestamp: Date, onClose: () -> Void)
```

Avatar (petit, sans ring) + username + timestamp relatif + bouton de fermeture.

## États de loading & d'empty

Trois endroits dans le produit peuvent afficher un "loading" ; chacun a un traitement défini pour qu'ils ne se chevauchent jamais visuellement.

### 1. Bootstrap de l'app

`StoriesTestApp` hydrate `StoryListViewModel` depuis un `.task` (l'init du store d'état persisté est `async throws`). Pendant ce run, on rend `LoadingView` :

- `Background` (`#000000`) plein écran
- Un `ProgressView` blanc 24pt centré — pas de logo, pas de copy, pas de fade

En pratique, l'hydration se termine en <50ms, donc la view existe pour la correction, pas comme une surface designée. La garder minimale est intentionnel : un splash designé flasherait visiblement pendant ~3 frames et donnerait l'impression d'un glitch.

### 2. Loading initial du tray (page 0 pas encore prête)

Quand `StoryListViewModel.pages` est vide et `isLoading == true`, rendre un **tray skeleton** :

- 8 instances `StoryTrayItem` en état `.loading` dans le `HStack`
- Chacune montre un ring qui pulse (token `Ring loading` existant) + un cercle `Surface elevated` à la place de l'avatar + un rectangle `Skeleton label width × Skeleton label height` arrondi en `Text tertiary @ 30% opacity` à la place du username
- L'animation pulse cycle à `Motion.skeletonPulse` (1.2s pour un round-trip complet 0.4 → 1.0 → 0.4 d'opacité) — `accessibilityReduceMotion` collapse à 70% d'opacité statique (pas de pulse)
- Pas de spinner global au-dessus du tray — le skeleton **est** l'indicateur

Le skeleton bat le spinner ici parce que l'utilisateur voit la *forme* de ce qui arrive (un carrousel horizontal de stories), donc la transition vers le contenu chargé est un swap de contenu, pas un remplacement d'écran.

### 3. Pagination (page N+1 pendant le scroll)

Quand `isLoadingMore == true`, append un seul `StoryTrayItem(.loading)` trailing au tray. Il utilise le même traitement skeleton que le loading initial. Retiré quand la nouvelle page arrive.

Le trigger N-3 fait qu'en pratique l'utilisateur atteint rarement la fin avant que la page suivante ne soit appendée ; le skeleton trailing n'est visible que sur réseau lent. Le trade-off (a) "pas d'indicateur" a été rejeté à cause de l'edge case d'échec de pagination ci-dessous : sans skeleton, une pagination en échec laisse l'utilisateur silencieusement à la fin d'un tray qui ne s'étendra pas, sans signal du pourquoi.

### 4. Échec de pagination

Quand `loadPage(currentPage + 1)` throw et que `isLoadingMore` repasse à `false`, le skeleton trailing transitionne en `StoryTrayItem(.failed(retry:))` :

- Ring remplacé par un glyphe SF Symbol `exclamationmark.triangle` à `Skeleton glyph size` (28pt), centré dans la slot avatar 64pt, teinté `Text tertiary`
- Username remplacé par le mot "Retry" en `Text secondary`
- Tap appelle `viewModel.loadMoreIfNeeded()` — même chemin que l'auto-trigger, donc le succès collapse l'item failed en page fraîche silencieusement
- Pas d'haptique, pas de toast, pas d'alerte — cohérent avec le reste du chrome d'erreur du produit

C'est la seule surface d'échec dans le tray. Les erreurs au niveau liste (JSON corrompu, repository indisponible) escaladent vers un empty-state plein écran avec la même affordance retry, pas une row inline.

## Discipline des previews

Chaque composant réutilisable a un bloc `#Preview` qui montre :

1. Le composant dans son état primaire
2. Toutes les variantes significatives dans un `VStack` ou `Group`
3. Les deux avec données réalistes et cas limites (vide, longueur max, etc.)

Les previews sont de la documentation. Un reviewer qui scrolle les fichiers devrait comprendre le système rien qu'avec les previews.

## Accessibilité

Les wins peu coûteux et à fort signal sont dans le scope :

- Tous les éléments interactifs ont `.accessibilityLabel`
- Le bouton like a `.accessibilityValue("liked" / "not liked")`
- Tap targets ≥ 44pt
- Labels VoiceOver pour le bouton de fermeture
- **Reduced motion** : respecté globalement via `Motion.fast/standard/slow` qui collapsent à `0` et les transitions ring/like qui deviennent instantanées. L'auto-advance se déclenche toujours sur un tick discret (pas de barre animée), le tap-through fonctionne toujours. Voir *Principes de motion → Reduced motion*.

Skippé (mentionné dans le README) :
- Support Dynamic Type (l'UI Stories est intentionnellement à taille fixe ; matche Instagram).
- Navigation VoiceOver entre items (pas d'item rotor ; tap forward/back est le seul flow).
