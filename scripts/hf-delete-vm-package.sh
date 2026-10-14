#!/usr/bin/env bash
# Remove exactly one VM image package from a Cloudcell HF bucket.
# No buckets or local files are deleted. No recursive operations.
# Usage: bash hf-delete-vm-package.sh [--dry-run]
set -euo pipefail

usage() {
    cat <<'HELP'
Usage: bash hf-delete-vm-package.sh [--dry-run]
Interactively select the Cloudcell private trials or public release bucket,
then select one QCOW2 image and its .sha256 / .provenance.json sidecars.
--dry-run previews the selected package without deleting anything.
HELP
}
DRY_RUN=0
case "${1:-}" in
    '') ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { usage >&2; exit 2; }

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
HF="${HF_CLI:-$(command -v hf || true)}"
[ -n "$HF" ] && command -v "$HF" >/dev/null 2>&1 || die 'Hugging Face CLI not found (install hf, or set HF_CLI)'
"$HF" auth whoami >/dev/null 2>&1 || die 'Not authenticated. Run: hf auth login'

printf 'Select bucket:\n  1) Private trials  (LabLoopCommunity/lab-trials)\n  2) Public releases (cloudcell/LabLoop)\n  0) Cancel\n'
read -r -p 'Bucket [0-2]: ' choice
case "$choice" in
    1) bucket='hf://buckets/LabLoopCommunity/lab-trials'; kind=PRIVATE ;;
    2) bucket='hf://buckets/cloudcell/LabLoop'; kind=PUBLIC ;;
    0) echo 'Cancelled.'; exit 0 ;;
    *) die 'Invalid bucket selection' ;;
esac
"$HF" buckets info "${bucket#hf://buckets/}" >/dev/null || die 'Bucket unavailable or access denied'

# Extract only safe artifact basenames from HF CLI output. Avoid matching
# arbitrary paths, and never pass wildcard/recursive deletion arguments.
raw="$("$HF" buckets ls "$bucket")" || die 'Bucket listing failed'
mapfile -t images < <(
    printf '%s\n' "$raw" \
        | grep -oE '(^|[[:space:]])[A-Za-z0-9][A-Za-z0-9._-]*\.qcow2([[:space:]]|$)' \
        | tr -d '[:space:]' | sort -u || true
)
[ "${#images[@]}" -gt 0 ] || die 'No root-level QCOW2 packages found in this bucket'
printf '\nAvailable VM packages in %s:\n' "$bucket"
for i in "${!images[@]}"; do printf '  %d) %s\n' "$((i+1))" "${images[$i]}"; done
printf '  0) Cancel\n'
read -r -p 'Package number: ' selected
[ "$selected" != 0 ] || { echo 'Cancelled.'; exit 0; }
[[ "$selected" =~ ^[1-9][0-9]*$ ]] && [ "$selected" -le "${#images[@]}" ] || die 'Invalid selection'
image="${images[$((selected-1))]}"
[[ "$image" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.qcow2$ ]] || die 'Unsafe filename'

# Match complete tokens only. A listed artifact's basename must be exact.
has_file() {
    local escaped="${1//./\\.}"
    grep -Eq "(^|[[:space:]])${escaped}([[:space:]]|$)" <<<"$raw"
}
objects=("$image")
for suffix in .sha256 .provenance.json; do
    if has_file "$image$suffix"; then objects+=("$image$suffix"); fi
done
printf '\n%s bucket: %s\nThese objects will be permanently deleted:\n' "$kind" "$bucket"
printf '  %s\n' "${objects[@]}"
printf 'Local files and the bucket itself are NOT affected.\n'
if [ "$DRY_RUN" -eq 1 ]; then echo 'DRY RUN: nothing deleted.'; exit 0; fi
printf '\nDeletion is irreversible. Public links may stop working.\n'
read -r -p "To confirm, type exactly DELETE $kind $image: " confirmation
[ "$confirmation" = "DELETE $kind $image" ] || die 'Confirmation does not match; nothing deleted'

# Remove the image first; preserve verification sidecars if that fails.
# --yes disables a *second* prompt inside hf, after our precise confirmation.
# Hugging Face documents --yes for 'hf buckets rm'.
for object in "${objects[@]}"; do
    printf '\nRemoving %s ...\n' "$object"
    "$HF" buckets rm "$bucket/$object" --yes \
        || die "Removal failed at $object; subsequent objects were left untouched"
done
post="$("$HF" buckets ls "$bucket")" || die 'Deletion performed but unable to verify bucket listing'
for object in "${objects[@]}"; do
    escaped="${object//./\.}"
    if grep -Eq "(^|[[:space:]])${escaped}([[:space:]]|$)" <<<"$post"; then
        die "Object still appears in bucket: $object"
    fi
done
printf '\nDeleted package %s and %d sidecar(s) from %s.\n' "$image" "$((${#objects[@]}-1))" "$bucket"
