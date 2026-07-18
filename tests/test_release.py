"""Release consistency — the version must mean the same thing everywhere.

Three places claim the version: `HWE_VERSION` in bin/hwe, the newest CHANGELOG
heading, and the git tag a release is cut from. Nothing forces them to agree, and
the failure is quiet: `hwe version` reports one number while the release page
shows another, and nobody notices until a user pastes the wrong one into a bug
report. These tests make the disagreement loud instead. The tag half of it is
enforced by .github/workflows/release.yml, which refuses to publish a mismatch.
"""
import re

import pytest

SEMVER = re.compile(r"^\d+\.\d+\.\d+$")


@pytest.fixture(scope="session")
def declared_version(repo) -> str:
    text = (repo / "bin" / "hwe").read_text()
    match = re.search(r'^HWE_VERSION="([^"]+)"', text, re.MULTILINE)
    assert match, "could not find HWE_VERSION in bin/hwe"
    return match.group(1)


@pytest.fixture(scope="session")
def changelog(repo) -> str:
    return (repo / "CHANGELOG.md").read_text()


def released_versions(changelog: str) -> list[str]:
    """Versions from the `## [x.y.z] — date` headings, newest first."""
    return re.findall(r"^## \[(\d+\.\d+\.\d+)\]", changelog, re.MULTILINE)


def test_the_declared_version_is_semver(declared_version):
    assert SEMVER.match(declared_version), f"HWE_VERSION={declared_version!r} is not x.y.z"


def test_the_changelog_has_a_release(changelog):
    assert released_versions(changelog), "CHANGELOG.md documents no released version"


def test_the_declared_version_matches_the_newest_changelog_entry(declared_version, changelog):
    newest = released_versions(changelog)[0]
    assert declared_version == newest, (
        f"bin/hwe says {declared_version}, but the newest CHANGELOG entry is {newest} — "
        "bump both, or move the entry"
    )


def test_changelog_versions_descend(changelog):
    """A release inserted in the wrong place makes 'newest' above a lie."""
    versions = [tuple(int(p) for p in v.split(".")) for v in released_versions(changelog)]
    assert versions == sorted(versions, reverse=True), (
        f"CHANGELOG entries are out of order: {released_versions(changelog)}"
    )


def test_no_version_is_documented_twice(changelog):
    versions = released_versions(changelog)
    assert len(versions) == len(set(versions)), f"duplicate CHANGELOG entry: {versions}"


def test_every_release_heading_carries_a_date(changelog):
    """`## [1.0.0]` with no date is an entry someone forgot to finish."""
    for line in changelog.splitlines():
        if re.match(r"^## \[\d+\.\d+\.\d+\]", line):
            assert re.match(r"^## \[\d+\.\d+\.\d+\] — \d{4}-\d{2}-\d{2}$", line), (
                f"release heading has no ISO date: {line!r}"
            )


def test_the_changelog_keeps_an_unreleased_section(changelog):
    """Where the next change gets written down — its absence is how changelogs die."""
    assert re.search(r"^## \[Unreleased\]", changelog, re.MULTILINE), (
        "CHANGELOG.md has no [Unreleased] section"
    )


def test_the_cli_reports_the_declared_version(repo, declared_version):
    """The number a user actually pastes into a bug report."""
    import subprocess

    out = subprocess.run(
        [str(repo / "bin" / "hwe"), "version"], capture_output=True, text=True, check=True
    ).stdout.strip()
    assert out == f"hwe {declared_version}"
