"""Tests for scripts/gen_identifiers.py: aws/identifiers.json to aws/terraform/identifiers.tf."""

import importlib.util
import json
import subprocess
import sys
from pathlib import Path
from types import ModuleType

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "gen_identifiers.py"


def load_generator() -> ModuleType:
    """Import the generator script as a module (scripts/ is not a package)."""
    spec = importlib.util.spec_from_file_location("gen_identifiers", SCRIPT)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


gen = load_generator()

SMALL: dict[str, object] = {
    "managed": ["Name", "EmailAddress"],
    "custom": {"CarbonForgeShort": r"\d{3}", "CarbonForgeLongerName": r"\b[A-Z]+\b"},
}

SMALL_BODY = """locals {
  managed_data_identifiers = [
    "Name",
    "EmailAddress",
  ]

  # AWS allows at most 10 custom data identifiers per policy.
  custom_data_identifiers = {
    CarbonForgeShort      = "\\\\d{3}"
    CarbonForgeLongerName = "\\\\b[A-Z]+\\\\b"
  }
}
"""


def run_cli(*args: str) -> subprocess.CompletedProcess[str]:
    """Run the generator as CI does, from the command line."""
    return subprocess.run(
        [sys.executable, str(SCRIPT), *args], capture_output=True, text=True, check=False
    )


def write_source(directory: Path, identifiers: dict[str, object]) -> Path:
    """Write an identifiers JSON file and return its path."""
    path = directory / "identifiers.json"
    path.write_text(json.dumps(identifiers), encoding="utf-8")
    return path


def test_render_writes_header_managed_list_and_aligned_custom_map() -> None:
    """The output is the generated-file header, then the locals block terraform fmt keeps as is."""
    rendered = gen.render(SMALL)
    assert rendered.startswith(
        "# Generated from aws/identifiers.json by scripts/gen_identifiers.py."
    )
    assert rendered.endswith("\n\n" + SMALL_BODY)


def test_render_keeps_the_source_order() -> None:
    """Order is kept: it is the order of the identifiers in the masking policy."""
    rendered = gen.render({"managed": ["Zed", "Alpha"], "custom": {"Zz": "z", "Aa": "a"}})
    assert rendered.index('"Zed"') < rendered.index('"Alpha"')
    assert rendered.index("Zz ") < rendered.index("Aa ")


def test_render_escapes_quotes_backslashes_and_template_sequences() -> None:
    """A regex reaches AWS character for character, so HCL escapes and interpolation are neutralised."""
    rendered = gen.render({"managed": [], "custom": {"Odd": 'a"b\\c${d}%{e}'}})
    assert 'Odd = "a\\"b\\\\c$${d}%%{e}"' in rendered


def test_render_rejects_more_than_ten_custom_identifiers() -> None:
    """AWS refuses a policy with more than 10 custom identifiers, so the generator does too."""
    custom = {f"Custom{i}": "x" for i in range(11)}
    with pytest.raises(ValueError, match="at most 10"):
        gen.render({"managed": [], "custom": custom})


def test_render_rejects_a_custom_name_that_is_not_a_plain_identifier() -> None:
    """Custom names become unquoted HCL keys and AWS identifier names."""
    with pytest.raises(ValueError, match="bad name"):
        gen.render({"managed": [], "custom": {"bad name": "x"}})


def test_write_mode_generates_the_terraform_file(tmp_path: Path) -> None:
    """Without --check the generator writes the Terraform file."""
    source = write_source(tmp_path, SMALL)
    target = tmp_path / "identifiers.tf"
    result = run_cli("--source", str(source), "--target", str(target))
    assert result.returncode == 0, result.stderr
    assert target.read_text(encoding="utf-8") == gen.render(SMALL)


def test_check_passes_when_the_terraform_file_is_in_sync(tmp_path: Path) -> None:
    """--check exits 0 and changes nothing when the file matches the JSON."""
    source = write_source(tmp_path, SMALL)
    target = tmp_path / "identifiers.tf"
    target.write_text(gen.render(SMALL), encoding="utf-8")
    result = run_cli("--check", "--source", str(source), "--target", str(target))
    assert result.returncode == 0, result.stderr
    assert target.read_text(encoding="utf-8") == gen.render(SMALL)


def test_check_fails_and_changes_nothing_when_the_terraform_file_is_out_of_date(
    tmp_path: Path,
) -> None:
    """--check exits 1, says how to fix it, and leaves the stale file in place."""
    source = write_source(tmp_path, SMALL)
    target = tmp_path / "identifiers.tf"
    target.write_text("stale\n", encoding="utf-8")
    result = run_cli("--check", "--source", str(source), "--target", str(target))
    assert result.returncode == 1
    assert "out of date" in result.stderr
    assert target.read_text(encoding="utf-8") == "stale\n"


def test_check_fails_when_the_terraform_file_is_missing(tmp_path: Path) -> None:
    """A missing file is out of date, not a crash."""
    source = write_source(tmp_path, SMALL)
    result = run_cli("--check", "--source", str(source), "--target", str(tmp_path / "none.tf"))
    assert result.returncode == 1
    assert "out of date" in result.stderr
