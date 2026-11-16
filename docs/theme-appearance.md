# Application theme selection

Status: agreed design; implementation is not part of this document.
Confirmed: 2026-11-05.

## Goal and scope

Let the user choose the application's colors without changing its typography,
geometry, or behavior. The choice applies to the whole application: the editor,
sidebar, tabs, Brain panels and read-only content, search, settings, and other
app-owned surfaces.

Changing the theme must not change fonts, font sizes, text zoom, heading scaling,
bold or italic styling, spacing, layout, or window geometry.

## Available choices

| Choice | Appearance | Accent |
| --- | --- | --- |
| Podle systému | Follows the current macOS light/dark appearance | System accent |
| Light | Native light appearance regardless of macOS appearance | System accent |
| Dark | Native dark appearance regardless of macOS appearance | System accent |
| Noir Essence | Custom light palette regardless of macOS appearance | Orange from the reference palette |

The custom theme's canonical name is **Noir Essence**, not "Nori Essence".

The default is **Podle systému**, preserving the behavior of existing
installations that have not selected a theme. Light and Dark are native
appearances, not additional custom color palettes.

## Settings and persistence

- Replace the existing appearance information in Settings → Appearance
  (Nastavení → Vzhled) with one selector containing the four choices.
- Keep the standard Notess → Settings command and its existing keyboard shortcut.
  Do not add a toolbar control or a separate theme menu.
- Store one local application preference on this Mac, shared across all vaults
  and windows, and restore it on subsequent launches.
- Do not store the preference in notes or vault contents, or synchronize it
  between devices.
- Apply the selection immediately, without a Save button or an application restart.

## Live updates and editing invariants

Update all open app windows and views, including already-open editors, read-only
Markdown, Brain content, and settings. Newly opened views use the same choice.

Switching themes must preserve unsaved text, the caret and selection, scroll
position, and undo/redo history. It must not modify note contents or mark a note
as edited merely because its presentation changed.

When macOS appearance changes, update the application immediately only if
**Podle systému** is selected. Explicit Light, Dark, and Noir Essence choices
remain unchanged.

## Noir Essence palette

Reference:
[Noir Essence Light](https://github.com/u1145h/vscode-theme/blob/master/themes/noir_essence_light.json).
The reference declares a light theme; no dark Noir Essence variant is requested.

Use its colors as the reference for a Notess-specific semantic palette, rather
than importing the VS Code theme wholesale:

| Role | Reference color or treatment |
| --- | --- |
| Main editor background | Cream, `#f7f3ea` |
| Main text | Dark, with `#000000` as the reference |
| Accent | Orange, `#e78a4e` |
| Supporting syntax colors | Reference red `#e06660`, pink `#cb7a90`, orange `#d57f47`, yellow `#e7b24e`, blue `#719fc0` |

Map colors to Notess roles such as links, wiki links, tags, Markdown markers,
tasks, quotations, code backgrounds, and table surfaces. Apply the same palette
consistently to app-owned navigation, panels, controls, and read-only content.
The exact mapping is an implementation detail, subject to the constraints below.

- Readability and the semantic meaning of errors, warnings, and other status
  indicators take precedence over literal color matching.
- Selection, focus, hover, and disabled states must remain distinguishable.
- Respect increased-contrast accessibility settings; color adjustments are
  permitted for readability.
- Keep native system dialogs native, using the selected appearance. Noir Essence
  uses their native light appearance, not custom recoloring.
- Do not copy font or font-style rules from the reference theme.

At discovery time, the source repository did not declare a license. The link is
a design reference, not evidence of permission to redistribute its complete
theme file. Do not vendor that file; resolve applicable permissions before
redistributing any source material that requires them.

## Acceptance scenarios

| Scenario | Expected result |
| --- | --- |
| First launch or upgrade with no stored theme choice | Podle systému is selected; existing automatic light/dark behavior is preserved |
| Select each of the four choices in settings | All app-owned surfaces update immediately and show a consistent theme |
| Select Light while macOS is dark | Notess stays in native light appearance |
| Select Dark while macOS is light | Notess stays in native dark appearance |
| Select Noir Essence while macOS is dark | Notess uses the custom cream/light palette and orange accent |
| Change macOS appearance with Podle systému selected | All open app views follow the new system appearance without restarting |
| Change macOS appearance with an explicit theme selected | The selected appearance remains in effect |
| Switch themes with an unsaved note and a selection | Text, dirty state, caret, selection, scroll, and undo/redo history remain intact |
| Switch themes after changing font settings and text zoom | Font family, sizes, zoom, heading scaling, and text emphasis remain unchanged |
| Restart after selecting a theme | The selected theme is restored |
| Open another window or change vault | The same application-wide theme applies |
| View the same Markdown in an editor and read-only Brain content | Both use the selected palette without typography or layout changes |
| Use Noir Essence with increased contrast | Text and meaningful interaction/status indicators remain readable and distinguishable |
| Open native dialogs with Noir Essence selected | Native light controls remain usable without forced custom palette colors |

## Out of scope

Custom theme editing or importing, additional theme variants, cross-device
synchronization, per-vault preferences, typography changes, layout redesign,
new toolbar controls, and a theme submenu.
