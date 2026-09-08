---
target: SwiftUI views (Sources/SwiftRestic/Views)
total_score: 32
max_score: 40
na_heuristics: 
p0_count: 0
p1_count: 2
target_identity: "file:/Users/newlix/github/at-least/SwiftRestic/Sources/SwiftRestic/Views"
timestamp: 2026-09-08T12-46-44Z
slug: sources-swiftrestic-views
closed: true
---
# Critique — SwiftRestic SwiftUI views (`Sources/SwiftRestic/Views`)

Method: dual-agent (A: agent_393ecf52 · B: agent_a3966256) — source-level assessment; no live visuals (native macOS target; the backup app was deliberately not launched to avoid state changes on the user's machine).

## Design Health Score

| # | Heuristic | Score | Key Issue |
|---|-----------|-------|-----------|
| 1 | Visibility of System Status | 3 | Check/prune run as an indeterminate spinner + label for potentially hours (`RepositoryDetailView.maintenanceCard`) — no elapsed time, phase, or progress; hung is indistinguishable from working. Everything else is exemplary. |
| 2 | Match System / Real World | 3 | "Blobs" appears as a bare StatTile title with no inline gloss; retention shorthand ("Keep 24h, 7d, 4w, 12m, 3y") must be decoded — definitions live in `ConceptsView`, behind the Help menu. |
| 3 | User Control and Freedom | 3 | Every sheet has Esc/Cancel; all operations cancellable. But pause/resume exists only inside `PlanEditorSheet` — not in the context menu or `PlanDetailView` — and there is no undo anywhere. |
| 4 | Consistency and Standards | 4 | Genuinely systematic component library, one destructive-dialog pattern. Nits: "Remove from SwiftRestic…" (detail, with ellipsis) vs without (sidebar menu); sidebar context menu relies on an error banner where the menu bar disables the same action. |
| 5 | Error Prevention | 4 | Strongest suit: repositories can't be saved unless the probe succeeds, all-zero retention is blocked, destructive console subcommands are tokenized and confirmed, rclone pre-checked. Gap: console `restore` is not in `destructiveSubcommands`. |
| 6 | Recognition Rather Than Recall | 3 | Tooltips, labeled buttons, console history menu, auto-selected newest problem in Activity. But help is not at point of use: Prune confirmation and the Blobs tile never link to `ConceptsView`. |
| 7 | Flexibility and Efficiency | 3 | ⇧⌘B/⇧⌘F/⌘R, menu-bar per-plan buttons, hooks. Missing: cannot paste or drag a path into sources; console history is session-only; no per-plan keyboard shortcut. |
| 8 | Aesthetic and Minimalist Design | 3 | Disciplined cards, reserved status colors, monospaced digits, honest empty states. `RepositoryDetailView` stacks four tiles + four cards + ambient caveat captions — minor noise. |
| 9 | Error Recovery | 3 | Exit codes become plain sentences with suggestions; error text selectable; recovery actions offered. But `model.banner` is a single slot — concurrent failures overwrite each other, and no banner renders in `ActivityView` or Settings. |
| 10 | Help and Documentation | 3 | `ConceptsView` is concise and task-framed; inline captions plentiful. No search, and no contextual entry into the glossary from dialogs. |
| **Total** | | **32/40** | **Good — address weak areas; solid foundation** |

## Design Specificity Verdict

**Authored for this product — behaviorally and linguistically; deliberately native-generic visually.** An unrelated product could not reuse this UI unchanged; what it could lift is only the layout skeleton.

**LLM assessment.** The information architecture is restic's, not a generic backup template: plans stamp snapshots with private tags, retention is restic's six `--keep-*` buckets with a safety projection, and lock semantics ("prune takes an exclusive lock… backups are held back") repeat consistently across four surfaces. The copy encodes restic's exit-code semantics ("Completed with errors" as a first-class outcome; `knownExitCodeDescription` mapping codes 3/10/11/12/130 to plain sentences). `SnapshotDiffView` answers a restic-specific question ("what did last night's backup actually pick up?") with restic-specific mechanics, and `ResticConsoleView` confirms only the genuinely destructive subcommands. Plan color identity is engineered across surfaces (ChartPalette slots, FNV-1a fallback, stable colors for renamed plans). The category-interchangeable part is the visual language: `Theme.swift` owns only geometry; every icon is an SF Symbol; a screenshot of the stat tiles could be any admin dashboard — a minute of use could not. The plan-color system is the one ownable visual asset, used well; the menu bar icon is the biggest missed chance for product character.

**Deterministic scan.** Clean: exit 0, zero primary and zero advisory findings across all 17 `.swift` files. The scanner's scope for `.swift` files was positively verified with a /tmp probe (a deliberately planted bounce-easing string was caught; the unmodified repo files were not). No detector-caught issues the review missed; nothing to flag as false positive. This corroborates the review's read of a disciplined, slop-free visual layer.

**Visual overlays.** None — the target is native SwiftUI source with no viewable URL, and launching backup software could mutate user state, so no browser injection was attempted. No reliable user-visible overlay exists for this run.

## Overall Impression

This is a rare SwiftUI codebase where the design rationale is visible in the code and almost always right: restic's semantics are translated rather than hidden, destruction is consequential and explained, and progress for the primary operation is visible on four surfaces at once. What's left is concentrated in one theme: **the app is trustworthy once opened, but not yet trustworthy at a glance.** The menu bar — the one always-visible surface — never shows failure; the maintenance wait is blind for hours; and a single banner slot can erase an error before it's read. The single biggest opportunity: make the glance surface carry the product's whole promise (protected / warning / failing), and give the long maintenance wait elapsed time and a last-activity line.

## What's Working

1. **`OperationProgressView` and its four-surface propagation** (`Components.swift`). One progress model feeds the plan detail card (files/bytes/rate/ETA/current file with middle truncation and monospaced digits), the sidebar spinner, the menu bar running lines with percent, and the toolbar's Back Up Now ↔ Cancel swap. The most anxiety-laden operation is visible everywhere you might look and cancellable from every surface — textbook visibility of system status.
2. **`SnapshotDiffView` end to end.** Defaults to the previous comparable snapshot, warns when a comparison is meaningless, encodes change kind as glyph *and* color, shows per-category counts inside the filter, and is honest about truncation ("list cut off at 20,000; the totals above are complete"). A terminal incantation turned into a question-and-answer surface without dumbing anything down.
3. **The retention tab + `RetentionProjection`.** Instead of restating bucket rules, it projects the outcome ("≈ N snapshots would survive, reaching back about X days"), and `isSafeToRun` plus an in-editor warning make the delete-everything configuration unreachable. Dangerous arithmetic turned into a previewed choice — the most product-thinking control in the app.

## Priority Issues

1. **[P1] The menu bar never shows failure — the trust surface is mute.** The MenuBarExtra icon has exactly two states (idle clock / running arrows) and the headline only ever says "Next: …". Backup software is bought with anxiety; the glance surface answers "is anything running?" but never "did the last run succeed?". An overnight failure is discoverable only via an optional notification or by opening the window.
   **Fix:** derive a third state from run history (warning/red triangle when the newest run failed or 7-day problem count > 0) and lead the headline with the most recent problem before "Next: …".
   *Suggested command:* `/impeccable shape`
2. **[P1] Check/prune progress is an indeterminate spinner for potentially hours.** `maintenanceCard` shows `ProgressView()` + "Check running…"; nothing streams to the UI, and the run appears in Activity only *after* it finishes. The user cannot distinguish "working" from "hung". This is the app's one large visibility hole.
   **Fix:** show elapsed time ("Checking — 14 min") and surface what's already capturable (prune's plain-text report is captured verbatim today; check's stdout lines could feed a last-activity line or mini log).
   *Suggested command:* `/impeccable shape`
3. **[P2] One shared banner slot loses errors and lands in the wrong window.** `model.banner` is a single `Banner?` rendered in only four views. A failing-repository refresh loop overwrites earlier errors; a success banner ("Restored …") can erase an unread error; `ActivityView` — where users read failures — shows no banner at all; Settings' test-notification result renders in a different window.
   **Fix:** queue banners or anchor errors to the card they belong to; render test-notification results inline; add `BannerView` to `ActivityView`.
   *Suggested command:* `/impeccable harden`
4. **[P2] Sources cannot be typed, pasted, or dragged — only browsed.** `PathListEditor` in browse mode renders only a "Choose…" button (NSOpenPanel); the text field exists only in excludes mode. The audience is developers with paths already on their clipboard; panel navigation per source is the app's biggest efficiency tax.
   **Fix:** always show the text field alongside "Choose…" (the component already has that mode) and accept dropped folders/files.
   *Suggested command:* `/impeccable harden`
5. **[P2] Esc silently discards all editor work.** Both editor sheets bind Cancel to `.keyboardShortcut(.cancelAction)` with no dirty-state check — paste ten exclude patterns, reflex-press Esc, lose everything. It contradicts the app's otherwise careful confirm-everything standard.
   **Fix:** compare `draft` to the initial value on cancel and present "Discard changes?" when dirty.
   *Suggested command:* `/impeccable harden`

## Persona Red Flags

**Alex (Power User)** — cannot paste or drag a path into "Back up these folders and files" (`PathListEditor` browse mode). No pause/resume outside the editor: `RootView.planContextMenu` offers Back Up Now / Edit… / Delete Plan only, despite the sidebar rendering a pause icon. Console history is session-only `@State` — gone when the sheet closes. No shortcut for running the *selected* plan (⇧⌘B is all plans). Counterweight: menu-bar per-plan buttons, context-menu run, console, and hooks make his life good overall.

**Sam (Accessibility-Dependent User)** — key information is gated behind hover-gated `.help` tooltips: the Protected tile's per-plan freshness breakdown, the alert-channel warning icon's reason, and the sidebar restic-missing triangle's explanation exist nowhere else on those surfaces. Instant-destructive clicks with no confirmation: "Remove" in `NotificationChannelsTab` and `HookEditor` delete immediately — inconsistent with the app's own standard (Clear History, prune, unlock, plan delete all confirm). Otherwise notably strong: accessibility labels on icon-only controls, status never carried by color alone, chart table fallback, monospaced digits.

**Riley (Stress Tester)** — Esc in either editor silently discards the draft (Priority Issue 5). `CommandLineTokenizer.destructiveSubcommands` omits `restore`: typing `restore <id> --target /some/dir` overwrites files at the destination with no confirmation — the destructive set covers repository mutation but not destination-file mutation. Two plans with the same name are indistinguishable in Activity's Subject column and share a chart series bucket (metrics key series by plan name). Credit where due: empty states are exemplary everywhere, long names truncate honestly, the diff list caps at 20,000 with complete totals, and stale-async writes are guarded by `Task.isCancelled` throughout.

## Minor Observations

- `RetentionPolicy.summary`'s "Keep 24h, 7d, 4w, 12m, 3y" appears on PlanDetail's Configuration card; the friendlier projection sentence exists only in the editor.
- Ellipsis drift: "Remove from SwiftRestic…" (detail) vs "Remove from SwiftRestic" (sidebar menu) for the identical dialog.
- Sidebar context menu's "Back Up Now" is enabled for incomplete plans (error banner follows) while the menu bar disables the same action — one guard, two behaviors.
- `StatTile` shrinks long values to 60% before truncating — very small text in the app's most prominent numerals.
- The schedule picker says "Manually" while the detail tile says "Manual" — tiny drift.
- Console `key` is confirmed wholesale even for read-only `key list`.
- The welcome screen's "Encrypted / Scheduled / Searchable" is interchangeable marketing copy — the one place the app undersells what makes it different (compare-snapshots, console, hooks).
- "Blobs" tile and the Activity "Subject" column header are the two least self-explanatory labels; a tooltip or ConceptsView link would fix both.

## Questions to Consider

- What if the menu bar icon were the product's whole promise in one glyph — green when protected, amber with warnings, red with failures — the way every tray in this category eventually learns to do?
- What if retention were edited by dragging a "reach back about 90 days" handle with the six buckets as the advanced disclosure, rather than the reverse?
- Does the restic console want to be a sheet at all, or its own persisted surface with durable history — the power user's home?
- What would a *confident* version of the maintenance card look like while a three-hour check runs — elapsed time, last log line, and "you can keep working; backups are queued, not lost"?
