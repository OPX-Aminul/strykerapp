#!/usr/bin/env python3
"""Refresh stryker_manifest.json after a rebuild.

Every entry that points at a release asset carries that asset's sha256 and size.
When a binary is rebuilt those two numbers change, and an app that checks them
(section 4 of images/BINARIES.md — the download is verified before it is used)
would otherwise reject the new file.

Entries are found by URL, not by JSON path: an asset that several blocks point
at (qemu-system-aarch64 and libslirp.so are referenced by both `rootless` and
`rootless_v2`) is updated once and every copy of it follows.

    images/update-manifest.py stryker_manifest.json \
        --entry rootless-main:qemu-system-aarch64=images/out/prebuilt/qemu-system-aarch64 \
        --entry rootless-main:libslirp.so=images/out/prebuilt/libslirp.so \
        --dry-run

Only sha256 and size are written; urls and everything else stay untouched.
"""

import argparse
import hashlib
import json
import os
import sys


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def walk(node, path=()):
    """Yield (path, dict) for every JSON object, so urls can be found anywhere."""
    if isinstance(node, dict):
        yield path, node
        for key, value in node.items():
            yield from walk(value, path + (key,))
    elif isinstance(node, list):
        for i, value in enumerate(node):
            yield from walk(value, path + (i,))


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("manifest")
    ap.add_argument("--entry", action="append", default=[], metavar="TAG:ASSET=FILE",
                    help="tag and asset name whose entry should point at FILE")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    with open(args.manifest, "r", encoding="utf-8") as fh:
        manifest = json.load(fh)

    if not args.entry:
        print("nothing to do: pass at least one --entry", file=sys.stderr)
        return 2

    wanted = []          # (tag, asset, file, sha256, size)
    for spec in args.entry:
        try:
            tag_asset, path = spec.split("=", 1)
            tag, asset = tag_asset.split(":", 1)
        except ValueError:
            print(f"bad --entry {spec!r}: expected TAG:ASSET=FILE", file=sys.stderr)
            return 2
        if not os.path.isfile(path):
            print(f"no such file: {path}", file=sys.stderr)
            return 2
        wanted.append((tag, asset, path, sha256_of(path), os.path.getsize(path)))

    changed = []
    for tag, asset, path, sha, size in wanted:
        suffix = f"/{tag}/{asset}"
        hits = 0
        for _, obj in walk(manifest):
            url = obj.get("url")
            if not isinstance(url, str) or not url.endswith(suffix):
                continue
            hits += 1
            old = (obj.get("sha256"), obj.get("size"))
            if old == (sha, size):
                continue
            obj["sha256"] = sha
            obj["size"] = size
            changed.append((url, old, (sha, size)))
        if hits == 0:
            print(f"warning: no manifest entry points at {suffix}", file=sys.stderr)

    for url, old, new in changed:
        print(f"{url}\n    sha256 {old[0]} -> {new[0]}\n    size   {old[1]} -> {new[1]}")

    if not changed:
        print("manifest is already up to date")
        return 0
    if args.dry_run:
        print(f"{len(changed)} entr(y/ies) would change (dry run, nothing written)")
        return 0

    text = json.dumps(manifest, indent=2, ensure_ascii=False) + "\n"
    with open(args.manifest, "w", encoding="utf-8") as fh:
        fh.write(text)
    print(f"{len(changed)} entr(y/ies) updated in {args.manifest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
