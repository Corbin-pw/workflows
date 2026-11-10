#!/usr/bin/env bash
# 04b-slurm-pmix.sh -- replace the apt Slurm (21.08, no PMIx) with Slurm built
# from source WITH PMIx, on every node, keeping slurm.conf/munge/users as they are.
#
# Why: the customer cluster supports PMIx (`srun --mpi=pmix`). With PMIx, plain
# srun launches OpenMPI 5 jobs; without it the workflow has to fall back to
# mpirun inside an allocation. The testbed must behave like production here.
# Versions are ASSUMPTIONS (README, "Customer cluster assumptions").
#
# Run:  sudo ./04b-slurm-pmix.sh            (after 04; idempotent -- skips the build if done)
#       sudo ./04b-slurm-pmix.sh --rebuild  (rebuild even if this version is installed)
# Builds once on the controller (16 CPUs, ~10 min), installs the same tarball on
# every node, then regenerates the config with MpiDefault=pmix.
TB_LIB="$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
[ -f "$TB_LIB" ] || { echo "ERROR: $TB_LIB is missing. Run it from a full clone of the repo (workflows/spack-builder/testbed), not a copied file" >&2; exit 1; }
. "$TB_LIB"
. "${TB_DIR}/lib/slurm.sh"
need_root
tb_start_log
[ "${SLURM_PMIX:-no}" = yes ] || die "SLURM_PMIX is not 'yes' in config.env -- nothing to do"
REBUILD=0; [ "${1:-}" = "--rebuild" ] && REBUILD=1

ART_DIR="${HOST_BASE}/slurm-build"            # host copy of the built tarball (survives node rebuilds)
ART="${ART_DIR}/slurm-${SLURM_VERSION}-pmix-tb.tar.gz"
BUILD_DIR="/root/slurm-build"                 # inside tb-ctl
mkdir -p "$ART_DIR"

# ---------------------------------------------------------------------------
say "Current state"
cur="$(tb_slurm_version || true)"
echo "  controller Slurm: ${cur:-none}  ($(tb_slurm_is_source_build && echo source build || echo apt))"
echo "  wanted:           ${SLURM_VERSION} + PMIx (${PMIX_SOURCE})"

# ---------------------------------------------------------------------------
if [ -f "$ART" ] && [ "$REBUILD" = 0 ]; then
  ok "build artifact exists: $ART (use --rebuild to build again)"
else
  say "Build dependencies on ${CONTROLLER}"
  # libpmix-dev is the Ubuntu 22.04 PMIx (4.1.x). The rest are what Slurm's
  # configure looks for; anything missing only drops an optional feature.
  nexec "$CONTROLLER" "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq build-essential pkg-config bzip2 python3 \
      libmunge-dev libpmix-dev libhwloc-dev libjson-c-dev libyaml-dev libdbus-1-dev libnuma-dev libreadline-dev \
      liblz4-dev libssl-dev libcurl4-openssl-dev libhttp-parser-dev libjwt-dev >/dev/null"
  ok "build deps installed"

  say "Locating PMIx"
  # Ubuntu's layout is looked up, not assumed: Slurm's --with-pmix wants a
  # prefix with include/pmix.h and lib/libpmix.so beneath it. If the package
  # spreads them over /usr/include and a multiarch lib dir, a small shim prefix
  # of two symlinks gives configure the shape it expects.
  read -r PMIX_H PMIX_SO < <(lxc exec "$CONTROLLER" -- bash -c \
    'h=$(dpkg -L libpmix-dev | grep "/pmix\.h$" | head -1); s=$(dpkg -L libpmix-dev libpmix2 2>/dev/null | grep "/libpmix\.so$" | head -1); echo "$h $s"')
  [ -n "${PMIX_H:-}" ] && [ -n "${PMIX_SO:-}" ] || die "could not find pmix.h / libpmix.so from libpmix-dev"
  PMIX_INC="$(dirname "$PMIX_H")"; PMIX_LIB="$(dirname "$PMIX_SO")"
  echo "  pmix.h:      $PMIX_H"
  echo "  libpmix.so:  $PMIX_SO -> $(lxc exec "$CONTROLLER" -- readlink -f "$PMIX_SO")"
  echo "  version:     $(lxc exec "$CONTROLLER" -- dpkg-query -W -f='${Version}' libpmix-dev)"
  if [ "$(dirname "$PMIX_INC")" = "$(dirname "$PMIX_LIB")" ]; then
    PMIX_PREFIX="$(dirname "$PMIX_INC")"
  else
    PMIX_PREFIX="/opt/pmix-shim"
    nexec "$CONTROLLER" "rm -rf $PMIX_PREFIX && mkdir -p $PMIX_PREFIX && ln -s $PMIX_INC $PMIX_PREFIX/include && ln -s $PMIX_LIB $PMIX_PREFIX/lib"
    echo "  (split layout -- configure gets a shim prefix $PMIX_PREFIX)"
  fi
  case "$PMIX_INC" in /usr/include|/usr/local/include) ok "pmix.h is on the default include path (the workflow's header probe will see it)";;
    *) warn "pmix.h is under $PMIX_INC, outside /usr/include -- the workflow's header probe will report PMIX MISSING (see README, assumption A2)";; esac

  say "Building Slurm ${SLURM_VERSION} with PMIx (${CONTROLLER}, -j$(lxc exec "$CONTROLLER" -- nproc))"
  nexec "$CONTROLLER" "set -e
    rm -rf $BUILD_DIR && mkdir -p $BUILD_DIR && cd $BUILD_DIR
    curl -fsSL -o slurm.tar.bz2 '$SLURM_URL'
    tar xjf slurm.tar.bz2 && cd slurm-${SLURM_VERSION}
    ./configure --prefix=/usr --sysconfdir=/etc/slurm --with-pmix=$PMIX_PREFIX --with-munge --with-hwloc >../configure.log 2>&1 \
      || { tail -40 ../configure.log; exit 1; }
    grep -iE 'pmix' config.log | grep -iE 'checking|result' | tail -6 | sed 's/^/    configure: /'
    make -j\$(nproc) >../make.log 2>&1 || { tail -60 ../make.log; exit 1; }
    rm -rf ../stage && make install DESTDIR=\$PWD/../stage >../install.log 2>&1
    make -C contribs/pmi2 install DESTDIR=\$PWD/../stage >>../install.log 2>&1   # libpmi2 + slurm/pmi2.h
    mkdir -p ../stage/etc/systemd/system && cp etc/slurmctld.service etc/slurmd.service ../stage/etc/systemd/system/
    ls ../stage/usr/lib/slurm/mpi_pmix*.so >/dev/null 2>&1 || { echo 'PMIx plugin was NOT built -- configure output:'; grep -i -B2 -A4 pmix ../configure.log | tail -30; exit 1; }
    tar -C ../stage -czf ../slurm-tb.tar.gz ."
  lxc file pull "$CONTROLLER$BUILD_DIR/slurm-tb.tar.gz" "$ART"
  ok "built: $ART ($(du -h "$ART" | cut -f1)); plugins: $(tar tzf "$ART" | grep -oE 'mpi_[a-z0-9_]+\.so' | sort -u | tr '\n' ' ')"
fi

# ---------------------------------------------------------------------------
say "Installing on every node"
# Runtime libraries for what was built, plus libpmix-dev everywhere: the PMIx
# HEADERS on the nodes are part of the customer assumption (A4), since Spack's
# OpenMPI/MPICH can then use the system PMIx as an external.
RUNTIME_PKGS="libmunge2 libpmix-dev libhwloc15 libjson-c5 libyaml-0-2 libdbus-1-3 libnuma1 libreadline8 liblz4-1 libssl3 libcurl4 libhttp-parser2.9 libjwt0"
for n in "${ALL_NODES[@]}"; do
    echo "  -- $n"
    lxc exec "$n" -- systemctl stop slurmctld slurmd 2>/dev/null || true
    # Remove every binary package built from Ubuntu's slurm-wlm source, so
    # nothing of 21.08 (binaries, plugins, libpmi*) is left to shadow the build.
    nexec "$n" "pk=\$(dpkg-query -W -f='\${Package} \${source:Package} \${Status}\n' 2>/dev/null | awk '\$2==\"slurm-wlm\" && \$NF==\"installed\" {print \$1}');
      [ -z \"\$pk\" ] || DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq \$pk >/dev/null"
    nexec "$n" "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $RUNTIME_PKGS >/dev/null"
    # The same slurm uid/gid everywhere: slurmd checks controller RPCs against it.
    nexec "$n" "getent group slurm >/dev/null || groupadd -r -g $SLURM_GID slurm
      id slurm >/dev/null 2>&1 || useradd -r -u $SLURM_UID -g slurm -d /var/lib/slurm -s /usr/sbin/nologin slurm
      [ \"\$(id -u slurm)\" = $SLURM_UID ] || { usermod -u $SLURM_UID slurm; groupmod -g $SLURM_GID slurm; }"
    lxc file push "$ART" "$n/tmp/slurm-tb.tar.gz"
    nexec "$n" "tar -C / --no-overwrite-dir -xzf /tmp/slurm-tb.tar.gz && rm /tmp/slurm-tb.tar.gz && ldconfig && mkdir -p /etc/slurm && echo '${SLURM_VERSION} pmix $(date -I)' > $TB_SLURM_MARKER"
    miss="$(lxc exec "$n" -- bash -c 'ldd /usr/sbin/slurmd /usr/sbin/slurmctld /usr/lib/slurm/mpi_pmix*.so 2>/dev/null | grep "not found" | sort -u')"
    if [ -n "$miss" ]; then fail "$n: unresolved libraries:"; echo "$miss" | sed 's/^/      /'; FAILED=1
    else ok "$n: $(lxc exec "$n" -- /usr/sbin/slurmd -V) installed, libraries resolve"; fi
done
[ "${FAILED:-0}" = 0 ] || die "fix the unresolved libraries above (add the package to RUNTIME_PKGS) and re-run"

# ---------------------------------------------------------------------------
say "Regenerating config (MpiDefault=${SLURM_MPI_DEFAULT})"
tb_slurm_configure "04b-slurm-pmix.sh"

say "PMIx check"
echo "  srun --mpi=list: $(lxc exec "$CONTROLLER" -- srun --mpi=list 2>&1 | tr '\n' ' ')"
for h in slurm/slurm.h slurm/pmi2.h pmix.h; do
  p="$(lxc exec "${COMPUTES[0]}" -- bash -c "ls /usr/include/$h /usr/local/include/$h 2>/dev/null | head -1")"
  [ -n "$p" ] && ok "header $h at $p" || warn "header $h not under /usr/include or /usr/local/include"
done
ok "done -- next: sudo ./05-verify-cluster.sh (now also checks srun --mpi=pmix)"
echo "Log saved: $TB_LOG"
