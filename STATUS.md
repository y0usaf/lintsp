# STATUS — dogfooding pass: does it run on a real file? (2026-09-15, DONE)

Edits only inside lintsp. No user project touched. No tests added. Every
number below is from a run of the built binary (store
`fk2hh8v8p92cn8d5f1nrn9pmyanfc297-lintsp-0.1.0`).

## Does it run clean on the big file?

Yes. `/home/y0usaf/dev/developing/ash/shell.lisp` is 219,688 bytes /
4,784 very long lines (not 220k lines — the memory figure was bytes).
`lintsp check` finished in **0.115 s**, exit 1 (findings), **0 bytes of
stderr**, no crash. Its own `src/` (7 files, 3,700 lines) likewise.

## Fixes this pass (two commits, both verified by re-run)

- `ffb9f68 fix(reader): read #. as quoted data instead of dropping the
  form`. `#.` under `*READ-EVAL* NIL` used to error and skip the whole
  enclosing top-level form — ash's `dt->type` (`case` keys written
  `#.+dt-dir+`) was invisible to analysis, which is also what made its
  three dead-definition findings false. A private readtable now reads
  `#.X` as `(QUOTE X)`: no evaluation, the form survives.
- `d86d0ec fix(rules): count quoted names as mentions for
  dead-definition`. A symbol inside `QUOTE` data is not a call site, but
  a dispatch table selects on it all the same — the rule had flagged all
  20 `rule-*` functions reachable through lintsp's own quoted
  `*rule-fns*` alist.

## Findings, before → after the fixes

`check src/` — 345 → **325 findings** (exit 1):

| rule | after | notes |
|---|---|---|
| carcdr | 172 | house policy; lintsp's own code doesn't follow it |
| missing-docstring | 101 | house policy |
| positional-arity-limit | 29 | house policy |
| self-concatenating-accumulator | 8 | real quadratic patterns |
| keyword-quoting | 8 | house policy |
| dead-definition | **4** | all four verified unreferenced by grep: `ORDER-INDEX`, `CTX-ALL-NODES`, `NODE-STRING-ATOMS`, `RULE-DEFAULT-ON-P` — true positives, real dead code |
| unused-binding | 1 | real (`dotimes` counter) |
| quadratic-append | 1 | real |
| boolean-coercion-in-test | 1 | real |

`check ash/shell.lisp` — 223 → **220 findings** (exit 1):

| rule | after | notes |
|---|---|---|
| missing-docstring | 167 | house policy |
| positional-arity-limit | 19 | house policy |
| no-defconstant | 11 | house policy |
| keyword-quoting | 9 | house policy |
| unused-parameter / unused-binding | 4 / 4 | spot-checked: real |
| long-function | 3 | real (169-, 155-, 84-line defuns) |
| self-concatenating-accumulator | 2 | real (string accumulator in loops) |
| dead-definition | **1** | `+DT-UNKNOWN+`, genuinely unreferenced |
| reader-error | 0 | was 1; `#.` now reads |

Triage of the delta: 23 clear false positives eliminated (20 quoted
dispatch-table entries on self, 3 `#.`-shadowed references on ash), 1
honest coverage note recovered (`dt->type` is now analysed and flagged
for a missing docstring). Remaining findings are real or intended
house-policy noise; nothing else looked like a false positive.

## Recommendation: keep dormant, run on demand — do not gate on it

- **Not retire**: it works, it's fast (0.1 s on the largest file), and it
  found real defects in both targets — four dead functions in lintsp
  itself and a dead constant in ash.
- **Not a flake check**: the finding mix is dominated by house-policy
  notes (288 of 325 on self). Its own source doesn't satisfy its own
  house rules, so a gate fails on day one unless policy is tuned per
  project via `.lintsprc` — real config work for a tool nothing invokes.
  If a gate is ever wanted, the sane subset is the structural rules
  (`dead-definition`, `unused-*`, `self-concatenating-accumulator`,
  `quadratic-append`) run on a project that has opted in — and lintsp
  itself would first need its four genuinely dead functions deleted.
- **Keep dormant**: value is the occasional audit exactly like this one.
  `nix run . -- check <path>` already works.

## Known limits surfaced

- `#.X` in an evaluated position (e.g. a `DEFVAR` init) is read as data:
  X's names become mentions but not call-site references. Strictly more
  coverage than the old skip-the-form behaviour; still not evaluation.
- `dead-definition` cannot see name dispatch a quoted symbol never
  mentions (`intern`-built names, `--allow-definition` remains the escape
  hatch).

---

# Previous status (kept verbatim)

> Renamed from lisplint on 2026-09-14. Historical text below keeps the old name.

## hardening the two unsafe fix rules + the inverse check rule (DONE)

Edits only inside /home/y0usaf/dev/sandbox/lisplint. No user project touched.
No tests / fixtures / golden files. Every number from a command actually run.
(NOTE: an earlier STATUS.md — the SIMPLIFICATION + HOUSE-POLICY pass, store
1igq9p76 — was overwritten here in a write collision with a sibling agent; its
detail lives on in REPORT.md sections 8-11.)

## What changed
- `fix` `internal-symbol-leak` (src/fix.lisp): NO LONGER adds an export. It
  narrows `PKG::SYM` only when the analysed set already shows SYM external (a
  DEFPACKAGE `:export` clause or a top-level `(export '(...))` call), then
  re-reads the defining file's source to confirm before splicing. Everything
  else is refused and printed report-only. This is what broke slope: the old
  two-site fix appended the export to a generated file
  (`git check-ignore` -> .gitignore:6 `src/ash.lisp`; the flake installs it from
  the `ash` input), so the real ASH package never exported `*builtins*`.
- `fix` `eta-reduction` (src/simplify.lisp): applies only when the target's
  definition provably PRECEDES the reference (same file by defun line; cross
  file by a KNOWN load order). Unknown order, a later definition, or a target not
  in the set is refused. `#'f` resolves at load time, the lambda does not, which
  is why the autolith rewrites (ref 52, def 381) broke the build. Rule
  description updated to say exactly when the fix applies.
- NEW rule `unexported-external-reference` (src/rules.lisp, warning, report
  only): a single-colon `PKG:SYM` whose SYM the analysed set does not export.
  Packages outside the analysed set are not reported (cannot check). Strings
  cannot match. `lisplint list` = 30 rules.
- `fix` prints guard refusals (`REFUSED (not proven safe: REASON)`) and counts
  them; refused edits make the exit code 1. Refusal lines are deduped.
- ctx gains `fn-defs` (function definitions by file:line) and `package-exports`;
  `cmd-fix` now computes load order like `cmd-check` so fix and check agree.

## Files changed
src/core.lisp, src/rules.lisp, src/simplify.lisp, src/fix.lisp, src/cli.lisp.

## Verification (store mn8a0v3zrn0zvlj2cw0wg2liik6nf6h4-lisplint-0.1.0)
- `nix build` green.
- Corpus (13 roots: ekko + its 6 worktrees, autolith, autolith-clinedi-fix,
  ash, slope, tomoe, tomoe-v2):
  check -> 8032 findings in 578 files (810 scanned, 22 excluded, 10 symlink
  targets skipped), exit 1, stderr 0 bytes, 8033 lines == 8033 unique. New rule
  0 findings; eta-reduction 4, each carrying its refusal reason.
  fix --dry-run -> 1954 proposals, 1631 refusals, exit 1, stderr 0, byte-identical
  across two runs.
- Newly-refused edits: **1457** = 1453 internal-symbol-leak (DEFPACKAGE in set,
  symbol not exported) + 4 eta-reduction.
- Isolation (real files, copies in /tmp):
  /tmp/iso-slope-leak  (real slope src + the real ash shell.lisp the flake
  installs) -> check reports `src/edit.lisp:199:28 warning[unexported-external-`
  `reference]: ash:*builtins* ...`.
  /tmp/iso-slope-leak2 (same, edit.lisp at git HEAD `ash::*builtins*`) -> fix
  refuses the narrowing.
  /tmp/iso-autolith-eta (git HEAD handoff.lisp; four real lambdas) -> fix refuses
  all four.
  /tmp/iso-eta-ok (same file, real defun moved before the lambda) -> fix proposes
  that one and refuses the other three: the guard is precise, not blanket.
- Real trees: slope fix --dry-run 0/0 exit 0; autolith 10/88; clinedi 0/86; zero
  eta-reduction proposals in all three. On live slope `check` does not fire the
  new rule — correct: the on-disk generated src/ash.lisp still carries the export
  the bad fix inserted.

## Rename + publish (2026-09-14)
- Directory `lisplint` -> `lintsp`; `lisplint.asd` -> `lintsp.asd`
  (`:defsystem "lintsp"`); Lisp package `#:lisplint` -> `#:lintsp`; flake
  package/app/check/binary -> `lintsp`; every CLI string (usage, errors, `.lintspignore`,
  `.lintsprc`). `grep -rn lisplint` over code/flake/asd/CLI = 0 hits; only
  REPORT.md and STATUS.md keep historical text, each carrying a top note.
- Deleted the 121 MB local `lintsp` image and the stale `result` symlink; added
  `.gitignore` (`result`, `result-*`, `/lintsp`, `.sbcl-path`, `*.fasl`,
  `*.dx64fsl`, `*.lx64fsl`, `.cache/`, `*.local/`, `.qlot/`).
- README.md written. Removed the dangling `lintsp/tests` defsystem from
  `lintsp.asd` (it pointed at a `tests/test` that does not exist; no tests added).
- `nix build` green (store `62ikrfwvrqvhnb3ia8zbshcqv36aqypq-lintsp-0.1.0`);
  `./result/bin/lintsp list` = 30 rules.
- Published private: https://github.com/y0usaf/lintsp (commit 7987664).

