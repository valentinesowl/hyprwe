#!/usr/bin/env bash
# Shared setup for the bats suites.

hwe_setup() {
    # tests/bats/helper.bash -> repo root
    HWE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    export HWE_ROOT
    PATH="$HWE_ROOT/bin:$PATH"
    export PATH

    # bats-assert/bats-support ship as pacman packages (pkg/dev.lst) and land in
    # /usr/lib/bats/; other distros and manual checkouts differ, so probe the
    # usual roots (and $BATS_LIB_PATH, which bats itself defines) rather than
    # hardcoding one. Order matters only in that the first hit wins.
    local base
    for base in ${BATS_LIB_PATH//:/ } /usr/lib/bats /usr/local/lib/bats /usr/lib /usr/local/lib; do
        if [[ -f "$base/bats-support/load.bash" && -f "$base/bats-assert/load.bash" ]]; then
            load "$base/bats-support/load.bash"
            load "$base/bats-assert/load.bash"
            return 0
        fi
    done
    echo "bats-support/bats-assert not found — install them (pkg/dev.lst)" >&2
    return 1
}

# Sourcing common.sh needs HWE_ROOT set; assert that up front so a broken
# environment reads as such rather than as a failing assertion downstream.
source_common() {
    [[ -n "${HWE_ROOT:-}" ]] || {
        echo "HWE_ROOT unset" >&2
        return 1
    }
}

# Assert a string carries no ANSI escapes.
refute_output_contains_escape() {
    local text="$1"
    if [[ "$text" == *$'\e['* ]]; then
        echo "expected no ANSI escapes, got: $(printf '%q' "$text")" >&2
        return 1
    fi
}
