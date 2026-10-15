#!/usr/bin/env python3
"""Copy deterministic, public frontend assets into the signed iOS application.

No server sources, environment files, credentials, user files or browser storage
are included. Run after editing frontend and before building the Xcode project.
"""
import hashlib
import json
import shutil
from pathlib import Path

root = Path(__file__).resolve().parents[2]
source = root / "frontend"
destination = root / "ios" / "AVELI" / "WebApp"
allowed = {".html", ".css", ".js", ".json", ".webmanifest", ".png", ".svg", ".jpg", ".jpeg", ".webp", ".ico", ".woff2"}
assets = sorted(path for path in source.iterdir() if path.is_file() and not path.is_symlink() and path.suffix.lower() in allowed)
if not (source / "index.html").is_file() or not assets:
    raise SystemExit("The AVELI frontend is missing.")
if destination.exists():
    shutil.rmtree(destination)
destination.mkdir(parents=True)
manifest = {}
for asset in assets:
    content = asset.read_bytes()
    if len(content) > 8 * 1024 * 1024:
        raise SystemExit(f"Bundled asset exceeds the local server limit: {asset.name}")
    (destination / asset.name).write_bytes(content)
    manifest[asset.name] = hashlib.sha256(content).hexdigest()
(destination / "native-bundle.json").write_text(json.dumps({"format": 1, "mode": "local-demo", "assets": manifest}, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(f"Bundled {len(assets)} frontend assets for AVELI (no remote sign-in).")
