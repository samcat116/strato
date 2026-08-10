#!/usr/bin/env python3
"""Check browser/control-plane route parity across deployment front doors."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
ROUTE_MANIFEST = (
    REPOSITORY_ROOT
    / "control-plane/web/src/lib/control-plane-route-prefixes.json"
)
COMPOSE_NGINX = REPOSITORY_ROOT / "deploy/compose/nginx.conf"


def fail_if_different(name: str, actual: set[str], expected: set[str]) -> None:
    if actual == expected:
        return

    missing = sorted(expected - actual)
    extra = sorted(actual - expected)
    details = []
    if missing:
        details.append(f"missing {missing}")
    if extra:
        details.append(f"unexpected {extra}")
    raise AssertionError(f"{name} route prefixes differ: {', '.join(details)}")


def gateway_prefixes(rendered: str) -> set[str]:
    documents = re.split(r"\n---\s*\n", rendered)
    http_routes = [
        document
        for document in documents
        if re.search(r"^kind:\s+HTTPRoute\s*$", document, re.MULTILINE)
    ]
    if len(http_routes) != 1:
        raise AssertionError(
            f"expected one rendered HTTPRoute, found {len(http_routes)}"
        )

    prefixes = set(
        re.findall(
            r"type:\s+PathPrefix\s*\n\s*value:\s+([^\s#]+)",
            http_routes[0],
        )
    )
    prefixes.discard("/")  # The frontend catch-all is not a control-plane route.
    return prefixes


def nginx_prefixes(configuration: str) -> set[str]:
    prefixes: set[str] = set()
    for match in re.finditer(
        r"location\s+(?:=\s+)?(/[^\s{]+)\s*\{([^{}]*)\}",
        configuration,
        re.DOTALL,
    ):
        path, body = match.groups()
        if re.search(r"proxy_pass\s+\$control_plane\s*;", body):
            prefixes.add(path.rstrip("/") or "/")
    return prefixes


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {Path(sys.argv[0]).name} RENDERED_GATEWAY_YAML")

    prefixes = json.loads(ROUTE_MANIFEST.read_text())
    if not isinstance(prefixes, list) or not all(
        isinstance(prefix, str) and re.fullmatch(r"/[a-z]+", prefix)
        for prefix in prefixes
    ):
        raise AssertionError(
            "route manifest must be a JSON array of simple path prefixes"
        )
    if len(prefixes) != len(set(prefixes)):
        raise AssertionError("route manifest contains duplicate prefixes")

    expected = set(prefixes)
    rendered_gateway = Path(sys.argv[1]).read_text()
    fail_if_different("Gateway", gateway_prefixes(rendered_gateway), expected)
    fail_if_different(
        "Compose nginx", nginx_prefixes(COMPOSE_NGINX.read_text()), expected
    )
    print(f"route parity verified for {len(prefixes)} control-plane prefixes")


if __name__ == "__main__":
    main()
