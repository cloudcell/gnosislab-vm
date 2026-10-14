#!/usr/bin/env bash
# prefetch-cache.sh — download/build every artifact a template build
# needs BEFORE the build starts, into the single cache tree
# ~/.cache/labloop/ (plan: docs/e-plans/plan-20260930-1838Z--offline-
# build-prefetch.md). The guest then consumes the cache over a
# transient http server on the NAT gateway instead of hitting the
# internet mid-install.
#
#   ./selfbuild/prefetch-cache.sh             # --ensure (default)
#   ./selfbuild/prefetch-cache.sh --verify    # report only; rc=1 on gaps
#   ./selfbuild/prefetch-cache.sh --refresh   # re-fetch everything
#   ./selfbuild/prefetch-cache.sh --only apt  # warm just one layer
#
# Env:  LABLOOP_OFFLINE=1        never fetch; missing artifact => fail
#       LABLOOP_CACHE_MAX_AGE_HOURS   (default 24 — ISO exempt: it is
#                                     sha256-verified at use time)
#       LABLOOP_CACHE_MIN_FREE_GIB    (default 8 — image tarballs are GBs)
#       GNOSISLAB_VER            gnosislab package pin: "latest" (default)
#                                resolves to the newest PyPI release every
#                                run — TTL=0 for this package, always fresh;
#                                set to a version to pin (required offline)
#       XDG_CACHE_HOME           cache root override
#
# GUEST_PKGS is the single source of truth for the guest package set —
# the apt-get lines in create-lab-template must match this list.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"

CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/labloop"
MAX_AGE_MIN=$(( ${LABLOOP_CACHE_MAX_AGE_HOURS:-24} * 60 ))
MIN_FREE_GIB="${LABLOOP_CACHE_MIN_FREE_GIB:-8}"
OFFLINE="${LABLOOP_OFFLINE:-0}"

# every apt package the guest installs (in-target + provisioning);
# codium's own dep closure is appended at fetch time via --print-uris
# on the local .deb — do not duplicate create-lab-template's lists here
GUEST_PKGS=(
    qemu-guest-agent spice-vdagent
    podman uidmap acl pipx python-is-python3 git curl mc nodejs npm nftables
    texlive-latex-base texlive-latex-recommended texlive-fonts-recommended latexmk
    numlockx
)
TRIAL_PKGS="numpy pandas scipy scikit-learn matplotlib reportlab"
UVX_PKGS="uv duckduckgo-mcp-server"
VSIX_EXTS="ZooCodeOrganization.zoo-code tomoki1207.pdf"

# opencode version: create-lab-template's npm line is the single source
# of truth — read it up front so have_pkgs can demand THIS version (a
# bump there must make the pkgs layer non-ok, else ensure never refetches)
OC_VER=$(grep -oE '@opencode/cli@[0-9]+\.[0-9]+\.[0-9]+' \
         "$REPO/create-lab-template" | head -1 | cut -d@ -f3)

# gnosislab version: create-lab-template's GNOSISLAB_VER line is the
# single source of truth — eval the assignment so its env override +
# default both apply here
eval "$(sed -n '/^GNOSISLAB_VER=/p' "$REPO/create-lab-template")"
GNOSISLAB_VER="${GNOSISLAB_VER:-}"

die()  { echo "prefetch-cache: $*" >&2; exit 1; }
note() { echo "==> $*"; }
say()  { echo "    $*"; }

MODE=ensure; ONLY=""
case "${1:-}" in
    --ensure|"") ;;
    --verify)  MODE=verify ;;
    --refresh) MODE=refresh ;;
    --only)    ONLY="${2:?--only needs a layer name}" ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) die "unknown flag '$1'" ;;
esac

# "latest" → newest PyPI release; a stale pin is exactly what TTL=0
# exists to prevent. Offline runs cannot resolve — require a pin.
if [ "$GNOSISLAB_VER" = latest ]; then
    [ "$OFFLINE" = 1 ] \
        && die "GNOSISLAB_VER=latest cannot resolve offline — set GNOSISLAB_VER to a version"
    GNOSISLAB_VER=$(curl -fsSL https://pypi.org/pypi/gnosislab/json \
        | grep -oE '"version": *"[^"]+"' | head -1 \
        | grep -oE '[0-9][0-9A-Za-z.-]*') \
        && [ -n "$GNOSISLAB_VER" ] \
        || die "cannot resolve latest gnosislab release from PyPI"
    say "gnosislab: latest -> $GNOSISLAB_VER"
fi

mkdir -p "$CACHE"/{apt,images,wheels/{trial-env,uvx,gnosislab},pkgs/gnosislab}

# ISO identity lives in mk-auto-iso.sh — eval its four assignments so a
# Mint point-release bump can't drift the two scripts apart
eval "$(sed -n '/^ISO_NAME=/p;/^ISO_URL=/p;/^SUMS_URL=/p;/^ISO_CACHE=/p' \
        "$REPO/selfbuild/mk-auto-iso.sh")"
mkdir -p "$ISO_CACHE"

# ------------------------------------------------------------------
# per-layer presence checks
# ------------------------------------------------------------------
have_iso()    { compgen -G "$ISO_CACHE/linuxmint-*-xfce-64bit.iso" >/dev/null; }
have_apt()    { [ -f "$CACHE/apt/Packages.gz" ] \
                && compgen -G "$CACHE/apt/*.deb" >/dev/null; }
have_images() { [ -f "$CACHE/images/lab-img-mcp-gnosislab-$GNOSISLAB_VER.tar" ] \
                && compgen -G "$CACHE/images/lab-img-exp-*.tar" >/dev/null; }
have_wheels() { compgen -G "$CACHE/wheels/trial-env/*.whl" >/dev/null \
                && compgen -G "$CACHE/wheels/uvx/uv-*.whl" >/dev/null \
                && compgen -G "$CACHE/wheels/uvx/duckduckgo*" >/dev/null \
                && compgen -G "$CACHE/wheels/gnosislab/gnosislab-${GNOSISLAB_VER}-*.whl" >/dev/null; }
have_pkgs()   { compgen -G "$CACHE/pkgs/codium_*.deb" >/dev/null \
                && [ -f "$CACHE/pkgs/opencode-cli-linux-x64-${OC_VER}.tgz" ] \
                && [ -f "$CACHE/pkgs/opencode-cli-linux-x64-baseline-${OC_VER}.tgz" ] \
                && [ -f "$CACHE/pkgs/gnosislab-${GNOSISLAB_VER}.tar.gz" ] \
                && [ -f "$CACHE/pkgs/gnosislab/ports.env" ] \
                && [ "$(find "$CACHE/pkgs" -name '*.vsix' | wc -l)" -ge 2 ]; }

# stale = a layer with ANY file older than the age cap (fetchers
# re-fetch the whole layer — a stale artifact is never silently kept)
fresh() { [ -z "$(find "$1" -type f -mmin +"$MAX_AGE_MIN" -print -quit 2>/dev/null)" ]; }
iso_fresh() { return 0; }   # exempt — sha256-verified at use time

LAYERS=(iso apt images wheels pkgs)
declare -A LAYER_DIR=(
    [iso]="$ISO_CACHE" [apt]="$CACHE/apt" [images]="$CACHE/images"
    [wheels]="$CACHE/wheels" [pkgs]="$CACHE/pkgs")

manifest_regen() {
    ( cd "$CACHE"
      printf '# labloop artifact manifest — regenerated by prefetch-cache.sh; do not edit\n'
      find . -type f ! -name 'MANIFEST*' -printf '%P\n' | sort | while read -r p; do
          printf '%s\t%s\t%s\t%s\n' "$p" "$(stat -c%s "$p")" \
              "$(sha256sum "$p" | cut -d' ' -f1)" \
              "$(date -u -r "$p" +%FT%TZ)"
      done ) > "$CACHE/MANIFEST.tmp"
    mv "$CACHE/MANIFEST.tmp" "$CACHE/MANIFEST"
}

# verify_manifest — every file on disk must hash to its manifest row.
# A file absent from MANIFEST is untracked, not corrupt (first-run case).
verify_manifest() {
    [ -f "$CACHE/MANIFEST" ] || return 0
    local bad=0 p sha
    while IFS=$'\t' read -r p _ sha _; do
        case "$p" in '#'*|'') continue ;; esac
        [ -f "$CACHE/$p" ] || continue
        [ "$(sha256sum "$CACHE/$p" | cut -d' ' -f1)" = "$sha" ] \
            || { say "BAD HASH: $p"; bad=1; }
    done < "$CACHE/MANIFEST"
    return $bad
}

# ------------------------------------------------------------------
# fetchers — each repopulates one layer; all run host-side, online
# ------------------------------------------------------------------
fetch_iso() {
    command -v curl >/dev/null || die "curl required"
    if have_iso; then say "iso: cached"; return; fi
    note "iso: downloading $ISO_NAME"
    curl -fsSL -o "$ISO_CACHE/sha256sum.txt" "$SUMS_URL" \
        || die "cannot fetch Mint checksums ($SUMS_URL)"
    curl -fL --progress-bar -o "$ISO_CACHE/$ISO_NAME.part" "$ISO_URL"
    mv "$ISO_CACHE/$ISO_NAME.part" "$ISO_CACHE/$ISO_NAME"
    ( cd "$ISO_CACHE" && grep -F "$ISO_NAME" sha256sum.txt | sha256sum -c - ) \
        || { rm -f "$ISO_CACHE/$ISO_NAME"; die "ISO checksum FAILED"; }
}

fetch_apt() {
    command -v curl dpkg-scanpackages >/dev/null \
        || die "curl + dpkg-scanpackages (dpkg-dev) required"
    note "apt: resolving guest package closure (empty-status print-uris)"
    local scratch; scratch="$(mktemp -d)"
    mkdir -p "$scratch/lists/partial" "$scratch/cache/archives/partial"
    # per-user lists dir: the resolve needs fresh indexes without sudo
    apt-get update -qq \
        -o Dir::State::Lists="$scratch/lists" \
        -o Dir::Cache="$scratch/cache"
    # pseudo-status = exactly what the installed guest already has.
    # Best source: filesystem.manifest inside the cached ISO (the real
    # squashfs baseline — verified: ~490-deb closure vs ~900 without it).
    # Fallback: mark only Essential/required/important as installed.
    # A fully empty status would drag the base system into the bundle;
    # the host's real status would silently drop packages the host
    # already has (podman etc.) out of the guest's closure.
    local fsm="$scratch/fsm"; mkdir -p "$fsm"
    if xorriso -osirrox on -indev "$ISO_CACHE/$ISO_NAME" \
        -extract /casper/filesystem.manifest "$fsm/filesystem.manifest" \
        >/dev/null 2>&1 && [ -s "$fsm/filesystem.manifest" ]; then
        awk -F'\t' '{p=$1; a="amd64";
            if (p ~ /:/) {split(p,b,":"); p=b[1]; a=b[2]}
            printf "Package: %s\nStatus: install ok installed\nVersion: %s\nArchitecture: %s\n\n",p,$2,a}' \
            "$fsm/filesystem.manifest" > "$scratch/status"
        say "apt: pseudo-status from ISO filesystem.manifest ($(grep -c '^Package:' "$scratch/status") pkgs)"
    else
        say "apt: no ISO manifest — falling back to essential-only status"
        cat "$scratch"/lists/*_Packages | awk '
            /^Package: /{p=$2} /^Version: /{v=$2} /^Essential: /{e=$2}
            /^Priority: /{pr=$2} /^Architecture: /{a=$2} /^Multi-Arch: /{m=$2}
            /^$/ { if(e=="yes"||pr=="required"||pr=="important") {
                printf "Package: %s\nStatus: install ok installed\nVersion: %s\nArchitecture: %s\n",p,v,a;
                if(m!="") printf "Multi-Arch: %s\n",m; printf "\n" }
              e="";pr="";a="";m="" }' > "$scratch/status"
    fi
    local cod_deb=""
    cod_deb="$(compgen -G "$CACHE/pkgs/codium_*.deb" || true)"
    {
        apt-get install --print-uris -y \
            -o Dir::State::Lists="$scratch/lists" \
            -o Dir::Cache="$scratch/cache" \
            -o Dir::State::Status="$scratch/status" \
            "${GUEST_PKGS[@]}"
        [ -z "$cod_deb" ] || apt-get install --print-uris -y \
            -o Dir::State::Lists="$scratch/lists" \
            -o Dir::Cache="$scratch/cache" \
            -o Dir::State::Status="$scratch/status" \
            "$CACHE/pkgs/$(basename "$cod_deb")"
    } | grep -oE "'[^']+' [^ ]+_(amd64|all)\.deb" \
      | tr -d "'" > "$scratch/uris"
    local n; n=$(wc -l < "$scratch/uris")
    note "apt: fetching $n debs"
    local fail=0 url fn
    while read -r url fn; do
        [ -f "$CACHE/apt/$fn" ] && continue
        curl -fsSL -o "$CACHE/apt/$fn" "$url" \
            || { say "MISS: $fn"; fail=1; }
    done < "$scratch/uris"
    rm -rf "$scratch"
    [ "$fail" = 0 ] || die "apt layer incomplete — $n debs resolved, some fetches failed"
    ( cd "$CACHE/apt" && dpkg-scanpackages . /dev/null 2>/dev/null | gzip -9 > Packages.gz )
    have_apt || die "apt bundle produced no debs"
}

fetch_images() {
    command -v podman >/dev/null || die "podman required (host-side image bake)"
    # the mcp ctx consumes the wheelhouse + sdist configs — fetched by
    # the wheels/pkgs layers, which precede images in the ordered run
    [ -n "$GNOSISLAB_VER" ] || die "cannot read gnosislab pin from create-lab-template"
    compgen -G "$CACHE/wheels/gnosislab/gnosislab-${GNOSISLAB_VER}-*.whl" >/dev/null \
        && [ -f "$CACHE/pkgs/gnosislab/ports.env" ] \
        || die "gnosislab==$GNOSISLAB_VER artifacts missing — warm wheels+pkgs first"
    # free space first — the two tarballs run ~1-3 GB
    local avail; avail=$(df -BG --output=avail "$CACHE" | tail -1 | tr -dc 0-9)
    [ "$avail" -ge "$MIN_FREE_GIB" ] \
        || die "only ${avail}GiB free under $CACHE (need $MIN_FREE_GIB)"
    note "images: staging gnosislab==$GNOSISLAB_VER ctx (wheelhouse + configs)"
    local ctx; ctx="$(mktemp -d)"
    mkdir -p "$ctx/mcp/pkgs/wheels" "$ctx/mcp/pkgs/gnosislab"
    cp -a "$CACHE/wheels/gnosislab/." "$ctx/mcp/pkgs/wheels/"
    cp -a "$CACHE/pkgs/gnosislab/." "$ctx/mcp/pkgs/gnosislab/"
    cp "$REPO/containers/mcp/Containerfile" \
       "$REPO/containers/mcp/entrypoint.sh" "$ctx/mcp/"
    note "images: podman build lab-img-mcp (offline wheelhouse) + lab-img-exp"
    podman build -t lab-img-mcp \
        --build-arg "GNOSISLAB_VERSION=$GNOSISLAB_VER" \
        --build-arg OFFLINE=1 \
        -f "$ctx/mcp/Containerfile" "$ctx/mcp"
    podman build -t lab-img-exp "$REPO/containers/experiment"
    # tarball suffixes carry honest provenance: mcp is pinned by package
    # version (a pinned release is clean by definition — no dirty flag
    # exists for it); exp is built from this repo and keeps its git stamp
    local mcp_rev="gnosislab-$GNOSISLAB_VER" exp_rev
    exp_rev=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo nogit)
    [ -z "$(git -C "$REPO" status --porcelain 2>/dev/null | head -1)" ] \
        || exp_rev="$exp_rev-dirty"
    note "images: saving -> $CACHE/images (mcp $mcp_rev, exp $exp_rev)"
    podman save --format docker-archive \
        -o "$CACHE/images/lab-img-mcp-$mcp_rev.tar" lab-img-mcp
    podman save --format docker-archive \
        -o "$CACHE/images/lab-img-exp-$exp_rev.tar" lab-img-exp
    # drop tarballs of superseded revs — each pair is multi-GB
    find "$CACHE/images" -name 'lab-img-mcp-*.tar' ! -name "*-$mcp_rev.tar" -delete
    find "$CACHE/images" -name 'lab-img-exp-*.tar' ! -name "*-$exp_rev.tar" -delete
    rm -rf "$ctx"
}

# Reuse pip's HTTP cache between containers, allow slow CDN reads,
# and retry transient failures. Never discard complete artifacts first.
pip_download() {
    local output=$1; shift
    mkdir -p "$output" "$CACHE/pip-http"
    podman run --rm -v "$output:/out:z" \
        -v "$CACHE/pip-http:/pip-cache:z" -e PIP_CACHE_DIR=/pip-cache \
        docker.io/library/python:3.12-slim \
        pip --disable-pip-version-check --timeout 120 --retries 8 \
        download -d /out "$@"
}

fetch_wheels() {
    command -v podman >/dev/null || die "podman required"
    note "wheels: trial-env + uvx closures (cached pip, 120s timeout, 8 retries)"
    pip_download "$CACHE/wheels/trial-env" $TRIAL_PKGS
    pip_download "$CACHE/wheels/uvx" $UVX_PKGS
    have_wheels || die "wheel layer incomplete"
}

# Stage downloads and verify before replacing the installed cache.
# Failed downloads preserve the previously validated wheelhouse/sdist.
fetch_gnosislab() (
    command -v podman python3 curl >/dev/null || die "podman + python3 + curl required"
    if [ "$MODE" = ensure ] && [ -z "$ONLY" ] \
       && compgen -G "$CACHE/wheels/gnosislab/gnosislab-${GNOSISLAB_VER}-*.whl" >/dev/null \
       && compgen -G "$CACHE/wheels/gnosislab/uv-*.whl" >/dev/null \
       && [ -s "$CACHE/pkgs/gnosislab-${GNOSISLAB_VER}.tar.gz" ] \
       && [ -s "$CACHE/pkgs/gnosislab/ports.env" ] \
       && verify_manifest; then
        say "gnosislab==$GNOSISLAB_VER: verified cache reused"
        exit 0
    fi
    note "gnosislab==$GNOSISLAB_VER: staged wheel closure + sdist"
    local stage gmeta gurl gsha actual config_dir
    stage=$(mktemp -d "$CACHE/.gnosislab-prefetch.XXXXXXXX")
    trap 'rm -rf "$stage"' EXIT
    mkdir -p "$stage/wheels" "$stage/config" "$stage/extract"
    pip_download "$stage/wheels" "gnosislab==$GNOSISLAB_VER" uv \
        || die "PyPI wheel fetch failed after retries; existing cache preserved"
    compgen -G "$stage/wheels/gnosislab-${GNOSISLAB_VER}-*.whl" >/dev/null \
        || die "wheel closure missing gnosislab==$GNOSISLAB_VER"
    compgen -G "$stage/wheels/uv-*.whl" >/dev/null \
        || die "wheel closure missing uv"
    gmeta=$(curl -fsSL --connect-timeout 15 --max-time 120 \
        --retry 5 --retry-delay 2 --retry-all-errors \
        "https://pypi.org/pypi/gnosislab/$GNOSISLAB_VER/json") \
        || die "sdist metadata fetch failed; existing cache preserved"
    read -r gurl gsha < <(printf '%s' "$gmeta" | python3 -c '
import json, sys
item=next((u for u in json.load(sys.stdin)["urls"] if u["packagetype"]=="sdist"), None)
if item: print(item["url"], item["digests"]["sha256"])
')
    [ -n "$gurl" ] && [ -n "$gsha" ] || die "sdist metadata incomplete"
    curl -fL --connect-timeout 15 --max-time 900 \
        --retry 8 --retry-delay 2 --retry-all-errors \
        -o "$stage/source.tar.gz" "$gurl" \
        || die "sdist download failed; existing cache preserved"
    actual=$(sha256sum "$stage/source.tar.gz" | cut -d' ' -f1)
    [ "$actual" = "$gsha" ] || die "GnosisLab sdist SHA256 mismatch"
    tar -xzf "$stage/source.tar.gz" -C "$stage/extract" \
        || die "sdist extraction failed; existing cache preserved"
    cp "$stage"/extract/gnosislab-*/ports.env \
       "$stage"/extract/gnosislab-*/ml-*.toml "$stage/config/" \
       || die "sdist missing required config"
    for config_dir in "$stage"/extract/gnosislab-*/diagnostics; do
        [ -d "$config_dir" ] || continue
        cp -a "$config_dir" "$stage/config/"
    done
    # Only switch the cache after all network operations and validations.
    # Backups are kept in staging until every new directory is installed.
    local published=0
    rollback() {
        if [ "$published" != 1 ]; then
            if [ -d "$stage/previous-wheels" ]; then
                rm -rf "$CACHE/wheels/gnosislab"
                mv "$stage/previous-wheels" "$CACHE/wheels/gnosislab"
            fi
            if [ -d "$stage/previous-config" ]; then
                rm -rf "$CACHE/pkgs/gnosislab"
                mv "$stage/previous-config" "$CACHE/pkgs/gnosislab"
            fi
        fi
        rm -rf "$stage"
    }
    trap rollback EXIT
    mv "$CACHE/wheels/gnosislab" "$stage/previous-wheels"
    mv "$stage/wheels" "$CACHE/wheels/gnosislab"
    mv "$CACHE/pkgs/gnosislab" "$stage/previous-config"
    mv "$stage/config" "$CACHE/pkgs/gnosislab"
    mv "$stage/source.tar.gz" "$CACHE/pkgs/gnosislab-$GNOSISLAB_VER.tar.gz"
    published=1
    find "$CACHE/pkgs" -maxdepth 1 -name 'gnosislab-*.tar.gz' \
        ! -name "gnosislab-$GNOSISLAB_VER.tar.gz" -delete
    say "gnosislab==$GNOSISLAB_VER: validated artifacts published"
)

fetch_pkgs() {
    command -v curl npm python3 >/dev/null || die "curl + npm + python3 required"
    note "pkgs: opencode tarball, codium deb, vsix extensions"
    # the launcher package is a 2 KB postinstall shim whose real
    # payload is a per-platform optionalDependency (still a registry
    # fetch even from the tgz) — so we pack the linux-x64 tarballs
    # directly and the guest installs package/bin/opencode straight to
    # /usr/local/bin, choosing baseline vs regular by /proc/cpuinfo
    # exactly like the package's postinstall.mjs. OC_VER comes from
    # create-lab-template's npm pin (single source of truth).
    [ -n "$OC_VER" ] || die "cannot read opencode pin from create-lab-template"
    ( cd "$CACHE/pkgs" && npm pack "@opencode/cli@$OC_VER" --silent >/dev/null \
        && npm pack "@opencode/cli-linux-x64@$OC_VER" --silent >/dev/null \
        && npm pack "@opencode/cli-linux-x64-baseline@$OC_VER" --silent >/dev/null )
    # superseded-version tarballs are dead weight (~88 MB each) and
    # would let a stale glob match satisfy the pin — drop them
    find "$CACHE/pkgs" -name 'opencode-cli*.tgz' \
        ! -name "*-${OC_VER}.tgz" -delete
    # codium: latest GitHub release amd64 .deb (replaces the gitlab apt repo)
    local rel url
    rel=$(curl -fsSL https://api.github.com/repos/VSCodium/vscodium/releases/latest)
    url=$(printf '%s' "$rel" | grep -oE '"browser_download_url": *"[^"]*_amd64\.deb"' \
          | grep -oE 'https:[^"]*' | head -1)
    [ -n "$url" ] || die "no amd64 .deb in latest VSCodium release"
    curl -fL --progress-bar -o "$CACHE/pkgs/$(basename "$url")" "$url"
    # vsix: open-vsx download endpoint per extension
    local ext ns name j u
    for ext in $VSIX_EXTS; do
        ns="${ext%%.*}"; name="${ext#*.}"
        j=$(curl -fsSL "https://open-vsx.org/api/$ns/$name") \
            || die "open-vsx: $ext metadata fetch failed"
        u=$(printf '%s' "$j" | grep -oE '"download"[^,}]*' \
            | grep -oE 'https:[^"]*' | head -1)
        [ -n "$u" ] || die "open-vsx: no download URL for $ext"
        curl -fsSL -o "$CACHE/pkgs/$(basename "$u")" "$u"
    done
    have_pkgs || die "pkgs layer incomplete"
}

# ------------------------------------------------------------------
# status + driver
# ------------------------------------------------------------------
status_line() {  # layer -> "ok" | "stale" | "missing"
    local l=$1
    "have_$l" || { echo missing; return; }
    # iso is hash-verified at use; staleness does not apply
    if [ "$l" != iso ] && ! fresh "${LAYER_DIR[$l]}"; then echo stale; return; fi
    echo ok
}

report() {
    echo "    artifact cache: $CACHE"
    for l in "${LAYERS[@]}"; do
        printf '    %-8s %s\n' "$l" "$(status_line "$l")"
    done
    verify_manifest && echo "    manifest: all hashes ok"
}

note "preflight: labloop artifact cache ($MODE$([ "$OFFLINE" = 1 ] && echo ', OFFLINE'))"
report

needs_fetch=()
if [ -n "$ONLY" ]; then
    case " ${LAYERS[*]} " in *" $ONLY "*) ;; *) die "no such layer '$ONLY'" ;; esac
    needs_fetch=("$ONLY")
else
    for l in "${LAYERS[@]}"; do
        s=$(status_line "$l")
        # Cache age is advisory in --ensure; only missing/pin-changed
        # artifacts require network access. --refresh opts into updates.
        if [ "$MODE" = refresh ] || [ "$s" = missing ] \
             || { [ "$s" = stale ] && [ "${LABLOOP_CACHE_REFRESH_STALE:-0}" = 1 ]; }; then
            [ "$s" = stale ] && say "$l: stale; explicitly refreshing"
            needs_fetch+=("$l")
        elif [ "$s" = stale ]; then
            say "$l: cached and complete (aged; use --refresh to update)"
        fi
    done
fi

if ((${#needs_fetch[@]})); then
    # hard gaps = missing/corrupt; stale is soft (usable when offline)
    hard=()
    for l in "${needs_fetch[@]}"; do
        [ "$(status_line "$l")" = stale ] || hard+=("$l")
    done
    if [ "$OFFLINE" = 1 ]; then
        ((${#hard[@]})) && {
            printf '    GAPS: %s\n' "${hard[*]}" >&2
            die "offline build but cache incomplete — cannot proceed"
        }
        say "WARN: stale layers kept (offline, nothing better to fetch): ${needs_fetch[*]}"
        needs_fetch=()
    elif [ "$MODE" = verify ]; then
        printf '    GAPS: %s\n' "${needs_fetch[*]}" >&2
        die "cache incomplete — warm it with ./selfbuild/prefetch-cache.sh"
    fi
fi

# gnosislab is TTL=0 — refreshed on every online ensure/refresh run
# (not only when its layer looks stale), before fetch_images bakes the
# mcp image against the wheelhouse. --verify never fetches; OFFLINE
# keeps whatever is cached.
if [ "$OFFLINE" != 1 ] && [ "$MODE" != verify ] \
    && { [ -z "$ONLY" ] || [ "$ONLY" = wheels ] || [ "$ONLY" = pkgs ]; }; then
    fetch_gnosislab
    manifest_regen
fi

if ((${#needs_fetch[@]})); then
    # pkgs first: the apt closure step reads pkgs/codium_*.deb for
    # codium's own dependency list. wheels before images: the mcp bake
    # consumes wheels/gnosislab + pkgs/gnosislab.
    ordered=()
    for l in pkgs iso apt wheels images; do
        case " ${needs_fetch[*]} " in *" $l "*) ordered+=("$l");; esac
    done
    for l in "${ordered[@]}"; do "fetch_$l"; done
    manifest_regen
    note "re-verify after prefetch"
    report
fi

for l in ${ONLY:-${LAYERS[*]}}; do
    s=$(status_line "$l")
    case "$s" in
        ok) ;;
        stale) say "WARN: $l stale but kept (offline — nothing better exists)" ;;
        *) die "layer '$l' still incomplete after prefetch" ;;
    esac
done
verify_manifest || die "manifest hash mismatch"

if [ -n "$ONLY" ]; then
    echo "    preflight: layer '$ONLY' ok"
else
    echo "    preflight: ${#LAYERS[@]}/${#LAYERS[@]} layers ok"
fi
