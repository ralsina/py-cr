#!/usr/bin/env python3
"""Assembles a self-contained wheel for the pycr extension.

Takes the Crystal-built pycr.so (repo root, from ./build.sh) plus
libgc.so.1 from the system, and packs:

    pycr/__init__.py          import shim with version + load errors
    pycr/_native.so           the compiled extension (RUNPATH $ORIGIN)
    pycr/libgc.so.1           bundled Boehm GC (resolved via $ORIGIN)
    pycr-<v>.dist-info/       METADATA, WHEEL (multi-version tags), RECORD

One wheel covers every CPython version the .so is validated against
(currently 3.11-3.14) because the module resolves Py* symbols from the
loading interpreter and uses no limited-API-only features.

    ./build.sh                                  # build pycr.so first
    python3 packaging/build_wheel.py            # -> dist/*.whl
"""

import base64
import hashlib
import os
import shutil
import ctypes.util
import subprocess
import sys
import sysconfig

VERSION = "0.1.0"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SO = os.path.join(ROOT, "pycr.so")
LIBGC_CANDIDATES = ["/usr/lib/libgc.so.1", "/usr/lib64/libgc.so.1"]
# Versions the .so is validated against (see notes in README).
PY_TAGS = ["cp311", "cp312", "cp313", "cp314"]
PLATFORM = "linux_x86_64"

WHEEL_TEMPLATE = """Wheel-Version: 1.0
Generator: pycr packaging ({version})
Root-Is-Purelib: false
{tag_lines}
"""

METADATA_TEMPLATE = """Metadata-Version: 2.1
Name: pycr
Version: {version}
Summary: Write Python extension modules in Crystal
Requires-Python: >=3.11
Description-Content-Type: text/markdown

py-cr: a framework for writing Python extension modules in Crystal.
This wheel ships the native `pycr` module; see the project README for
the DSL (`Pycr.pyinit` / `pyfunction` / `pyclass`), the scheduler
bridge, and the tartrazine example.
"""


def record_hash(data: bytes) -> str:
    digest = hashlib.sha256(data).digest()
    return base64.urlsafe_b64encode(digest).rstrip(b"=").decode("ascii")


def main() -> None:
    import zipfile

    if not os.path.exists(SO):
        sys.exit("pycr.so not found - run ./build.sh first")

    libgc = next((p for p in LIBGC_CANDIDATES if os.path.exists(p)), None)
    if libgc is None:
        # CI runners and slim images lack the gc runtime package; fetch
        # the shared library from the Crystal toolchain's own bundle.
        crystal_lib = subprocess.run(
            ["crystal", "env", "CRYSTAL_LIBRARY_PATH"], capture_output=True, text=True
        ).stdout.strip()
        search_dirs = []
        for directory in crystal_lib.split(":"):
            search_dirs.append(directory)
            search_dirs.append(os.path.join(directory, "gc"))
        for directory in search_dirs:
            candidate = os.path.join(directory, "libgc.so.1")
            if os.path.exists(candidate):
                libgc = candidate
                break
    if libgc is None:
        found = ctypes.util.find_library("gc")
        if found:
            libgc = found
    if libgc is None:
        sys.exit("libgc.so.1 not found - install the gc runtime package")

    # Multi-version wheels use dot-compressed tag sets in the filename:
    # pip matches the FILENAME tags for local installs, and the WHEEL
    # metadata's Tag lines for the full set.
    py_set = ".".join(PY_TAGS)
    abi_set = ".".join(PY_TAGS)
    filename = f"pycr-{VERSION}-{py_set}-{abi_set}-{PLATFORM}.whl"

    dist_dir = os.path.join(ROOT, "dist")
    os.makedirs(dist_dir, exist_ok=True)
    out_path = os.path.join(dist_dir, filename)

    init_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "pycr", "__init__.py")
    init_py = open(init_path).read()

    tag_lines = "".join(f"Tag: cp{v[2:]}-cp{v[2:]}-{PLATFORM}\n" for v in PY_TAGS)
    wheel_meta = WHEEL_TEMPLATE.format(version=VERSION, tag_lines=tag_lines)
    metadata = METADATA_TEMPLATE.format(version=VERSION)

    records = []

    def add(zf, arcname, data: bytes):
        zf.writestr(arcname, data)
        records.append((arcname, record_hash(data), str(len(data))))

    with zipfile.ZipFile(out_path, "w", zipfile.ZIP_DEFLATED) as zf:
        add(zf, "pycr/__init__.py", init_py.encode())
        add(zf, "pycr/pycr.so", open(SO, "rb").read())
        add(zf, "pycr/libgc.so.1", open(libgc, "rb").read())
        add(zf, f"pycr-{VERSION}.dist-info/METADATA", metadata.encode())
        add(zf, f"pycr-{VERSION}.dist-info/WHEEL", wheel_meta.encode())

        # RECORD: hashes for everything except itself (empty hash)
        record_lines = [f"{name},{sha},{size}" for name, sha, size in records]
        record_lines.append(f"pycr-{VERSION}.dist-info/RECORD,,")
        zf.writestr(f"pycr-{VERSION}.dist-info/RECORD", "\n".join(record_lines).encode())

    size_mb = os.path.getsize(out_path) / 1e6
    print(f"built {out_path} ({size_mb:.1f} MB)")
    print(f"tags: {', '.join(f'cp{v[2:]}-cp{v[2:]}-{PLATFORM}' for v in PY_TAGS)}")


if __name__ == "__main__":
    main()
