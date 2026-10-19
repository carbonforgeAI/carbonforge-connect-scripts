"""Generate aws/terraform/identifiers.tf from aws/identifiers.json."""

import sys


def render(identifiers: dict[str, object]) -> str:
    """Return the content of identifiers.tf for the given identifiers."""
    raise NotImplementedError


def main(argv: list[str] | None = None) -> int:
    """Write identifiers.tf, or with --check report whether it is up to date."""
    raise NotImplementedError


if __name__ == "__main__":
    sys.exit(main())
