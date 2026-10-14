#!/usr/bin/env bash
# 11-release-template.sh — release a template image: move one
# *.qcow2 + its .sha256 sidecar from the private trials bucket to the
# public release bucket.
#
#   ./11-release-template.sh [image-name] [--keep]
#   ./11-release-template.sh --backfill <already-released-image.qcow2>
#     Sign and upload provenance for an existing official release,
#     using its locally retained QCOW2 without transferring it again.
#
# With no image name, lists the *.qcow2 objects in the source bucket
# and shows a numbered menu. "Move" = copy both objects to the
# destination, verify they landed, then remove them from the source
# (--keep copies without deleting).
#
# Requires: hf CLI authenticated with read+write on both buckets.
#
# env:   SRC_BUCKET=...   default hf://buckets/LabLoopCommunity/lab-trials
#        DST_BUCKET=...   default hf://buckets/cloudcell/LabLoop
#        HF_CLI=...       path to hf binary if not on PATH
#        VM_ATTESTATION=required (default), skip only for non-Cloudcell destinations
set -euo pipefail
cd "$(dirname "$0")"

SRC="${SRC_BUCKET:-hf://buckets/LabLoopCommunity/lab-trials}"
DST="${DST_BUCKET:-hf://buckets/cloudcell/LabLoop}"
KEEP=0
BACKFILL=0
NAME=""

die()  { echo "11-release: $*" >&2; exit 1; }
note() { echo; echo "==> $*"; }

for a in "$@"; do
    case "$a" in
        --keep|-k) KEEP=1 ;;
        --backfill) BACKFILL=1 ;;
        -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
        *.qcow2)   NAME="$a" ;;
        *) die "unknown argument: $a" ;;
    esac
done

# ------------------------------------------------------------------
# hf CLI — PATH, HF_CLI override, or the private venv script 10 uses
HF="${HF_CLI:-}"
[ -z "$HF" ] && HF="$(command -v hf || true)"
if [ -z "$HF" ]; then
    HFENV="$HOME/.cache/labloop-hfenv"
    [ -x "$HFENV/bin/hf" ] || {
        note "bootstrapping hf CLI into $HFENV"
        python3 -m venv "$HFENV"
        "$HFENV/bin/pip" -q install -U huggingface_hub
    }
    HF="$HFENV/bin/hf"
fi
"$HF" auth whoami >/dev/null 2>&1 \
    || die "not logged in — run: $HF auth login"
WHO="$("$HF" auth whoami 2>/dev/null | sed -n 's/.*user:[[:space:]]*//p' | head -n1)"
[ -n "$WHO" ] || WHO="the authenticated hf account"

bucket_files() {  # bare object names in a bucket, one per line
    "$HF" buckets ls "$1" 2>/dev/null \
        | grep -oE '[^[:space:]]+\.(qcow2|sha256|json)' | sort -u
}

# Backfill an already-public legacy release without re-exporting, sealing
# or uploading the QCOW2. Never silently invent a GnosisLab version.
if [ "$BACKFILL" -eq 1 ]; then
    [ "$KEEP" -eq 0 ] || die "--backfill cannot be combined with --keep"
    [ -n "$NAME" ] || die "usage: $0 --backfill existing-image.qcow2"
    [ "$DST" = "hf://buckets/cloudcell/LabLoop" ] \
        || die "--backfill only supports the official public Cloudcell bucket"
    [ "${VM_ATTESTATION:-required}" = required ] \
        || die "--backfill requires GitHub signature verification"
    LOCAL="$PWD/dist/$NAME"
    SIDECAR="$LOCAL.sha256"
    MANIFEST="$LOCAL.provenance.json"
    [ -f "$LOCAL" ] && [ -f "$SIDECAR" ] \
        || die "backfill requires existing dist/$NAME and its .sha256 on this host"
    note "verifying existing local published image"
    (cd "$PWD/dist" && sha256sum --check --status "$NAME.sha256") \
        || die "local QCOW2 differs from its checksum"

    dst_files="$(bucket_files "$DST")"
    grep -qxF "$NAME" <<<"$dst_files" \
        || die "$NAME is not present in the official public bucket"
    grep -qxF "$NAME.sha256" <<<"$dst_files" \
        || die "$NAME.sha256 is missing from the official public bucket"
    remote_tmp="$(mktemp -d)"
    trap 'rm -rf "$remote_tmp"' EXIT
    "$HF" buckets cp "$DST/$NAME.sha256" "$remote_tmp/$NAME.sha256" \
        || die "cannot retrieve published checksum"
    cmp -s "$SIDECAR" "$remote_tmp/$NAME.sha256" \
        || die "published checksum differs from local checksum; refusing backfill"
    rm -rf "$remote_tmp"
    trap - EXIT

    if [ ! -f "$MANIFEST" ]; then
        IMAGE_VM="${NAME%-????????T????Z.qcow2}"
        BUILD_INFO="$PWD/dist/$IMAGE_VM.build-info.json"
        if [ -f "$BUILD_INFO" ]; then
            python3 scripts/vm_publication_attestation.py provenance-create \
                "$SIDECAR" --build-info "$BUILD_INFO" \
                || die "invalid completed template build record"
        else
            [ -n "${GNOSISLAB_VER:-}" ] \
                || die "legacy release has no build record; set GNOSISLAB_VER to its known version"
            python3 scripts/vm_publication_attestation.py provenance-create \
                "$SIDECAR" --gnosislab-version "$GNOSISLAB_VER" \
                || die "cannot create declared provenance"
        fi
    fi
    python3 scripts/vm_publication_attestation.py provenance-check \
        "$SIDECAR" --provenance "$MANIFEST" \
        || die "provenance does not match the original image and sidecar"

    if ! python3 scripts/vm_publication_attestation.py verify \
         "$SIDECAR" --image-name "$NAME" --provenance "$MANIFEST" >/dev/null 2>&1; then
        note "requesting signed provenance for already-published image"
        python3 scripts/vm_publication_attestation.py request \
            "$LOCAL" "$SIDECAR" --provenance "$MANIFEST" \
            || die "GitHub attestation refused; nothing changed in the public bucket"
    fi

    if grep -qxF "$NAME.provenance.json" <<<"$dst_files"; then
        remote_tmp="$(mktemp -d)"
        trap 'rm -rf "$remote_tmp"' EXIT
        "$HF" buckets cp "$DST/$NAME.provenance.json" "$remote_tmp/$NAME.provenance.json"
        cmp -s "$MANIFEST" "$remote_tmp/$NAME.provenance.json" \
            || die "remote provenance already exists and differs; refusing overwrite"
        rm -rf "$remote_tmp"
        trap - EXIT
        echo "==> provenance already present and identical in $DST"
        exit 0
    fi
    note "publishing signed JSON provenance only (no QCOW2 transfer)"
    note "image: $NAME"
    read -rp "    add signed provenance to $DST? [y/N] " a
    case "$a" in [Yy]*) ;; *) die "aborted";; esac
    "$HF" buckets cp "$MANIFEST" "$DST/$NAME.provenance.json" \
        || die "JSON provenance upload failed"
    bucket_files "$DST" | grep -qxF "$NAME.provenance.json" \
        || die "JSON provenance not visible in destination"
    echo "==> signed JSON provenance published; QCOW2 and checksum unchanged"
    exit 0
fi

# ------------------------------------------------------------------
# pick the image — argument wins; otherwise a numbered menu
note "listing $SRC"
mapfile -t images < <(bucket_files "$SRC" | grep '\.qcow2$' || true)
[ "${#images[@]}" -gt 0 ] || die "no *.qcow2 objects in $SRC"

if [ -z "$NAME" ]; then
    echo
    i=1
    for f in "${images[@]}"; do printf "    %d) %s\n" "$i" "$f"; i=$((i+1)); done
    read -rp "    release which image? [1-${#images[@]}] " sel
    [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "${#images[@]}" ] \
        || die "bad selection"
    NAME="${images[$((sel-1))]}"
fi
grep -qxF "$NAME" <(printf '%s\n' "${images[@]}") \
    || die "$NAME not found in $SRC"

SHA="$NAME.sha256"
PROVENANCE="$NAME.provenance.json"
VM_ATTESTATION="${VM_ATTESTATION:-required}"
case "$VM_ATTESTATION" in
    required|skip) ;;
    *) die "VM_ATTESTATION must be required or skip" ;;
esac
# No release, including opt-out community releases, without checksums
# and the human-readable signed publication manifest.
bucket_files "$SRC" | grep -qxF "$SHA" \
    || die "source is missing $SHA; refusing unchecked release"
have_sha=1
bucket_files "$SRC" | grep -qxF "$PROVENANCE" \
    || die "source is missing signed provenance manifest $PROVENANCE"
# The official Cloudcell public bucket is always signed, even if skip was
# accidentally exported in the shell. Independent destinations can opt out.
if [ "$DST" = "hf://buckets/cloudcell/LabLoop" ] && [ "$VM_ATTESTATION" = skip ]; then
    die "cannot skip signed verification for the official Cloudcell release bucket"
fi

# Download and verify only the small checksum sidecar, not the VM image.
# The signed statement binds both the checksum file and image digest.
if [ "$VM_ATTESTATION" = required ]; then
    attest_dir="$(mktemp -d)"
    trap 'rm -rf "$attest_dir"' EXIT
    note "verifying signed GitHub publication declaration"
    "$HF" buckets cp "$SRC/$SHA" "$attest_dir/$SHA" \
        || die "could not download checksum sidecar for attestation"
    "$HF" buckets cp "$SRC/$PROVENANCE" "$attest_dir/$PROVENANCE" \
        || die "could not download provenance manifest"
    python3 scripts/vm_publication_attestation.py verify "$attest_dir/$SHA" \
        --image-name "$NAME" --provenance "$attest_dir/$PROVENANCE" \
        || die "no valid Cloudcell GitHub publication attestation; release refused"
    rm -rf "$attest_dir"
    trap - EXIT
else
    echo "    UNATTESTED COMMUNITY RELEASE: signature verification skipped explicitly"
    attest_dir="$(mktemp -d)"
    trap 'rm -rf "$attest_dir"' EXIT
    "$HF" buckets cp "$SRC/$SHA" "$attest_dir/$SHA"
    "$HF" buckets cp "$SRC/$PROVENANCE" "$attest_dir/$PROVENANCE"
    python3 scripts/vm_publication_attestation.py provenance-check \
        "$attest_dir/$SHA" --provenance "$attest_dir/$PROVENANCE" \
        || die "unsigned provenance metadata is inconsistent with checksum"
    rm -rf "$attest_dir"
    trap - EXIT
fi

# ------------------------------------------------------------------
# release is opt-in, every time — default answer is NO
note "image:     $NAME$([ "$have_sha" -eq 1 ] && echo " (+ .sha256)" || echo " (no checksum!)")"
note "account:   $WHO"
note "from:      $SRC"
note "to:        $DST"
[ "$KEEP" -eq 1 ] && note "mode:      copy (source kept)" || note "mode:      move (source deleted after copy)"
read -rp "    release $NAME to $DST? [y/N] " a
case "$a" in [Yy]*) ;; *) die "aborted — nothing released";; esac

# destination bucket must exist — create it if it doesn't
if ! "$HF" buckets info "${DST#hf://buckets/}" >/dev/null 2>&1; then
    read -rp "    bucket $DST does not exist — create it? [y/N] " a
    case "$a" in [Yy]*) ;; *) die "aborted";; esac
    "$HF" buckets create "${DST#hf://buckets/}"
fi

# ------------------------------------------------------------------
# copy — try bucket->bucket first; fall back to a temp round-trip
copy_obj() {  # $1=object name
    if "$HF" buckets cp "$SRC/$1" "$DST/$1" 2>/dev/null; then
        return 0
    fi
    echo "    direct bucket->bucket copy failed for $1 — falling back to download+upload" >&2
    local tmp; tmp="$(mktemp -d)"
    "$HF" buckets cp "$SRC/$1" "$tmp/$1" || { rm -rf "$tmp"; return 1; }
    "$HF" buckets cp "$tmp/$1" "$DST/$1" || { rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
}

note "copying -> $DST"
copy_obj "$NAME"                        || die "copy failed: $NAME"
copy_obj "$SHA" || die "copy failed: $SHA"
copy_obj "$PROVENANCE" || die "copy failed: $PROVENANCE"

# verify both objects are present in the destination
note "verifying"
dst_files="$(bucket_files "$DST")"
grep -qxF "$NAME" <<<"$dst_files" || die "$NAME did not land in $DST"
if [ "$have_sha" -eq 1 ]; then
    grep -qxF "$SHA" <<<"$dst_files" || die "$SHA did not land in $DST"
fi
grep -qxF "$PROVENANCE" <<<"$dst_files" \
    || die "$PROVENANCE did not land in $DST"
echo "    present in $DST: $NAME + $SHA + $PROVENANCE"

# ------------------------------------------------------------------
if [ "$KEEP" -eq 0 ]; then
    note "removing from $SRC"
    "$HF" buckets rm "$SRC/$NAME" || echo "    WARN: could not remove $NAME from source"
    if [ "$have_sha" -eq 1 ]; then
        "$HF" buckets rm "$SRC/$SHA" || echo "    WARN: could not remove $SHA from source"
    fi
    "$HF" buckets rm "$SRC/$PROVENANCE" \
        || echo "    WARN: could not remove $PROVENANCE from source"
fi

cat <<EOF

==> released: $DST/$NAME

    recipients:
      hf buckets cp $DST/$NAME .
      sha256sum -c $NAME.sha256
      python3 scripts/vm_publication_attestation.py verify $NAME.sha256 --provenance $PROVENANCE
      ./20-import-lab-vm.sh $NAME <name>
EOF
