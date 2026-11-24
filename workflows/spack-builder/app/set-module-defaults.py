"""Make the newest version of each package its module default.

    spack python set-module-defaults.py MODULE_ROOT

A re-run installs new versions BESIDE the old ones (nothing is removed), so a
module directory can hold mpich/3.4.3-... and mpich/4.2.2-..., or openmpi from
two runs. Lmod picks a default by its own ordering, which is not "newest
version" once names carry suffixes, so the choice is written down instead:

    <root>/<name>/.modulerc:   module-version <name>/<module> default

`.modulerc` rather than `.version` because Spack already keeps that file for
hidden implicit modules (hide_implicits) and preserves lines it did not write.
Directories with a `.version` file are left alone: the Python environments and
Miniforge set their own defaults that way.

Only directories with MORE THAN ONE version get a default. Several modules of
ONE version (gromacs per MPI) are alternatives, not an update, and choosing one
of them as the default would be arbitrary.
"""

import os
import re
import sys

TAG = "# spack-builder: newest version is the default"
HEADER = "#%Module4.7"


def version_key(s):
    """Order version strings the way people expect: 3.4.3 < 4.2.2 < 4.10."""
    return [(0, int(p), "") if p.isdigit() else (1, 0, p)
            for p in re.split(r"[.\-_]", s) if p != ""]


def module_dirs(root):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if not d.startswith(".")]
        mods = [f for f in filenames if not f.startswith(".")]
        if mods and not dirnames:
            yield dirpath, mods


def main(root):
    changed = 0
    for d, mods in module_dirs(root):
        name = os.path.relpath(d, root)
        if os.path.exists(os.path.join(d, ".version")):
            continue
        versions = {}
        for m in mods:
            versions.setdefault(m.split("-", 1)[0], []).append(m)
        rc = os.path.join(d, ".modulerc")
        lines = []
        if os.path.exists(rc):
            with open(rc) as f:
                lines = f.read().split("\n")
        # Drop what an earlier run wrote; everything else (Spack's hide lines) stays.
        kept = []
        skip_next = False
        for line in lines:
            if skip_next:
                skip_next = False
                continue
            if line == TAG:
                skip_next = True
                continue
            kept.append(line)
        while kept and kept[-1] == "":
            kept.pop()
        if len(versions) > 1:
            newest = max(versions, key=version_key)
            pick = max(versions[newest], key=version_key)
            if not kept:
                kept = [HEADER]
            kept += [TAG, "module-version %s/%s default" % (os.path.basename(name), pick)]
            print("  %-28s default -> %s   (versions: %s)"
                  % (name, pick, ", ".join(sorted(versions, key=version_key))))
        new = "\n".join(kept) + "\n" if kept and kept != [HEADER] else ""
        old = "\n".join(lines) if lines else ""
        if new.rstrip("\n") != old.rstrip("\n"):
            if new:
                with open(rc, "w") as f:
                    f.write(new)
            elif os.path.exists(rc):
                os.remove(rc)
            changed += 1
    print("  %d .modulerc file(s) updated" % changed)


if __name__ == "__main__":
    main(sys.argv[1])
