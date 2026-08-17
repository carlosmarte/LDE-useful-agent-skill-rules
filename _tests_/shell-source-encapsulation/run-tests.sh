#!/usr/bin/env bash
# run-tests.sh — tests for the shell-source-encapsulation skill.
#
# Two jobs:
#   1. Re-verify every shell behavior the skill states as fact, so a bash/zsh
#      upgrade that invalidates the skill shows up here as a failure.
#   2. Extract the template embedded in shell-source-encapsulation.md and run
#      check-scope.sh against it, proving the copy in the skill file is the one
#      that actually works.
#
# Usage: _tests_/shell-source-encapsulation/run-tests.sh
# Exit 0 = all pass, 1 = failures.

set -u

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
skill=$repo/shell-source-encapsulation.md
checker=$here/check-scope.sh

work=$(mktemp -d) || exit 2
trap 'rm -rf "$work"' EXIT

pass=0
fail=0

ok()   { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  FAIL %s\n'  "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; }

# expect <label> <expected> <actual>
expect() {
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi
}

# expect_match <label> <pattern> <actual>
expect_match() {
    case "$3" in
        *$2*) ok "$1" ;;
        *)    bad "$1" "expected to contain [$2], got [$3]" ;;
    esac
}

have() { command -v "$1" >/dev/null 2>&1; }

printf '== shell facts the skill asserts ==\n'

# Fact: function definitions are always global, nesting included.
for sh in bash zsh; do
    have "$sh" || continue
    out=$("$sh" -c 'outer(){ inner(){ :; }; inner; }; outer; command -v inner >/dev/null && echo GLOBAL || echo SCOPED' 2>&1)
    expect "$sh: nested function definition is global" "GLOBAL" "$out"
done

# Fact: `local` at top level — bash errors, zsh accepts and leaks.
printf 'local TOPLEVEL=leaked\n' >"$work/toplevel.sh"
if have bash; then
    out=$(bash --noprofile --norc -c 'source "$1" 2>&1 >/dev/null | head -1' _ "$work/toplevel.sh")
    expect_match "bash: top-level local is an error" "can only be used in a function" "$out"
fi
if have zsh; then
    out=$(zsh -f -c 'source "$1" >/dev/null 2>&1; printf "%s" "${TOPLEVEL-gone}"' _ "$work/toplevel.sh")
    expect "zsh: top-level local silently leaks" "leaked" "$out"
fi

# Fact: `local x=$(cmd)` masks the exit status; declare-then-assign preserves it.
for sh in bash zsh; do
    have "$sh" || continue
    out=$("$sh" -c 'f(){ local x=$(false); printf "%s " "$?"; local y; y=$(false); printf "%s" "$?"; }; f')
    expect "$sh: local x=\$(cmd) masks status, split preserves it" "0 1" "$out"
done

# Fact: a function can unset itself mid-run and still finish.
for sh in bash zsh; do
    have "$sh" || continue
    out=$("$sh" -c 'f(){ unset -f f; printf "finished"; }; f; command -v f >/dev/null && printf %s "STILL" || printf %s "-gone"')
    expect "$sh: function may unset itself mid-run" "finished-gone" "$out"
done

# Fact: `::` is a legal function name character in both shells.
for sh in bash zsh; do
    have "$sh" || continue
    out=$("$sh" -c 'ns::fn(){ printf ok; }; ns::fn' 2>&1)
    expect "$sh: :: is legal in a function name" "ok" "$out"
done

# Fact: typeset -g is zsh-only.
if have bash; then
    out=$(bash -c 'typeset -g X=1' 2>&1 | head -1)
    expect_match "bash: typeset -g is rejected" "-g" "$out"
fi
if have zsh; then
    out=$(zsh -f -c 'f(){ typeset -g X=1; }; f; printf "%s" "${X-gone}"' 2>&1)
    expect "zsh: typeset -g sets a global" "1" "$out"
fi

# Fact: set -u in a sourced file leaks into the caller.
printf 'set -u\n' >"$work/opt.sh"
if have bash; then
    out=$(bash --noprofile --norc -c 'source "$1"; case $- in (*u*) printf LEAKED ;; (*) printf clean ;; esac' _ "$work/opt.sh")
    expect "bash: sourced set -u leaks into the caller" "LEAKED" "$out"
fi

# Fact: zsh emulate -L / local_options restores options on return.
if have zsh; then
    out=$(zsh -f -c 'f(){ emulate -L zsh; setopt nounset; }; f; setopt | grep -qx nounset && printf LEAKED || printf restored')
    expect "zsh: emulate -L restores options on return" "restored" "$out"
fi

# Fact: sourced-vs-executed detection works in both shells.
cat >"$work/detect.sh" <<'EOF'
if [ -n "${BASH_VERSION-}" ]; then
    ( return 0 2>/dev/null ) && __sourced=1 || __sourced=0
else
    case "${ZSH_EVAL_CONTEXT-}" in (*:file*) __sourced=1 ;; (*) __sourced=0 ;; esac
fi
printf '%s' "$__sourced"
EOF
if have bash; then
    expect "bash: detects sourced"  "1" "$(bash --noprofile --norc -c 'source "$1"' _ "$work/detect.sh")"
    expect "bash: detects executed" "0" "$(bash --noprofile --norc "$work/detect.sh")"
fi
if have zsh; then
    expect "zsh: detects sourced"  "1" "$(zsh -f -c 'source "$1"' _ "$work/detect.sh")"
    expect "zsh: detects executed" "0" "$(zsh -f "$work/detect.sh")"
fi

printf '\n== the template embedded in the skill file ==\n'

if [ ! -r "$skill" ]; then
    bad "skill file present" "missing: $skill"
else
    # Pull the fenced block between the template markers.
    awk '/^<!-- BEGIN template:sourceable.sh -->/{grab=1; next}
         /^<!-- END template:sourceable.sh -->/{grab=0}
         grab && !/^```/{print}' "$skill" >"$work/mytool.sh"

    if [ ! -s "$work/mytool.sh" ]; then
        bad "template extracted from skill" "no content between the template markers"
    else
        ok "template extracted from skill"

        # Syntax-checks under both shells.
        for sh in bash zsh; do
            have "$sh" || continue
            if err=$("$sh" -n "$work/mytool.sh" 2>&1); then
                ok "$sh: template parses"
            else
                bad "$sh: template parses" "$err"
            fi
        done

        allow="mytool_init __MYTOOL_LOADED"

        # Default path: only the public name, the guard, and the namespaced helpers.
        out=$("$checker" "$work/mytool.sh" $allow 2>&1)
        if printf '%s' "$out" | grep -q '__mytool::' &&
           ! printf '%s' "$out" | grep -qv -e '__mytool::' -e '^===' -e '^LEAKED' -e '^clean' -e '^$' -e '^Leaks found' -e '^them,'; then
            ok "source only: nothing beyond the namespaced helpers survives"
        else
            bad "source only: nothing beyond the namespaced helpers survives" "$out"
        fi

        # After the entry point runs, its epilogue must leave nothing behind.
        if CHECK_SCOPE_CALL="mytool_init" "$checker" "$work/mytool.sh" $allow >/dev/null 2>&1; then
            ok "after mytool_init: helpers retired, zero leaks"
        else
            bad "after mytool_init: helpers retired, zero leaks" \
                "$(CHECK_SCOPE_CALL="mytool_init" "$checker" "$work/mytool.sh" $allow 2>&1)"
        fi

        # Opt-in path must publish MYTOOL_ROOT and nothing else.
        out=$(CHECK_SCOPE_CALL="mytool_init --global" "$checker" "$work/mytool.sh" $allow 2>&1)
        leaked=$(printf '%s\n' "$out" | grep -E '^(fn|var|opt) ' | sort -u)
        expect "opt-in path publishes exactly MYTOOL_ROOT" "var MYTOOL_ROOT" "$leaked"

        # Sourcing twice must be a no-op (idempotence guard).
        for sh in bash zsh; do
            have "$sh" || continue
            out=$("$sh" -c 'source "$1"; source "$1"; printf "%s" "$__MYTOOL_LOADED"' _ "$work/mytool.sh" 2>&1)
            expect "$sh: second source is a no-op" "1" "$out"
        done
    fi
fi

printf '\n== the checker itself catches a polluting file ==\n'

cat >"$work/bad.sh" <<'EOF'
set -u
GREETING=hello
helper() { COUNT=1; }
EOF
out=$("$checker" "$work/bad.sh" 2>&1)
status=$?
expect "checker exits non-zero on a polluting file" "1" "$status"
for want in 'fn helper' 'var GREETING'; do
    expect_match "checker reports $want" "$want" "$out"
done
have bash && expect_match "checker reports the leaked shell option" "opt set -u" "$out"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
