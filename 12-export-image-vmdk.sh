#!/usr/bin/env bash
# 12-export-image-vmdk.sh <image.qcow2> [--ova] [--out DIR]
#
# Repackages a sealed lab qcow2 for hypervisors where the KVM/libvirt
# pipeline (00-02, 20) does not run: VirtualBox, VMware, UTM.
#
# Default: writes <name>.vmdk (+ .sha256) — attach it to a new
# "Ubuntu (64-bit)" VM with EFI enabled.
# With --ova: also writes <name>.ova (+ .sha256), a streamOptimized
# VMDK plus a generated OVF descriptor tarred together — VirtualBox
# and VMware import it natively (File -> Import Appliance).
#
# Only requirement: qemu-img (package qemu-utils) — already present on
# any KVM build host. tar and sha256sum are coreutils.
#
# usage: ./12-export-image-vmdk.sh dist/lab-template-*.qcow2 [--ova] [--out DIR]
set -euo pipefail

die()  { echo "12-export: $*" >&2; exit 1; }
note() { echo; echo "==> $*"; }

SRC=""; OVA=0; OUT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --ova)  OVA=1 ;;
        --out)  shift; OUT="${1:-}"; [ -n "$OUT" ] || die "--out needs a directory" ;;
        -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
        -*) die "unknown argument: $1" ;;
        *)  [ -z "$SRC" ] || die "one image only"; SRC="$1" ;;
    esac
    shift
done

[ -n "$SRC" ] && [ -f "$SRC" ] \
    || die "usage: $0 <image.qcow2> [--ova] [--out DIR]"
[ -z "$OUT" ] && OUT=$(dirname "$SRC")
[ -d "$OUT" ] || die "no such directory: $OUT"

command -v qemu-img >/dev/null || die "need qemu-img — apt install qemu-utils"
qemu-img info "$SRC" | grep -q 'file format: qcow2' \
    || die "$SRC is not qcow2"

BASE=$(basename "$SRC" .qcow2)
VMDK="$OUT/$BASE.vmdk"

# guest sizing for the OVF descriptor — labloop.conf when reachable,
# else the documented defaults
VCPUS=16; MEMMIB=16384
CONF="$(dirname "$0")/labloop.conf"
[ -f "$CONF" ] && . "$CONF"
VCPUS=${LABLOOP_VCPUS:-$VCPUS}; MEMMIB=${LABLOOP_MEMORY_MIB:-$MEMMIB}

VIRT_BYTES=$(qemu-img info --output=json "$SRC" | grep -oP '"virtual-size":\s*\K[0-9]+' | tail -1)
CAP_GIB=$(( (VIRT_BYTES + 1073741823) / 1073741824 ))

note "convert: $SRC -> $VMDK (sparse VMDK)"
qemu-img convert -p -f qcow2 -O vmdk "$SRC" "$VMDK"
( cd "$OUT" && sha256sum "$(basename "$VMDK")" > "$BASE.vmdk.sha256" )

if [ "$OVA" = 1 ]; then
    note "ova: streamOptimized VMDK + generated OVF"
    WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
    OVMDK="$WORK/$BASE-disk001.vmdk"
    OVF="$WORK/$BASE.ovf"
    qemu-img convert -p -f qcow2 -O vmdk -o subformat=streamOptimized "$SRC" "$OVMDK"

    sed -e "s|@NAME@|$BASE|g" \
        -e "s|@VMDK@|$(basename "$OVMDK")|g" \
        -e "s|@VMDK_BYTES@|$(stat -c%s "$OVMDK")|g" \
        -e "s|@CAP_GIB@|$CAP_GIB|g" \
        -e "s|@VCPUS@|$VCPUS|g" \
        -e "s|@MEM@|$MEMMIB|g" >"$OVF" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<Envelope xmlns="http://schemas.dmtf.org/ovf/envelope/1"
          xmlns:ovf="http://schemas.dmtf.org/ovf/envelope/1"
          xmlns:rasd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_ResourceAllocationSettingData"
          xmlns:vssd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_VirtualSystemSettingData"
          ovf:version="1.0" xml:lang="en-US">
  <References>
    <File ovf:href="@VMDK@" ovf:id="file1" ovf:size="@VMDK_BYTES@"/>
  </References>
  <DiskSection>
    <Info>Virtual disk information</Info>
    <Disk ovf:capacity="@CAP_GIB@" ovf:capacityAllocationUnits="byte * 2^30"
          ovf:diskId="vmdisk1" ovf:fileRef="file1"
          ovf:format="http://www.vmware.com/interfaces/specifications/vmdk.html#streamOptimized"/>
  </DiskSection>
  <VirtualSystem ovf:id="@NAME@">
    <Info>A virtual machine</Info>
    <Name>@NAME@</Name>
    <OperatingSystemSection ovf:id="96" ovf:osType="Ubuntu_64">
      <Info>The kind of installed guest operating system</Info>
      <Description>Linux Mint 22.3 (Ubuntu 24.04 base), 64-bit, UEFI</Description>
    </OperatingSystemSection>
    <VirtualHardwareSection>
      <Info>Virtual hardware requirements</Info>
      <System>
        <vssd:ElementName>Virtual Hardware Family</vssd:ElementName>
        <vssd:InstanceID>0</vssd:InstanceID>
        <vssd:VirtualSystemIdentifier>@NAME@</vssd:VirtualSystemIdentifier>
        <vssd:VirtualSystemType>virtualbox-2.2</vssd:VirtualSystemType>
      </System>
      <Item>
        <rasd:Caption>@VCPUS@ virtual CPUs</rasd:Caption>
        <rasd:Description>Number of virtual CPUs</rasd:Description>
        <rasd:ElementName>@VCPUS@ virtual CPUs</rasd:ElementName>
        <rasd:InstanceID>1</rasd:InstanceID>
        <rasd:ResourceType>3</rasd:ResourceType>
        <rasd:VirtualQuantity>@VCPUS@</rasd:VirtualQuantity>
      </Item>
      <Item>
        <rasd:AllocationUnits>MegaBytes</rasd:AllocationUnits>
        <rasd:Caption>@MEM@ MB of memory</rasd:Caption>
        <rasd:Description>Memory Size</rasd:Description>
        <rasd:ElementName>@MEM@ MB of memory</rasd:ElementName>
        <rasd:InstanceID>2</rasd:InstanceID>
        <rasd:ResourceType>4</rasd:ResourceType>
        <rasd:VirtualQuantity>@MEM@</rasd:VirtualQuantity>
      </Item>
      <Item>
        <rasd:Caption>sataController0</rasd:Caption>
        <rasd:Description>SATA Controller</rasd:Description>
        <rasd:ElementName>sataController0</rasd:ElementName>
        <rasd:InstanceID>3</rasd:InstanceID>
        <rasd:ResourceSubType>AHCI</rasd:ResourceSubType>
        <rasd:ResourceType>20</rasd:ResourceType>
      </Item>
      <Item>
        <rasd:AddressOnParent>0</rasd:AddressOnParent>
        <rasd:ElementName>disk1</rasd:ElementName>
        <rasd:HostResource>ovf:/disk/vmdisk1</rasd:HostResource>
        <rasd:InstanceID>4</rasd:InstanceID>
        <rasd:Parent>3</rasd:Parent>
        <rasd:ResourceType>17</rasd:ResourceType>
      </Item>
    </VirtualHardwareSection>
  </VirtualSystem>
</Envelope>
EOF

    note "pack: $OUT/$BASE.ova (ovf first — required by the OVA spec)"
    tar -C "$WORK" -cf "$OUT/$BASE.ova" "$BASE.ovf" "$BASE-disk001.vmdk"
    ( cd "$OUT" && sha256sum "$BASE.ova" > "$BASE.ova.sha256" )
fi

note "done"
cat <<EOF
    artifacts:
      $VMDK (+ .sha256)$([ "$OVA" = 1 ] && echo "
      $OUT/$BASE.ova (+ .sha256)")

    recipients — VirtualBox:
      File -> Import Appliance -> pick the .ova, tick "EFI" on the
      settings screen — or New VM "Ubuntu (64-bit)" -> use existing
      disk -> the .vmdk, then enable EFI in Settings -> System.
      UTM (Apple Silicon): attach the .qcow2 directly; x86 emulation
      applies. See README -> "Running without KVM".
EOF
