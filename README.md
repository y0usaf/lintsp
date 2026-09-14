# lintsp

A reader-only Common Lisp linter. It parses your source with the **host reader**
and reports structural pathologies — no compiler, no daemon, no LSP, no
third-party dependencies. One binary that reads files and exits.

The design model is `strictix` (the Nix equivalent): one thing that runs, a
fixed rule set, and a machine-readable output mode.

## Build and run

Requires Nix (the flake pins `nixpkgs`); SBCL alone also works for the ASDF
system.

```console
$ nix build
$ ./result/bin/lintsp check /path/to/project

# or without a local checkout:
$ nix run . -- check /path/to/project
```

## CLI

```console
lintsp check [paths...] [options]   parse and report; exit 1 on any finding
lintsp fix   [paths...] [--dry-run] apply the rewrites it can prove safe
lintsp list                         print every rule, its default and description
```

`check` needs at least one path. Options (repeatable where noted):

| option | effect |
|---|---|
| `--enable RULE` / `--disable RULE` | toggle a rule |
| `--exclude GLOB` | skip matching paths |
| `--format json` | machine-readable output instead of text |
| `--allow-definition NAME` | treat NAME as used (name-dispatched handlers) |
| `--allow-symbol NAME` | treat NAME as host-provided |
| `--order FILE` | load order, one path per line |
| `--relative` | print paths relative to the single root (default: absolute) |
| `--long-function-lines N` | threshold (default 80) |
| `--deep-nesting-depth N` | threshold (default 10) |

Exclusions: a `.lintspignore` in the current directory and beside each analysed
path (one glob per line, `#` comments), plus `--exclude GLOB`. The path
components `.git`, `node_modules`, `.qlot`, `old-home`, `.cache` and
`*.local/state/*` are always skipped, and any path that resolves outside every
given root (a `result` store symlink, for instance) is skipped visibly rather
than silently.

Policy: a `.lintsprc` beside the paths selects rules and tunes thresholds
(`enable RULE`, `disable RULE`, `threshold RULE N`, `opt-out RULE GLOB`).

Exit codes: **0** no findings, **1** findings (or a refused fix), **2** usage
error.

## `check` vs `fix`

`check` only reports. `fix` is deliberately conservative: it applies a rewrite
**only when it can prove the rewrite safe and local**, prints every refusal with
its reason (`REFUSED (not proven safe: …)`), and leaves everything else
report-only by design. There is no rule that rewrites on a guess. Overlaps are
refused rather than reordered, the pass re-runs to a fixpoint, and `--dry-run`
prints and writes nothing.

This is not theoretical caution. Two former `fix` rewrites (`internal-symbol-leak`
appending an export to a *generated* file, and `eta-reduction` rewriting to `#'f`
for a target defined *later*) produced real regressions in the user's projects,
each caught only by an independent build. Both were removed: the fix now narrows
an internal reference only when the analysed `DEFPACKAGE` already exports the
symbol, and an eta-reduction applies only when the target provably precedes the
reference in load order.

**Fixes should be followed by the project's own build.** That build is how the
tool's own safety was validated — a rewrite that changes behaviour shows up
there, not in the linter.

## Rules

28 rules, grouped by family. `list` prints the same set with full descriptions
and defaults. Three are **off by default** (marked below).

### Structural — `src/rules.lisp`

| rule | default | what it flags |
|---|---|---|
| `dead-definition` | on | a top-level definition referenced nowhere in the analysed files |
| `deep-nesting` | **off** | a form nested deeper than the depth threshold |
| `defparameter-named-like-constant` | **off** | a `defparameter` using the `+constant+` convention (policy, not a defect) |
| `defstruct-after-use` | on | a structure accessor used before the `DEFSTRUCT` that defines it |
| `duplicated-literal-table` | on | two near-identical literal key lists with a divergence |
| `earmuffs` | on | a special variable named without `*earmuffs*` |
| `forward-reference` | **off** | a load-time use of a name before its definition |
| `ignore-then-read` | on | a `(declare (ignore x))` on a parameter the body then reads |
| `internal-symbol-leak` | on | a cross-package `PKG::` reference in source (strings excluded) |
| `long-function` | on | a function body longer than the line threshold |
| `optional-and-key` | on | a lambda list containing both `&OPTIONAL` and `&KEY` |
| `quadratic-append` | on | `(setf x (append x (list y)))`, which copies the whole list per call |
| `unexported-external-reference` | on | a single-colon `PKG:SYM` whose symbol the package does not export |
| `unused-binding` | on | a lexical binding never referenced |
| `unused-parameter` | on | a lambda-list parameter never referenced |

### Simplification — `src/simplify.lisp`

| rule | what it flags |
|---|---|
| `boolean-coercion-in-test` | an `(if (not (null X)) A B)` test (fixable in a test position only) |
| `eta-reduction` | a `(lambda (A…) (f A…))` that only passes its arguments through |
| `funcall-literal-function` | `(funcall #'f …)` / `(apply #'f (list …))` with a literal designator |
| `list-star-nil` | `(list* A … nil)`, whose value is `(list A …)` |
| `quote-quote` | a doubly-quoted `(quote (quote X))` (report-only: the rewrite is not value-preserving) |
| `redundant-progn` | a `(progn X)` whose sole body form is `X`, or a `PROGN` nested in a `PROGN` |
| `when-progn` | a `(when/unless C (progn A B))` whose `PROGN` is body syntax |

### House policy — `src/house.lisp`

| rule | what it flags |
|---|---|
| `carcdr` | `CAR`/`CDR` in application code; the style prefers `FIRST`/`REST` |
| `keyword-quoting` | a bare keyword in an evaluated keyword-value position |
| `keyword-quoting-in-unevaluated` | a keyword quoted in an unevaluated syntax position (`:initarg`, `case` key) |
| `missing-docstring` | a `DEFUN`/`DEFMETHOD`/`DEFMACRO`/`DEFCLASS` with no documentation string |
| `no-defconstant` | `DEFCONSTANT`/`DEFINE-CONSTANT`, forbidden by the project's Lisp style |
| `positional-arity-limit` | a lambda list with more than 3 required positional parameters |

See `REPORT.md` for the engineering record and the corpus measurements behind
these defaults, and `STATUS.md` for the running log.
