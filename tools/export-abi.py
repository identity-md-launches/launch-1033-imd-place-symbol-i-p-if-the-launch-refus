#!/usr/bin/env python3
"""Export locally compiled ABIs; needs only Python's standard library."""
import json
import os
from pathlib import Path

root = Path(__file__).resolve().parent.parent
names = ["PlaceHook", "Canvas", "Seasons", "PlaceRouter", "PlaceToken", "CustomRevert"]
build_out = Path(os.environ.get("IMD_FORGE_OUT", root / "out"))
abis = {name: json.loads((build_out / f"{name}.sol" / f"{name}.json").read_text())["abi"] for name in names}
(root / "site" / "abi.json").write_text(json.dumps(abis, separators=(",", ":")) + "\n")
print("Exported five contract ABIs and the v4 error wrapper to site/abi.json")
