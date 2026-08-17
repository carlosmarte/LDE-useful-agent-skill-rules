---
name: shell-source-encapsulation
description: Write bash/zsh files that are safe to `source` — every internal variable and helper function stays local, and only the one required entry point becomes global, with globals published solely when the user opts in. Use when authoring or reviewing a .sh/.zsh/.bash file meant to be sourced (dotfiles, env bootstraps, tool loaders, completion or activate scripts, shell-based skill/CLI plumbing), when asked to "not pollute my shell", "keep it out of my environment", "make it opt-in", "namespace these helpers", or when a sourced file leaked variables, helper functions, aliases, traps, or `set -u`/`set -e` into an interactive session.
---

# Sourced shell files must not pollute the caller's shell

`source file.sh` (a.k.a. `. file.sh`) runs the file **in the caller's own shell
process**. Every variable it assigns, every function it defines, every `set`
option it flips, every alias and trap it installs stays behind in the user's
interactive session for the rest of that session. Nothing is scoped, nothing is
cleaned up, and the user gets no say in it.

## The rule

> **Anything sourceable that you generate exposes exactly one public name — the
> documented entry point. Every other variable is `local`, every other function
> is namespaced and unset before the file finishes, and no global is written
> into the user's environment unless the user explicitly opted in.**

"Explicitly opted in" means one of: they passed a flag to the entry point
(`init_x --global`), they set an env var before sourcing
(`LOAD_X_TOOLS=true source x.sh`), or they called a function whose documented
job is to export. Sourcing the file by itself is never consent.

This applies to files you write, files you edit, and files you propose in a plan
or README. If an existing file already pollutes, do not extend the pattern —
flag it and offer the wrapper below.

## Why `local` alone is not enough

Two facts do most of the damage. Both verified on bash 3.2 / 5.x and zsh 5.9:

1. **Function definitions are always global.** There is no local function scope
   in either shell. Defining a helper inside another function still publishes it
   globally the moment the outer function runs:

   ```bash
   outer() { inner() { echo hi; }; inner; }
   outer
   command -v inner   # → inner is now defined in the caller's shell
   ```

2. **`local` at file top level does not work — and fails differently per shell.**
   bash errors with `local: can only be used in a function`; zsh accepts it and
   **silently leaks the variable** into the caller. Never write `local` outside a
   function body in a sourceable file.

So encapsulation comes from the *shape* of the file, not from sprinkling
`local`.

## Method 1 — Function wrapper (the default; use this unless told otherwise)

Sourcing only registers the entry point. Nothing runs, nothing is set, until the
user calls it. Globals appear only behind an explicit flag. Copy this whole file
as the starting point:

<!-- BEGIN template:sourceable.sh -->
```bash
#!/usr/bin/env bash
# mytool.sh — bash/zsh compatible, safe to source.
#
# Contract:
#   source mytool.sh          -> registers exactly one function: mytool_init
#                                nothing runs, nothing is set, nothing exported
#   mytool_init               -> runs; all internals are local; nothing survives
#   mytool_init --global      -> ALSO exports MYTOOL_ROOT (explicit opt-in)
#
# Nothing else in this file is part of the public surface. Helpers are
# namespaced __mytool:: and retired before mytool_init returns.

# --- idempotence: a second source is a no-op --------------------------------
[ -n "${__MYTOOL_LOADED-}" ] && return 0
__MYTOOL_LOADED=1

# --- private helpers (namespaced; unset in the epilogue) ---------------------

__mytool::detect_root() {
    local candidate
    # Declare first, assign second: `local x=$(cmd)` would swallow cmd's status.
    candidate=${1:-$PWD}
    [ -d "$candidate" ] || return 1
    printf '%s\n' "$candidate"
}

__mytool::usage() {
    printf 'usage: mytool_init [--global] [PATH]\n' >&2
}

# --- the single public entry point ------------------------------------------

mytool_init() {
    # Every internal is local; it disappears when this function returns.
    local publish=0 arg root

    while [ $# -gt 0 ]; do
        case $1 in
            --global) publish=1 ;;
            -h|--help) __mytool::usage; return 0 ;;
            -*) printf 'mytool_init: unknown option %s\n' "$1" >&2
                __mytool::usage; return 2 ;;
            *)  arg=$1 ;;
        esac
        shift
    done

    root=$(__mytool::detect_root "${arg-}") || {
        printf 'mytool_init: no usable root\n' >&2
        return 1
    }

    if [ "$publish" -eq 1 ]; then
        # Opt-in only. Drop `export` if child processes do not need it.
        export MYTOOL_ROOT="$root"
        printf 'MYTOOL_ROOT=%s (exported)\n' "$root"
    else
        printf 'mytool root: %s (not exported; pass --global to export)\n' "$root"
    fi

    # Epilogue: retire the helpers. Safe even mid-run — a function may unset
    # itself and still finish. Drop this block only if the helpers are needed
    # on every subsequent call, and say so in the header above.
    unset -f __mytool::detect_root __mytool::usage
}

# No top-level `local` (bash errors, zsh leaks silently).
# No `set -e` / `set -u` / `setopt` here — those would leak into the user's shell.
# No `exit` anywhere in this file — it would kill an interactive shell.
```
<!-- END template:sourceable.sh -->

If helpers must survive because the entry point calls them on every invocation,
drop the `unset -f` epilogue, keep the `__mytool::` prefix, and say so in the
header. Namespaced names are a documented, greppable, single-`unset` surface —
not hidden, but not a collision either. Both shells accept `::` in function
names.

**How the user interacts**

| Step | Effect |
|------|--------|
| `source mytool.sh` | one function registered; no variables, no side effects |
| `mytool_init` | runs; every internal is `local`; helpers retired; nothing survives |
| `mytool_init --global` | user explicitly opts in; `MYTOOL_ROOT` is exported |

## Method 2 — Feature flag (strict opt-in, nothing registered by default)

When even registering a function is too much — a file auto-sourced by a
directory hook, a shared profile fragment, an optional debug toolkit — gate the
whole body on an env var the caller must set:

```bash
# tools.sh — loaded only with: LOAD_MY_TOOLS=true source tools.sh
if [ "${LOAD_MY_TOOLS-}" = "true" ]; then
    export API_ENDPOINT="https://internal.example"

    my_special_function() {
        local payload
        payload=$(...)
        printf '%s\n' "$payload"
    }
fi
```

`source tools.sh` alone leaves the environment untouched. Use `= "true"`
(explicit value), not `-n` — an inherited empty-ish value should not count as
consent.

## Method 3 — Execute instead of source (no shell contact at all)

If the file only needs to *do* something rather than *install* something, stop
sourcing it. `./tool.sh` or `bash tool.sh` runs in a subshell process: its
variables, functions, `cd`, `set -e`, and exports die with it.

```bash
#!/usr/bin/env bash
set -euo pipefail          # safe here — this is a real script, not a fragment
MY_VAR=123
do_work() { printf 'working with %s\n' "$MY_VAR"; }
do_work
```

Reserve `source` for the one thing a subshell genuinely cannot do: change the
caller's environment (`cd`, `export`, shell functions, `PATH`). If the answer to
"does this need to modify the user's live shell?" is no, it must not be sourced.

## Choosing

| Method | Mechanism | Use when |
|---|---|---|
| Function wrapper | one public function; internals `local`; globals behind a flag | default — a toolset the user loads, then triggers |
| Feature flag | whole body inside `if [ "$FLAG" = "true" ]` | auto-sourced/shared files; nothing may register by accident |
| Execute | run in a subshell instead of sourcing | the file performs a task and needs no access to the live shell |

## Authoring checklist

Apply every line to any sourceable file you generate:

- [ ] **One public name.** The entry point. Everything else is `local`, or
      namespaced `__tool::` / `__tool_` and unset before the file or entry point
      finishes.
- [ ] **`local` every function-internal variable**, including loop counters and
      `i`. An undeclared assignment inside a function is a global in both shells.
- [ ] **Declare, then assign, for command substitution.** `local x=$(cmd)`
      throws away `cmd`'s exit status — `$?` is the status of `local`, always 0
      (verified). Write `local x; x=$(cmd) || return 1`.
- [ ] **No `local` at top level.** bash errors; zsh leaks it silently.
- [ ] **Don't nest helpers to hide them** — nested definitions are still global.
- [ ] **No global writes without opt-in.** Plain assignment inside a function is
      global; `export` also crosses into child processes. Both need consent.
      `typeset -g` is zsh-only — bash rejects `-g` outright, so don't reach for
      it in a portable file.
- [ ] **No shell options.** `set -u` / `set -e` / `shopt` / `setopt` in a sourced
      file leak into the interactive shell (verified — `set -u` in a sourced file
      leaves the user's shell in nounset mode, where a typo'd variable then kills
      it). If a function truly needs an option, scope it: zsh
      `emulate -L zsh` or `setopt local_options` restore on return (verified);
      in bash, save `$-` / `shopt -p` and restore before every `return` path.
- [ ] **No unrequested aliases, traps, `cd`, or `PATH` edits.** A `trap` set at
      file scope replaces whatever the user had. If a `PATH` edit is the point,
      make it the opt-in action and guard against duplicate entries.
- [ ] **Idempotent.** Guard with `[ -n "${__TOOL_LOADED-}" ] && return 0` so a
      second `source` (new tab, re-run `.zshrc`) is a no-op.
- [ ] **`return`, never `exit`.** `exit` in a sourced file kills the user's
      interactive shell.
- [ ] **Header comment states the contract:** what the public name is, how to
      trigger it, and what — if anything — goes global on opt-in.

## Detecting sourced vs. executed

Use this when a file must work both ways, or must refuse the wrong one:

```bash
if [ -n "${BASH_VERSION-}" ]; then
    ( return 0 2>/dev/null ) && __sourced=1 || __sourced=0
else
    case "${ZSH_EVAL_CONTEXT-}" in (*:file*) __sourced=1 ;; (*) __sourced=0 ;; esac
fi
```

Verified: bash gives 1 under `source` and 0 under `bash file.sh`; zsh's
`ZSH_EVAL_CONTEXT` is `cmdarg:file` / `toplevel:file` / `cmdarg:shfunc:file` when
sourced and plain `toplevel` when executed. Guard the execute-only path with it
(`[ "$__sourced" -eq 1 ] || { echo "source me"; exit 1; }`), and unset
`__sourced` before returning.

## Verify before you hand it over

Source the file in a pristine shell and diff the namespace. This is the whole
check — paste it as-is, substituting your file:

```bash
# bash: what survived a plain `source`?
bash --noprofile --norc -c '
  bf=$(declare -F | cut -d" " -f3); bv=$(compgen -v)
  . "$1" >/dev/null 2>&1
  comm -13 <(printf "%s\n" "$bf" | sort -u) <(declare -F | cut -d" " -f3 | sort -u) | sed "s/^/fn  /"
  comm -13 <(printf "%s\n" "$bv" | sort -u) <(compgen -v | sort -u) | grep -v "^b[fv]$" | sed "s/^/var /"
' _ ./mytool.sh

# zsh: same question
zsh -f -c '
  bf=${(ko)functions}; bv=${(ko)parameters}
  source "$1" >/dev/null 2>&1
  comm -13 <(print -l ${=bf} | sort -u) <(print -l ${(ko)functions} | sort -u) | sed "s/^/fn  /"
  comm -13 <(print -l ${=bv} | sort -u) <(print -l ${(ko)parameters} | sort -u) | grep -v "^b[fv]$" | sed "s/^/var /"
' _ ./mytool.sh
```

Expected output for the template above: the two `__mytool::` helpers plus
`mytool_init` and `__MYTOOL_LOADED` — and nothing at all once `mytool_init` has
run and retired its helpers. Append `; mytool_init` after the `source` line to
check that post-call state, and `; mytool_init --global` to confirm the opt-in
path publishes `MYTOOL_ROOT` and nothing else.

Shell options leak too and do not show up in a name diff — compare `$-` and
`shopt -p` (bash) or `setopt` (zsh) across the source the same way.

A runnable version of all of this, covering both shells and subtracting each
shell's own baseline noise, lives at
`_tests_/shell-source-encapsulation/check-scope.sh`:

```bash
_tests_/shell-source-encapsulation/check-scope.sh ./mytool.sh mytool_init __MYTOOL_LOADED
CHECK_SCOPE_CALL="mytool_init" _tests_/shell-source-encapsulation/check-scope.sh ./mytool.sh mytool_init __MYTOOL_LOADED
```

It exits non-zero when anything outside the allow-list survives.

## Gotchas that keep biting

| Symptom | Cause | Fix |
|---|---|---|
| Helper function visible after sourcing | function definitions are always global, nesting included | namespace + `unset -f` in the epilogue |
| `local: can only be used in a function` | `local` at top level in bash | move it into a function |
| Variable leaks only under zsh | zsh accepts top-level `local` and leaks it | same — move it into a function |
| Failing command not detected | `local x=$(cmd)` masks the exit status | `local x; x=$(cmd) || return 1` |
| Interactive shell dies on an unset variable after sourcing | `set -u` leaked from the file | drop it, or scope with `emulate -L zsh` / save-and-restore `$-` |
| Terminal closes when the file hits an error | `exit` in a sourced file | use `return` |
| PATH grows on every new tab | no idempotence guard | `__TOOL_LOADED` guard + duplicate check |
| `typeset: -g: invalid option` | `typeset -g` is zsh-only | plain assignment inside the function, or `export` |
