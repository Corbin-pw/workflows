"""Render spack.yaml from the environment template plus a fabric fragment.

Run with Spack's own interpreter (`spack python render-env.py ...`) so PyYAML is
available without adding a dependency to the cluster image.

    spack python render-env.py FRAGMENT TEMPLATE OUT TARGET GPU_ACTIVE CUDA_ARCH MODULE_ROOT

It must be a real file: `spack python -` does not read a script from stdin the
way `python -` does -- it tries to open "-" as a filename.

The `packages:` section is merged STRUCTURALLY, not by text substitution. Both
sides legitimately configure the same package: the template pins MPI versions
globally, the fragment sets the fabric-specific variants. Splicing the fragment
in as text produced a YAML file with two `openmpi:` keys, which Spack rejects
outright ("found duplicate key"). Merging the parsed dicts -- and concatenating
`require` lists rather than letting one win -- is what lets both live together.
"""

import os
import re
import sys

import yaml

SPEC_PLACEHOLDERS = ("__MPI_SPECS__", "__CUDA_AWARE_MPI_SPECS__",
                     "__GROMACS_SPECS__", "__GROMACS_GPU_SPECS__")


def merge_packages(base, extra):
    """Deep-merge fragment package config into the template's.

    `require` lists are concatenated so a global version pin and a fabric
    variant requirement both apply; any other key the fragment sets wins.
    """
    for pkg, cfg in (extra or {}).items():
        if pkg not in base:
            base[pkg] = cfg
            continue
        merged = dict(base[pkg])
        for key, value in cfg.items():
            if key == "require":
                old = merged.get("require", [])
                old = [old] if isinstance(old, str) else list(old)
                new = [value] if isinstance(value, str) else list(value)
                merged["require"] = old + [v for v in new if v not in old]
            else:
                merged[key] = value
        base[pkg] = merged
    return base


# GPU libraries installed for users on the GPU path (service_gpu_libraries).
# The MPI-dependent ones are built against THE cuda-aware MPI spec of the
# fabric fragment -- see gpu_specs() for why the whole spec is repeated.
GPU_LIBRARIES = {
    "cudnn":   "cudnn",
    "nccl":    "nccl +cuda",
    "nvshmem": "nvshmem +cuda +mpi +ucx +nccl +gdrcopy ^{mpi}",
    "cufftmp": "cufftmp +cuda ^nvshmem +cuda +mpi +ucx +nccl +gdrcopy ^{mpi}",
}


def gpu_specs(frag, cuda_arch, libraries):
    """Root specs the GPU path adds beyond the fragment's own lists.

    Under `unify: false` every root concretizes on its own, so a bare
    `^openmpi+cuda` resolves to a DIFFERENT openmpi than the fragment's
    cuda-aware MPI spec (the README's two-copies trap: gromacs linked against
    one openmpi while the module tree advertised the other). Every root that
    links the cuda-aware MPI therefore carries that exact spec, and so resolves
    to the same node. The fragment's gromacs GPU spec is rewritten the same way
    when it uses the bare form.
    """
    mpi = [s.replace("__CUDA_ARCH__", cuda_arch) for s in frag.get("cuda_aware_mpi_specs", [])]
    if not mpi:
        return [], []
    cuda_mpi = mpi[0]

    def share_mpi(spec):
        if "fabrics=" in spec or not re.search(r"\^openmpi\s*\+cuda\b", spec):
            return spec
        spec = re.sub(r"\^openmpi\s*\+cuda\b", "", spec)
        spec = re.sub(r"\^cuda(?![-_@\w])", "", spec)
        return " ".join(spec.split()) + " ^" + cuda_mpi

    gromacs = [share_mpi(s.replace("__CUDA_ARCH__", cuda_arch))
               for s in frag.get("gromacs_gpu_specs", [])]
    extra = ["cuda", "osu-micro-benchmarks +cuda ^" + cuda_mpi]
    for lib in libraries:
        if lib not in GPU_LIBRARIES:
            sys.exit("render-env: unknown GPU library %r (choose from %s)"
                     % (lib, " ".join(GPU_LIBRARIES)))
        extra.append(GPU_LIBRARIES[lib].format(mpi=cuda_mpi))
    return gromacs, extra



# --- additional software (service_extra_specs / service_mpich_extra_versions) --
SPEC_NAME = re.compile(r"^([A-Za-z0-9_][A-Za-z0-9_.-]*)\s*(.*)$")
BARE_VERSION = re.compile(r"^@[^\s%^+~=]+$")


def read_spec_lines(path):
    """One Spack spec per line; '#' starts a comment, blank lines are skipped."""
    if not path or not os.path.isfile(path):
        return []
    out = []
    with open(path) as f:
        for line in f:
            line = line.split("#", 1)[0].strip()
            if line:
                out.append(" ".join(line.split()))
    return out


def add_version_alongside(packages, name, version):
    """Let `name@version` coexist with the version the template pins.

    The template pins each MPI with `require: ["@x"]` so that a bare `^mpich`
    in gromacs or osu resolves to the same build as the standalone MPI. A
    second version can only be installed if that pin becomes a choice:
    `one_of: ["@x", "@y"]`. Consumers that do not name a version still get the
    newest (the solver prefers newer versions, and both are installed), and
    the extra version is reached only by asking for it explicitly.
    Returns True if a pin was widened, False if the package had none.
    """
    cfg = packages.get(name)
    if not cfg or "require" not in cfg:
        return False
    req = cfg["require"]
    req = [req] if isinstance(req, (str, dict)) else list(req)
    want = "@%s" % version.lstrip("@")
    for i, item in enumerate(req):
        if isinstance(item, str) and BARE_VERSION.match(item):
            if item != want:
                req[i] = {"one_of": [item, want]}
            cfg["require"] = req
            return True
        if isinstance(item, dict) and "one_of" in item and \
                all(isinstance(x, str) and BARE_VERSION.match(x) for x in item["one_of"]):
            if want not in item["one_of"]:
                item["one_of"].append(want)
            cfg["require"] = req
            return True
    return False


def add_extra_specs(env, lines):
    """Add user-requested roots, keeping the stack to ONE build per package.

    For a spec with its own constraints and no dependency clause
    (`git +tcltk`, `cmake@3.31`), the constraints also become a package
    requirement: under `unify: false` any other root that depends on the same
    package would otherwise concretize its own copy with default variants, and
    two builds of one name/version abort `module tcl refresh` with "Name clashes
    detected" (the ucx lesson in fabric-azure.yaml). A package the template
    already pins (the MPIs, the compiler) instead gets its version pin widened
    by add_version_alongside, so the existing build is untouched.
    """
    spack = env["spack"]
    packages = spack.setdefault("packages", {})
    specs = spack.get("specs") or []
    include = spack["modules"]["default"]["tcl"].setdefault("include", [])
    for line in lines:
        m = SPEC_NAME.match(line)
        if not m:
            sys.exit("render-env: cannot read additional spec %r" % line)
        name, rest = m.group(1), m.group(2).strip()
        note = ""
        if rest and "^" not in rest and "%" not in rest:
            ver = re.match(r"^@([^\s%^+~=]+)\s*(.*)$", rest)
            if name in packages and "require" in packages[name]:
                if ver and add_version_alongside(packages, name, ver.group(1)):
                    note = "(alongside the pinned version)"
                else:
                    note = "(root only: %s already has a requirement)" % name
            else:
                packages.setdefault(name, {})["require"] = [rest]
                note = "(also required of every %s in the stack)" % name
        if line not in specs:
            specs.append(line)
        # include wins over the externals exclude: if a site external satisfies
        # the spec, users still get a module for it.
        if name not in include:
            include.append(name)
        print("  + %s %s" % (line, note))
    spack["specs"] = specs


def main(argv):
    frag_path, tmpl_path, out_path, target, gpu_active, cuda_arch, module_root = argv[1:8]
    gpu_active = gpu_active == "1"

    with open(frag_path) as f:
        frag = yaml.safe_load(f)["fabric"]

    def specs_block(key, only_if=True):
        if not only_if:
            return ""
        items = [s.replace("__CUDA_ARCH__", cuda_arch) for s in frag.get(key, [])]
        return "\n".join('    - "%s"' % s for s in items)

    with open(tmpl_path) as f:
        tmpl = f.read()

    # The fragment's packages are merged after parsing, so drop the placeholder line.
    tmpl = "\n".join(l for l in tmpl.split("\n") if l.strip() != "__FABRIC_PACKAGES__")

    for placeholder, value in [
        ("__TARGET__", target),
        ("__MODULE_ROOT__", module_root),
        ("__MPI_SPECS__", specs_block("mpi_specs")),
        ("__CUDA_AWARE_MPI_SPECS__", specs_block("cuda_aware_mpi_specs", gpu_active)),
        ("__GROMACS_SPECS__", specs_block("gromacs_specs")),
        ("__GROMACS_GPU_SPECS__", ""),   # added below, sharing the cuda-aware MPI
    ]:
        tmpl = tmpl.replace(placeholder, value)

    leftover = [p for p in SPEC_PLACEHOLDERS + ("__TARGET__", "__MODULE_ROOT__",
                                                "__FABRIC_PACKAGES__", "__CUDA_ARCH__")
                if p in tmpl]
    if leftover:
        sys.exit("render-env: unsubstituted placeholders remain: %s" % ", ".join(leftover))

    env = yaml.safe_load(tmpl)
    env["spack"]["packages"] = merge_packages(env["spack"].get("packages", {}),
                                              frag.get("packages", {}))

    # Python environments (build-python-envs.sh) are venvs on a Spack-built
    # python@<version>; it is a root so it is installed, cached and gets a module.
    python_version = os.environ.get("SB_PYTHON_VERSION", "").strip()
    if python_version:
        specs = env["spack"].get("specs") or []
        if "python@%s" % python_version not in specs:
            specs.append("python@%s" % python_version)
        env["spack"]["specs"] = specs
        print("Python environments: python@%s added as a root" % python_version)

    # Additional MPICH versions (service_mpich_extra_versions), each with an OSU
    # build so the launch can be tested like the pinned one.
    mpich_versions = os.environ.get("SB_MPICH_EXTRA_VERSIONS", "").replace(",", " ").split()
    if mpich_versions:
        print("Additional MPICH versions: %s" % " ".join(mpich_versions))
        extra = []
        for v in mpich_versions:
            v = v.lstrip("@")
            extra += ["mpich@%s" % v, "osu-micro-benchmarks ^mpich@%s" % v]
        add_extra_specs(env, extra)

    # Additional software (service_extra_specs), one Spack spec per line.
    extra_lines = read_spec_lines(os.environ.get("SB_EXTRA_SPECS_FILE", ""))
    if extra_lines:
        print("Additional software: %d spec(s)" % len(extra_lines))
        add_extra_specs(env, extra_lines)

    # GPU path: CUDA pinned (unless the cluster's own toolkit is registered as
    # an external -- build.sh then leaves SB_CUDA_VERSION empty), the GPU
    # libraries, and every MPI-dependent GPU root sharing one cuda-aware MPI.
    if gpu_active:
        cuda_version = os.environ.get("SB_CUDA_VERSION", "").strip().lstrip("@")
        libraries = os.environ.get("SB_GPU_LIBS", "").replace(",", " ").split()
        if cuda_version:
            env["spack"]["packages"] = merge_packages(
                env["spack"]["packages"], {"cuda": {"require": ["@%s" % cuda_version]}})
        gromacs_gpu, extra = gpu_specs(frag, cuda_arch, libraries)
        specs = env["spack"].get("specs") or []
        for spec in gromacs_gpu + extra:
            if spec not in specs:
                specs.append(spec)
        env["spack"]["specs"] = specs
        print("GPU path: cuda %s, libraries [%s]" % (
            cuda_version or "(site external)", " ".join(libraries) or "none"))
        for spec in gromacs_gpu + extra:
            print("  + %s" % spec)

    # cuda_arch has to reach EVERY package that consumes CUDA, not only the ones
    # a spec string names. Setting it per-spec covered gromacs and missed the
    # transitive ones: on gce2 run funky-pigeon, ucx and gdrcopy concretized with
    # `cuda_arch:=none` because nothing named them, and gdrcopy's build then ran
    #   nvcc --generate-code arch=compute_none,code=sm_none
    #   nvcc fatal : Unsupported gpu architecture 'compute_none'
    # after 1h28m of compiling. A preference under `packages: all:` applies to
    # any package that HAS the variant and leaves the rest untouched, which is
    # the only place that reaches a dependency no spec mentions.
    # Reuse must be constrained to the chosen target, or it silently defeats it.
    # `packages: all: target:` is a PREFERENCE, and `reuse: true` outranks a
    # preference: an installed spec for a different microarchitecture satisfies
    # the request, so Spack takes it. On aws run fair-mastodon the target
    # resolved correctly to x86_64_v3 for a zen2 worker, and the environment
    # still came out with 45 skylake_avx512 specs -- fftw, gcc-runtime, curl and
    # the three CPU gromacs builds -- reused wholesale from the Intel login
    # node's earlier CPU stack. Those carry AVX-512 and cannot execute on zen2,
    # so the run "passed" with a stack that would SIGILL on the nodes it was
    # built for. Nothing in the pass criteria can see that.
    #
    # `include` keeps reuse working for everything already at the right target
    # (which is the normal redeploy case, where it is the whole point) and
    # forbids it for everything else, from the local install tree and the build
    # cache alike.
    env["spack"].setdefault("concretizer", {})["reuse"] = {
        "include": ["target=%s" % target]
    }

    # A GPU environment contains a ~cuda and a +cuda build of the same
    # name/version/compiler for openmpi, gromacs, fftw, hwloc and more, and the
    # CPU projections name both identically -- so `module tcl refresh` aborts
    # with "Name clashes detected in module files" AFTER a completely successful
    # install (gce2 run caring-warthog: the whole GPU stack built and pushed,
    # then the run failed on naming). Two changes, GPU builds only:
    #   * a -cuda suffix, so a user can SEE which module is the CUDA build. It
    #     marks exactly one thing: THIS package is CUDA-enabled. The constraint
    #     is `+cuda` on the package itself -- NOT `^mpi+cuda`, which was the
    #     first attempt and silently mislabelled three builds in four. A variant
    #     constraint on a VIRTUAL is dropped, so `^mpi+cuda` degenerates to
    #     `^mpi` and matched every MPI build: run moral-silkworm named its
    #     mpich~cuda and intel-oneapi-mpi GROMACS "-cuda" although neither they
    #     nor their MPI had CUDA at all. Constrain the concrete provider, or the
    #     package, and matching behaves.
    #     `+cuda ^mpi` (package is CUDA-enabled AND links an MPI) comes first so
    #     such a package keeps the MPI in its name; `+cuda` alone then catches
    #     the CUDA-aware MPIs themselves, which PROVIDE mpi rather than depend
    #     on it and so never match the first rule.
    #   * `^hwloc+cuda` -> -cuda as well: pmix and prrte appear twice with
    #     IDENTICAL variants, differing only in which hwloc they were built
    #     against. This used to be solved with hash_length 7 on GPU builds, but
    #     that gave every module of a GPU run a different name from the same
    #     module of a CPU run, so one flat folder ended up with two modules per
    #     version (testbed, 2026-11-24). Names are now the same in both, and a
    #     later run updates a module in place. Hidden implicit modules
    #     (hide_implicits) would have been the other way out, but Lmod 6.6 --
    #     Ubuntu 22.04's -- aborts on the `module-hide` lines Spack writes.
    #     Any clash that remains (two builds of an implicit dependency that no
    #     projection can tell apart) is resolved per package at refresh time;
    #     see module-names.py.
    if gpu_active:
        tcl = env["spack"]["modules"]["default"]["tcl"]
        tcl["projections"] = {
            "+cuda ^mpi": "{name}/{version}-{^mpi.name}-{^mpi.version}-cuda",
            "+cuda": "{name}/{version}-{compiler.name}-{compiler.version}-cuda",
            "^hwloc+cuda": "{name}/{version}-{compiler.name}-{compiler.version}-cuda",
            **tcl.get("projections", {}),
        }

    if gpu_active and cuda_arch:
        all_cfg = env["spack"]["packages"].setdefault("all", {})
        existing = all_cfg.get("variants", "")
        if isinstance(existing, list):
            all_cfg["variants"] = existing + ["cuda_arch=%s" % cuda_arch]
        else:
            all_cfg["variants"] = (existing + " " if existing else "") + \
                                  "cuda_arch=%s" % cuda_arch

    # The stack compiler is written down only in the template. Report it so the
    # caller can install and register it before concretizing -- `spack python -c`
    # takes a single statement, so a multi-line inline reader is not an option.
    req = env["spack"]["packages"]["c"]["require"]
    gcc_spec = req[0] if isinstance(req, list) else req

    with open(out_path, "w") as f:
        yaml.safe_dump(env, f, default_flow_style=False, sort_keys=False, width=100)

    print("rendered %s: target=%s gpu=%s cuda_arch=%s specs=%d"
          % (out_path, target, gpu_active, cuda_arch if gpu_active else "n/a",
             len(env["spack"]["specs"])))
    print("GCC_SPEC=%s" % gcc_spec)


if __name__ == "__main__":
    main(sys.argv)
