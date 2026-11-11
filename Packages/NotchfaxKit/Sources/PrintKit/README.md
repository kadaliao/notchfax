# PrintKit

The print engine behind Notchfax: the slot at the top of the screen, the paper that
comes out of it, how that paper moves and sounds, and the queue of jobs.

Features (`Memories`, `PhotoBooth`, `FaxKit`) depend only on this module. Everything
public is `@MainActor` unless marked `Sendable`.

## Registering a feature

Each module exposes one class conforming to `FeatureModule`. The app shell already
creates `MemoriesFeature`, `PhotoBoothFeature` and `FaxFeature` (see
`App/AppDelegate.swift`), so a feature never has to touch the app target.

```swift
import PrintKit

@MainActor
public final class MemoriesFeature: FeatureModule {
    private let printer: Printer

    public init(printer: Printer) {
        self.printer = printer
        printer.menu.addSection(id: "memories", order: 10) { [weak self] in
            [.action("打印那年今日", systemImage: "photo.on.rectangle") { self?.printToday() }]
        }
    }

    public func start() { /* called once the slot is on screen */ }
}
```

## Printing

```swift
let sheet = PaperSheet(.glossyPhoto) { PhotoPrintContent(image: cgImage, date: takenAt) }
let handle = printer.enqueue(PrintJob(sheet))

await handle.finishedFeeding()          // the whole sheet is out
let outcome = await handle.outcome()    // .torn, .draggedOut(url), .retracted or .cancelled
```

`await printer.print(job)` is shorthand for enqueue + `outcome()`.

### Paper

| `Paper` | Default size (pt) | Notes |
|---|---|---|
| `.thermal` | 160 wide, height fits the content | Content is converted to a 1-bit thermal print. Tears along a serrated edge. |
| `.glossyPhoto` | 164 on the long side, follows the image's aspect ratio | White border, gloss sheen that follows the pointer and the sheet's movement. |
| `.photoStrip` | 84 × 268 | Four frames and a caption band. |

`PaperSheet(_:size:content:)` takes a SwiftUI view builder, a `CGImage`
(`PaperSheet(.thermal, image: dithered)`) or nothing. Content is laid out in
`paper.contentRect(in: size)` and rasterised once when the job starts, so it must
not depend on later state. Pass `size:` to override the default; sheets wider than
`printer.slot.maxPaperWidth` (165 pt under a real notch) are scaled down to fit.

Ready-made content:

- `PhotoPrintContent(image:date:)` — a photo with the orange dot-matrix `DateStamp` bottom-right.
- `DateStamp(date)` / `DateStamp(text: "'98 11 11")` — the stamp on its own.
- `ThermalBitmap(image)` — a 1-bit picture, dot for dot (see below).
- `PhotoStripContent(frames:caption:)` — four `CGImage`s; `Paper.stripFrameRects(contentSize:)` gives the frame boxes.
- `PaperSurface(.thermal) { ... }` — live paper for content still being edited.

### Job options

```swift
PrintJob(
    sheet,
    reveal: .progressive(lineHeight: 14),   // print line by line as it feeds; default .withPaper
    cadence: nil,                           // override the motor rhythm (FeedCadence)
    autoRetract: .after(10),                // or .never
    interaction: .all,                      // [.grab, .detach, .dragOut]; [] = inert
    export: PNGExport(filename: "那年今日 2019") { try await fullResolutionPNG() },
    actions: [
        PaperAction(id: "reply", title: "回复", systemImage: "arrowshape.turn.up.left.fill") { _ in compose() },
        PaperAction(id: "hangup", title: "挂断", systemImage: "phone.down.fill") { $0.tearOff() },
    ],
    priority: .normal,                      // or .ambient
    readingTime: 8,                         // how long it stays out before a waiting job may replace it
    onEvent: { event, handle in ... }
)
```

- **Reveal.** `.progressive` advances one line per motor burst and lets the ink
  darken just below the slot. Use it for fax text. The sheet hangs upright, so the
  bottom of the page comes out first.
- **Export.** Three forms: `PNGExport(filename:)` exports the sheet as printed under
  your file name; `PNGExport(filename:) { ... }` takes a `@Sendable` closure for a
  composite made off the main actor; `PNGExport(filename:onMainActor:)` takes a
  main-actor closure. A closure runs once, right after the sheet finishes feeding;
  if the sheet is dragged away before it returns, the sheet as printed is exported.
- **Actions** appear as a small bar under the sheet while the pointer is on it.
  The handler gets the `PrintHandle`; nothing happens to the sheet unless the
  handler asks (`retract()`, `tearOff()`, `cancel()`).
- **Interaction.** With `interaction: []` and no actions the sheet is scenery: it
  has no hit area and clicks pass through it.
- **Priority and reading time** are described under *One thing under the slot* below.

### Pre-dithered pictures on thermal paper

Thermal paper is always rendered at `Paper.thermalDotsPerPoint` (2), and a default
sheet is `Paper.thermalContentDots` (276) dots wide. `ThermalBitmap(image)` draws a
1-bit picture at exactly one image pixel per dot, never interpolated; pure black and
white pass through the thermal conversion as they are (only the print head's uneven
density is added), so the dots you dithered are the dots that print. Dither at 276
wide or less and keep the sheet at its default width.

### Captions on a photo's border

For `.glossyPhoto`, a bare `CGImage` gets the faint emulsion edge automatically. A
view does not: it draws its own picture and may leave part of the content area as
white border for a caption. Put `.photoEmulsionEdge()` on the picture itself
(`PhotoPrintContent` already does).

### Events

`PrintEvent`: `.startedFeeding`, `.finishedFeeding`, `.tapped`, `.action(id:)`,
`.torn`, `.draggedOut(URL?)`, `.retracted`, `.cancelled`. Receive them through
`PrintJob.onEvent`, or iterate `handle.events` (an `AsyncStream` that finishes when
the sheet is gone):

```swift
for await event in handle.events {
    if case .tapped = event { openDetail() }
}
```

`.torn` is sent when a tear is complete (the sheet is free of the roll); if the torn
sheet is then dropped on another app, `.draggedOut` follows and is the outcome.

### What the user can do to a sheet

| Gesture | Thermal | Photo / strip |
|---|---|---|
| Grab and move a little | Swings from the slot with resistance, bends below the hand, springs back | Same, stiffer |
| Rip sideways, or pull hard | A tear starts at the far edge and travels across with the pointer; a stub is left under the slot and retracts. `.torn` is sent when the tear is complete | Slips out of the slot into the hand |
| Let go part-way through a tear | Past half way it finishes by itself. Before that it hangs by what is left, and gives way after a couple of seconds | — |
| Let go of a loose sheet (including a throw) | Flutters down and fades. Never creates a file | Drifts back to the slot and is gripped again |
| Carry it well away from the slot **and slow down or stop** | Becomes a real PNG file drag (`.draggedOut` if a target accepts it; otherwise it falls away) | Same; if nothing accepts it, it returns to the slot |
| Click | `.tapped` | `.tapped` |
| Leave it alone | Retracts after `autoRetract` | Same |

A file drag only begins once the pointer is outside a zone of roughly 260 pt around
the hanging sheet and has been moving slower than about 260 pt/s for 0.18 s, the way
a hand slows when it aims at a folder. A sheet released while still moving fast is a
throw, not a drop.

While the motor is running the sheet can be swung but not removed. Catching a
sheet that is retracting brings it back out.

## One thing under the slot

The printer has one policy for everything that shares the slot, so features never
need to look at each other.

- **A sheet occupies the slot** from the moment it starts feeding until it is
  retracted, torn off or dragged away. A torn sheet frees the slot at once.
- **Jobs wait in line**: ordinary jobs in order, then `.ambient` ones. When an
  ordinary job is waiting, the sheet that is out is taken back once it has been out,
  untouched, for its `readingTime` (default: `Printer.Configuration.handoffDelay`,
  1.4 s), even if its own policy is `.never`. Hovering restarts the clock.
- **`.ambient` jobs** are things nobody asked for just now (a daily photo, the
  welcome slip). They wait behind every ordinary job and never displace a sheet a
  person asked for; a waiting ambient job only moves another ambient sheet along.
- **A presentation takes precedence over paper.** When one opens, a sheet that is out
  is drawn back into the slot (*stowed*) and comes out again about half a second
  after the presentation has closed, without new events. Jobs enqueued meanwhile
  wait, and if one is waiting when the presentation closes, it prints instead of the
  stowed sheet coming back. `Options.hangingSheet` can ask for `.retract` (gone for
  good) or `.leave`. Retracting or tearing a stowed sheet ends it where it is.
- **One presentation at a time.** Presenting while another is open closes the first.

`printer.activity` (`SlotActivity`) says what is going on: `sheet` (`.none`,
`.feeding`, `.hanging`, `.stowed`), `isPresenting`, `waitingJobs`, and `isIdle`.
Optional things pick their moment with it:

```swift
// Show a notice only when nothing is out, open or waiting.
observation = printer.observeActivity { [weak self] activity in
    if activity.isIdle { self?.showNextNotice() }
}
await printer.waitUntilIdle()
```

`handle.cancel()` removes a waiting job or fades out a visible one;
`printer.cancelAll()` does both for everything.

## Presenting a view under the slot

```swift
let presentation = printer.present { presentation in
    ViewfinderView(onShutter: {
        printer.sound.play(.shutter)
        presentation.dismiss()
    })
}
```

The view hangs from the top edge of the screen inside a black body that reads as
the notch grown larger, slides down on a spring and slides back up on `dismiss()`.
Its content starts below the notch/slot automatically. `SlotPresentation.Options`:

- `chrome`: `.machine` (default) or `.none` (the content draws everything).
- `acceptsKeyboard`: lets text fields take input without activating the app.
- `hangingSheet`: `.stow` (default), `.retract` or `.leave`; see *One thing under the slot*.
- `dismissesOnOutsideClick`, `dismissesOnEscape` (Escape needs `acceptsKeyboard`). A
  click in an open/save panel or an alert raised from the presentation is not an
  outside click.
- `onDismiss`: called once however it ends.

The panel is sized to the content's fitting size and follows size changes.

### Sending paper up into the slot

The reverse of printing, for sending a fax:

```swift
let presentation = printer.present(options: .init(chrome: .none, acceptsKeyboard: true)) { presentation in
    ComposeView(onSend: { text in
        let sheet = PaperSheet(.thermal, size: CGSize(width: 160, height: 150)) { FaxPage(text) }
        Task { await presentation.feedIntoSlot(sheet, topOffset: 26) }
    })
}
```

`feedIntoSlot(_:topOffset:)` fades the presentation's content, puts `sheet` exactly
where the paper was (centred under the slot, its top `topOffset` points below the
top of the content), glides it up to the slot and feeds it in with the motor
cadence, then dismisses. It returns when the paper is fully inside. Draw the paper
being edited with `PaperSurface` at the same size so the swap is invisible; a
working example is `ComposeDemo` in `App/DebugSamples.swift`.

Without a presentation, `printer.feedIntoSlot(_:startingBelowSlot:)` does the same
from a given distance below the slot.

## Menu items

```swift
printer.menu.addSection(id: "fax", order: 30) {
    [
        .action("写传真…", systemImage: "square.and.pencil") { compose() },
        .action("接收传真", isOn: isOnline) { toggleOnline() },
        .submenu(title: "线路", items: lines.map { line in .action(line.name) { open(line) } }),
        .label("今日还可发送 3 封"),
    ]
}
```

`.action` also takes `shortcut: MenuShortcut("b", modifiers: [.control, .option, .command])`,
shown beside the item (it works while the menu is open; register a global hot key
separately if it should work everywhere).

The closure runs every time the menu opens, so it can reflect current state.
Sections are ordered by `order`, then `id`, and separated automatically. The app's
own items (调试, 静音, 登录时启动, 退出) come last.

## Sound and haptics

`printer.sound.play(_:)` with `SoundEffect`: `.feedStep(duration:variant:)`,
`.cutter`, `.tear`, `.shutter`, `.slip`, `.thunk`, `.tick`. All are synthesised;
the engine starts on first use and stops after a few idle seconds. The engine
already plays feed, cutter, tear and slip itself — features only need `.shutter`
and `.tick`. `printer.isMuted` silences everything.

## Slot geometry and debugging

- `printer.slot` (`SlotGeometry`): `kind` (`.notch`, `.simulatedNotch`, `.drawnSlot`),
  `mouth`, `slotLineY`, `centerX`, `maxPaperWidth`, in screen-local top-left coordinates.
- `printer.simulatesNotch = true` draws a 185 × 32 notch on a display without one
  (调试 → 模拟刘海, or launch with `--simulate-notch`).
- `printer.reducesMotion` mirrors the system setting; paper then fades in and out
  instead of feeding, and torn sheets fade instead of falling.
  `printer.debugForcesReducedMotion = true` (or `--reduce-motion`) turns that path on without touching the system setting.
- `PrintSamples.fax()`, `.photo()`, `.strip()` are ready-made jobs;
  `PrintSamples.landscape` and `.portrait` are procedural stand-in pictures (the
  photo booth can use `portrait` as its simulated camera on a Mac without one).
- `printer.debugPlayGesture(_:)` plays a scripted pointer gesture against the sheet in
  the slot through the real interaction code, without posting system events or moving
  the real pointer. Names are in `Printer.debugGestureNames`: `hover` (brings up the
  action bar), `swing`, `carry`, `carry-out`, `rip`, `half-tear`, `fling`. Also under 调试 → 模拟手势.
- `printer.debugPointerReport()` asks the window server which window a click would
  land on at the centre of the sheet, just beside it, below it and in the menu bar.
- `Gallery.render(to:)` draws every paper type offscreen through the same layer tree
  the live stage uses, and writes `motion-*.png` contact sheets: the same gestures run
  through the real sheet controller at 120 steps per second, photographed at set times
  with the phase and the scripted pointer marked. The app exposes it as
  `Notchfax --render-gallery <dir>`. (Layer shadows are not drawn by
  `CALayer.render(in:)`, so the gallery paints them itself from the same paths and radii.)

App launch flags for scripted runs: `--demo <steps>` where steps are sample names
(`fax`, `photo`, `strip`, `all`, `viewfinder`, `compose`, `compose-send`), `wait:<seconds>`,
`gesture:<name>` and `pointer-report`, run in order — for example
`--demo fax,wait:3,gesture:rip`. Plus `--simulate-notch`, `--reduce-motion`, `--quit-after <seconds>`.

## How it is put together

| File | Role |
|---|---|
| `Printer.swift` | Public entry point; queue coordination |
| `PrintJob.swift` | `Paper`, `PaperSheet`, `PrintJob`, `PrintEvent`, `PrintHandle` |
| `PrintQueue.swift`, `FeedProgram.swift`, `Motion.swift`, `SlotGeometry.swift` | Pure logic, unit-tested |
| `PaperRenderer.swift` | Stock, thermal printing, edges, serration |
| `SheetNode.swift` | Layer tree of one sheet: strips, bend, shadows |
| `SheetController.swift` | One sheet's state machine and physics; `SheetHost` |
| `Stage.swift` | Windows, frame clock, hit panels, drag-out, action bar |
| `Presentation.swift` | Views anchored under the slot |
| `Sound.swift` | Synth and playback |
| `Menu.swift` | `FeatureModule`, menu contributions |
| `MotionCapture.swift` | Scripted pointer gestures and the offscreen host that runs them |
| `PaperViews.swift`, `Samples.swift`, `Gallery.swift` | Reusable content, samples, offscreen gallery |

**Paper shape.** A sheet is cut into horizontal strips about 9 pt tall, each an
affine-mapped slice of one image. Shearing strips sideways bends the sheet in the
plane of the screen (the free end trails the hand, then catches up); squashing them
and widening them slightly reads as paper standing off the screen (roll curl, the
flick of each motor step). Tilt shading and gloss are one overlay cut to the bent
outline, and the two shadows follow the outline too, falling further and softer
where the paper stands off more.

**Windows.** Borderless, non-activating panels above the menu bar: presentations,
the drawn slot, a full-screen stage that never takes the mouse, and one invisible
hit panel per sheet that is kept exactly over the paper (and its action bar). The
window server therefore routes clicks itself; nothing is polled, and everything
outside the paper stays clickable. A click inside a tilted sheet's bounding box but
outside the paper is swallowed.
