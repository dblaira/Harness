# Harness Design Vocabulary

**The rule: if a word, icon, font, or color is not in this file, it is not
used in Harness.** Every token below is quoted verbatim from Adam's shipped
apps — SAVY-iOS, Understood (iOS), understood-app (web), Re_Call — with its
source cited. New needs come back to Adam as one question.

Compiled 2026-07-06 from the four public repos at github.com/dblaira.

---

## Colors

### Shared suite palette

| Token | Hex | Source |
|---|---|---|
| Crimson (primary accent) | `#DC143C` | `Brand.crimson` (SAVY `ReminderBrandTheme.swift`), `understoodCrimson` (Understood `Colors.swift`), `--color-red` (understood-app `style.css`), `crimson` (Re_Call `Theme.swift`) |
| SAVY shell crimson | `#E60E44` | `SavyTheme.crimson` (SAVY `RootView.swift`) — FAB, active tabs, dividers |
| Deep navy (hero/page) | `#08172D` | `SavyTheme.deepNavy` |
| Navy page | `#0A1626` | `Brand.page` (SAVY, Re_Call) |
| Near black (dark cards, FAB options) | `#0C1E33` | `Brand.nearBlack` |
| Cream card | `#F3EAD5` | `Brand.card` (SAVY, Re_Call), `RecallFormBrand.card` (Understood) |
| Paper | `#F8F4ED` | `SavyTheme.paper` |
| Paper accent | `#EFEBE4` | `SavyTheme.paperAccent` |
| Tan band | `#D5C194` | `Brand.tan` (SAVY, Re_Call) |
| Bottom-nav tan | `#CCB394` | `SavyTheme.bottomNavTan` |
| Dark red (rank-2 card, delete swipe) | `#B00124` | `Brand.darkRed` |
| Ink | `#000000` | `Brand.ink`, `SavyTheme.ink` |
| Beige | `#E8E2D8` | `understoodBeige` (Understood), `understood-beige` (web tailwind) |
| Editorial cream | `#F5F0E8` | `understood-cream` (understood-app) |

### Status colors (the readiness palette)

| Token | Hex | Meaning | Source |
|---|---|---|---|
| Live dot | `#29B859` | live content / connected | SAVY `SavyShellComponents` status dot `Color(red: 0.16, green: 0.72, blue: 0.35)` |
| Pending dot | `#DB731F` | seed / pending sync | SAVY status dot `Color(red: 0.86, green: 0.45, blue: 0.12)` |
| Action green | `#22C55E` | completed action | `actionGreen` (Understood `Colors.swift`) |
| Overdue red | `#EF4444` | overdue action | `overdueRed` (Understood) |
| Failed text | crimson `#DC143C` | failed status text | SAVY content status band |

### Harness macOS palette (shipped in `Sources/Harness/Theme.swift`)

Harness mac surfaces are SAVY light: `macBg` = paper `#F8F4ED`, `macInk` ink
`#000000`, `macEntry` cream card `#F3EAD5`, `macBarBg`/`macTan` bottom-nav tan
`#CCB394`, `macRed` SAVY shell crimson `#E60E44`, `macHair` black @8%,
`macFaint` black @45%, `macMuted` black @62%. SAVY tokens quoted verbatim from
SAVY-iOS: `savyDeepNavy #08172D`, `savyCrimson #E60E44`, `savyGreen #2AB860`
(`SavyTheme.green`), `savyCard #F3EAD5`, `savyPaper #F8F4ED`, `savyPaperAccent
#EFEBE4` (`SavyTheme.paperAccent`), `savyBeliefCard #F5F0E6`
(`SavyTheme.beliefCard`), `savySectionBand #F4EFE7` (`SavyTheme.sectionBand`),
`savyTabActive #2E2716` (`Brand.tabActive`), `savyBottomNavTan #CCB394`,
`savySecondaryText` black @62%, `savyTertiaryText` black @45%.

The SAVY component set lives in `Sources/Harness/SavyComponents.swift`, each
ported from SAVY-iOS with its source cited in code: `SavyHeroHeader`
(display serif 48–64 + crimson divider, navy and paper variants),
`SavyEyebrowBand` (15pt heavy, tracking 2.5, tan on navy), the four card
species `SavyLeverageCard` (white, shadow black @5% radius 10 y 4),
`SavyStoryCard` (cream, flat), `SavyQuoteCard` (white, crimson bar, shadow
black @6% radius 12 y 5), `SavyDarkCard` (near-black, white @8% hairline),
plus `SavyLockedInToast` (the `"Locked In"` save confirmation, shadow black
@20% radius 28 y 12) and `SavyTagChip` (15pt semibold capsule).
`SavyComponentTypography.timesSerif` is the Times New Roman quote/carousel
serif already listed under Fonts.

---

## Fonts

| Role | Font | Source |
|---|---|---|
| Display serif (headlines, heroes) | Bodoni: `"Bodoni 72 Oldstyle"` → `"BodoniModa-Regular"` fallback | `SavyTypography.displaySerif` (SAVY); `Bodoni Moda` (understood-app) |
| Alternate display serif | `"PlayfairDisplay"` | Understood `Typography.swift` (48pt hero, 34pt empty state) |
| Label / list sans | `"Roboto-Medium"` | SAVY belief list; bundled in Harness `Sources/Harness/Fonts` |
| Body sans | Inter (web/Understood) / SF Pro system (Re_Call, SAVY UI) | `Typography.swift`, system `.system(size:weight:)` |
| Quote serif | Georgia / Times New Roman | Understood versions; SAVY carousel titles |

Harness bundles `BodoniModa-Regular.ttf`, `PlayfairDisplay.ttf`,
`Roboto-Medium.ttf` — the exact families above.

### The eyebrow / band label pattern (signature look)

ALL CAPS, system font weight `.heavy`, letter tracking 1.4–2.5:
band titles (`"UP NEXT"`, `"PRIORITY"`) tracking 2.5; card kind badges 1.5;
carousel eyebrows 1.8; auth eyebrows 2.4. On dark navy the label color is
tan `#CCB394`; on light surfaces `black @ 45–62%` or crimson for emphasis.

---

## Words

### Status words (readiness / health)

| Word | Meaning | Source |
|---|---|---|
| `"live"` | connected and answering | SAVY `"Capture: live"` sync status |
| `"pending (n)"` | waiting on something | SAVY sync status |
| `"failed (message)"` | probe failed, message verbatim | SAVY sync status |
| `"Checking gateway…"` | probe in flight | SAVY `LeverageDataStore` |
| `"Completed"` / `"Overdue"` / `"Due Today"` / `"Upcoming"` | action states | Understood Actions view |
| `"explicit"` / `"implied"` / `"inferred"` | confidence levels | Understood extractions |
| `"candidate"` / `"confirmed"` / `"rejected"` / `"retired"` | axiom statuses | understood-app ontology |

### Entry kinds and form vocabulary (shared `EntryFormCopy` across the suite)

- Kinds: `"Reminder"`, `"Action"`, `"Event"`
- Section headers: `"Destination"`, `"Delegate"`, `"Pattern"`, `"Choose"`,
  `"Schedule"`, `"Organize"`, `"Details"`, `"Place / People"`
- Prompts: `"What do I want?"`, `"When I am...I like to"`, `"Done looks like..."`
- Fields: `"Steps"`, `"Add Step"`, `"Due"`, `"Start / defer"`, `"Nudge"`,
  `"End"`, `"Repeat"`, `"Early Reminder"`, `"Priority"`, `"Effort"`,
  `"Energy"`, `"Flag"`, `"Lift"`, `"Tags"`, `"Notes"`, `"Link"`, `"Image"`,
  `"Location"`, `"Waiting on / delegate to"`, `"None"`
- Save toast: `"Locked In"`
- Buttons: `"Cancel"`, `"Save"`, `"Done"`, `"Pin"`, `"Unpin"`, `"Delete"`,
  `"Reopen"`, `"Edit"`, `"Undo"`, `"Retry"`, `"Continue"`, `"Add"`, `"Change"`

### The Adam Pattern steps (verbatim, all repos)

`"Context"`, `"Circle"`, `"Close the Gap"`, `"Choose Success"`,
`"Code the Pattern"`, `"Create Kill Switch"`, `"Clear Sign of Success"`,
`"Compound"`

### Lift categories

`"Learning"`, `"Leverage"`, `"Delegation"`, `"Inspiration"`, `"Risk"`, `"Health"`

### Picker values

- Priority: `"None"`, `"Low"`, `"Medium"`, `"High"` — marks `"!"`, `"!!"`, `"!!!"`
- Effort: `"—"`, `"5m"`, `"15m"`, `"30m"`, `"1h"`, `"2h+"`
- Energy: `"—"`, `"Low"`, `"Med"`, `"High"`
- Repeat: `"Never"`, `"Daily"`, `"Weekdays"`, `"Weekly"`, `"Monthly"`, `"Yearly"`

### Band / section labels

`"UP NEXT"`, `"PRIORITY"`, `"GREATEST LEVERAGE"`, `"FEATURED SIGNAL"`,
`"NEWS CHANNEL"`, `"PINNED"`, `"COMPLETED"`, `"MOMENTS"`, `"MORE STORIES"`,
`"LATEST STORIES"`

### Kicker labels

`"PROCESS ANCHOR"`, `"PATTERN INTERRUPT"`, `"VALIDATED PRINCIPLE"`, `"PINNED"`

### Taglines already in the family

`"What matters next."`, `"Choose the move that matters."`,
`"Time blocks live on the calendar."`, `"The map of leverage."`,
`"Principles worth keeping close."`, `"Start with the move already shaped."`

---

## Icons (SF Symbols → concept)

| Symbol | Concept | Source |
|---|---|---|
| `bolt` / `bolt.fill` | Action / energy / the FAB | all repos |
| `bell` | Reminder / Nudge | all repos |
| `clock` | Reminder kind / time | Re_Call, SAVY |
| `calendar` | Event / Due | all repos |
| `calendar.badge.clock` | Start / defer | form |
| `clock.badge.checkmark` | End time | form |
| `checklist` | Steps | form |
| `list.number` | Pattern step | form |
| `exclamationmark.3` | Priority | form |
| `timer` | Effort | form |
| `sparkles` | Lift / AI activity | form, Understood |
| `tag` | Tags | form |
| `clock.arrow.circlepath` | Recent tags | form |
| `flag` | Flag | form |
| `person` | Waiting on / delegate | form |
| `mappin.and.ellipse` / `location` | Location | form |
| `message` | When messaging a person | form |
| `photo` | Image | form |
| `checkmark` / `checkmark.circle.fill` | Done / saved | all repos |
| `xmark` / `xmark.circle` / `xmark.circle.fill` | Close / cancel / remove | all repos |
| `pin` / `pin.fill` | Pin | SAVY, Re_Call |
| `trash` | Delete | all repos |
| `arrow.uturn.left` | Reopen | SAVY |
| `chevron.*` | Navigation / expand | all repos |
| `chevron.up.chevron.down` | Menu affordance | form |
| `house` | Now / home | SAVY, Understood |
| `line.3.horizontal` | Account menu | SAVY |
| `magnifyingglass` | Search | SAVY |
| `briefcase.fill` | PRO | Re_Call |
| `checkmark.seal.fill` | Validated principle | Understood |
| `shield.fill` | Identity anchor | Understood |
| `arrow.triangle.2.circlepath` | Pattern interrupt | Understood |
| `list.bullet.rectangle.fill` | Process anchor | Understood |
| `lightbulb.fill` | Connection (default) | Understood |
| `exclamationmark.triangle` | Error / overdue | Understood |
| `gearshape` | Settings | Understood |
| `faceid` | Face ID | SAVY |
| Custom floppy-disk shape | Save | SAVY/Re_Call/Understood (not an SF Symbol) |

---

## Status display pattern (how readiness is shown)

From SAVY's content status band, the suite's one way to show whether a
source is ready:

- **small colored dot + status word** in the band-label style
- green dot `#29B859` + `"live"` — working now
- orange dot `#DB731F` + `"pending"` — waiting on one named action
- `"failed (message)"` — text in crimson, message verbatim
- `"Checking gateway…"` — while a probe runs

Harness uses this exact treatment for backend readiness. No other status
visual (no traffic lights, no badges, no invented iconography).
