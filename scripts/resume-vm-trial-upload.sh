#!/usr/bin/env bash
# Resume upload of an already-sealed, already-compressed QCOW2.
# Does NOT reseal, convert or rebuild an image.
# Usage: scripts/resume-vm-trial-upload.sh dist/<image>.qcow2 [bucket]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
die() { echo "resume-upload: $*" >&2; exit 1; }
[ "$#" -ge 1 ] && [ "$#" -le 2 ] || die "usage: $0 <image.qcow2> [hf-bucket]"
IMAGE="$1"
BUCKET="hf://buckets/LabLoopCommunity/lab-trials"
[ "$#" -eq 1 ] || BUCKET="$2"
[[ "$BUCKET" == hf://buckets/* ]] || die "invalid bucket URI"
[[ "$IMAGE" == *.qcow2 ]] || die "expected QCOW2 file"
[ -f "$IMAGE" ] || die "missing QCOW2 image: $IMAGE"
IMAGE="$(realpath "$IMAGE")"
SIDECAR="$IMAGE.sha256"
MANIFEST="$IMAGE.provenance.json"
[ -f "$SIDECAR" ] || die "missing checksum sidecar"
[ -f "$MANIFEST" ] || die "missing provenance manifest; generate and sign it before uploading"
echo "==> verifying local image, checksum and provenance"
(cd "$(dirname "$IMAGE")" && sha256sum --check --status "$(basename "$SIDECAR")") \
  || die "QCOW2 checksum mismatch, refusing upload"
python3 scripts/vm_publication_attestation.py provenance-check "$SIDECAR" \
  --provenance "$MANIFEST" || die "invalid provenance manifest"
HF="$(command -v hf || true)"
[ -z "${HF_CLI:-}" ] || HF="${HF_CLI}"
if [ -z "$HF" ]; then
  HF="$HOME/.cache/labloop-hfenv/bin/hf"
fi
[ -x "$HF" ] || die "HF CLI missing; install it or set HF_CLI"
"$HF" auth whoami >/dev/null 2>&1 || die "HF CLI not authenticated"
case "${VM_ATTESTATION:-required}" in
  required|"")
    echo "==> verifying existing signed GitHub publication"
    python3 scripts/vm_publication_attestation.py verify "$SIDECAR" \
        --image-name "$(basename "$IMAGE")" --provenance "$MANIFEST" \
      || die "no valid attestation for this image/sidecar; do not upload"
    ;;
  skip)
    echo "==> UNATTESTED COMMUNITY UPLOAD: signature check explicitly skipped"
    ;;
  *) die "VM_ATTESTATION must be required or skip" ;;
esac
echo
echo "==> image: $(basename "$IMAGE")"
echo "==> bucket: $BUCKET"
read -r -p "    upload this verified image and checksum? [y/N] " answer
case "$answer" in [Yy]*) ;; *) die "cancelled";; esac
"$HF" buckets cp "$IMAGE" "$BUCKET/$(basename "$IMAGE")"
"$HF" buckets cp "$SIDECAR" "$BUCKET/$(basename "$SIDECAR")"
"$HF" buckets cp "$MANIFEST" "$BUCKET/$(basename "$MANIFEST")"
echo "==> uploaded $(basename "$IMAGE") its checksum and signed provenance manifest to $BUCKET"
