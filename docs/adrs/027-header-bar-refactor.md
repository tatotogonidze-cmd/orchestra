# ADR 027: Header bar — split action surface from status footer

- **Status:** Accepted
- **Date:** 2026-04-25

## Context

The cost_footer started as a thin status strip in Phase 13 (one
spent label + one budget label + a single "Budget HUD" button). It
acquired action buttons over the next four phases:

- Phase 14 (ADR 014): "Lock now" button.
- Phase 16 (ADR 016): "GDD" button.
- Phase 23 (ADR 023): "Scenes" button.

By Phase 23 ADR 023 already flagged this as the threshold:

> "The cost_footer is full. Three buttons fit but adding more
> would be cramped — next global affordance probably wants a
> header bar."

The fourth button arrived in Phase 14's "Lock now" — though the
ADR-flagged crowding language was for THREE; by FOUR we're past the
inflection. Phase 26's hard-gating closed the cost story without
adding a button (the toggle lives inside BudgetHUD), but the
underlying layout pressure remains.

The decisions to make:

1. **Header bar vs different split.** Action buttons separate from
   status, OR keep them together but split status across two rows,
   OR fold into a dropdown menu?
2. **What stays in cost_footer?** Status only? Click-to-open-HUD
   convenience? Color states?
3. **How to migrate signals without breaking subscribers?**
4. **Where does the title go?** Header bar? Header is also the
   place where future menu / tabs / global navigation will live.

## Decision

1. **Top-of-shell `header_bar.gd`, four action buttons + a title
   label.** Same `PanelContainer` shape as cost_footer. The four
   buttons land in the order they emerged across phases: GDD
   (16), Scenes (23), Budget HUD (13), Lock now (14). The title
   defaults to "Orchestra".

2. **cost_footer becomes status-only, plus click-anywhere-to-HUD.**
   The action buttons go away. The `gui_input` / `_on_panel_input`
   handler that used to fire on left-click stays — clicking the
   spend/budget numbers is a natural drill-in target for the
   Budget HUD, and we don't lose that affordance just because the
   action button moved up. main_shell wires `cost_footer.hud_requested`
   AND `header_bar.hud_requested` to the same `_on_hud_requested`.

3. **Signal name reuse, not migration.** `header_bar` emits the
   same names cost_footer used to: `hud_requested`, `lock_requested`,
   `gdd_requested`, `scenes_requested`. main_shell's existing
   `_on_*_requested` handlers don't care which child emits them.
   The ONLY handler-side change is the `connect()` site (footer →
   header). cost_footer drops the three signals it no longer
   emits (`lock_requested`, `gdd_requested`, `scenes_requested`)
   and keeps `hud_requested` for the click-anywhere affordance.

4. **Title in header_bar.** A `Label` on the left, expand-fill so
   the action buttons hug the right edge. Future iterations of
   the header layer (menus, tabs, "current project" indicator)
   slot in next to or replacing the title without a layout
   rebuild.

## Consequences

- **Layout breathes.** cost_footer at the bottom is once again a
  thin status strip. header_bar at the top has four buttons
  comfortably; we can add 2-3 more before the next refactor.
- **Click-on-status drill-in preserved.** Users who learned the
  Phase 13 click-anywhere affordance keep it. The header button
  is the second way to reach the same overlay.
- **Wiring delta is small.** main_shell's `bind_orchestrator`
  swaps `cost_footer.gdd_requested` → `header_bar.gdd_requested`
  for three of the four signals. cost_footer.hud_requested stays
  hooked up.
- **Existing tests need updates, not rewrites.** The button
  presence + signal tests move from `test_cost_footer.gd` to
  `test_header_bar.gd` essentially verbatim — same internal
  helper names (`_emit_gdd_requested`, etc), same assertion
  shapes.
- **Three-row outer VBox.** main_shell's outer container goes
  from `[hbox, cost_footer]` to `[header_bar, hbox, cost_footer]`.
  hbox keeps `SIZE_EXPAND_FILL` vertically; the two strips are
  fixed height.
- **No header-bar visual style yet.** Default PanelContainer
  background. Visual polish (logo, brand colours, drop shadow)
  is its own pass; documenting in follow-ups.

## Alternatives considered

- **Fold actions into a single hamburger menu in cost_footer.**
  PopupMenu off a "≡" button. Rejected: the four buttons are
  used often enough that hiding them behind a menu costs daily-
  driver clicks. Hamburger menus are for actions you rarely
  reach for.
- **Two-row cost_footer (status row + actions row).** Doable but
  the bottom strip becomes ~50px tall, eats the same vertical
  space as a real header would consume at the top. Same cost,
  worse semantic split.
- **Tabs across the top instead of buttons.** Tabs imply "the
  view changes". Our overlays don't replace the panel HBox —
  they overlay on top. Buttons better match the actual UX.
- **Drop the click-anywhere-on-cost_footer affordance.** Cleaner
  implementation. Rejected for the UX reason — the spend
  numbers are the natural place a user reaches for "tell me
  more about what I'm spending".
- **Migrate cost_footer to a sidebar.** Proposed once and
  filed. Rejected: status that's always visible should stay in
  the canonical "status bar at the bottom" position.
- **Use Godot's `MenuBar` Control.** Considered for future
  expansion. Today's needs (4 buttons) don't justify it; it'd
  also give us OS-native menu semantics on macOS that we don't
  necessarily want. Reach for this when we have actual nested
  menus.

## Follow-ups

- **Visual polish for header_bar.** Logo asset, brand color, an
  optional separator below the row. Currently default styled.
- **Menu / tabs.** Once we have more than 6-7 actions, a menu
  group ("File", "Edit", "View") + a separate tab for current
  document context becomes natural. Replaces the current label
  on the left.
- **Active-overlay indicator.** When a modal is open, highlight
  the corresponding header button. Helps users know which
  overlay is currently active.
- **Drag-to-reorder action buttons.** Power users could rearrange
  to match their workflow. Persists via SettingsManager (ADR 024)
  under `header_bar.action_order`.
- **Hide action buttons at narrow widths.** Responsive layout.
  At <800px shell width, fold into a hamburger menu. Today the
  shell assumes a desktop-class viewport.
- **Header-as-status surface.** When something interesting is
  happening (a chat-edit task in flight, an unsaved edit, an
  in-flight HTTP probe), surface a small status indicator on
  the right side of the header. Today task_list is the only
  surface for that.
