#!/bin/bash
# Tears down the software stack (OpenStack + K3S + Ceph) on all nodes.
# Runs from Mac. VMs remain running — only software is wiped.
# After this completes, run ./deploy.sh to redeploy from scratch.
#
# Usage: ./teardown.sh [--phase N]  (default: all phases 1-6)
set -euo pipefail
trap 'echo "ERROR: teardown failed at line $LINENO"' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_KEY="$HOME/.ssh/openstack_key"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=15 -o BatchMode=yes"
PHASE="${2:-all}"

CONTROLLER="192.168.0.101"
COMPUTE="192.168.0.102"
STORAGE="192.168.0.103"

log() { echo "==> $*"; }

# Returns 0 (run) or 1 (skip) — use with: if run_phase N "desc"; then ... fi
run_phase() {
  local n="$1"; shift
  [[ "$PHASE" == "all" || "$PHASE" == "$n" ]] || return 1
  echo ""
  echo "--- Phase $n: $* ---"
}

ssh_node() {
  local node="$1"; shift
  ssh $SSH_OPTS "sysoperator@${node}" "$@"
}

# ---------------------------------------------------------------------------
# Phase 1: kolla-ansible destroy
# Removes all OpenStack containers, volumes, and virtual networks on all nodes.
# kolla-ansible is installed at /opt/venv/kolla on the controller and SSHes
# to compute + storage on its own.
# Pre-step: kill QEMU processes — nova_libvirt refuses to stop while VMs run.
# ---------------------------------------------------------------------------
if run_phase 1 "Destroy OpenStack (kolla-ansible)"; then
  log "Killing QEMU processes on all nodes (kolla-ansible destroy requires this)..."
  for NODE in "$CONTROLLER" "$COMPUTE" "$STORAGE"; do
    ssh_node "$NODE" "sudo pkill -9 -f qemu-system || true" || true
  done
  sleep 3

  log "Running kolla-ansible destroy on controller..."
  ssh_node "$CONTROLLER" \
    "sudo env PATH=/opt/venv/kolla/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
     /opt/venv/kolla/bin/kolla-ansible destroy \
       -i /etc/kolla/inventory \
       --yes-i-really-really-mean-it"
fi

# ---------------------------------------------------------------------------
# Phase 2: K3S teardown
# K3S server is on storage; K3S agents are on controller and compute.
# ---------------------------------------------------------------------------
if run_phase 2 "Tear down K3S"; then
  log "Removing K3S server (storage $STORAGE)..."
  ssh_node "$STORAGE" \
    "sudo /usr/local/bin/k3s-uninstall.sh && echo 'k3s server removed' \
     || echo 'k3s-uninstall.sh not found (already clean)'"

  log "Removing K3S agent (controller $CONTROLLER)..."
  ssh_node "$CONTROLLER" \
    "sudo /usr/local/bin/k3s-agent-uninstall.sh && echo 'k3s agent removed' \
     || echo 'k3s-agent-uninstall.sh not found (already clean)'"

  log "Removing K3S agent (compute $COMPUTE)..."
  ssh_node "$COMPUTE" \
    "sudo /usr/local/bin/k3s-agent-uninstall.sh && echo 'k3s agent removed' \
     || echo 'k3s-agent-uninstall.sh not found (already clean)'"
fi

# ---------------------------------------------------------------------------
# Phase 3: Wipe Ceph OSD disks (/dev/sdb on all nodes)
# VMs use VirtIO SCSI: OS disk = /dev/sda, Ceph OSD disk = /dev/sdb.
# Wipe partition table, first/last 100 MB, discard when supported, and clear
# common Ceph BlueStore label offsets. Raw BlueStore metadata can survive a
# normal wipefs/start-of-disk cleanup, causing Rook to skip the disk as
# belonging to an older cluster on the next deployment.
# ---------------------------------------------------------------------------
if run_phase 3 "Wipe Ceph OSD disks"; then
  for NODE in "$CONTROLLER" "$COMPUTE" "$STORAGE"; do
    log "Wiping /dev/sdb on $NODE..."
    ssh_node "$NODE" '
      set -e
      DEV=/dev/sdb
      sudo swapoff "$DEV"* 2>/dev/null || true
      sudo blkdiscard -f "$DEV" 2>/dev/null || true
      sudo wipefs -af "$DEV" || true
      sudo sgdisk --zap-all "$DEV" 2>/dev/null || true
      sudo dd if=/dev/zero of="$DEV" bs=1M count=100 conv=fsync 2>/dev/null
      SIZE_MB=$(($(sudo blockdev --getsize64 "$DEV") / 1024 / 1024))
      for OFFSET_MB in 1024 10240 102400 1024000; do
        if [ "$SIZE_MB" -gt "$OFFSET_MB" ]; then
          sudo dd if=/dev/zero of="$DEV" bs=1M seek="$OFFSET_MB" count=16 conv=fsync 2>/dev/null
        fi
      done
      SECTORS=$(sudo blockdev --getsz "$DEV")
      SEEK=$((SECTORS / 2048 - 100))
      if [ "$SEEK" -gt 0 ]; then
        sudo dd if=/dev/zero of="$DEV" bs=1M seek="$SEEK" count=100 conv=fsync 2>/dev/null
      fi
      sudo partprobe "$DEV" 2>/dev/null || true
      sudo udevadm settle 2>/dev/null || true
    '
  done
fi

# ---------------------------------------------------------------------------
# Phase 4: Clean Rook state directories
# /var/lib/rook holds Ceph monitor data and Rook operator state.
# Must be removed so Rook starts clean on redeploy.
# ---------------------------------------------------------------------------
if run_phase 4 "Clean /var/lib/rook on all nodes"; then
  for NODE in "$CONTROLLER" "$COMPUTE" "$STORAGE"; do
    log "Removing /var/lib/rook on $NODE..."
    ssh_node "$NODE" "sudo rm -rf /var/lib/rook"
  done
fi

# ---------------------------------------------------------------------------
# Phase 5: Clean kolla config and Docker state on controller
# /etc/kolla holds passwords (passwords.yml), config, and keyrings —
# removing it forces kolla-genpwd to regenerate on the next deploy.
# /opt/venv/kolla is the kolla-ansible virtualenv; remove it so
# install_kolla reinstalls a known-good version on next deploy.
# ---------------------------------------------------------------------------
if run_phase 5 "Clean OpenStack config on controller"; then
  log "Removing /etc/kolla and /opt/venv/kolla on controller..."
  ssh_node "$CONTROLLER" "sudo rm -rf /etc/kolla /opt/venv/kolla"

  log "Pruning Docker images and volumes on controller..."
  ssh_node "$CONTROLLER" "sudo docker system prune -af --volumes 2>/dev/null || true"

  log "Pruning Docker images and volumes on compute..."
  ssh_node "$COMPUTE" "sudo docker system prune -af --volumes 2>/dev/null || true"
fi

# ---------------------------------------------------------------------------
# Phase 6: Local cleanup on Mac
# Remove cached Ceph keyrings, FSID, and WireGuard pubkey written by deploy.
# ---------------------------------------------------------------------------
if run_phase 6 "Local cleanup"; then
  log "Removing local Ceph keyrings and state..."
  rm -rf /var/tmp/ceph-keyrings 2>/dev/null || true
  rm -f  /var/tmp/ceph_fsid /var/tmp/ceph_mon_dump.json 2>/dev/null || true
  log "Removing local WireGuard pubkey..."
  rm -f  "$HOME/.cloud-vpn-pubkey" 2>/dev/null || true
fi

echo ""
log "Teardown complete. All nodes wiped and ready for redeploy."
log "Next: run ./deploy.sh to rebuild the full stack."
