#!/usr/bin/env python3
"""Record or check the custom-node packs installed on the running pod.

ComfyUI-Manager installs and updates nodes on the pod and R2 mirrors whatever
is there, so an "update all" silently changes every graph that uses those
nodes. custom-nodes.lock.json records each pack's ComfyUI-Manager `ver`
(registry semver or git commit), where it came from, whether it is enabled,
and the ComfyUI version the pod runs. `check` exits 1 when the live pod
differs from the lock and 2 when the pod cannot be read.

Usage: nodes-lock.py write|check [COMFYUI_URL]   (default http://localhost:8188)
"""

import json
import sys
import urllib.error
import urllib.request
from pathlib import Path

LOCK = Path(__file__).resolve().parent.parent / "custom-nodes.lock.json"
PACK_FIELDS = ("ver", "cnr_id", "aux_id", "enabled")


def fetch(url, path):
    with urllib.request.urlopen(url.rstrip("/") + path, timeout=30) as response:
        return json.load(response)


def live_state(url):
    installed = fetch(url, "/customnode/installed")
    stats = fetch(url, "/system_stats")
    return {
        "comfyui_version": stats["system"]["comfyui_version"],
        "packs": {
            name: {field: entry[field] for field in PACK_FIELDS}
            for name, entry in sorted(installed.items())
        },
    }


def drift(locked, live):
    lines = []
    if locked["comfyui_version"] != live["comfyui_version"]:
        lines.append(
            f"ComfyUI: locked {locked['comfyui_version']}, live {live['comfyui_version']}"
        )
    for name in sorted(locked["packs"].keys() | live["packs"].keys()):
        want, have = locked["packs"].get(name), live["packs"].get(name)
        if have is None:
            lines.append(f"{name}: locked at {want['ver']}, not installed")
        elif want is None:
            lines.append(f"{name}: installed at {have['ver']}, not in the lock")
        else:
            for field in PACK_FIELDS:
                if want[field] != have[field]:
                    lines.append(f"{name}: {field} locked {want[field]!r}, live {have[field]!r}")
    return lines


def main(argv):
    if len(argv) not in (2, 3) or argv[1] not in ("write", "check"):
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    url = argv[2] if len(argv) == 3 else "http://localhost:8188"
    try:
        live = live_state(url)
    except (urllib.error.URLError, OSError, KeyError, ValueError) as error:
        print(f"cannot read custom nodes from {url}: {error} (pod down? try `make attach`)", file=sys.stderr)
        return 2
    if argv[1] == "write":
        LOCK.write_text(json.dumps(live, indent=2) + "\n")
        print(f"wrote {LOCK.name}: {len(live['packs'])} packs, ComfyUI {live['comfyui_version']}")
        return 0
    try:
        locked = json.loads(LOCK.read_text())
    except (OSError, ValueError) as error:
        print(f"cannot read {LOCK.name}: {error} (run `make nodes-lock` first)", file=sys.stderr)
        return 2
    lines = drift(locked, live)
    for line in lines:
        print(line)
    if lines:
        print(f"custom nodes drifted from {LOCK.name}: {len(lines)} difference(s)", file=sys.stderr)
        return 1
    print(f"custom nodes match {LOCK.name}: {len(live['packs'])} packs, ComfyUI {live['comfyui_version']}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
