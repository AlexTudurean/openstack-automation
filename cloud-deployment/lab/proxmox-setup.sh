#!/bin/bash
# Run ON the Proxmox host to create the lab environment from scratch.
# Creates vmbr1, downloads Ubuntu 24.04 cloud image, provisions VMs 100-102.
#
# Prerequisites on Proxmox:
#   - Copy your openstack_key.pub to /root/openstack_key.pub
#   - Run as root
#
# Usage: bash proxmox-setup.sh [--ssh-key /path/to/key.pub]
set -euo pipefail
trap 'echo "ERROR at line $LINENO"' ERR

STORAGE="local-lvm"
IMG_PATH="/var/lib/vz/template/iso/noble-server-cloudimg-amd64.img"
IMG_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
SSH_KEY_FILE="/root/openstack_key.pub"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ssh-key) SSH_KEY_FILE="$2"; shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

if [[ ! -f "$SSH_KEY_FILE" ]]; then
  echo "ERROR: SSH public key not found at $SSH_KEY_FILE"
  echo "Copy your openstack_key.pub to $SSH_KEY_FILE (or pass --ssh-key /path/to/key.pub)"
  exit 1
fi

log() { echo "==> $*"; }

# ---------------------------------------------------------------------------
# 1. Create vmbr1 (internal bridge for OVS external network, 10.0.2.1/24)
# ---------------------------------------------------------------------------
if ip link show vmbr1 &>/dev/null; then
  log "vmbr1 already exists, skipping"
else
  log "Creating vmbr1 bridge (10.0.2.1/24)..."
  cat >> /etc/network/interfaces << 'IFACE'

auto vmbr1
iface vmbr1 inet static
    address 10.0.2.1/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    # Route mgmt-net (10.0.4.0/24) via the OVN mgmt-router external IP.
    # Required so the admin VPN (which terminates on Proxmox) can reach
    # dev VM management NICs. mgmt-router is fixed at 10.0.2.200 on vmbr1.
    post-up   ip route add 10.0.4.0/24 via 10.0.2.200 || true
    pre-down  ip route del 10.0.4.0/24 via 10.0.2.200 || true
IFACE
  ifup vmbr1
fi

# ---------------------------------------------------------------------------
# 2. Ubuntu 24.04 cloud image
# ---------------------------------------------------------------------------
if [[ -f "$IMG_PATH" ]]; then
  log "Ubuntu 24.04 cloud image already present at $IMG_PATH"
else
  log "Downloading Ubuntu 24.04 cloud image..."
  wget -q --show-progress -O "$IMG_PATH" "$IMG_URL"
fi

# ---------------------------------------------------------------------------
# 3. Create VMs
# ---------------------------------------------------------------------------

# OpenStack nodes: 16 GB RAM, 4 cores, VLAN trunk, 60 GB root + 60 GB Ceph OSD
create_openstack_vm() {
  local VMID="$1"
  local NAME="$2"
  local IP="$3"

  if qm status "$VMID" &>/dev/null; then
    log "VM $VMID ($NAME) already exists, skipping"
    return
  fi

  log "Creating OpenStack VM $VMID ($NAME) with IP $IP..."

  qm create "$VMID" \
    --name "$NAME" \
    --memory 16384 \
    --balloon 0 \
    --cores 4 \
    --cpu host \
    --machine q35 \
    --bios ovmf \
    --scsihw virtio-scsi-pci \
    --net0 "virtio,bridge=vmbr0,trunks=4000;4001;4002" \
    --onboot 1 \
    --ostype l26

  qm set "$VMID" --efidisk0 "${STORAGE}:4,efitype=4m,pre-enrolled-keys=0"

  qm importdisk "$VMID" "$IMG_PATH" "$STORAGE" --format raw
  IMPORTED=$(qm config "$VMID" | awk -F'[ ,]' '/^unused0:/{print $2}')
  qm set "$VMID" --scsi0 "${IMPORTED},discard=on"
  qm resize "$VMID" scsi0 60G

  # Ceph OSD disk (scsi1 → /dev/sdb)
  qm set "$VMID" --scsi1 "${STORAGE}:60,format=raw"

  qm set "$VMID" \
    --ide2 "${STORAGE}:cloudinit" \
    --ciuser sysoperator \
    --sshkeys "$SSH_KEY_FILE" \
    --ipconfig0 "ip=${IP}/24,gw=192.168.0.1" \
    --nameserver "8.8.8.8 8.8.4.4"

  qm set "$VMID" --boot order=scsi0
}

# Portal VM: 4 GB RAM, 2 cores, VLAN 4000 only (OpenStack API), 30 GB root, no Ceph disk
create_portal_vm() {
  local VMID="$1"
  local NAME="$2"
  local IP="$3"

  if qm status "$VMID" &>/dev/null; then
    log "VM $VMID ($NAME) already exists, skipping"
    return
  fi

  log "Creating portal VM $VMID ($NAME) with IP $IP..."

  qm create "$VMID" \
    --name "$NAME" \
    --memory 4096 \
    --balloon 0 \
    --cores 2 \
    --cpu host \
    --machine q35 \
    --bios ovmf \
    --scsihw virtio-scsi-pci \
    --net0 "virtio,bridge=vmbr0,trunks=4000" \
    --onboot 1 \
    --ostype l26

  qm set "$VMID" --efidisk0 "${STORAGE}:4,efitype=4m,pre-enrolled-keys=0"

  qm importdisk "$VMID" "$IMG_PATH" "$STORAGE" --format raw
  IMPORTED=$(qm config "$VMID" | awk -F'[ ,]' '/^unused0:/{print $2}')
  qm set "$VMID" --scsi0 "${IMPORTED},discard=on"
  qm resize "$VMID" scsi0 30G

  qm set "$VMID" \
    --ide2 "${STORAGE}:cloudinit" \
    --ciuser sysoperator \
    --sshkeys "$SSH_KEY_FILE" \
    --ipconfig0 "ip=${IP}/24,gw=192.168.0.1" \
    --nameserver "8.8.8.8 8.8.4.4"

  qm set "$VMID" --boot order=scsi0
}

create_openstack_vm 100 "controller" "192.168.0.101"
create_openstack_vm 101 "compute"    "192.168.0.102"
create_openstack_vm 102 "storage"    "192.168.0.103"
create_portal_vm    103 "portal"     "192.168.0.104"

# 4. controller gets an extra NIC on vmbr1 (OVS external bridge uplink)
if ! qm config 100 | grep -q "^net1:"; then
  log "Adding vmbr1 NIC to controller (VM 100)..."
  qm set 100 --net1 "virtio,bridge=vmbr1"
fi

# ---------------------------------------------------------------------------
# 5. Start VMs
# ---------------------------------------------------------------------------
for VMID in 100 101 102 103; do
  STATUS=$(qm status "$VMID" 2>/dev/null | awk '{print $2}' || echo "stopped")
  if [[ "$STATUS" != "running" ]]; then
    log "Starting VM $VMID..."
    qm start "$VMID"
  fi
done

# ---------------------------------------------------------------------------
# 6. iptables rules
# These are host-level rules required for OpenStack VM internet access,
# the user WireGuard VPN, and the portal. Applied idempotently — safe to re-run.
# ---------------------------------------------------------------------------
log "Configuring iptables rules..."

# Ensure netfilter-persistent is available for rule persistence
apt-get install -y -q netfilter-persistent iptables-persistent

# Enable IP forwarding
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p -q

# VM internet access: MASQUERADE floating IP traffic out through vmbr0
iptables -C FORWARD -i vmbr1 -o vmbr0 -j ACCEPT 2>/dev/null || \
  iptables -A FORWARD -i vmbr1 -o vmbr0 -j ACCEPT
iptables -C FORWARD -i vmbr0 -o vmbr1 -j ACCEPT 2>/dev/null || \
  iptables -A FORWARD -i vmbr0 -o vmbr1 -j ACCEPT
iptables -t nat -C POSTROUTING -s 10.0.2.0/24 -o vmbr0 -j MASQUERADE 2>/dev/null || \
  iptables -t nat -A POSTROUTING -s 10.0.2.0/24 -o vmbr0 -j MASQUERADE

# User VPN: DNAT UDP 51821 to vpn-gateway floating IP (hardcoded 10.0.2.150)
iptables -t nat -C PREROUTING -p udp --dport 51821 -j DNAT \
  --to-destination 10.0.2.150:51821 2>/dev/null || \
  iptables -t nat -A PREROUTING -p udp --dport 51821 -j DNAT \
  --to-destination 10.0.2.150:51821

# Persist all rules so they survive reboots
# NOTE: The portal VM (192.168.0.104) is directly on the home LAN — no DNAT needed.
# For external (internet) access, configure port forwarding on the home router instead.
netfilter-persistent save

# ---------------------------------------------------------------------------
# 7. Wait for VMs to boot (cloud-init typically takes 60-90 s)
# ---------------------------------------------------------------------------
log "Waiting 90 s for VMs to boot and apply cloud-init..."
sleep 90

log ""
log "Lab environment ready:"
log "  controller  192.168.0.101  (VM 100) — with vmbr1 NIC for OVS"
log "  compute     192.168.0.102  (VM 101)"
log "  storage     192.168.0.103  (VM 102)"
log "  portal      192.168.0.104  (VM 103) — PaaS portal (Proxmox VM, outside OpenStack)"
log ""
log "Manual step (one-time) — admin WireGuard AllowedIPs:"
log "  Add 10.0.4.0/24 to AllowedIPs in /etc/wireguard/wg0.conf on this host,"
log "  then: wg-quick down wg0 && wg-quick up wg0"
log "  This lets the admin VPN reach dev VM management NICs (10.0.4.x)."
log ""
log "Verify SSH from your Mac, then run deploy.sh:"
log "  ssh -i ~/.ssh/openstack_key sysoperator@192.168.0.101"
log "  ./deploy.sh"
