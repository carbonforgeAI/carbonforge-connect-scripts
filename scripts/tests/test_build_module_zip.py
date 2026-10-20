"""scripts/build_module_zip.sh: the published Terraform module zip is reproducible and complete."""

from __future__ import annotations

import hashlib
import os
import subprocess
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "build_module_zip.sh"
ENTRIES = {
    "README.md", "identifiers.tf", "main.tf", "outputs.tf", "scripts/",
    "scripts/existing_logging.sh", "variables.tf", "versions.tf",
}


def build(out: Path, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    """Run the build script on HEAD into ``out``."""
    return subprocess.run(["sh", str(SCRIPT), "HEAD", str(out)], cwd=ROOT, env=env,
                          capture_output=True, text=True)


def test_two_builds_of_one_commit_are_identical_and_hold_the_module_at_the_root(tmp_path: Path) -> None:
    first, second = tmp_path / "a.zip", tmp_path / "b.zip"
    for out in (first, second):
        run = build(out)
        assert run.returncode == 0, run.stderr
    assert hashlib.sha256(first.read_bytes()).digest() == hashlib.sha256(second.read_bytes()).digest()
    assert set(zipfile.ZipFile(first).namelist()) == ENTRIES


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
