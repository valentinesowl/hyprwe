"""Tests for scripts/fontlock.py --verify — the CI watchdog over the one artifact
HWE fetches without a distribution signature behind it.

The watchdog's whole job is to notice when a pinned, published artifact changes.
Two ways it used to fail quietly: parsing an archive whose hash already failed,
and reporting success after a run that compared nothing because every fetch died.
"""

import io
import lzma
import tarfile
import urllib.error


def _make_tar_xz(member: str, content: bytes) -> bytes:
    """A real .tar.xz holding one file, so extract() has something to open."""
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w") as tf:
        info = tarfile.TarInfo(f"./{member}")
        info.size = len(content)
        tf.addfile(info, io.BytesIO(content))
    return lzma.compress(raw.getvalue())


def _lock(fontlock, archive: bytes, member: str, content: bytes, *, break_archive=False):
    a = fontlock.sha256(archive)
    f = fontlock.sha256(content)
    if break_archive:
        a = "0" * 64
    return {
        "symbols": {
            "url": "https://example.invalid/fonts.tar.xz",
            "archive_sha256": a,
            "member": member,
            "file_sha256": f,
        }
    }


def test_verify_passes_when_the_pin_matches(fontlock, monkeypatch):
    member, content = "Glyphs.ttf", b"pretend font bytes"
    archive = _make_tar_xz(member, content)
    monkeypatch.setattr(fontlock, "read_lock", lambda: _lock(fontlock, archive, member, content))
    monkeypatch.setattr(fontlock, "fetch", lambda url: archive)
    assert fontlock.verify() == 0


def test_verify_does_not_parse_an_archive_whose_hash_failed(fontlock, monkeypatch):
    """A hash mismatch is the finding; the rejected bytes must not reach the xz
    parser. The fetched bytes here are not a valid tar.xz at all, so if verify
    tried to extract them it would raise instead of returning a clean 1."""
    member, content = "Glyphs.ttf", b"pretend font bytes"
    archive = _make_tar_xz(member, content)
    lock = _lock(fontlock, archive, member, content, break_archive=True)
    monkeypatch.setattr(fontlock, "read_lock", lambda: lock)
    monkeypatch.setattr(fontlock, "fetch", lambda url: b"definitely not a tar.xz stream")
    assert fontlock.verify() == 1


def test_verify_is_inconclusive_when_nothing_could_be_fetched(fontlock, monkeypatch):
    """Every fetch dies → the watchdog compared nothing. That must be a distinct
    non-zero (2), not the 0 that used to slip by unnoticed."""
    member, content = "Glyphs.ttf", b"pretend font bytes"
    archive = _make_tar_xz(member, content)
    monkeypatch.setattr(fontlock, "read_lock", lambda: _lock(fontlock, archive, member, content))

    def _boom(url):
        raise urllib.error.URLError("network down")

    monkeypatch.setattr(fontlock, "fetch", _boom)
    assert fontlock.verify() == 2
