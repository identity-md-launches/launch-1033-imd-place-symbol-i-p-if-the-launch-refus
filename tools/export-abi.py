#!/usr/bin/env python3
"""Export locally compiled ABIs; needs only Python's standard library."""
import json
from pathlib import Path

root = Path(__file__).resolve().parent.parent
names = ["PlaceHook", "Canvas", "Seasons", "PlaceRouter", "PlaceToken"]
abis = {name: json.loads((root / "out" / f"{name}.sol" / f"{name}.json").read_text())["abi"] for name in names}
(root / "site" / "abi.json").write_text(json.dumps(abis, separators=(",", ":")) + "\n")
print("Exported five contract ABIs to site/abi.json")
