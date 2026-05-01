# ADR 038: Onboarding empty-state polish

- **Status:** Accepted
- **Date:** 2026-05-01

## Context

After 37 phases the app is feature-complete for the core workflow:
plugins generate assets, GDD authoring is fully closed, settings
persist, snapshots compare, etc. But fresh users hit a wall on
launch:

1. **Unlock dialog** appears with no creds set. They click Skip.
2. **Plugin panel** shows every known plugin as `[unregistered]`.
   Manage credentials button exists but they don't know that's
   the affordance they need.
3. **Asset gallery** shows `(no assets)` — silent emptiness.
4. **GDD viewer** shows `(no GDD loaded yet)` and a path input
   pre-filled with `user://gdd.json` that doesn't exist. Click
   Load → load fails. Now what?
5. **Generate form** has no plugin to select.

Each of these is functionally correct but unhelpful. The user gets
no signal about what to do next. "What's a GDD? Why is it asking
for a path? How do I make a thing?"

This isn't a wizard / tutorial problem — those would block users
who already know what they're doing. It's a hinting problem: each
empty state should tell the user *what their next action is*.

The decisions to make:

1. **Inline hints vs separate first-launch wizard?**
2. **Starter GDD: hard-coded vs user-typed wizard?**
3. **Should we auto-create the starter GDD, or require an explicit
   click?**
4. **Plugin panel: add a banner, or modify the existing `[unregistered]`
   row labels?**
5. **Asset gallery: differentiate "filtered out" vs "empty library"?**

## Decision

1. **Inline hints, no wizard.** A wizard adds friction for the 80%
   case (returning users, developers spinning up a fresh checkout
   for testing, automated runs) and arguably doesn't help the 20%
   either — fresh-launch users can read a hint label as fast as
   they can dismiss a wizard step.
   - GDD viewer empty-state hint: tells user to Load or Create.
   - Plugin panel hint: surfaces above the list, points at Manage
     credentials.
   - Asset gallery hint: tells user to generate.
   - Snapshot timeline hint: differentiates "no snapshots ever" from
     "GDD loaded but unsaved".

2. **Hard-coded starter GDD.** A wizard that asks the user "what's
   your game called? what genre?" delays getting them into a
   working state. Hard-coded `Untitled Game` + one example mechanic
   gets them past `validate()` immediately; they can rename via
   form-edit (Phase 18) or chat-edit (Phase 17) once they're
   inside.
   - The starter is non-empty (one mechanic) so the entities-rendered
     code path on the panel runs on the first open. An empty starter
     would still show `(empty)` everywhere — half the polish gain.

3. **Explicit click required** to create the starter. Auto-creating
   on first launch would silently write to disk without the user's
   say-so — and would clobber any pre-existing path the user typed.
   The Create-starter button:
   - Is visible only when no GDD is loaded (inverse of Edit / Export).
   - Refuses to overwrite an existing file at the typed path —
     surfaces a "Path already has a file — Load it instead" hint.
   - Triggers a normal `_on_load_pressed()` after writing, so the
     downstream wiring (status label, persisted-path setting) runs
     uniformly.

4. **Plugin panel: separate hint label.** A banner above the list
   makes the empty state visible without changing the list rows
   (which still mark each plugin's individual state via
   `[unregistered]`). The hint tells the user what TO DO; the rows
   tell them what's currently happening. Different jobs.
   - Hint visible when `registered_count == 0`.
   - Hint hides as soon as one plugin gets credentials.

5. **Asset gallery: differentiate filtered vs unfiltered empty.**
   When `_current_filter == "all"`, the empty hint says "generate
   something to populate your library." When a filter is active,
   it says "no <type> assets — try a different filter or generate
   one." Two different actions for two different situations.

## What's NOT in this phase

- **Sample asset pack.** Bundling stub assets so the gallery is
  non-empty on first launch. Considered. Rejected — they'd be
  the user's first impression of asset quality, and they'd be
  fake. The Create-starter approach extends naturally to assets
  if we ever want it.
- **Tutorial overlay.** Step-by-step "click here, then here"
  highlights. Out of scope; the hints above are the lightest
  version of that.
- **Default plugin selection.** Pre-pick a plugin in the Generate
  Form when only one is registered. Considered — leaving it
  alone for now since the dropdown's first item is already
  selected by Godot's default behaviour.
- **Welcome dialog at first launch.** A modal explaining what
  the app does. Rejected — it's a wizard in disguise, and the
  README + UI hints together cover the same ground.
- **Scene panel empty state.** Less common path; users who reach
  the scene panel typically already have assets. Punt.

## Consequences

- **First launch is no longer dead-air.** Each surface tells the
  user what to do next.
- **Starter GDD shape is now load-bearing.** If we change the
  schema in a way that makes the starter invalid, the test
  suite catches it (the `test_create_starter_gdd_validates`
  assertion).
- **Plugin panel has a new optional widget**. The hint label is
  visible/hidden in `refresh()`, so the panel grows by one
  child node — small footprint, but it's there.
- **Asset gallery's empty branch grew a filter check.** Trivial.
- **Phase tests for empty states are inverse-state checks** —
  asserting things that DON'T appear when data is loaded. That
  pattern was new to test_gdd_panel.gd; we now have a precedent
  for it.

## Alternatives considered

- **Wizard on first launch.** Detect `is_fresh_install` (no
  settings.json), pop a modal, walk the user through each step.
  Rejected: blocks returning / developer / CI users; replicating
  the same info as inline hints in modal form.
- **Auto-seed starter GDD if `gdd.last_path` is unset.** Silent
  disk write on launch. Rejected — surprises the user, can't
  be opted out of.
- **Make the GDD viewer auto-load the starter if no GDD exists.**
  Same problem as above. The Create-starter button keeps the
  action explicit.
- **Use modal toast notifications for hints.** "Welcome! Click
  here to..." popping up on each empty surface. Rejected — toasts
  expire / get dismissed; inline hints stay until the state
  changes.
- **Banner across the whole shell** ("Set up your first plugin").
  Considered. Rejected — would interfere with the always-visible
  cost footer / header bar layout.

## Settings registry

No new settings keys.

## Follow-ups

- **`is_fresh_install` detection.** Track first launch via a
  settings flag (`onboarding.completed`). Once set, suppress the
  hints. Currently the hints stay visible whenever the underlying
  state matches their condition — that's correct behaviour for
  returning users who genuinely have no plugins / no GDD, but a
  "don't show again" toggle on the hints could help advanced
  users.
- **Generate form: hint when no plugin registered.** Today the
  dropdown just says "(no plugins registered)". A click-through
  to the credential editor would close the loop.
- **Tutorial mode.** Optional walkthrough that highlights one
  surface at a time. Out of scope here, but the hint
  infrastructure is what a tutorial layer would steer.
- **Sample asset pack toggle.** A setting to populate the
  gallery with stub assets for screenshots / demos. Pairs with
  is_fresh_install detection.
- **Localised hints.** Strings are English-only today. Pairs
  with a broader i18n pass.
