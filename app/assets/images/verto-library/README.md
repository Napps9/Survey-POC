# Verto Image Library

Curated imagery that powers two things:

1. **Add media → Verto Library** in the editor. Anything in this folder (or
   any sub-folder) is offered as a manual pick. Listing is built at request
   time by `ApplicationHelper#verto_library_images`.
2. **AssetPopulator** (`app/services/asset_populator.rb`) — the auto-fill that
   runs at the end of the Create-a-Verto wizard when the user chooses
   "Populate Content", and again on every Shuffle. The populator only sees
   files declared in `manifest.yml`.

Supported formats: `.jpg`, `.jpeg`, `.png`, `.webp`, `.svg`.
Recommended dimensions for left-panel art: tall portrait, ~9:16 ratio (the
left card panel is 425 × 680 px).

## Folders

| Folder | Role | Used as |
|---|---|---|
| `backgrounds/` | Survey-level backdrops | `survey.background_image` |
| `left-panel/` | Themed per-card art | `card["image"]` (Tier 1, theme-matched) |
| `select-art/` | Generic art for the `multiple_choice` / `select_*_grid` / `yes_no` family | `card["image"]` (Tier 2) |
| `range-art/` | Generic art for `range` / `rating` / `nps` | `card["image"]` (Tier 2) |
| `swipe-cards/` | Backgrounds for individual swipe statements on a `tap_card` | `card["option_images"][i]` |

When no entry in `manifest.left_panel` clears the score threshold, the
populator falls through to the matching Tier-2 folder (`select-art/`
or `range-art/`). For `tap_card`, the left panel stays blank — the
statement backgrounds from `swipe-cards/` carry the visual weight.
When no asset fits, the card image is simply left empty.

## Adding a new asset

1. Drop the file into the matching sub-folder.
2. Add a YAML entry to `manifest.yml`. Filename only — no path. Tags are
   optional but a missing `themes`/`age` means the matcher only sees the
   asset when it's exhausted the better-tagged candidates.
3. Refresh the editor. No precompile or rebuild needed in development;
   `manifest.yml` is re-read whenever its mtime changes.

## Tag vocabularies

- `themes`: open list — seeded with the themes the existing backgrounds
  cover (sport, fitness, community, social, climate, environment, outdoors,
  nature, travel, brand, work, health, education, family, lifestyle).
- `age`: `kids | teen | young-adult | adult | senior | all`
- `mood`: `playful | energetic | festive | calm | serious | warm`
- `style`: `photo | illustrated | vector | vibrant | minimal | warm`
- `card_types`: any keys from `config/card_types.yml`
- `keywords`: per-asset words to match against card text + options
  (heavier weight than themes — use for subject-specific picks)

## Scoring (see `AssetPopulator#score`)

- `+3` per matching theme keyword (parsed from `survey.theme`)
- `+2` per matching age bucket (derived from `survey.audience_age`), or
  `+1` if the asset is tagged `all`
- `+2` per matching mood
- `+1` per matching style
- `+4` per asset `keyword` found in the card's text + options
