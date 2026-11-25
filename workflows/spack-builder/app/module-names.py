"""Module names that stay the same from run to run.

    spack python module-names.py hash-for SPACK_YAML NAME@=VERSION...
    spack python module-names.py prune MODULE_ROOT STAMP_FILE

hash-for: `module tcl refresh` aborts with "Name clashes detected" when two
builds in one environment map to the same module name. With hash_length 0
(the only setting that keeps names stable between CPU and GPU runs, see
render-env.py) that still happens for a few implicit dependencies that two
roots pull in with different dependency subtrees -- on the testbed GPU stack
gettext, krb5, openssh and a build-only python 3.14. No projection can tell
those apart, so each clashing package VERSION gets a projection with a
7-character hash, inserted first (first match wins), and the refresh is
retried. Only those carry a hash; everything else keeps its stable name.

prune: a module whose name changed (the hashed names of earlier GPU runs) is
left behind by a refresh, which never deletes. After a refresh, a Spack
modulefile that names the SAME build (the /hash7 on its header line) as a
file written by this refresh, under a different name, is a stale duplicate
and is removed. Different builds are never removed, nor anything not written
by Spack.
"""

import os
import re
import sys

import yaml

HASHED = "{name}/{version}-{compiler.name}-{compiler.version}-{hash:7}"


def hash_for(path, names):
    with open(path) as f:
        d = yaml.safe_load(f)
    tcl = d["spack"]["modules"]["default"]["tcl"]
    old = tcl.get("projections") or {}
    new = {n: HASHED for n in names if n not in old}
    tcl["projections"] = {**new, **old}
    with open(path, "w") as f:
        yaml.safe_dump(d, f, default_flow_style=False, sort_keys=False, width=100)
    for n in names:
        print("  %s: two builds share one module name; they get a hash suffix" % n)


HEADER = re.compile(r"^## Module file created by spack")
SPEC = re.compile(r"/([a-z0-9]{7})\s*$")


def spack_hash(path):
    try:
        with open(path, errors="replace") as f:
            head = [next(f, "") for _ in range(4)]
    except OSError:
        return None
    if not HEADER.match(head[1]):
        return None
    m = SPEC.search(head[3])
    return m.group(1) if m else None


def prune(root, stamp):
    since = os.path.getmtime(stamp)
    current, older = {}, []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if not d.startswith(".")]
        for f in filenames:
            if f.startswith("."):
                continue
            p = os.path.join(dirpath, f)
            h = spack_hash(p)
            if not h:
                continue
            if os.path.getmtime(p) >= since:
                current.setdefault(h, p)
            else:
                older.append((h, p))
    removed = 0
    for h, p in older:
        if h in current and current[h] != p:
            os.remove(p)
            removed += 1
            print("  removed %s (same build as %s)"
                  % (os.path.relpath(p, root), os.path.relpath(current[h], root)))
    print("  %d stale duplicate module(s) removed" % removed)


if __name__ == "__main__":
    if sys.argv[1] == "hash-for":
        hash_for(sys.argv[2], sys.argv[3:])
    elif sys.argv[1] == "prune":
        prune(sys.argv[2], sys.argv[3])
    else:
        sys.exit("usage: module-names.py hash-for SPACK_YAML NAME... | prune MODULE_ROOT STAMP")
