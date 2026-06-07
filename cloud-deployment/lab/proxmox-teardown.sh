#!/bin/bash
# Run ON the Proxmox host to destroy the lab environment.
# Stops and deletes VMs 100-102, removes vmbr1.
# Does NOT touch the Ubuntu 24.04 cloud image (re-download is slow).
#
# Usage: bash proxmox-teardown.sh [--remove-image]
set -euo pipefail

REMOVE_IMAGE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --remove-image) REMOVE_IMAGE=true; shift ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

log() { echo "==> $*"; }

# ---------------------------------------------------------------------------
# 1. Stop and destroy VMs
# ---------------------------------------------------------------------------
for VMID in 100 101 102; do
  if ! qm status "$VMID" &>/dev/null; then
    log "VM $VMID does not exist, skipping"
    continue
  fi

  STATUS=$(qm status "$VMID" | awk '{print $2}')
  if [[ "$STATUS" == "running" ]]; then
    log "Stopping VM $VMID..."
    qm stop "$VMID" --timeout 30 || qm stop "$VMID" --skiplock 1
    sleep 2
  fi

  log "Destroying VM $VMID (including all disks)..."
  qm destroy "$VMID" --purge 1 --destroy-unreferenced-disks 1
done

# ---------------------------------------------------------------------------
# 2. Remove vmbr1
# ---------------------------------------------------------------------------
if ip link show vmbr1 &>/dev/null; then
  log "Bringing down vmbr1..."
  ifdown vmbr1 2>/dev/null || ip link set vmbr1 down
  ip link delete vmbr1 type bridge 2>/dev/null || true

  log "Removing vmbr1 from /etc/network/interfaces..."
  # Remove the 'auto vmbr1' + 'iface vmbr1' block (multi-line)
  perl -0pe 's/\nauto vmbr1\niface vmbr1 [^\n]*\n(\s+[^\n]*\n)*/\n/g' \
    -i /etc/network/interfaces
else
  log "vmbr1 not found, skipping"
fi

# ---------------------------------------------------------------------------
# 3. Optionally remove cloud image
# ---------------------------------------------------------------------------
IMG_PATH="/var/lib/vz/template/iso/noble-server-cloudimg-amd64.img"
if $REMOVE_IMAGE && [[ -f "$IMG_PATH" ]]; then
  log "Removing Ubuntu 24.04 cloud image..."
  rm -f "$IMG_PATH"
elif [[ -f "$IMG_PATH" ]]; then
  log "Keeping cloud image at $IMG_PATH (pass --remove-image to delete)"
fi

log ""
log "Proxmox teardown complete. Run proxmox-setup.sh to rebuild."
