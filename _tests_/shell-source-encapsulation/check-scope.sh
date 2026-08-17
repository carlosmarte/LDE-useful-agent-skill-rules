#!/usr/bin/env bash
# check-scope.sh — report everything a sourceable file leaves behind in the
# caller's shell.
#
#   check-scope.sh FILE [ALLOWED_NAME ...]
#
# Sources FILE in a pristine `bash --noprofile --norc` and `zsh -f`, diffs the
# function and variable namespaces before/after, subtracts each shell's own
# baseline noise, and prints whatever survived. Names listed as ALLOWED_NAME
# (the file's documented public surface) are expected and not counted.
#
#   CHECK_SCOPE_CALL="mytool_init"   also run this after sourcing, so helpers
#                                    that are unset in the entry point's
#                                    epilogue are judged after the cleanup.
#
# Exit status: 0 = nothing outside the allow-list leaked, 1 = leaks found,
# 2 = usage/setup error.

set -u

target=${1-}
if [ -z "$target" ]; then
    printf 'usage: check-scope.sh FILE [ALLOWED_NAME ...]\n' >&2
    exit 2
fi
if [ ! -r "$target" ]; then
    printf 'check-scope.sh: cannot read %s\n' "$target" >&2
    exit 2
fi
shift
allowed=$*
target=$(cd "$(dirname "$target")" && printf '%s/%s\n' "$PWD" "$(basename "$target")")

workdir=$(mktemp -d) || exit 2
trap 'rm -rf "$workdir"' EXIT

# --- probes ------------------------------------------------------------------
# Each probe sources $1 (empty file for the baseline run) and prints the names
# that appeared, as "fn <name>" / "var <name>". Probe-internal names are
# prefixed __cs_ and filtered out.

cat >"$workdir/probe.bash" <<'PROBE'
__cs_before_f=$(declare -F | cut -d' ' -f3)
__cs_before_v=$(compgen -v)
__cs_before_o=$({ printf '%s\n' "$-" | fold -w1 | sed 's/^/set -/'; shopt -p; } 2>/dev/null)
# shellcheck disable=SC1090
. "$1" >/dev/null 2>&1
[ -n "${CHECK_SCOPE_CALL-}" ] && eval "$CHECK_SCOPE_CALL" >/dev/null 2>&1
__cs_after_f=$(declare -F | cut -d' ' -f3)
__cs_after_v=$(compgen -v)
__cs_after_o=$({ printf '%s\n' "$-" | fold -w1 | sed 's/^/set -/'; shopt -p; } 2>/dev/null)
{
    comm -13 <(printf '%s\n' "$__cs_before_f" | sort -u) \
             <(printf '%s\n' "$__cs_after_f"  | sort -u) | sed 's/^/fn /'
    comm -13 <(printf '%s\n' "$__cs_before_v" | sort -u) \
             <(printf '%s\n' "$__cs_after_v"  | sort -u) | sed 's/^/var /'
    comm -13 <(printf '%s\n' "$__cs_before_o" | sort -u) \
             <(printf '%s\n' "$__cs_after_o"  | sort -u) | sed 's/^/opt /'
} | grep -v ' __cs_' || true
PROBE

cat >"$workdir/probe.zsh" <<'PROBE'
__cs_before_f=${(ko)functions}
__cs_before_v=${(ko)parameters}
__cs_before_o=$(setopt)
source "$1" >/dev/null 2>&1
[[ -n ${CHECK_SCOPE_CALL-} ]] && eval "$CHECK_SCOPE_CALL" >/dev/null 2>&1
__cs_after_f=${(ko)functions}
__cs_after_v=${(ko)parameters}
__cs_after_o=$(setopt)
{
    comm -13 <(print -l ${=__cs_before_f} | sort -u) \
             <(print -l ${=__cs_after_f}  | sort -u) | sed 's/^/fn /'
    comm -13 <(print -l ${=__cs_before_v} | sort -u) \
             <(print -l ${=__cs_after_v}  | sort -u) | sed 's/^/var /'
    comm -13 <(print -l ${=__cs_before_o} | sort -u) \
             <(print -l ${=__cs_after_o}  | sort -u) | sed 's/^/opt /'
} | grep -v ' __cs_' || true
PROBE

: >"$workdir/empty.sh"

run_probe() {                       # run_probe <shell> <probe> <file>
    case $1 in
        bash) bash --noprofile --norc "$2" "$3" 2>/dev/null ;;
        zsh)  zsh -f "$2" "$3" 2>/dev/null ;;
    esac
}

status=0

for shell in bash zsh; do
    if ! command -v "$shell" >/dev/null 2>&1; then
        printf '%s: not installed, skipped\n\n' "$shell"
        continue
    fi
    probe=$workdir/probe.$shell

    # Baseline: what the probe itself perturbs, with nothing sourced.
    run_probe "$shell" "$probe" "$workdir/empty.sh" | sort -u >"$workdir/base.$shell"
    run_probe "$shell" "$probe" "$target"           | sort -u >"$workdir/real.$shell"

    leaks=$(comm -13 "$workdir/base.$shell" "$workdir/real.$shell")

    kept=""
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        name=${line#* }
        skip=0
        for a in $allowed; do
            [ "$name" = "$a" ] && skip=1 && break
        done
        [ "$skip" -eq 1 ] && continue
        kept="$kept$line
"
    done <<EOF
$leaks
EOF

    printf '=== %s ===\n' "$shell"
    if [ -z "$kept" ]; then
        printf 'clean — nothing outside the allow-list survived\n\n'
    else
        printf 'LEAKED:\n%s\n' "$kept"
        status=1
    fi
done

if [ "$status" -ne 0 ]; then
    printf 'Leaks found. Make internals `local`, namespace helpers and `unset -f`\n'
    printf 'them, and publish globals only behind an explicit opt-in.\n'
fi
exit "$status"
