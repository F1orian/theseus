# scripts/brand

Generators for the brand foundation (ADR 0140, `docs/design/brand.md`). The inputs are committed copies of the
staged brand export (`.scratch/brand/export/`, not in git); the outputs are generated Swift, never edited by hand.

| Script | Input | Output |
|---|---|---|
| `gen_sprites.py` | `sprites.json` (palette + nine poses + the petting frames, #174) | `Modules/Sources/DesignSystem/PixelMouseSprites.generated.swift` |
| `gen_working_mouse.py` | `working_mouse_scenes.py` (the 18 working-mouse scenes of #185, ported from the approved mock-up) + `sprites.json` | `Modules/Sources/DesignSystem/WorkingMouseFrames.generated.swift` (ADR 0146) |
| `gen_collection.py` | `collection.json` + the focal points, short artist names and extra slots in the script | `Modules/Sources/ArtCollection/Artwork+Catalog.generated.swift` |

After a new export (the export has no `frames`, the petting reactions of #174: merge them back in rather than
overwriting them):

```sh
cp .scratch/brand/export/sprites.json scripts/brand/ && scripts/brand/gen_sprites.py
scripts/brand/gen_collection.py --import-art /path/to/.scratch/brand/export   # copies art/*.jpg byte for byte
swift test --package-path Modules --filter "DesignSystemTests|ArtCollectionTests"
```

To change a working-mouse scene, edit its drawing in `working_mouse_scenes.py`, run `scripts/brand/gen_working_mouse.py`
(standard library only, deterministic), and look at every frame with
`THESEUS_WORKING_MOUSE_SHEET=$PWD/.scratch/working-mouse swift test --package-path Modules --filter WorkingMouseContactSheet`.
A scene's Reduce Motion frame is its `still` entry in `SCENES`.

Freestanding ink marks (the waiting `?`, the thought puffs; anything inked that isn't attached to the mouse or a prop)
use the ink glyph `k` (`INK`), never `K` (#192). `gen_sprites.py` adds `k` to the palette as `K`'s umber, so light mode
doesn't change; the app draws it light grey in dark mode. To see every pose and scene on the dark-mode backdrop:
`THESEUS_MOUSE_BACKDROP_SHEET=$PWD/.scratch/mouse-backdrop swift test --package-path Modules --filter MouseBackdropContactSheet`.

A new artwork needs an entry in `FOCAL` and `SHORT_ARTIST` in `gen_collection.py` (the script refuses to run
without them). To look at the components without a simulator:
`THESEUS_BRAND_SNAPSHOTS=$PWD/.scratch/brand-foundation/raw swift test --package-path Modules --filter BrandSnapshotRenders`.
