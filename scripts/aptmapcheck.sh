#!/usr/bin/env bash
# scripts/aptmapcheck.sh — is pkg/map/apt.map still true?
#
# The map is not code. It is ~20 assertions about someone else's package archive,
# measured on one day and then trusted forever: this Arch name is spelled that way
# on Ubuntu, and this one does not exist there at all. Archives move. A rename we
# have not noticed breaks `hwe install` on Ubuntu for the first person who tries
# it, and nothing before that point says a word.
#
# Same shape of problem as pkg/fonts.lock, so the same answer: a job that asks the
# question on a schedule (see .github/workflows/aptmapwatch.yml). This lives in a
# script rather than in the workflow because a check you cannot run yourself is a
# check you have to fix blind.
#
# Run it on Ubuntu — natively, or from anywhere with:  just apt-map-check
#
# Exit codes are distinct on purpose. A mirror that did not answer is not the same
# news as a package that is gone, and a red tick that conflates them trains people
# to re-run instead of read.
#   0  the map still describes the archive
#   1  the map is wrong: something was renamed, removed, or has since appeared
#   2  the archive could not be reached — nothing was learned either way

set -uo pipefail

HWE_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
export HWE_ROOT
# shellcheck source=lib/common.sh
source "$HWE_ROOT/lib/common.sh"

[[ "$(_distro_family)" == apt ]] || die "run this on a Debian/Ubuntu system (or: just apt-map-check)"
command -v apt-get >/dev/null 2>&1 || die "apt-get not found"

_sudo() { if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi; }

log "Checking pkg/map/apt.map against $(. /etc/os-release && printf '%s %s' "$NAME" "$VERSION_ID")"

# Did the archive actually answer? Two tempting ways to ask are both wrong:
# `apt-get update` exits 0 even when every source failed to download, and
# `apt-cache policy <some package>` answers from the dpkg status for anything
# already installed, so it reports a candidate with no index at all. Ask for the
# thing itself — a downloaded Packages index. Without this, a machine with no
# network finds every package missing and accuses the map of being wrong, which
# is the one conclusion the evidence cannot support.
_sudo apt-get update -qq >/dev/null 2>&1
if ! find /var/lib/apt/lists -maxdepth 1 -name '*Packages*' -size +0c -print -quit 2>/dev/null | grep -q .; then
    err "no package index was downloaded — the archive did not answer"
    info "nothing was checked; this says nothing about pkg/map/apt.map"
    exit 2
fi

fail=0

# --- 1. everything HWE installs still resolves ----------------------------
# The lists are Arch's vocabulary; _pm_translate turns them into local names,
# which is precisely the thing under test.
# Same rules as _pkgs_read in the installer, inlined rather than sourcing the
# whole installer for one sed — this script has no business defining install steps.
_lst() { sed -e 's/#.*//' -e '/^[[:space:]]*$/d' -e 's/[[:space:]]//g' "$@"; }

mapfile -t pkgs < <(
    {
        _lst "$HWE_ROOT/pkg/core.lst" "$HWE_ROOT/pkg/dev.lst" "$HWE_ROOT/pkg/vm.lst" \
            | _pm_translate
        # Some map entries exist only for `need` hints (the VM-host tools) and
        # are in no list, so the translation above never reaches them. Watch
        # every right-hand side the map asserts, not just what the lists name.
        sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$HWE_ROOT/pkg/map/apt.map" \
            | cut -f2- | tr ' ' '\n' | grep -vE '^(-)?$'
    } | sort -u
)
[[ ${#pkgs[@]} -gt 0 ]] || die "translated to an empty package list — the lists or the map are unreadable"
info "${#pkgs[@]} translated package names to resolve"

sim="$(mktemp)"
if _sudo apt-get install -s --no-install-recommends "${pkgs[@]}" >"$sim" 2>&1; then
    # A resolution that installs NOTHING is not a pass — on a clean machine it
    # means the simulation did not do what we think it did. Prove the instrument
    # can answer before believing its answer.
    inst="$(grep -c '^Inst ' "$sim" || true)"
    if [[ "$inst" -eq 0 ]]; then
        err "the simulation resolved but would install nothing"
        info "either everything is already installed (run this in a clean container)"
        info "or the package list never reached apt — the check proved nothing"
        fail=1
    else
        ok "all ${#pkgs[@]} names resolve ($inst packages would be installed)"
    fi
else
    err "the translated package list no longer resolves on this archive"
    grep -E '^(E:|Note, selecting|Package .* has no installation candidate|Unable to locate)' "$sim" \
        | sed 's/^/    /' >&2
    info "a name in pkg/map/apt.map — or an unmapped name that used to match — has moved"
    fail=1
fi
rm -f "$sim"

# --- 2. the packages we deliberately DROP are still absent ----------------
# `-` in the map means "this does not exist here and nothing replaces it". If the
# archive has since gained one, HWE keeps silently withholding software the user
# could have had. That drift has no symptom at all, which is why it is checked.
dropped=()
while IFS=$'\t' read -r from to; do
    [[ -z "$from" || "$from" == \#* ]] && continue
    [[ "$to" == "-" ]] && dropped+=("$from")
done < <(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$HWE_ROOT/pkg/map/apt.map")

appeared=()
for p in "${dropped[@]}"; do
    # apt-cache policy, NOT apt-cache show: show is satisfied by a name that has
    # no installation candidate at all, which is how two entries slipped through
    # the map's first pass. Only a candidate means the package is installable.
    cand="$(apt-cache policy "$p" 2>/dev/null | awk '/Candidate:/ {print $2; exit}')"
    [[ -n "$cand" && "$cand" != "(none)" ]] && appeared+=("$p ($cand)")
done

if [[ ${#appeared[@]} -gt 0 ]]; then
    err "${#appeared[@]} package(s) marked absent in the map are now in the archive:"
    printf '    %s\n' "${appeared[@]}" >&2
    info "drop the '-' and map them, or say in the map why they are still refused"
    fail=1
else
    ok "${#dropped[@]} deliberately-dropped names are still absent"
fi

if [[ $fail -ne 0 ]]; then
    err "pkg/map/apt.map no longer describes this archive"
    exit 1
fi
ok "pkg/map/apt.map still describes this archive"
