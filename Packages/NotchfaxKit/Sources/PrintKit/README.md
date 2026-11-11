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
- `PhotoStripContent(frames:caption:)` — four `CGImage`s; `Paper.stripFrameRects(contentSize:)` gives the frame boxes.
- `PaperSurface(.thermal) { ... }` — live paper for content still being edited.

### Job options

```swift
PrintJob(
    sheet,
    reveal: .progressive(lineHeight: 14),   // print line by line as it feeds; default .withPaper
    cadence: nil,                           // override the motor rhythm (FeedCadence)
    autoRetract: .after(10),                // or .never
    interaction: .all,                      // [.grab, .detach, .dragOut]
    export: PNGExport(filename: "那年今日 2019") { try await fullResolutionPNG() },
    actions: [
        PaperAction(id: "reply", title: "回复", systemImage: "arrowshape.turn.up.left.fill") { _ in compose() },
        PaperAction(id: "tear", title: "撕掉", systemImage: "scissors") { $0.tearOff() },
        PaperAction(id: "report", title: "举报", role: .destructive) { handle in report(); handle.retract() },
    ],
    onEvent: { event, handle in ... }
)
```

- **Reveal.** `.progressive` advances one line per motor burst and lets the ink
  darken just below the slot. Use it for fax text. The sheet hangs upright, so the
  bottom of the page comes out first.
- **Export.** The closure runs once, right after the sheet finishes feeding, and
  its PNG is written to a temporary file. If the user drags the sheet away before
  it has returned, the sheet as rendered on screen is exported instead. Without an
  `export` that is always what is exported.
- **Actions** appear as a small bar under the sheet while the pointer is on it.
  The handler gets the `PrintHandle`; nothing happens to the sheet unless the
  handler asks (`retract()`, `tearOff()`, `cancel()`).

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

`.torn` is sent at the moment of the tear; if the torn sheet is then dropped on
another app, `.draggedOut` follows and is the outcome.

### What the user can do to a sheet

| Gesture | Thermal | Photo / strip |
|---|---|---|
| Grab and move a little | Swings from the slot with resistance, springs back | Same |
| Rip sideways, or pull hard | Tears at the slot (`.torn`), then falls away when released | Slips out of the slot into the hand; goes back to the slot when released |
| Carry it well away from the slot | Becomes a real PNG file drag (`.draggedOut` if a target accepts it) | Same; if nothing accepts it, it returns to the slot |
| Click | `.tapped` | `.tapped` |
| Leave it alone | Retracts after `autoRetract` | Same |

While the motor is running the sheet can be swung but not removed. Catching a
sheet that is retracting brings it back out.

### Queue

One sheet occupies the slot at a time; other jobs wait in order. When a job is
waiting, the hanging sheet is retracted after `Printer.Configuration.handoffDelay`
(1.4 s) without the pointer on it, even if its own policy is `.never`. A torn
sheet frees the slot immediately. `handle.cancel()` removes a waiting job or
fades out a visible one; `printer.cancelAll()` does both for everything.

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
- `dismissesOnOutsideClick`, `dismissesOnEscape` (Escape needs `acceptsKeyboard`).
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
- `PrintSamples.fax()`, `.photo()`, `.strip()` are ready-made jobs;
  `PrintSamples.landscape` and `.portrait` are procedural stand-in pictures (the
  photo booth can use `portrait` as its simulated camera on a Mac without one).
- `Gallery.render(to:)` draws every paper type offscreen through the same layer
  tree the live stage uses. The app exposes it as `Notchfax --render-gallery <dir>`.

App launch flags for scripted runs: `--demo fax,photo,strip,all,viewfinder,compose,compose-send`
and `--quit-after <seconds>`.

## How it is put together

| File | Role |
|---|---|
| `Printer.swift` | Public entry point; queue coordination |
| `PrintJob.swift` | `Paper`, `PaperSheet`, `PrintJob`, `PrintEvent`, `PrintHandle` |
| `PrintQueue.swift`, `FeedProgram.swift`, `Motion.swift`, `SlotGeometry.swift` | Pure logic, unit-tested |
| `PaperRenderer.swift` | Stock, thermal printing, edges, serration, shadows |
| `SheetNode.swift` | Layer tree of one sheet |
| `SheetController.swift` | One sheet's state machine and physics |
| `Stage.swift` | Windows, frame clock, pointer routing, drag-out, action bar |
| `Presentation.swift` | Views anchored under the slot |
| `Sound.swift` | Synth and playback |
| `Menu.swift` | `FeatureModule`, menu contributions |
| `PaperViews.swift`, `Samples.swift`, `Gallery.swift` | Reusable content, samples, offscreen gallery |

Three borderless, non-activating panels sit above the menu bar: presentations, the
drawn slot, and a full-screen stage for paper. The stage ignores the mouse except
while the pointer is over paper or the action bar, so everything under it stays
clickable.
