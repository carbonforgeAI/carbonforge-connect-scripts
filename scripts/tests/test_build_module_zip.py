"""scripts/build_module_zip.sh: the published Terraform module zip is reproducible and complete."""

from __future__ import annotations

import hashlib
import os
import re
import subprocess
import zipfile
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "build_module_zip.sh"
EXCLUDED = ("tests/", "examples/", ".gitignore")


def module_files(commit: str) -> set[str]:
    """The commit's tracked files under aws/terraform that the published zip must hold."""
    listed = subprocess.run(
        ["git", "ls-tree", "-r", "--name-only", f"{commit}:aws/terraform"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=True,
    ).stdout.split()
    return {f for f in listed if not f.startswith(EXCLUDED)}


def build(out: Path, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    """Run the build script on HEAD into ``out``."""
    return subprocess.run(
        ["sh", str(SCRIPT), "HEAD", str(out)],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )


def git_has_archive_mtime() -> bool:
    """Whether this git's ``git archive`` has ``--mtime`` (2.40 or later)."""
    found = re.search(
        r"(\d+)\.(\d+)",
        subprocess.run(["git", "--version"], capture_output=True, text=True, check=True).stdout,
    )
    return found is not None and (int(found[1]), int(found[2])) >= (2, 40)


@pytest.mark.skipif(not git_has_archive_mtime(), reason="needs git 2.40+ (git archive --mtime)")
def test_two_builds_are_identical_with_the_module_at_the_root(tmp_path: Path) -> None:
    first, second = tmp_path / "a.zip", tmp_path / "b.zip"
    for out, tz in ((first, "UTC"), (second, "Asia/Tokyo")):
        run = build(out, {**os.environ, "TZ": tz})
        assert run.returncode == 0, run.stderr
    assert (
        hashlib.sha256(first.read_bytes()).digest() == hashlib.sha256(second.read_bytes()).digest()
    )
    files = {n for n in zipfile.ZipFile(first).namelist() if not n.endswith("/")}
    assert files == module_files("HEAD")
    assert {"main.tf", "variables.tf", "scripts/existing_logging.sh"} <= files


def test_an_old_git_is_refused_with_a_clear_message(tmp_path: Path) -> None:
    fake = tmp_path / "bin"
    fake.mkdir()
    (fake / "git").write_text("#!/bin/sh\necho 'git version 2.34.1'\n")
    (fake / "git").chmod(0o755)
    env = {**os.environ, "PATH": f"{fake}:{os.environ['PATH']}"}
    run = build(tmp_path / "out.zip", env)
    assert run.returncode == 2
    assert "git 2.40" in run.stderr
    assert not (tmp_path / "out.zip").exists()
