#!/usr/bin/env python3
"""Package a built .app directory into an unsigned .ipa.

Usage:
    python3 scripts/package_ipa.py <path/to/App.app> <output.ipa>

The resulting IPA contains Payload/<AppName>.app/... and preserves the
executable bit on the Mach-O binary.
"""

import os
import sys
import zipfile


def add_file(zf, path, arcname):
    st = os.stat(path)
    zi = zipfile.ZipInfo.from_file(path, arcname)
    zi.external_attr = (st.st_mode & 0xFFFF) << 16
    zi.compress_type = zipfile.ZIP_DEFLATED
    with open(path, "rb") as f:
        zf.writestr(zi, f.read())


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 1

    app = os.path.abspath(sys.argv[1])
    out = os.path.abspath(sys.argv[2])

    if not os.path.isdir(app):
        print(f"error: not a directory: {app}")
        return 1

    app_name = os.path.basename(app)
    if not app_name.endswith(".app"):
        print(f"error: expected a .app directory, got: {app_name}")
        return 1

    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)

    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zf:
        for root, _dirs, files in os.walk(app):
            for name in files:
                path = os.path.join(root, name)
                rel = os.path.relpath(path, app).replace(os.sep, "/")
                arcname = "Payload/" + app_name + "/" + rel
                add_file(zf, path, arcname)

    print(f"IPA: {out} ({os.path.getsize(out)} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
