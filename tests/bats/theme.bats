#!/usr/bin/env bats
# lib/theme.sh — `hwe theme` list / validate / current.
#
# apply and pick are deliberately absent: they symlink into ~/.config, restart
# waybar and reload the compositor. Those belong in the VM, not in a test run.
# What is pinned here is everything that reads or reports — including the
# validate gate, which is the thing standing between a broken theme and a
# desktop rendered in the loud placeholder colour.

bats_require_minimum_version 1.5.0

setup() {
    load 'helper'
    hwe_setup
    # Point the module at scratch theme roots so tests never touch themes/.current
    # — and never see the themes of whoever is running them.
    export HWE_THEMES="$BATS_TEST_TMPDIR/themes"
    export HWE_THEMES_USER="$BATS_TEST_TMPDIR/user-themes"
    export HWE_TEMPLATES="$HWE_ROOT/templates"
    mkdir -p "$HWE_THEMES" "$HWE_THEMES_USER"
}

# Source theme.sh with the module's environment in place.
load_theme_lib() {
    source "$HWE_ROOT/lib/common.sh"
    source "$HWE_ROOT/lib/theme.sh"
}

# Copy a real shipped theme into a scratch root ($2: shipped [default] | user).
fixture_theme() {
    local name="$1" root="${2:-shipped}" dir
    [[ "$root" == user ]] && dir="$HWE_THEMES_USER/$name" || dir="$HWE_THEMES/$name"
    mkdir -p "$dir"
    cp "$HWE_ROOT/themes/default/theme.toml" "$dir/theme.toml"
    printf '%s\n' "$dir"
}

# --- theme_names / list ----------------------------------------------------

@test "theme_names lists directories that hold a theme.toml" {
    fixture_theme alpha
    fixture_theme beta
    run bash -c "
        export HWE_ROOT='$HWE_ROOT' HWE_THEMES='$HWE_THEMES'
        source '$HWE_ROOT/lib/common.sh'; source '$HWE_ROOT/lib/theme.sh'
        theme_names
    "
    assert_success
    assert_line "alpha"
    assert_line "beta"
}

@test "theme_names ignores a directory without a theme.toml" {
    fixture_theme alpha
    mkdir -p "$HWE_THEMES/not-a-theme"
    run bash -c "
        export HWE_ROOT='$HWE_ROOT' HWE_THEMES='$HWE_THEMES'
        source '$HWE_ROOT/lib/common.sh'; source '$HWE_ROOT/lib/theme.sh'
        theme_names
    "
    assert_success
    refute_line "not-a-theme"
}

@test "theme list marks the current theme" {
    fixture_theme alpha
    fixture_theme beta
    echo beta > "$HWE_THEMES/.current"
    run --separate-stderr bash -c "
        export HWE_ROOT='$HWE_ROOT' HWE_THEMES='$HWE_THEMES' NO_COLOR=1
        source '$HWE_ROOT/lib/common.sh'; source '$HWE_ROOT/lib/theme.sh'
        theme_list
    "
    assert_success
    [[ "$stderr" == *"beta *"* ]]
    [[ "$stderr" != *"alpha *"* ]]
}

# --- the two theme roots ---------------------------------------------------
# Themes you write live outside the repo, so `git pull` never collides with them
# and `git status` never shows them. Same anatomy, resolved through both roots.

@test "theme_names lists a theme of your own alongside the shipped ones" {
    fixture_theme shipped-one
    fixture_theme mine user
    run bash -c "
        source '$HWE_ROOT/lib/common.sh'; source '$HWE_ROOT/lib/theme.sh'
        theme_names
    "
    assert_success
    assert_line "shipped-one"
    assert_line "mine"
}

@test "a theme of your own shadows a shipped one of the same name" {
    fixture_theme frost
    fixture_theme frost user
    run bash -c "
        source '$HWE_ROOT/lib/common.sh'
        _theme_dir frost
    "
    assert_success
    assert_output "$HWE_THEMES_USER/frost"
}

@test "a shadowed name is listed once, not twice" {
    fixture_theme frost
    fixture_theme frost user
    run bash -c "
        source '$HWE_ROOT/lib/common.sh'; source '$HWE_ROOT/lib/theme.sh'
        theme_names
    "
    assert_success
    [ "$(grep -c '^frost$' <<< "$output")" -eq 1 ]
}

@test "theme list marks which themes are yours" {
    fixture_theme shipped-one
    fixture_theme mine user
    run --separate-stderr bash -c "
        export NO_COLOR=1
        source '$HWE_ROOT/lib/common.sh'; source '$HWE_ROOT/lib/theme.sh'
        theme_list
    "
    assert_success
    [[ "$stderr" == *"mine (yours)"* ]]
    [[ "$stderr" != *"shipped-one (yours)"* ]]
}

@test "validate resolves a theme that lives in the user root" {
    fixture_theme mine user
    run bash -c "
        source '$HWE_ROOT/lib/common.sh'; source '$HWE_ROOT/lib/theme.sh'
        theme_main validate mine
    "
    assert_success
}

@test "_theme_dir returns nothing for a theme in neither root" {
    run bash -c "
        source '$HWE_ROOT/lib/common.sh'
        _theme_dir no-such-theme
    "
    assert_failure
    assert_output ""
}

@test "a directory without a theme.toml is not a theme in either root" {
    mkdir -p "$HWE_THEMES_USER/not-a-theme"
    run bash -c "
        source '$HWE_ROOT/lib/common.sh'
        _theme_dir not-a-theme
    "
    assert_failure
}

# --- theme names address a directory, so they must be one ------------------
# A name reaches us from a config file and (once themes are shareable) from
# strangers. It is concatenated into a path and handed to commands as an
# argument, so the shapes below are refused before either happens.

@test "a theme name cannot escape the theme roots" {
    for name in "../../etc" "foo/bar" "/etc/passwd" ".." "."; do
        run bash -c "
            source '$HWE_ROOT/lib/common.sh'
            _theme_dir '$name'
        "
        assert_failure
        assert_output ""
    done
}

@test "a theme name cannot start with a dash or a dot" {
    # A leading dash reads as an option to the commands we hand it to; a leading
    # dot addresses the roots' own state (.current).
    for name in "-rf" "--theme" ".current" ".hidden"; do
        run bash -c "
            source '$HWE_ROOT/lib/common.sh'
            _theme_dir '$name'
        "
        assert_failure
    done
}

@test "validate names a malformed theme name as invalid rather than missing" {
    run --separate-stderr bash -c "
        source '$HWE_ROOT/lib/common.sh'; source '$HWE_ROOT/lib/theme.sh'
        theme_main validate '../../etc'
    "
    assert_failure
    [[ "$stderr" == *"invalid theme name"* ]]
}

@test "theme_names never offers a name _theme_dir would refuse" {
    # Otherwise a picker hands a listed name straight back and gets a failure —
    # under `set -e` in bin/hwe, that ends the command.
    fixture_theme good-theme
    mkdir -p "$HWE_THEMES/-rf"
    cp "$HWE_ROOT/themes/default/theme.toml" "$HWE_THEMES/-rf/theme.toml"
    run bash -c "
        source '$HWE_ROOT/lib/common.sh'; source '$HWE_ROOT/lib/theme.sh'
        while IFS= read -r n; do _theme_dir \"\$n\" >/dev/null || { echo \"unresolvable: \$n\"; exit 1; }; done < <(theme_names)
    "
    assert_success
    refute_output --partial "unresolvable"
}

@test "an ordinary theme name is accepted" {
    for name in "frost" "my-theme" "my_theme" "theme.2" "a" "Frost9"; do
        run bash -c "source '$HWE_ROOT/lib/common.sh'; _theme_name_ok '$name'"
        assert_success
    done
}

# --- current ---------------------------------------------------------------

@test "theme current prints the current theme" {
    echo mocha > "$HWE_THEMES/.current"
    run bash -c "
        export HWE_ROOT='$HWE_ROOT' HWE_THEMES='$HWE_THEMES'
        source '$HWE_ROOT/lib/common.sh'; source '$HWE_ROOT/lib/theme.sh'
        theme_main current
    "
    assert_success
    assert_output "mocha"
}

@test "theme current reports none when nothing is applied" {
    run bash -c "
        export HWE_ROOT='$HWE_ROOT' HWE_THEMES='$HWE_THEMES'
        source '$HWE_ROOT/lib/common.sh'; source '$HWE_ROOT/lib/theme.sh'
        theme_main current
    "
    assert_success
    assert_output "(none)"
}

# --- validate --------------------------------------------------------------

@test "validate accepts every shipped theme" {
    # Deliberately WITHOUT the scratch HWE_THEMES from setup: this one test is
    # about the real themes/ tree, so theme.sh must fall back to its default.
    for dir in "$HWE_ROOT"/themes/*/; do
        [ -f "$dir/theme.toml" ] || continue
        run env -u HWE_THEMES bash -c "
            export HWE_ROOT='$HWE_ROOT'
            source '$HWE_ROOT/lib/common.sh'; source '$HWE_ROOT/lib/theme.sh'
            theme_main validate '$(basename "$dir")'
        "
        assert_success
    done
}

@test "validate rejects a theme missing a role" {
    mkdir -p "$HWE_THEMES/broken"
    cat > "$HWE_THEMES/broken/theme.toml" <<'EOF'
name = "broken"
[sem]
bg_dark = "#000000"
EOF
    run bash -c "
        export HWE_ROOT='$HWE_ROOT' HWE_THEMES='$HWE_THEMES' HWE_TEMPLATES='$HWE_TEMPLATES'
        source '$HWE_ROOT/lib/common.sh'; source '$HWE_ROOT/lib/theme.sh'
        theme_main validate broken
    "
    assert_failure
}

@test "validate names an unknown theme rather than guessing" {
    run --separate-stderr bash -c "
        export HWE_ROOT='$HWE_ROOT' HWE_THEMES='$HWE_THEMES'
        source '$HWE_ROOT/lib/common.sh'; source '$HWE_ROOT/lib/theme.sh'
        theme_main validate no-such-theme
    "
    assert_failure
    [[ "$stderr" == *"no-such-theme"* ]]
}

@test "validate without a name asks for one" {
    run --separate-stderr bash -c "
        export HWE_ROOT='$HWE_ROOT' HWE_THEMES='$HWE_THEMES'
        source '$HWE_ROOT/lib/common.sh'; source '$HWE_ROOT/lib/theme.sh'
        theme_main validate
    "
    assert_failure
    [[ "$stderr" == *"no theme name"* ]]
}

# --- dispatch --------------------------------------------------------------

@test "theme with no action shows usage" {
    run --separate-stderr bash -c "
        export HWE_ROOT='$HWE_ROOT' HWE_THEMES='$HWE_THEMES'
        source '$HWE_ROOT/lib/common.sh'; source '$HWE_ROOT/lib/theme.sh'
        theme_main
    "
    assert_success
    [[ "$stderr" == *"Usage:"* ]]
}

@test "an unknown theme action fails and says which" {
    run --separate-stderr bash -c "
        export HWE_ROOT='$HWE_ROOT' HWE_THEMES='$HWE_THEMES'
        source '$HWE_ROOT/lib/common.sh'; source '$HWE_ROOT/lib/theme.sh'
        theme_main frobnicate
    "
    assert_failure
    [[ "$stderr" == *"unknown theme action: frobnicate"* ]]
}

@test "the documented action aliases dispatch" {
    # list|ls, apply|set, validate|check, sddm|greeter — pinned so an alias
    # cannot quietly disappear.
    for pair in "list|ls" "apply|set" "validate|check" "sddm|greeter"; do
        run bash -c "grep -qE '^\s+${pair}\)' '$HWE_ROOT/lib/theme.sh'"
        assert_success
    done
}
