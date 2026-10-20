"""Tests for scripts/gen_identifiers.py: aws/identifiers.json to identifiers.tf and connect.yaml."""

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


SMALL_CFN_BLOCK = """\
      DataProtectionPolicy:
        Name: carbonforge-mask-pii
        Version: '2021-06-01'
        Configuration:
          CustomDataIdentifier:
            - Name: 'CarbonForgeShort'
              Regex: '\\d{3}'
            - Name: 'CarbonForgeLongerName'
              Regex: '\\b[A-Z]+\\b'
        Statement:
          - Sid: audit
            DataIdentifier:
              - 'arn:aws:dataprotection::aws:data-identifier/Name'
              - 'arn:aws:dataprotection::aws:data-identifier/EmailAddress'
              - 'CarbonForgeShort'
              - 'CarbonForgeLongerName'
            Operation:
              Audit:
                FindingsDestination:
                  CloudWatchLogs:
                    LogGroup: !Ref FindingsLogGroup
          - Sid: mask
            DataIdentifier:
              - 'arn:aws:dataprotection::aws:data-identifier/Name'
              - 'arn:aws:dataprotection::aws:data-identifier/EmailAddress'
              - 'CarbonForgeShort'
              - 'CarbonForgeLongerName'
            Operation:
              Deidentify:
                MaskConfig: {}
"""

TEMPLATE_BEFORE = "Resources:\n  LogGroup:\n    Properties:\n"
TEMPLATE_AFTER = "      RetentionInDays: 14\n"


def template_with(block: str) -> str:
    """A CloudFormation template whose generated block holds the given text."""
    return f"{TEMPLATE_BEFORE}{gen.CFN_BEGIN}\n{block}{gen.CFN_END}\n{TEMPLATE_AFTER}"


def test_render_cfn_writes_the_data_protection_policy_block() -> None:
    """The CloudFormation block is the masking policy the Terraform module builds, in YAML."""
    assert gen.render_cfn(SMALL) == SMALL_CFN_BLOCK


def test_render_cfn_quotes_regexes_for_yaml() -> None:
    """Single-quoted YAML keeps backslashes as is; a single quote is doubled."""
    block = gen.render_cfn({"managed": [], "custom": {"Odd": "a'b\\c"}})
    assert "Regex: 'a''b\\c'" in block


def test_render_cfn_rejects_what_render_rejects() -> None:
    """Both outputs share the same input checks."""
    with pytest.raises(ValueError, match="at most 10"):
        gen.render_cfn({"managed": [], "custom": {f"Custom{i}": "x" for i in range(11)}})


def test_splice_cfn_replaces_only_the_generated_block() -> None:
    """Everything outside the markers is kept byte for byte."""
    assert gen.splice_cfn(template_with("old\n"), SMALL_CFN_BLOCK) == template_with(SMALL_CFN_BLOCK)


def test_splice_cfn_rejects_a_template_without_markers() -> None:
    """Without both markers there is nowhere safe to write."""
    with pytest.raises(ValueError, match="markers"):
        gen.splice_cfn(TEMPLATE_BEFORE + TEMPLATE_AFTER, SMALL_CFN_BLOCK)


def write_targets(directory: Path, tf: str, cfn: str) -> tuple[Path, Path]:
    """Write the two generated files with the given content and return their paths."""
    tf_path, cfn_path = directory / "identifiers.tf", directory / "connect.yaml"
    tf_path.write_text(tf, encoding="utf-8")
    cfn_path.write_text(cfn, encoding="utf-8")
    return tf_path, cfn_path


def run_on(source: Path, tf: Path, cfn: Path, *extra: str) -> subprocess.CompletedProcess[str]:
    """Run the generator on the given files instead of the repository's."""
    return run_cli(
        *extra, "--source", str(source), "--tf-target", str(tf), "--cfn-target", str(cfn)
    )


def test_write_mode_generates_both_files(tmp_path: Path) -> None:
    """Without --check the generator writes identifiers.tf and the template's block."""
    source = write_source(tmp_path, SMALL)
    tf, cfn = write_targets(tmp_path, "stale\n", template_with("old\n"))
    result = run_on(source, tf, cfn)
    assert result.returncode == 0, result.stderr
    assert tf.read_text(encoding="utf-8") == gen.render(SMALL)
    assert cfn.read_text(encoding="utf-8") == template_with(SMALL_CFN_BLOCK)


def test_check_passes_when_both_files_are_in_sync(tmp_path: Path) -> None:
    """--check exits 0 and changes nothing when both files match the JSON."""
    source = write_source(tmp_path, SMALL)
    tf, cfn = write_targets(tmp_path, gen.render(SMALL), template_with(SMALL_CFN_BLOCK))
    result = run_on(source, tf, cfn, "--check")
    assert result.returncode == 0, result.stderr
    assert tf.read_text(encoding="utf-8") == gen.render(SMALL)
    assert cfn.read_text(encoding="utf-8") == template_with(SMALL_CFN_BLOCK)


def test_check_fails_and_changes_nothing_when_the_terraform_file_is_out_of_date(
    tmp_path: Path,
) -> None:
    """--check exits 1, says how to fix it, and leaves the stale file in place."""
    source = write_source(tmp_path, SMALL)
    tf, cfn = write_targets(tmp_path, "stale\n", template_with(SMALL_CFN_BLOCK))
    result = run_on(source, tf, cfn, "--check")
    assert result.returncode == 1
    assert "identifiers.tf is out of date" in result.stderr
    assert tf.read_text(encoding="utf-8") == "stale\n"


def test_check_fails_and_changes_nothing_when_the_template_is_out_of_date(
    tmp_path: Path,
) -> None:
    """A stale CloudFormation block fails --check like a stale identifiers.tf."""
    source = write_source(tmp_path, SMALL)
    tf, cfn = write_targets(tmp_path, gen.render(SMALL), template_with("old\n"))
    result = run_on(source, tf, cfn, "--check")
    assert result.returncode == 1
    assert "connect.yaml is out of date" in result.stderr
    assert cfn.read_text(encoding="utf-8") == template_with("old\n")


def test_check_fails_when_the_template_has_no_markers(tmp_path: Path) -> None:
    """A template that lost its markers fails --check with the reason."""
    source = write_source(tmp_path, SMALL)
    tf, cfn = write_targets(tmp_path, gen.render(SMALL), TEMPLATE_BEFORE)
    result = run_on(source, tf, cfn, "--check")
    assert result.returncode == 1
    assert "markers" in result.stderr


def test_check_fails_when_the_terraform_file_is_missing(tmp_path: Path) -> None:
    """A missing file is out of date, not a crash."""
    source = write_source(tmp_path, SMALL)
    _, cfn = write_targets(tmp_path, "", template_with(SMALL_CFN_BLOCK))
    result = run_on(source, tmp_path / "none.tf", cfn, "--check")
    assert result.returncode == 1
    assert "out of date" in result.stderr
