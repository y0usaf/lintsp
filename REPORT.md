> Renamed from lisplint on 2026-09-14. Historical text below keeps the old name.

# lisplint — cleanup pass: four defects fixed, corpus evaluated

Reader-only Common Lisp linter at `/home/y0usaf/dev/sandbox/lisplint` (SBCL 2.6.8,
Nix flake, no third-party dependencies). This is the cleanup pass: it fixes four
defects the previous worker left, repairs several further false-positive roots
found while verifying them, and delivers the evaluation report that worker never
wrote.

Everything below is quoted from output actually produced by the built binary.
Nothing in `ekko`, `slope`, `headlong-lisp`, `autolith`, `pi-lisp` or `finix` was
modified, staged or committed. No tests or fixtures were created.

## 0. Build and run

```console
$ cd /home/y0usaf/dev/sandbox/lisplint
$ nix build
$ readlink result
/nix/store/wba2hvg9yq32bd8qrv1ss1wlp6lwqin-lisplint-0.1.0
```

The image compiles with zero style-warnings (`nix log <drv>` shows none), and
every run below writes an empty stderr.

## 1. What changed

Files touched: `src/rules.lisp`, `src/core.lisp`, `src/cli.lisp`.

### The four defects in the brief

1. **`defstruct-after-use` was reading slot lists and guessing cross-file order.**
   Rewritten: a slot list or slot option inside any `defstruct` / `defclass` /
   `define-condition` form is skipped (tagged with its own file — the old code
   compared byte offsets across files), and two files are compared only when the
   load order is actually known. The message now names the defining file.
2. **`forward-reference` compared files whose order was unknown** (the driver's
   alphabetical fallback is not a load order) and **emitted once per occurrence**
   of a name inside one form. Now order-aware, and at most one emission per
   (name, file).
3. **`ignore-then-read` counted `(declare (ignore x))` itself as a read of `x`,
   read a nested `lambda`'s lambda list as its body, and scanned the whole
   enclosing `defun`.** Now a declaration's scope is exactly the forms that follow
   it in its immediate parent list; `scan-function-form` handles `LAMBDA`
   correctly; `walk-refs` skips `ignore` / `ignorable` specifiers.
4. **Duplicate emission + a message-format bug.** `long-function` and
   `deep-nesting` both mapped to one function that emitted both kinds, so every
   finding printed twice; split into one function per rule. A final `dedupe-diags`
   pass collapses exact duplicates. `duplicated-literal-table` now orients pairs by
   (file, line) instead of comparing line numbers across files, and prints `(none)`
   instead of an empty list.

### Further false-positive roots found while verifying the four

All measured on the corpus, not suspected:

5. **Two rules were entirely dead.** `unused-binding` and `unused-parameter` both
   mapped to the undefined function `LISPLINT::RULE-UNUSED`: they emitted nothing
   and wrote `rule unused-parameter failed ... function LISPLINT::RULE-UNUSED is
   undefined` to stderr for every file. Mapped to the two functions that exist.
6. **`scan-function-form` used `(cddr form)` for every definer, but `LAMBDA` has
   no name slot** — so `(lambda (x) (declare (ignore x)) ...)` had its body read as
   a lambda list. This alone produced most of the 321 `ignore-then-read` hits and
   all macro-parameter hits.
7. **SBCL's reader hides `,x` / `,@x` inside a backquote** as an `SB-IMPL::COMMA`
   struct, not a cons, so a datum walk never saw the unquoted form:
   `(defmacro check (form) ... ,form ...)` reported `FORM` unused (audit §4 trap 1).
   Handled explicitly under `#+sbcl`.
8. **Keywords are data, not references** — `:configuration` was counted as a
   reference to a variable `CONFIGURATION`.
9. `destructure-names` returned `&OPTIONAL` / `&REST` as binding names.
10. **`DEFGENERIC` has no body**, so every generic signature was reported as unused
    parameters (812 of autolith's hits).
11. A symbol's `raw` kept the reader's trailing delimiter, so a symbol ending a
    line carried a newline into a message and split it across two output lines.

## 2. The corpus run

```console
$ ./result/bin/lisplint check \
    /home/y0usaf/dev/developing/slope \
    /home/y0usaf/dev/maintaining/ekko \
    /home/y0usaf/dev/maintaining/ekko-ui-reliability \
    /home/y0usaf/dev/maintaining/ekko-zellij-parity \
    /home/y0usaf/dev/maintaining/ekko-hide-panes-worktree \
    /home/y0usaf/dev/maintaining/ekko-finix-menu \
    /home/y0usaf/dev/sandbox/headlong-lisp \
    /home/y0usaf/finix/modules/finix/desktop/tomoe-policy.lisp \
    /home/y0usaf/finix/modules/finix/desktop/deck.lisp \
    /home/y0usaf/dev/sandbox/pi-lisp
```
stdout (stderr empty):

```
2755 findings in 215 files (275 scanned; load order from ekko.asd (:components))
```
`wc -l` = 2756, `sort -u | wc -l` = 2756 — every line unique.

```console
$ ./result/bin/lisplint check /home/y0usaf/dev/sandbox/autolith \
                            /home/y0usaf/dev/maintaining/autolith-clinedi-fix
```
```
7921 findings in 435 files (488 scanned; load order from autolith.asd (:components))
```
`wc -l` = 7922, unique = 7922.

Headline three — baseline (pre-fix binary, store
`qafirah5wn31zzjzyhynf91mv72lp1sa`) vs now:

| corpus | before lines | before unique | after lines | after unique |
|---|---|---|---|---|
| headlong-lisp | 252 | 89 | 50 | 50 |
| ekko/src | 2082 | 1925 | 212 | 212 |
| slope | 88 | 54 | 49 | 49 |

## 3. Per-rule results across the corpus

"main" = the 10-path corpus above (275 files); "auto" = the two autoliths (488
files). Every rule is on by default in the shipped `list` output.


| rule | main | main files | auto | auto files | default | verdict |
|---|---|---|---|---|---|---|
| `forward-reference` | 0 | 0 | 4242 | 269 | on | **NOISE** — 0 real hits on the main corpus; 4242 in autolith, almost all names appearing as data in test-registration macros |
| `deep-nesting` | 761 | 198 | 2501 | 385 | on | **NOISE at the default threshold** — 761 notes / 198 files, almost all ordinary test `defun`s at depth 10-12 |
| `internal-symbol-leak` | 1799 | 61 | 174 | 32 | on | **SIGNAL** — 1799 hits / 61 files; every one a real `PKG::sym` token outside a string (the audit found 2014 of the same shape) |
| `long-function` | 76 | 55 | 645 | 208 | on | **SIGNAL** — 76 hits / 55 files; the audit found a 1458-line test function |
| `unused-parameter` | 0 | 0 | 246 | 74 | on | **SIGNAL** — 0 on the main corpus; 246 in autolith, dominated by DEFMETHOD specialisers whose only role is dispatch |
| `quadratic-append` | 8 | 6 | 56 | 25 | on | **SIGNAL** — 8 hits / 6 files, all `(setf x (append x (list ...)))` |
| `unused-binding` | 22 | 14 | 30 | 25 | on | **SIGNAL** — 22 hits / 14 files, all plain dead `dotimes`/`let` binders |
| `duplicated-literal-table` | 35 | 10 | 2 | 2 | on | **SIGNAL** — 35 hits / 10 files; every pair a real drifted key list |
| `defstruct-after-use` | 27 | 4 | 0 | 0 | on | **SIGNAL after fix** — 27 hits / 4 files, all provable from a known load order, incl. ekko's real `popup` inline-loss |
| `dead-definition` | 7 | 7 | 20 | 12 | on | **SIGNAL** — 7 hits / 7 files; `pane-owner` is the exact defun the audit found dead |
| `optional-and-key` | 11 | 11 | 1 | 1 | on | **SIGNAL** — 11 hits / 11 files; SBCL emits the same style-warning |
| `reader-error` | 5 | 5 | 2 | 2 | on | **SIGNAL** — 5 hits, all `#.` forms the reader refuses under `*read-eval*` nil |
| `ignore-then-read` | 0 | 0 | 2 | 2 | on | **SIGNAL after fix** — 0 on the main corpus; 2 in autolith, a variable/`cl:format` name collision |
| `earmuffs` | 2 | 1 | 0 | 0 | on | **SIGNAL** — 2 hits / 1 file, the audit's confirmed `+namespace-limit+`/`+file-limit+` |
| `defparameter-named-like-constant` | 2 | 1 | 0 | 0 | on | **POLICY-dependent** — 2 hits; autolith's AGENTS.md forbids `defconstant`, so the rule contradicts that project's policy |


## 4. Concrete findings a human would act on

Paths are printed exactly as lisplint emitted them, relative to each run's
common prefix (`/home/y0usaf/` for the main corpus, `/home/y0usaf/dev/` for the
autolith run); a given finding repeats once per near-identical ekko worktree, so
examples are deduplicated by file name to show distinct findings.

### `internal-symbol-leak` (warning) — 1799 main / 61 files
- `dev/maintaining/ekko-zellij-parity/tests/render.lisp:7` — ekko/runtime::viewer-io reaches past the package boundary; export it or move the API
  ```lisp
  (setf (ekko/runtime::viewer-io viewer) (ekko/runtime::make-wire :fd -1)
  ```
- `dev/maintaining/ekko/src/menus.lisp:7` — ekko/vt::character-width reaches past the package boundary; export it or move the API
  ```lisp
  (loop for c across (getf span :text) sum (ekko/vt::character-width c)))
  ```
- `dev/maintaining/ekko-zellij-parity/tests/assets.lisp:8` — ekko/platform::*asset-directory* reaches past the package boundary; export it or move the API
  ```lisp
  (ekko/platform::*asset-directory* nil)
  ```
- `dev/maintaining/ekko-zellij-parity/tests/runner.lisp:13` — ekko/vt::update-rendition reaches past the package boundary; export it or move the API
  ```lisp
  (equal (ekko/vt::update-rendition '(0 1 38 2 90 80 70) '(48 2 0 24 30 24))
  ```
- `dev/maintaining/ekko-zellij-parity/tests/input.lisp:13` — ekko/runtime::wire-queue reaches past the package boundary; export it or move the API
  ```lisp
  (loop for packet in (ekko/runtime::wire-queue wire)
  ```
- `dev/maintaining/ekko-zellij-parity/tests/customization.lisp:26` — ekko/runtime::make-pane reaches past the package boundary; export it or move the API
  ```lisp
  (let* ((pane (ekko/runtime::make-pane :id 1 :vt (ekko/vt:make-terminal :cols 10 :rows 4)))
  ```
- `dev/maintaining/ekko-zellij-parity/src/cli.lisp:34` — ekko/runtime::extension-worker-main reaches past the package boundary; export it or move the API
  ```lisp
  ((string= command "--extension-worker") (ekko/runtime::extension-worker-main))
  ```

### `deep-nesting` (note) — 761 main / 198 files — *recommend off by default*
- `dev/sandbox/pi-lisp/src/bash-builtins.lisp:3` — defun BASH-RESULT reaches list depth 13 (threshold 10)
  ```lisp
  (defun bash-result (directory arguments control)
  ```
- `dev/maintaining/ekko-zellij-parity/tests/assets.lisp:3` — defun RUN-ASSET-TESTS reaches list depth 12 (threshold 10)
  ```lisp
  (defun run-asset-tests ()
  ```
- `dev/maintaining/ekko-zellij-parity/tests/graphics-parser.lisp:3` — defun RUN-GRAPHICS-PARSER-TESTS reaches list depth 11 (threshold 10)
  ```lisp
  (defun run-graphics-parser-tests ()
  ```
- `dev/maintaining/ekko-zellij-parity/tests/base64.lisp:3` — defun RUN-BASE64-TESTS reaches list depth 10 (threshold 10)
  ```lisp
  (defun run-base64-tests ()
  ```
- `dev/maintaining/ekko-zellij-parity/tests/desktop.lisp:3` — defun RUN-DESKTOP-TESTS reaches list depth 12 (threshold 10)
  ```lisp
  (defun run-desktop-tests ()
  ```
- `dev/maintaining/ekko-zellij-parity/tests/selection.lisp:3` — defun RUN-SELECTION-TESTS reaches list depth 12 (threshold 10)
  ```lisp
  (defun run-selection-tests ()
  ```

### `long-function` (note) — 76 main / 55 files
- `dev/maintaining/ekko-zellij-parity/tests/assets.lisp:3` — defun RUN-ASSET-TESTS spans 86 lines (threshold 80)
  ```lisp
  (defun run-asset-tests ()
  ```
- `dev/maintaining/ekko-ui-reliability/tests/selection.lisp:3` — defun RUN-SELECTION-TESTS spans 103 lines (threshold 80)
  ```lisp
  (defun run-selection-tests ()
  ```
- `dev/maintaining/ekko/examples/profiles/zellij-bindings.lisp:4` — defun INSTALL-PANE-BINDINGS spans 137 lines (threshold 80)
  ```lisp
  (defun install-pane-bindings (owner)
  ```
- `dev/maintaining/ekko-zellij-parity/tests/customization.lisp:10` — defun RUN-CUSTOMIZATION-TESTS spans 887 lines (threshold 80)
  ```lisp
  (defun run-customization-tests ()
  ```
- `dev/maintaining/ekko-zellij-parity/tests/render.lisp:14` — defun RUN-RENDER-TESTS spans 87 lines (threshold 80)
  ```lisp
  (defun run-render-tests ()
  ```
- `dev/maintaining/ekko-zellij-parity/tests/erase-history.lisp:16` — defun RUN-ERASE-HISTORY-TESTS spans 88 lines (threshold 80)
  ```lisp
  (defun run-erase-history-tests ()
  ```

### `unused-binding` (note) — 22 main / 14 files
- `dev/sandbox/headlong-lisp/lisp/src/protocol.lisp:13` — dotimes binding I is never referenced
  ```lisp
  (dotimes (i 32) (format out "~2,'0X" (read-byte random))))
  ```
- `dev/sandbox/headlong-lisp/lisp/demo/verify.lisp:14` — dotimes binding I is never referenced
  ```lisp
  (dotimes (i 3) (assert (eq :completed (run-turn store id))))
  ```
- `dev/sandbox/headlong-lisp/lisp/tests/runtime.lisp:58` — dotimes binding I is never referenced
  ```lisp
  (dotimes (i 3) (check (eq :ready (run-turn store "repeater"))))
  ```
- `dev/maintaining/ekko-zellij-parity/tests/customization.lisp:73` — dotimes binding I is never referenced
  ```lisp
  (dotimes (i 1000) (ekko/vt::remember-row vt row))
  ```
- `dev/developing/slope/src/json.lisp:84` — dotimes binding K is never referenced
  ```lisp
  (dotimes (k 4)
  ```
- `dev/maintaining/ekko/src/extensions.lisp:230` — dotimes binding CELL is never referenced
  ```lisp
  (dotimes (cell overlap) (write-char #\Space out)))
  ```

### `duplicated-literal-table` (warning) — 35 main / 10 files
- `dev/maintaining/ekko-zellij-parity/src/builtins.lisp:8` — key list matches dev/maintaining/ekko-zellij-parity/src/extensions.lisp:12 but has drifted; missing here: CHROME-STATUS GEOMETRY PANE-NOTES; extra here: (none)
  ```lisp
  :reads '(:session :focus :panes :viewport :mode :zoom :layout :component-state)
  ```
- `dev/maintaining/ekko/examples/profiles/desktop.lisp:11` — key list matches dev/maintaining/ekko/src/builtins.lisp:10 but has drifted; missing here: LAYOUT SESSIONS; extra here: (none)
  ```lisp
  (ekko/extensions:register-component :id :desktop-windows :reads '(:session :focus :mode :panes :zoom :component-state :viewport :time)
  ```
- `dev/maintaining/ekko-zellij-parity/src/extensions.lisp:12` — key list matches dev/maintaining/ekko-ui-reliability/src/builtins.lisp:8 but has drifted; missing here: (none); extra here: CHROME-STATUS GEOMETRY PANE-NOTES
  ```lisp
  (defparameter *context-keys* '(:session :focus :panes :layout :mode :zoom :viewport :chrome-status :pane-notes :component-state :geometry))
  ```
- `dev/sandbox/headlong-lisp/lisp/src/orchestration.lisp:48` — key list matches dev/sandbox/headlong-lisp/lisp/src/context.lisp:136 but has drifted; missing here: CONSTRAINTS DEPENDENCIES; extra here: ANCESTORS IN-FLIGHT LEASE-UNTIL
  ```lisp
  (dolist (key '(:steps :actions :messages :summaries :ancestors :seen-messages :pending-response
  ```
- `dev/maintaining/ekko/src/commands.lisp:828` — key list matches dev/maintaining/ekko-zellij-parity/src/commands.lisp:426 but has drifted; missing here: (none); extra here: MIDDLE-COMMAND WHEEL-COMMAND
  ```lisp
  (unless (member key '(:x :y :text :sgr :rows :overlay :action :context-command :command :arguments :hover-sgr :wheel-command :middle-command :pane :drag)) (error "Unknown decoration field: ~S" key))
  ```

### `defstruct-after-use` (warning) — 27 main / 4 files
- `dev/developing/slope/src/api.lisp:36` — LINE-MODEL (slot) is used before its definition at dev/developing/slope/src/line.lisp:17; the call cannot be inlined
  ```lisp
  (body (to-json (list (cons :model (line-model line))
  ```
- `dev/maintaining/ekko-finix-menu/src/cli.lisp:63` — MAKE-SESSION (constructor) is used before its definition at dev/maintaining/ekko-finix-menu/src/server.lisp:9; the call cannot be inlined
  ```lisp
  (ekko/runtime::install-registry (ekko/runtime::make-session)
  ```
- `dev/maintaining/ekko-finix-menu/src/client.lisp:67` — RECT-X (slot) is used before its definition at dev/maintaining/ekko-finix-menu/src/geometry.lisp:14; the call cannot be inlined
  ```lisp
  (list (ekko/scene:rect-x cut) (ekko/scene:rect-y cut)
  ```
- `dev/maintaining/ekko-hide-panes-worktree/src/commands.lisp:918` — POPUP-OWNER (slot) is used before its definition at dev/maintaining/ekko-hide-panes-worktree/src/menus.lisp:5; the call cannot be inlined
  ```lisp
  (list :object :owner (popup-owner popup) :x (popup-x popup) :y (popup-y popup)
  ```

### `dead-definition` (warning) — 7 main / 7 files
- `dev/maintaining/ekko-zellij-parity/tests/runner.lisp:11` — defun RUN-EKKO-TESTS is never referenced in the analysed files; delete it, or --allow-definition it if a name-dispatched handler reaches it
  ```lisp
  (defun run-ekko-tests ()
  ```
- `dev/maintaining/ekko-hide-panes-worktree/tests/layout_capacity.lisp:15` — defmacro EXPECT-EQUAL is never referenced in the analysed files; delete it, or --allow-definition it if a name-dispatched handler reaches it
  ```lisp
  (defmacro expect-equal (desc got want)
  ```
- `dev/maintaining/ekko/src/daemon.lisp:30` — defun PANE-OWNER is never referenced in the analysed files; delete it, or --allow-definition it if a name-dispatched handler reaches it
  ```lisp
  (defun pane-owner (pane-or-id &optional (daemon *daemon*))
  ```
- `dev/maintaining/ekko/src/commands.lisp:138` — defun LAYOUT-CONTEXT is never referenced in the analysed files; delete it, or --allow-definition it if a name-dispatched handler reaches it
  ```lisp
  (defun layout-context (view)
  ```

### `optional-and-key` (warning) — 11 main / 11 files
- `dev/maintaining/ekko/src/layout.lisp:40` — DEFUN mixes &OPTIONAL and &KEY in one lambda list; callers cannot tell positional from keyword tail arguments
  ```lisp
  (defun rectangles (tree cols rows focus &optional zoom
  ```
- `dev/maintaining/ekko-hide-panes-worktree/tests/dock_capacity.lisp:59` — DEFUN mixes &OPTIONAL and &KEY in one lambda list; callers cannot tell positional from keyword tail arguments
  ```lisp
  (defun snapshot (width height &optional (mode :normal) &key (minimized-last t) (focus 1))
  ```
- `dev/maintaining/ekko-zellij-parity/src/geometry.lisp:86` — DEFUN mixes &OPTIONAL and &KEY in one lambda list; callers cannot tell positional from keyword tail arguments
  ```lisp
  (defun clip-placement (destination source pane client visible &optional overlays
  ```

### `quadratic-append` (warning) — 8 main / 6 files
- `dev/maintaining/ekko-finix-menu/src/extensions.lisp:33` — setf *COMPONENTS* (append *COMPONENTS* (list ...)) copies the whole list on every call; accumulate and NREVERSE once
  ```lisp
  (setf *components* (append *components* (list (make-component :id (name-string id) :reads reads :handler handler))))
  ```
- `dev/developing/slope/src/line.lisp:462` — setf MESSAGES (append MESSAGES (list ...)) copies the whole list on every call; accumulate and NREVERSE once
  ```lisp
  (setf messages (append messages (list message)))))
  ```

### `earmuffs` / `defparameter-named-like-constant` (note) — 2 each, 1 file
- `dev/maintaining/ekko/src/store.lisp:10` — (defparameter +NAMESPACE-LIMIT+) names a special without earmuffs; bind it with LET and you rebind global state
  ```lisp
  (defparameter +namespace-limit+ 256)
  ```

- `dev/maintaining/ekko/src/store.lisp:10` — (defparameter +NAMESPACE-LIMIT+) is named like a constant but is rebindable
  ```lisp
  (defparameter +namespace-limit+ 256)
  ```

### `reader-error` (note) — 5 main / 5 files
- `dev/maintaining/ekko/src/presentation.lisp:0` — can't read #. while *READ-EVAL* is NIL (skipped to the next top-level form)
  ```lisp
  <past eof>
  ```

### `forward-reference` (note) — 0 main; 4242 autolith — *recommend off by default*
- `maintaining/autolith-clinedi-fix/tests/plan-tests.lisp:3` — TEST-WORKSPACE-PLAN is used at load time before it is defined (later in load order)
  ```lisp
  (-> test-workspace-plan () null)
  ```
- `maintaining/autolith-clinedi-fix/tests/openai-compatible-provider-tests.lisp:3` — OPENAI-COMPATIBLE-PROVIDER-TESTS--SAVE-KEY is used at load time before it is defined (later in load order)
  ```lisp
  (-> openai-compatible-provider-tests--save-key
  ```
- `maintaining/autolith-clinedi-fix/src/terminal/layout.lisp:3` — LAYOUT-COLUMN-WIDTHS is used at load time before it is defined (later in load order)
  ```lisp
  (-> layout-column-widths (list integer &key (:gap-width integer) (:minimum-widths (option list)) (:fill-p boolean)) list)
  ```
- `sandbox/autolith/tests/nous-device-authentication-tests.lisp:5` — NOUS-DEVICE-TEST--MANAGER is used at load time before it is defined (later in load order)
  ```lisp
  (-> nous-device-test--manager () nous-credential-manager)
  ```
- `sandbox/autolith/tests/layout-tests.lisp:5` — TEST-LAYOUT-COLUMN-WIDTHS is used at load time before it is defined (later in load order)
  ```lisp
  (-> test-layout-column-widths () null)
  ```
- `sandbox/autolith/src/core/streams.lisp:5` — FILE-STAT--SAME-OBJECT-P is used at load time before it is defined (later in load order)
  ```lisp
  (-> file-stat--same-object-p (t t) boolean)
  ```

### `unused-parameter` (note) — 0 main; 246 autolith
- `sandbox/autolith/src/workers/scratchpad.lisp:14` — defmethod: parameter TOOL is never referenced
  ```lisp
  (defmethod tool-compact-result-visible-p ((tool lisp-scratchpad-run-tool))
  ```
- `sandbox/autolith/src/inference/policy.lisp:15` — defmethod: parameter POLICY is never referenced
  ```lisp
  (defmethod rlm-decompose-inference-task
  ```
- `maintaining/autolith-clinedi-fix/src/tools/lisp-paren-check.lisp:15` — defmethod: parameter TOOL is never referenced
  ```lisp
  (defmethod tool-storm-guard-exempt-p ((tool lisp-paren-check-tool))
  ```
- `maintaining/autolith-clinedi-fix/src/tools/plan.lisp:17` — defmethod: parameter TOOL is never referenced
  ```lisp
  (defmethod tool-storm-guard-exempt-p ((tool plan-list-tool))
  ```
- `sandbox/autolith/src/tools/workspace.lisp:19` — defmethod: parameter TOOL is never referenced
  ```lisp
  (defmethod tool-child-safe-p ((tool fs-view-image-tool))
  ```
- `maintaining/autolith-clinedi-fix/src/provider/anthropic/client.lisp:21` — defmethod: parameter FAMILY is never referenced
  ```lisp
  (defmethod provider-family-create
  ```

### `ignore-then-read` (warning) — 0 main; 2 autolith
- `sandbox/autolith/src/conversation/image-input.lisp:631` — (declare (ignore FORMAT)) but the body reads or writes FORMAT
  ```lisp
  (declare (ignore format))
  ```

## 5. Rules I would ship disabled, and why

| rule | why |
|---|---|
| `forward-reference` | 4242 hits on autolith, all names that appear as data in test-registration macros. A reader cannot tell a quoted test name from a load-time call without an evaluation model, so the rule cannot be made precise. (It is now order-aware and deduplicated, so its few real hits — e.g. headlong's `*FAULT-HOOK*` in `src/package.lisp` — are correct, but swamped.) |
| `deep-nesting` | 761 notes over 198 files at the default threshold 10; almost all ordinary test `defun`s at depth 10-12. Turn on per-run with `--deep-nesting-depth 14`. |
| `defparameter-named-like-constant` | 2 hits, both `(defparameter +namespace-limit+ ...)`. Autolith's own `AGENTS.md` forbids `defconstant`, so the rule contradicts a project's stated policy; it is a policy check, not a defect check. |

`earmuffs` is kept on despite flagging the same two forms — it asserts the
opposite, non-policy-dependent doctrine (a rebindable special with no earmuffs).

`ignore-then-read` and `unused-parameter` stay on: after the fixes they produce
zero findings on the main corpus, and their residual autolith hits are
name-collision or CLOS-dispatch cases rather than structural false positives.

## 6. State of the four defects, measured

### Defect 1 — `defstruct-after-use` over-firing

* Before: `ekko/src` alone = 1632 findings; the run was 2082 lines.
* After, `ekko/src` alone = 0 (no load order is discoverable there, so it reports
  same-file cases only, exactly as the summary line has always claimed).
* After, on the full `ekko` checkout whose `ekko.asd` supplies a real load order,
  the genuine cross-file `popup` inline-loss cases appear (see §4).
* Corpus-wide after: 27 findings in 4 files, all provable from a known order.
* The slot-list trap is gone: `commands.lisp:1334: PANE-ID (slot) ...` no longer
  appears; the surviving message names the defining file, e.g.
  `... at dev/maintaining/ekko-hide-panes-worktree/src/menus.lisp:5 ...`.

### Defect 2 — `forward-reference` duplicates and test-helper false positives

* Before: headlong `CHECK` 106x, `REJECTS` 28x, 150 total.
* After: headlong `forward-reference` = 5, each a single genuine case:
  `*FAULT-HOOK*`, `*PROFILES*`, `*PROTOCOL-PRINCIPALS*`, `*REMOTE-AUTHORITY*`
  (`src/package.lisp`) and `ANCESTORS` (`src/context.lisp`). The `CHECK`/`REJECTS`
  lines are gone: they are defined in an unordered test file, so the rule no longer
  guesses their order.
* Main corpus: 0. `sort -u` equals `wc -l` on every run.

### Defect 3 — `ignore-then-read` on correct declarations

* The verified case `ekko/src/layout.lisp:12`
  `(destructuring-bind (axis ratio a b) tree (declare (ignore ratio)) ...)` is no
  longer reported; `ekko/src` ignore-then-read = 0.
* Before: ekko/src 60, corpus 321. After: ekko/src 0, corpus 0.
* Remaining: 2 in autolith, both a variable / `cl:format` name collision in one
  function (`(declare (ignore format))` beside `(format nil ...)`), which a
  name-based reader cannot distinguish. Documented, not hidden.

### Defect 4 — duplicate emission and the message-format bug

* Duplicates: `wc -l` == `sort -u | wc -l` on every run — headlong 50/50,
  ekko/src 212/212, slope 49/49, main corpus 2756/2756, autolith 7922/7922.
  Before: 252/89, 2082/1925, 88/54.
* Root causes fixed, not merely masked: the double run of `rule-size` behind two
  rule names (split into two functions) and `forward-reference` emitting per
  occurrence (deduplicated per name+file); `dedupe-diags` is the backstop.
* `duplicated-literal-table` message now populates the left-hand side:

```
sandbox/headlong-lisp/lisp/src/orchestration.lisp:48: ... missing here: ASSIGNMENT BASE-COMMIT REPOSITORY WORK-BRANCH; extra here: ACTIONS BUDGET-OVERRUN CHILDREN DECISIONS MEMORY MESSAGES RESERVATION UNFINISHED
```
  and prints `(none)` when a side is genuinely empty:

```
maintaining/ekko/src/extensions.lisp:16: ... missing here: (none); extra here: ALL-PANES CHROME-STATUS GEOMETRY PANE-NOTES STORE VIEW WORKSPACE
```

  Note: the brief's claim that the left-hand side is *never* populated was itself
  imprecise — the headlong pair above populated it all along; only the ekko pair
  was one-sided, and it now reads cleanly.

### Defect 5 (found, not in the brief) — two rules were dead

`unused-parameter` and `unused-binding` mapped to an undefined function, emitted
nothing, and wrote a `rule ... failed ... undefined` line to stderr for every
file. Both are now live and stderr is empty on every run above.

## 7. Kept small

* All edits are inside `/home/y0usaf/dev/sandbox/lisplint`.
* Scratch files are `/tmp/*.txt` only, small and disposable.

## 8. Second pass — six fixes, plus `fix`

Store `brqan3ibj2p3la3vkrk83s1sn7lpsf38-lisplint-0.1.0`. Files touched this pass:
`src/rules.lisp`, `src/order.lisp`, `src/core.lisp`, `src/cli.lisp`,
`src/fix.lisp` (new), `lisplint.asd`. Nothing outside
`/home/y0usaf/dev/sandbox/lisplint` was written, staged or committed; no tests
or fixtures exist. Every number below is from a command run against the named
real tree.

### 8.1 Three rules are off by default

`lisplint list` now reads `off` for `deep-nesting`, `forward-reference` and
`defparameter-named-like-constant`, with the reason in the description.
`--enable` still turns each on: slope alone goes 38 findings -> 163 with all
three enabled; ekko with `--enable forward-reference` still reports 0.

### 8.2 The load order is never invented

`build-order` now collects every candidate source separately (each `.asd`,
dependency-resolved by topological sort of its `:depends-on` graph; all literal
load lists of one file are one source) and uses one only when there is exactly
one candidate and exactly one analysed root. Anything else prints
`no load order, same-file cases only`.

| run | before | after |
|---|---|---|
| `check $(cat all-files.txt)` (1328 files, 31 roots) | 12484 findings, 1328 scanned, `load order from publish-resume.lisp (literal load list)` | **3464 findings, 1008 scanned, 320 excluded, `no load order, same-file cases only`** |
| 10-path corpus (276 files) | 2869 findings, `load order from ekko.asd (:components)` | **1981 findings, `no load order, same-file cases only`** |
| ekko alone (single root) | 270 findings, `load order from ekko.asd (:components)` | **68 findings, same source — one root, one source, so it is used** |

Whole-corpus line counts are identical to `sort -u` (3465 / 3465), stderr is 0
bytes, exit is 1, wall clock 8.7 s (was 10.3 s).

### 8.3 `ignore-then-read` asks the variable namespace

The rule now collects reads with a new `walk-var-refs`: the operator of a form
is a function, so `(format nil ...)` is not a read of a variable `FORMAT`.

| case | before | after |
|---|---|---|
| whole corpus | 7 | **5** |
| autolith + autolith-clinedi-fix `src/conversation/image-input.lisp` | 1 each (`(declare (ignore FORMAT))` beside `(format nil ...)`) | **0** |
| `dev/developing/ash/shell.lisp:3485` (`out` read in `(write-line target out)`) | fires | **still fires** |
| `dev/sandbox/lisp-lint-audit/benchcheck.lisp:4` (`c` read in `(muffle-warning c)`) | fires | **still fires** |

### 8.4 `defstruct-after-use` respects the dependency graph

The `.asd` reader used to concatenate every `(:file ...)` in file order, which
put `ekko/scene`'s `src/geometry` *after* `src/client` even though
`ekko/runtime` depends on `ekko/scene`. Systems are now topologically sorted by
`:depends-on` before their components are indexed, and quoted data and
keyword-headed clauses are no longer read as call sites.

| run | before | after |
|---|---|---|
| ekko alone | 25 (RECT-X/Y/WIDTH/HEIGHT "used before `src/geometry.lisp:15`", MAKE-SESSION, EXTENSION-WORKER-REGISTRY) | **4, all genuine: `commands.lisp:1456-1457` reads `popup-owner/-x/-y/-selected` before `src/menus.lisp:5`** |
| whole corpus | 9 (from the invented global order) | **0 (no load order, so only same-file cases, of which there are none)** |

### 8.5 Excludes are real and visible

Built-in patterns: `.git`, `node_modules`, `.qlot`, `old-home`, `.cache`,
`*.local/state/*`. Plus `--exclude GLOB` and `.lisplintignore` (current
directory and beside each analysed path; `#` comments). Slash patterns match at
any depth; a bare pattern matches a path component. The whole-corpus run drops
320 paths (319 generated files under `~/.local/state`, 1 `.qlot` example) and
the summary says so rather than hiding it:

```
3464 findings in 497 files (1008 scanned, 320 excluded; no load order, same-file cases only)
```

### 8.6 Whole-corpus per-rule, before -> after

| rule | before | after | why |
|---|---|---|---|
| `deep-nesting` | 4422 | 0 | off by default |
| `forward-reference` | 4238 | 0 | off by default |
| `internal-symbol-leak` | 2088 | 2004 | 84 lived in excluded state trees |
| `long-function` | 910 | 766 | excluded state trees |
| `unused-parameter` | 278 | 278 | |
| `unused-binding` | 136 | 106 | excluded state trees |
| `dead-definition` | 121 | 121 | |
| `quadratic-append` | 120 | 67 | excluded state trees |
| `duplicated-literal-table` | 53 | 53 | |
| `earmuffs` | 38 | 38 | |
| `defparameter-named-like-constant` | 38 | 0 | off by default |
| `reader-error` | 13 | 13 | |
| `optional-and-key` | 13 | 13 | |
| `defstruct-after-use` | 9 | 0 | no load order |
| `ignore-then-read` | 7 | 5 | namespace fix |

### 8.7 `lisplint fix`

Three rewrites, chosen because they are provably safe and local:

1. `ignore-then-read` — delete a `(declare (ignore X))` the body reads as a
   variable. The rule's own predicate is reused, so fix and finding cannot
   disagree. Verified on a copy of `dev/developing/ash/shell.lisp`:

```diff
 (defun builtin-cd (args out in)
-  (declare (ignore out))
   (let* ((target (or (first args) (var-ref "HOME")))
```
   16 findings -> 15, indentation intact.
2. `internal-symbol-leak` — two sites in one pass: add the symbol to the
   defining `defpackage`'s `:export` list and narrow `pkg::sym` to `pkg:sym`.
   Verified on a copy of ekko: 45 edits in 14 files, 64 -> 24 findings, and the
   diff is exactly those two shapes, e.g.

```diff
-           #:parameters))
+           #:parameters #:row-text #:character-width #:update-rendition))
-    (let* ((keys (and semi (ekko/graphics::header ...
+    (let* ((keys (and semi (ekko/graphics:header ...
```
3. `unused-binding` — delete a `let`/`let*` binding only when its init form is a
   literal, quoted, or a plain symbol, the name is unqualified and not declared
   special in the analysed set, and another binding remains. Verified on a copy
   of `dev/sandbox/lisp-lint-audit/fmtfinal.lisp`: 12 edits, 13 -> 1 finding.

Mechanics: splices collected per file, an edit that overlaps one already
accepted in the pass is refused (and reported) rather than reordered, deletions
are widened over the whitespace of the line they empty, splices are applied from
the highest offset down, and the whole pass re-runs to a fixpoint (max 10).
`--dry-run` prints and writes nothing (verified: md5 of ekko's `vt.lisp`
unchanged across a dry run). Whole-corpus dry run: 1850 proposals (1826
`internal-symbol-leak`, 19 `unused-binding`, 5 `ignore-then-read`).
`0 edits applied in 0 files` on a second run in every case.

Deliberately never auto-fixed, each said in the rule's own description:
`quadratic-append` (the rewrite reorders or needs an `nreverse` at the use
site), `dead-definition` (name-dispatched handlers), `optional-and-key` and
`long-function` / `deep-nesting` (API and design changes),
`duplicated-literal-table` (which side is right is a judgement),
`defstruct-after-use` (structural: reordering or an `.asd` edit),
`defparameter-named-like-constant` (a project policy). `reader-error` is not a
registry rule at all — the host reader refused the form, so there is nothing
read to rewrite.

### 8.8 The broken pipe

SBCL ignores `SIGPIPE`, so `lisplint check ... | head` used to die with a
`BROKEN-PIPE` backtrace (4782 bytes on stderr, exit 1). `run` restores the
default action at startup.

```
$ ./result/bin/lisplint check /home/y0usaf/dev/maintaining/ekko | head -1
src/presentation.lisp:0:0: note[reader-error]: can't read #. while *READ-EVAL* is NIL ...
$ echo ${PIPESTATUS[0]}   # 141, stderr 0 bytes
```

## 9. Third pass — SIMPLIFICATION and HOUSE-POLICY families

Store `1igq9p762vmjm25p958dm3ikimm9i2xl-lisplint-0.1.0`. Files touched:
`src/simplify.lisp` (new), `src/house.lisp` (new), `src/core.lisp`,
`src/rules.lisp`, `src/cli.lisp`, `src/fix.lisp`, `lisplint.asd`. Nothing outside
`/home/y0usaf/dev/sandbox/lisplint` was written, staged or committed; no tests or
fixtures exist. `nix build` is green and the image compiles with zero style
warnings. `lisplint list` now has 27 rules; the 13 new ones are all on.

Corpus run for this section: the 11 roots
(`ekko` and its four worktrees, `autolith`, `autolith-clinedi-fix`, `ash`,
`slope`, `tomoe`, `tomoe-v2`) with `--exclude nix` (a `result` symlink under a
project points into `/nix/store` and duplicated one project otherwise):

```console
$ lisplint check <11 roots> --exclude nix
8945 findings in 602 files (807 scanned, 36 excluded; no load order, same-file cases only)
```
`wc -l` 8946 == `sort -u` 8946, exit 1, stderr 0 bytes. The user's trees are
live: `dev/maintaining/tomoe` changed between two runs of this command (a test
function grew from 311 to 318 lines), so per-rule totals drift by a few. The
counts below are from the run above.

### 9.1 The SIMPLIFICATION family

Seven reader-only rules. Six auto-fix; `quote-quote` is report-only because the
requested rewrite is not value-preserving — that is the proof, run against SBCL
2.6.8, and it is why the rule refuses to fix:

```console
$ sbcl --non-interactive --load /tmp/qq.lisp
(eval ''xx)   = 'XX
(eval 'xx)    = BOUND-VALUE
equal?       = NIL
(eval ''5)    = '5
(eval '5)     = 5
list* a nil   = (A) ; list a = (A)
list* a b nil = (A B) ; list a b = (A B)
car==first    = NIL ; cdr==rest = NIL
```

`(quote (quote x))` is the list `(QUOTE X)`; `(quote x)` is the datum. Dropping
the inner quote changes the value, so the rule only reports the doubly-quoted
form as a note.

| rule | decision | why | main corpus | files |
|---|---|---|---|---|
| `redundant-progn` | **fix** | PROGN returns its last form's values and evaluates it once, so `(progn X)` = X in every position | 15 | 13 |
| `when-progn` | **fix** | WHEN/UNLESS's body is already an implicit PROGN and PROGN passes values through, so splicing is a no-op | 0 | 0 |
| `boolean-coercion-in-test` | **fix, test position only** | `(not (null X))` is T/NIL *as a value*; only in a test is it truth-equivalent to X. The `(null X)`→swap is done only for the 3-argument IF | 74 | 38 |
| `funcall-literal-function` | **fix** | `(funcall #'f a b)` and `(f a b)` call f with the same arguments evaluated once, in order; refused for a macro/special-operator name (a macro call expands), a variable designator, or a non-literal arg list | 0 | 0 |
| `quote-quote` | **report-only** | the rewrite is not value-preserving (above) | 0 | 0 |
| `eta-reduction` | **fix** | `(lambda (A..) (f A..))` makes the same call with the same arguments in the same order; refused on &optional/&key/&rest, any transformation, a captured name, a parameter as f, a macro f, a shadowed f, or a multi-form body | 27 | 14 |
| `list-star-nil` | **fix** | `(list* A.. nil)` is `(list A..)`: same arguments, evaluated once, in order | 0 | 0 |

Guards applied to every rule: a form inside a QUOTE is data and is never touched;
evaluation count is preserved (one evaluation to one); nothing replaces a copying
operation with an aliasing one; multiple values pass through PROGN and a spliced
body unchanged.

### 9.2 The HOUSE-POLICY family — one data table, one engine

The conventions come verbatim from the "Common Lisp Style" sections of
`dev/sandbox/autolith/AGENTS.md` and
`dev/maintaining/autolith-clinedi-fix/AGENTS.md` (identical text):

> Do not use `defconstant` or `define-constant`. … Functions and methods with
> four or more parameters use keyword arguments. … Prefer `first` and `rest` over
> `car` and `cdr` in application code. … Whenever a keyword value directly
> follows a keyword-argument name, in a call, an evaluated plist, or a `defclass`
> `:initform`, quote the value … Never quote keywords in unevaluated syntax
> positions: `defclass` `:initarg` names, `case` clause keys, `member` type
> specifiers, quoted configuration data, and macro metadata the macro quotes
> itself. … Give functions and macros documentation strings.

Each row of `*house-policy*` is a plist (name, matcher, severity, default, fix,
opt-out, message); the engine has one matcher per *kind* and the table holds every
head, rename, threshold, severity and message. `carcdr` and `no-defconstant` are
the same matcher kind (`:call-heads`) with different rows. A new convention is a
row, not a rule function.

| rule | default | corpus | files | fixable |
|---|---|---|---|---|
| `carcdr` | on | 929 | 147 | **yes** (same functions) |
| `no-defconstant` | on | 107 | 45 | no (DEFPARAMETER vs DEFVAR is a judgement) |
| `positional-arity-limit` | on | 484 | 204 | no (API change; threshold 3) |
| `missing-docstring` | on | 2531 | 191 | no (author's job; `tests` opted out) |
| `keyword-quoting` | on | 1463 | 160 | no (style) |
| `keyword-quoting-in-unevaluated` | on | 0 | 0 | no |

**What `keyword-quoting` detects.** A call argument is flagged only when a bare
keyword sits in the *value* slot of a maximal run of consecutive keywords (odd
positions from the run's start), and only when the operator is not a CL builtin
(`(list :a :b)`, `(member :a :b)` are excluded by `find-symbol … "CL"`), not a
macro the analysed set defines (their keyword metadata is quoted by the macro),
and not `case`/`cond`/`quote` syntax. A `defclass`/`defstruct` slot definition is
recognised by its second element being a slot-option keyword, and only the
`:initform`/`:default-initargs` values are flagged — never an `:initarg` name.
That last guard is what removed the flood: the first build flagged `:initarg
:state` (an unevaluated name) as a value.

**What `keyword-quoting-in-unevaluated` detects.** Only the two positions a
reader can prove: a `defclass` `:initarg` whose value is a quoted keyword, and a
`case`-family clause key that is a quoted keyword. `member` type specifiers and
quoted configuration data are deliberately **not** detected: `(member 'x lst)` is
a legitimate call and `'(:a ':b)` is indistinguishable from `'(:a (quote :b))`,
so a rule there would be guesswork, and the rule's description says so.

### 9.3 The `.lisplintrc` config surface

A line-oriented table read from the current directory and beside each analysed
path, exactly like `.lisplintignore`; no new dependency:

```
enable RULE / disable RULE            select a policy rule
threshold RULE N                      tune a numeric threshold
opt-out RULE GLOB [GLOB...]           a path a row skips
```

Verified live:

```console
$ cat /tmp/rctest/.lisplintrc        # threshold positional-arity-limit 6
$ lisplint check /tmp/rctest         # (defun foo (a b c d) ...) — no arity note
$ cat /tmp/rctest/.lisplintrc        # threshold positional-arity-limit 2
$ lisplint check /tmp/rctest
x.lisp:1:1: note[positional-arity-limit]: defun FOO has 4 required positional parameters …
x.lisp:1:1: note[missing-docstring]: defun FOO has no documentation string …
$ cat /tmp/rctest/.lisplintrc        # opt-out carcdr tests
$ lisplint check /tmp/rctest         # tests/t.lisp carcdr finding gone; app.lisp kept
```

### 9.4 Real-corpus examples, verified against the files

Paths are as lisplint printed them (relative to the run's common prefix
`/home/y0usaf/dev/`); each source line was read back from the file.

- `redundant-progn` — `maintaining/ekko/src/graphics.lisp:189`
  ```lisp
  (progn
    (commit-image store
  ```
  and `sandbox/autolith/src/terminal/stream.lisp:174`.
- `boolean-coercion-in-test` — `developing/slope/src/api.lisp:20`
  ```lisp
  (if (null at)
      (values (if (plusp (length line)) line nil) nil)
  ```
  `maintaining/tomoe/examples/float.lisp:24` `(if (null output) …)`,
  `sandbox/tomoe-v2/lisp/examples/float.lisp:24` (same form).
- `eta-reduction` — `maintaining/ekko/examples/profiles/zellij-bindings.lisp:42`
  ```lisp
  :handler (lambda (snapshot event)
             (zellij-pane-rename-input-action snapshot event)))
  ```
  `sandbox/autolith/src/localgroup/handoff.lisp:52` and the clinedi-fix copy:
  ```lisp
  (lambda (application handoff-pathname)
    (localgroup-handoff--launch application handoff-pathname))
  ```
- `carcdr` — `maintaining/ekko/src/windows.lisp:10`
  ```lisp
  (let ((rect (cdr (assoc pane rectangles))))
  ```
  `maintaining/tomoe/tests/wm-native.lisp:3`
  `(defun wm-summary (state) (cdr (assoc :wm-state (getf state :data))))`,
  `maintaining/ekko/examples/profiles/scrolling.lisp:10`.
- `no-defconstant` — `maintaining/ekko/src/worker.lisp:3`
  ```lisp
  (defconstant +extension-packet-limit+ 65536)
  ```
  `maintaining/tomoe/src/ipc.lisp:3` `(defconstant +json-wire-version+ 2)`,
  `maintaining/tomoe/src/ipc-transport.lisp:5`.
- `positional-arity-limit` — `maintaining/ekko/src/windows.lisp:7`
  ```lisp
  (defun tiled-border-split (tree rectangles pane edge)
  ```
  `sandbox/autolith/tests/papercut-resource-tests.lisp:8`,
  `sandbox/autolith/tests/memory-resource-tests.lisp:8` (both `…--call`).
- `missing-docstring` — `maintaining/ekko/src/commands.lisp:3`
  ```lisp
  (defun option (session key &optional default)
    (getf (getf (session-registry session) :options) key default))
  ```
  `maintaining/ekko/src/server.lisp:3` `(defun pty-cell-size (view)`,
  `sandbox/tomoe-v2/lisp/src/native.lisp:3` `(defmacro define-native …)`.
- `keyword-quoting` — `maintaining/ekko/src/server.lisp:4`
  ```lisp
  (if (eq (option (view-session view) :pty-pixel-source :effective) :reported)
  ```
  `maintaining/ekko/examples/init.lisp:6`
  ```lisp
  :id :personal :reads '(:session :focus)
  ```
  `maintaining/tomoe/src/processes.lisp:6`
  `(cwd (sb-alien:c-string :external-format :utf-8))`.

`when-progn`, `funcall-literal-function`, `quote-quote`, `list-star-nil` and
`keyword-quoting-in-unevaluated` have **zero** hits in this corpus; their
mechanism is verified on the /tmp copy in 9.5, not on a project file.

### 9.5 Fix demonstrations (copies in /tmp; nothing real touched)

Copy of `dev/developing/slope` at `/tmp/fixdemo-slope`:

```console
$ lisplint check /tmp/fixdemo-slope | grep -cE '\[(carcdr|boolean-coercion-in-test|…)'
182                                  # 165 carcdr + 17 boolean-coercion
$ find … -name '*.lisp' | xargs md5sum | md5sum      # content md5
c2f596f5eecc1901a6ca34fad83b4203
$ lisplint fix /tmp/fixdemo-slope --dry-run | tail -1
212 proposed edits (dry run; nothing written)
$ find … -name '*.lisp' | xargs md5sum | md5sum
c2f596f5eecc1901a6ca34fad83b4203      # unchanged: dry-run wrote nothing
$ lisplint fix /tmp/fixdemo-slope | tail -1
230 edits applied in 9 files (7 refused)
$ lisplint check /tmp/fixdemo-slope | grep -cE '\[(carcdr|…)'
0
$ lisplint fix /tmp/fixdemo-slope     # second run
$                                     # silent: fixpoint reached
```

Copy of a hand-written exercise file at `/tmp/fixdemo.lisp`, which is the only
place the zero-hit rules are shown applying (11 findings -> 0, two passes):

```diff
-  (progn x))
+  x)
-  (when c (progn (alpha) (beta))))
+  (when c (alpha) (beta)))
-  (if (not (null x)) a b))
+  (if x a b))
-  (if (null x) a b))
+  (if x b a))
-  (funcall #'cons a b))
+  (cons a b))
-  (list* a b nil))
+  (list a b))
-  (list* a nil))
+  (list a))
-  (mapcar (lambda (y) (car y)) lst))
+  (mapcar #'first lst))
-  (mapcar (lambda (y) (cdr y)) lst))
+  (mapcar #'rest lst))
```

`(lambda (y) (car y))` shows the two-fix interaction: the carcdr rename is
accepted first (it sits inside the lambda), the eta edit is refused in that pass,
and the next pass reduces `(lambda (y) (first y))` to `#'first`. The loop
converges, and the source spelling is preserved (`#'first`, not `#'FIRST`).

### 9.6 Over-firing check

The loudest new rules were investigated before shipping, not after:

| rule | largest single project | verdict |
|---|---|---|
| `missing-docstring` | 463 (ekko) | **precise** — 4 sampled hits read back from file are `defun option`, `defun pty-cell-size`, `defun leave-copy`, `defmacro define-native`, all genuinely with no docstring. Their written policy requires one; the code simply does not comply as uniformly as the brief assumed. Severity is `note`, `tests` is opted out. |
| `keyword-quoting` | 249 (ekko-finix-menu) | **precise after the `:initarg` fix**; every sampled hit is a bare keyword in a keyword value slot (`:pty-pixel-source :effective`, `:id :personal`, `:external-format :utf-8`). |
| `carcdr` | 165 (slope) | **precise** — operator-position `car`/`cdr` only; every sampled hit is a real call (`(cdr (assoc …))`). |

No new rule was found imprecise, so **none ships disabled**. Duplicate output is
still zero: the whole-corpus run is 8946 lines with 8946 unique, and every run
writes 0 bytes to stderr.

## 10. Fourth pass — printed paths and `result` symlinks

Two output/collection defects, found by independent verification of the 28-rule
build and fixed in `src/core.lisp` (both), `src/cli.lisp` and `src/fix.lisp`
(plumbing). Build:

```console
$ nix build --no-link --print-out-paths
/nix/store/76p2v5285h88sdsfqdnkl3gr1y25ldwp-lisplint-0.1.0
$ nix log /nix/store/phk70mzggifp8csr8xxm9ldnfsfxx2xr-lisplint-0.1.0.drv | grep -i 'warn|style|error'
(no match: the image compiles with zero warnings)
```

`result` was deliberately **not** refreshed: another worker was running
`./result/bin/lisplint` while this was built, so every measurement below uses
the printed store path directly.

### 10.1 Printed paths: absolute by default, `--relative` opts in

`common-prefix` returned `/` for any multi-root or `~/`-spanning set, and
`short-name` then did `(subseq abs 1)` — dropping the leading slash and printing
`home/y0usaf/dev/...`, a string neither a shell nor an editor can open. The old
single-root form (`src/ash.lisp:0:0`) had the same problem from the other end:
relative to a root the reader does not know.

Chosen: **absolute paths by default, `--relative` as the explicit opt-in for the
single-root short form.** The output is machine-readable `path:line:col`, and a
consumer's first act with that path is to open it; a shorter string is worth
less than an openable one. `short-name` now strips `*root-prefix*` only when
`*relative*` is on *and* the prefix is longer than `/`, so the leading slash can
no longer be dropped by construction. `--relative` with more than one root is a
request the tool cannot honour and exits 2 rather than guessing.

```console
$ lisplint check /home/y0usaf/dev/sandbox/lisplint
/home/y0usaf/dev/sandbox/lisplint/tools/readcheck.lisp:3:14: note[carcdr]: CDR is …
$ lisplint check /home/y0usaf/dev/sandbox/lisplint --relative
tools/readcheck.lisp:3:14: note[carcdr]: CDR is …
$ lisplint check /home/y0usaf/dev/sandbox/lisplint /home/y0usaf/dev/developing/slope --relative
lisplint: --relative needs exactly one root, got 2        # exit 2
$ lisplint check <the two roots above> --format json
… "summary":{"findings":596,"files":23,"excluded":1,"symlinks_skipped":2,"order":"unknown"}
… "path":"/home/y0usaf/dev/developing/slope/src/ash.lisp"
```

### 10.2 `result` symlinks into the store are skipped, visibly

SBCL's `directory` resolves a symlink before returning it, so a `result` link
inside a project arrived as `/nix/store/<hash>-tomoe-0.1.0/share/tomoe/…` and was
linted as ordinary source: build output of the code already under the root,
counted twice and reported against a vendored copy. `collect-lisp-files` now
drops any entry that resolves outside **every given root** (which covers
`/nix/store` and any other out-of-tree link), counting them. The count is
printed, not swallowed, exactly as the built-in excludes are:

```console
$ lisplint check <11 corpus roots>            # before, old store 1igq9p76
8385 findings in 600 files (814 scanned, 15 excluded; no load order, same-file cases only)
$ grep -c 'nix/store' out                                   # 85 lines, e.g.
nix/store/9l1phhzl7x58qamgpin74izi8fcpxsz5-tomoe-0.1.0/share/tomoe/examples/float.lisp:8:1: note[earmuffs]: …
$ lisplint check <11 corpus roots>            # after, store 76p2v528
8300 findings in 594 files (807 scanned, 21 excluded, 10 symlink targets skipped; no load order, same-file cases only)
$ grep -c 'nix/store' out                                   # 0
```

The corpus command carries no `--exclude nix`: that flag was the previous
worker's workaround for exactly this defect and is no longer needed.

### 10.3 Numbers, before and after on the same trees

| run | findings | files | scanned | excluded | symlink targets | store lines |
|---|---|---|---|---|---|---|
| old, no flag (the reported defect) | 8385 | 600 | 814 | 15 | — | 85 |
| old, `--exclude nix` | 8300 | 594 | 807 | 36 | — | 0 |
| new, no flag | 8300 | 594 | 807 | 21 | 10 | 0 |

The new run is **identical to `--exclude nix` in findings, files and scanned**
(8300 / 594 / 807) and differs from the unexcluded old run by exactly the 85
store findings in 6 vendored files. So the defect-1 change moved no count at
all, and the defect-2 change removed precisely the store copies. `--exclude nix`
skipped exactly the 15 directories named `nix` that sit under these roots (10 in
the five worktrees — each has `nix/` and `docs/evidence/zellij/.../nix` — 2 at the
autolith roots, 3 under `ref/`); `find` confirms none of the 15 holds a `.lisp`/`.asd`, so the new run
descends them harmlessly and counts only the 21 default-pattern exclusions plus
the 10 out-of-root targets. The analysed file set is the same 807.

```console
$ lisplint check <11 corpus roots> > out 2> err
$ echo $?; wc -c < err; wc -l < out; sort -u out | wc -l; grep -vc '^/' out
1
0
8301
8301
1          # the summary line only: every diagnostic line starts with '/'
```

`sort -u` equals `wc -l`, stderr is 0 bytes, exit is 1 (findings), and three
sampled paths open as printed:

```console
$ for f in /home/y0usaf/dev/sandbox/autolith/recovery/launcher.lisp \
           /home/y0usaf/dev/maintaining/ekko-finix-menu/tests/assets.lisp \
           /home/y0usaf/dev/maintaining/ekko-ui-reliability/src/client.lisp; do test -f "$f" && echo OPENABLE $f; done
OPENABLE /home/y0usaf/dev/sandbox/autolith/recovery/launcher.lisp
OPENABLE /home/y0usaf/dev/maintaining/ekko-finix-menu/tests/assets.lisp
OPENABLE /home/y0usaf/dev/maintaining/ekko-ui-reliability/src/client.lisp
```


## 11. Fifth pass — `keyword-quoting` is auto-fixed in its evaluated positions

`keyword-quoting` was the largest report-only rule. Its refusal ("a style
convention") is right for an unevaluated position — a macro can inspect the raw
form — but wrong for the positions the rule restricts itself to: a call
argument, an evaluated plist, a `defclass`/`defstruct` `:initform`, and
`:default-initargs`. A keyword self-evaluates, so in those positions `:X` and
`':X` are the same value and evaluating each returns that one value; inserting
`'` before the token is provably value-preserving.

Files touched: `src/house.lisp`, `src/simplify.lisp`, `src/fix.lisp`. No new
mechanism: the existing splice engine and the SIMPLIFICATION proposal pattern
were extended.

### What changed

- `src/house.lisp` — the `keyword-quoting` row is now `:fix t` and its
  description says so. The three emitters (`flag-keyword-run`,
  `flag-kw-value`, `flag-slot-options`) became proposal builders
  (`propose-keyword-run`, `propose-kw-value`, `propose-slot-options`), and
  `match-kw-value-quote` now merely emits the proposals its own predicate
  `propose-kw-value-quote` returns. Each proposal carries its edit (one `'`
  inserted at the keyword token's first character), so an edit can only exist
  where the finding does. `policy-kw-quote-fix-edits` feeds those edits into
  the splice engine, using the same `:fix` gate, opt-out and `.lisplintrc`
  settings as the other policy fixes.
- `src/simplify.lisp` — the DEFMACRO-name scan moved into `defmacro-names-of`,
  shared by the SIMPLIFICATION fixes and the new keyword fix (the macro table
  is built from the analysed set, as `check` does).
- `src/fix.lisp` — `collect-fix-edits` appends `policy-kw-quote-fix-edits`.

### The one position kept report-only

A macro reads its arguments as forms, so quoting a keyword there is not
provably safe. The rule already excludes heads that are CL names, macros, or
unevaluated syntax (`CASE`/`COND`/`QUOTE`/`FUNCTION`), and that exclusion is
unchanged. One hole in that exclusion is in the slot-option path: a form shaped
like a slot definition, `(some-macro :initform :x)`, reaches
`propose-slot-options` before any macro test. The finding is still reported
(unchanged), but the edit is withheld when the head names a macro known to the
analysed set, so the quote is never inserted where a macro can see the raw
form. This is the only case where the fix is narrower than the finding, and it
is stated in the rule's description.

### Demonstration (`/tmp/kwdemo/demo.lisp`, a copy — never a real project)

A synthetic file with five `keyword-quoting` findings: a non-CL call with two
keyword values, two `defclass` `:initform` values, and one macro-headed
`(capture :initform :raw)`. `check` before: 5 `keyword-quoting`, 13 findings
total. `fix --dry-run`: **4 proposed edits**, file content md5 unchanged
(`ec37d84d6004b2e2e154712ecf2fd9ad` before and after). `fix`: **4 edits applied
in 1 file, 0 refused** (md5 `71b617fa1baed64cbfa6652713e2a1ff`). The edited
lines read `:pty-pixel-source ':effective`, `:initform ':idle`,
`:initform ':fast`; the macro-headed `:raw` was left bare. `check` after: 1
`keyword-quoting` (the macro-headed one), 9 findings total. A second `fix`
exits 0 silently (fixpoint). Read back in SBCL 2.6.8: the call parses as
`(SPAWN-PTY "sh" :PTY-PIXEL-SOURCE ':EFFECTIVE :EXTERNAL-FORMAT ':UTF-8)`, its
evaluated arguments equal the unquoted call's, and `(eq :utf-8 ':utf-8)` is
`T`.

### Application to the canonical checkouts

`fix --enable keyword-quoting` (same as `fix`, since `keyword-quoting` is on by
default) was run with the rebuilt binary. Nothing was staged, committed,
stashed, checked out or reset; every change is uncommitted. `tomoe` was not
touched, its 36 deferred files and the four `ekko` worktrees were not touched,
and `autolith`'s three files carrying the user's pre-existing uncommitted work
(`src/application/runtime.lisp`, `src/terminal/ui.lisp`,
`tests/terminal-tests.lisp`) were excluded.

| project | dry-run proposals | edits applied | files | `keyword-quoting` before → after | total before → after |
|---|---|---|---|---|---|
| ekko | 208 | 208 | 18 | 208 → 0 | 777 → 569 |
| autolith | 52 | 52 | 21 | 59 → 7 | 702 → 650 |
| autolith-clinedi-fix | 77 | 77 | 26 | 77 → 0 | 859 → 782 |
| ash | 9 | 9 | 1 | 9 → 0 | 214 → 205 |
| slope | 29 | 29 | 5 | 29 → 0 | 302 → 273 |
| tomoe-v2 | 16 | 16 | 7 | 16 → 0 | 212 → 196 |

391 edits applied in 78 files, 0 refused; every project re-ran `fix` to a
silent exit 0 (fixpoint). The 7 surviving `keyword-quoting` findings in
`autolith` are all in the deferred `tests/terminal-tests.lisp`, which the run
was told to leave alone. `check`'s behaviour is otherwise unchanged: the
`before` totals above are identical to those section 10 recorded on the same
scopes.

## 12. Sixth pass — hardening the two unsafe fix rules, and the inverse check

Two `fix` rewrites produced real regressions in the user's projects, each caught
only by an independent build. This pass removes both, adds the check that would
have caught the first in review, and re-verifies on the real corpus.

### 12.1 `internal-symbol-leak`: the fix never creates an export

The old fix was two-site: append the symbol to the defining DEFPACKAGE's
`:export` and narrow `PKG::SYM` to `PKG:SYM`. In slope that appended the export
to `src/ash.lisp`, a **generated** file (`git check-ignore` matches it; the flake
does `install -m644 ${ash}/shell.lisp src/ash.lisp`), so the real ASH package
still exported only `#:main #:run-command` and the build failed with `The symbol
"*BUILTINS*" is not external in the ASH package`. An export the fix itself adds
is not proof, so the fix no longer adds one. It narrows only when the analysed set
already shows the symbol external — a DEFPACKAGE `:export` clause or a top-level
`(export '(...))` call — and then re-reads the defining file's source to confirm
it before emitting the splice; anything unprovable is refused and printed:

```console
$ lisplint fix --dry-run /tmp/iso-slope-leak2      # git HEAD edit.lisp (ash::*builtins*)
/tmp/iso-slope-leak2/src/edit.lisp:199: internal-symbol-leak: REFUSED (not proven safe: the analysed DEFPACKAGE for ASH does not export *BUILTINS*; narrowing would create an external it never declared)
3 proposed edits, 1 refused (not proven safe) (dry run; nothing written)
exit 1, stderr 0 bytes
```

### 12.2 `eta-reduction`: the target must precede the reference

`#'f` resolves at load time; `(lambda (...) (f ...))` resolves when called. The
old rule rewrote a lambda to `#'f` with no look at definition order, so both
autolith checkouts got `#'localgroup-handoff--launch` at `handoff.lisp:52` for a
defun at line 381, and the build died with `The function
AUTOLITH::LOCALGROUP-HANDOFF--LAUNCH is undefined`. (`git diff` shows four such
rewrites, all forward.) The fix now applies only when the analysed set holds a
definition of the target that provably precedes the reference — same file, defun
line earlier; cross file, earlier in a KNOWN load order — and refuses (report
only) when the order is unprovable, including any target not in the set. The rule
description states exactly that.

```console
$ lisplint fix --dry-run /tmp/iso-autolith-eta     # git HEAD handoff.lisp, the four real lambdas
handoff.lisp:52: eta-reduction: REFUSED (not proven safe: the definition of LOCALGROUP-HANDOFF--LAUNCH does not precede this reference in load order)
handoff.lisp:57: eta-reduction: REFUSED (... LOCALGROUP-HANDOFF--STOP-REPLACEMENT ...)
handoff.lisp:62: eta-reduction: REFUSED (... LOCALGROUP-HANDOFF--WAIT-FOR-REPLACEMENT ...)
handoff.lisp:71: eta-reduction: REFUSED (... LOCALGROUP-HANDOFF--LAUNCH-FOR ...)
0 proposed edits, 4 refused (not proven safe) (dry run; nothing written)
```

It is not a blanket refusal: the same real file with the real
`(defun localgroup-handoff--launch ...)` moved before its reference proposes the
same rewrite and refuses only the three whose defuns still follow.

```console
$ lisplint fix --dry-run /tmp/iso-eta-ok
handoff.lisp:54: eta-reduction: (lambda (application handoff-pathname) (localgroup-handoff--launch application handoff-pathname)) -> #'localgroup-handoff--launch
handoff.lisp:58: eta-reduction: REFUSED (...)
handoff.lisp:62: eta-reduction: REFUSED (...)
handoff.lisp:69: eta-reduction: REFUSED (...)
1 proposed edit, 3 refused (not proven safe) (dry run; nothing written)
```

### 12.3 The inverse rule: `unexported-external-reference`

New, warning, report-only: a `PKG:SYM` reference with a **single** colon whose
SYM the analysed set does not export. Strings cannot match (only symbol nodes are
read). A package whose DEFPACKAGE is not in the analysed set is **not** reported:
its exports cannot be checked, and guessing is what caused the slope regression.
It is the mirror of `internal-symbol-leak` and is what would have caught the
broken file in review. `lisplint list` is now 28 rules (was 27).

```console
$ lisplint check /tmp/iso-slope-leak       # real slope src + the real ash shell.lisp the flake installs
/tmp/iso-slope-leak/src/edit.lisp:199:28: warning[unexported-external-reference]: ash:*builtins* uses a single colon but ASH does not export *BUILTINS*; reading it signals a package error
exit 1, stderr 0 bytes
```

On the **live** slope tree the rule does not fire, and that is correct: the
on-disk generated `src/ash.lisp` currently carries the `#:*builtins*` export the
bad fix inserted, so as far as the reader can see the symbol is external there.

An early draft reported 70 corpus findings; every one was a false positive from
`ekko/platform` exporting `initialize-assets` and friends with a top-level
`(export '(...))` call (src/assets.lisp:42) rather than in its defpackage. The
rule and the fix now both read that form, and the corpus count is 0.

### 12.4 Real-corpus verification (13 roots: ekko + 6 worktrees, autolith, autolith-clinedi-fix, ash, slope, tomoe, tomoe-v2)

`nix build` green; store `mn8a0v3zrn0zvlj2cw0wg2liik6nf6h4-lisplint-0.1.0` (the
run below reproduced byte-identically under the earlier build of the same code).

```console
$ lisplint check <13 roots>
8032 findings in 578 files (810 scanned, 22 excluded, 10 symlink targets skipped; no load order, same-file cases only)
exit 1; stderr 0 bytes; wc -l 8033 == sort -u 8033     # no duplicate diagnostic lines
  2550 missing-docstring   1947 internal-symbol-leak   1163 keyword-quoting
   758 long-function         484 positional-arity-limit  440 carcdr
   ...
     4 eta-reduction          0 unexported-external-reference

$ lisplint fix --dry-run <13 roots>
1954 proposed edits, 1631 refused (not proven safe) (dry run; nothing written)
exit 1; stderr 0 bytes; two runs byte-identical (deterministic)
  proposed: 1167 keyword-quoting, 440 carcdr, 320 internal-symbol-leak,
            21 boolean-coercion-in-test, 5 redundant-progn, 1 ignore-then-read
  refused:  1627 internal-symbol-leak (174 no DEFPACKAGE in the set, which the
            old code also declined; 1453 DEFPACKAGE present but the symbol not
            exported), 4 eta-reduction
```

**Newly-refused edits: 1457** — 1453 `internal-symbol-leak` the old code would
have narrowed while appending an export, plus 4 `eta-reduction` it would have
rewritten ahead of the target. The 320 remaining `internal-symbol-leak`
proposals are cases where the symbol is already external.

On the two named projects, `fix --dry-run` proposes neither rewrite again:

```console
$ lisplint fix --dry-run /home/y0usaf/dev/developing/slope
0 proposed edits, 0 refused (not proven safe) (dry run; nothing written)   # exit 0
$ lisplint fix --dry-run /home/y0usaf/dev/sandbox/autolith
10 proposed edits, 88 refused (not proven safe) (dry run; nothing written) # 0 eta, exit 1
$ lisplint fix --dry-run /home/y0usaf/dev/maintaining/autolith-clinedi-fix
0 proposed edits, 86 refused (not proven safe) (dry run; nothing written)  # 0 eta, exit 1
```
