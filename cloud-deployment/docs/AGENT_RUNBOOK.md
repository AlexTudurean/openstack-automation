# Agent Runbook — OpenStack PaaS Platform

> Scope: **cloud deployment / infrastructure** ops. Portal ops runbook: see `portal/docs/AGENT_RUNBOOK.md`.

This document tells an AI agent everything it needs to operate, debug, and redeploy this environment without asking the user.

---

## 1. Repository layout

```
/Users/tudu/Uni/Master/Disertatie/
├── SECRETS.md                        ← credentials (not in git)
├── DEVLOG.md                         ← decision log
└── resources/openstack-automation/
    ├── AGENT_RUNBOOK.md              ← this file
    ├── portal/                       ← portal application source
    │   ├── backend/                  ← FastAPI (Python 3.12)
    │   │   ├── app/
    │   │   │   ├── routers/          ← auth.py, vms.py, admin.py
    │   │   │   ├── services/         ← openstack.py, pool.py, gateway.py, wireguard.py
    │   │   │   ├── models/           ← SQLAlchemy models
    │   │   │   ├── schemas/          ← Pydantic schemas
    │   │   │   └── scripts/          ← create_admin.py (one-time bootstrap)
    │   │   └── requirements.txt
    │   ├── frontend/                 ← React + Vite + TailwindCSS + TanStack Query
    │   │   └── src/
    │   │       ├── api/client.ts     ← typed API client with JWT refresh
    │   │       ├── hooks/useAuth.ts
    │   │       └── pages/            ← Login, MyServers, Admin
    │   ├── docker-compose.yml
    │   └── nginx.conf
    └── cloud-deployment/
        ├── deploy.sh                 ← full platform deploy (phases 1-7)
        ├── deploy-portal.yml         ← Ansible: portal VM only
        ├── deploy-openstack.yml      ← Ansible: phases 3-6
        ├── bootstrap-nodes.yml       ← Ansible: phase 1
        ├── inventory/inventory.ini
        ├── host_vars/portal.yaml     ← portal VM: 192.168.0.104
        ├── group_vars/all/vault.yaml ← encrypted secrets
        ├── .vault_pass               ← vault password file (not in git)
        └── templates/portal_env.j2   ← renders .env on portal VM
```

---

## 2. Infrastructure at a glance

Proxmox host (hypervisor): `192.168.0.100` — the LAN gateway is `192.168.0.1`.

| VM | Proxmox ID | IP (LAN) | IP (VLAN) | Role |
|---|---|---|---|---|
| controller | 100 | 192.168.0.101 | 10.0.1.2 | OpenStack controller (Kolla) |
| compute | 101 | 192.168.0.102 | 10.0.1.3 | Nova compute + K3S worker |
| storage | 102 | 192.168.0.103 | 10.0.1.4 | Rook/Ceph + K3S control-plane |
| portal | 103 | 192.168.0.104 | — | Docker Compose: nginx+FastAPI+PG |

All four VMs are created with `--onboot 1`, so they auto-start when the Proxmox
host reboots (see §3.1 if any come up stopped).

OpenStack VIP: `10.0.1.254` (Keepalived on controller)
VPN gateway VM (inside OpenStack): floating IP `10.0.2.150`, demo-net `10.0.0.41`

---

## 3. SSH access

SSH key for all nodes: `~/.ssh/openstack_key`

```bash
# Portal VM — reachable directly on LAN (no VPN needed)
ssh -i ~/.ssh/openstack_key sysoperator@192.168.0.104

# OpenStack nodes — ONLY reachable via admin WireGuard VPN (10.99.0.x)
ssh -i ~/.ssh/openstack_key sysoperator@10.0.1.2   # controller
ssh -i ~/.ssh/openstack_key sysoperator@10.0.1.3   # compute
ssh -i ~/.ssh/openstack_key sysoperator@10.0.1.4   # storage

# Proxmox hypervisor
ssh root@192.168.0.100
```

All `ssh` commands need `-o StrictHostKeyChecking=no` on first connection to a host.

---

## 3.1 Proxmox host: VM autostart & reboot recovery

All four lab VMs (100–103) are provisioned with `--onboot 1` by
`cloud-deployment/lab/proxmox-setup.sh`, so they start automatically when the
Proxmox host boots, in VMID order (controller first → portal last).

If the host was rebooted and one or more VMs did not come up (e.g. VMs created
before the `onboot` flag was added), run this **on the Proxmox host as root** —
it sets `onboot` on every VM and starts any that are stopped:

```bash
for v in 100 101 102 103; do
  qm set "$v" --onboot 1
  [ "$(qm status "$v" | awk '{print $2}')" = running ] || qm start "$v"
done
qm list
```

`proxmox-setup.sh` skips VMs that already exist, so re-running it will **not**
retrofit `onboot` onto existing VMs — use the loop above for that.

### Full-stack cold-boot behaviour

The first full power-cycle (2026-06-08) exposed several "configured at deploy
time but not persisted" gaps (DEVLOG Challenges 29–33). **All are now in the
automation**, so a clean cold boot should recover unattended:

| Layer | Survives reboot via | If it didn't |
|---|---|---|
| Proxmox VMs autostart | `qm --onboot 1` (`proxmox-setup.sh`) | loop above |
| Proxmox IP forwarding | `/etc/sysctl.d/99-openstack-forward.conf` | `sysctl -w net.ipv4.ip_forward=1` on host |
| Node `/etc/hosts` (RabbitMQ) | cloud-init `manage_etc_hosts: false` + mgmt-IP entries (`bootstrap_nodes`) | see Challenge 30 |
| OpenStack guests resume | `resume_guests_state_on_host_boot` (`nova-compute.conf`) | `openstack server start <vm>` |
| vpn-gateway dnsmasq | `bind-dynamic` + `After=wg-quick@wg0` (`vpn_gateway_userdata.j2`) | `systemctl restart dnsmasq` on gateway |

Post-reboot health sweep (run from the Mac; OpenStack checks need the admin VPN):

```bash
# 1. Nodes reachable (LAN works even without VPN)
for ip in 101 102 103 104; do ssh -i ~/.ssh/openstack_key sysoperator@192.168.0.$ip 'echo ok'; done

# 2. Control plane healthy (no unhealthy containers, rabbitmq up)
ssh -i ~/.ssh/openstack_key sysoperator@192.168.0.101 \
  "sudo docker ps -a --format '{{.Names}} {{.Status}}' | grep -iE 'unhealthy|Exited|Restarting'"

# 3. OpenStack services + guests (openstack client lives at /opt/venv/kolla/bin)
ssh -i ~/.ssh/openstack_key sysoperator@192.168.0.101 'sudo bash -c "
  source /etc/kolla/admin-openrc.sh; OS=/opt/venv/kolla/bin/openstack
  \$OS compute service list; \$OS network agent list; \$OS server list --all-projects"'

# 4. Ceph (Rook in K3S on storage)
ssh -i ~/.ssh/openstack_key sysoperator@192.168.0.103 \
  'sudo kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph -s'

# 5. Admin VPN reaches the management VLAN (Horizon / Ceph dashboard)
nc -z -G3 10.0.1.254 8080 && echo horizon-ok
nc -z -G3 10.0.1.4 32680 && echo ceph-dash-ok
```

If step 5 fails but the tunnel is up (`ping 10.99.0.1` works), check
`ip_forward` on the Proxmox host first — see Challenge 32.

---

## 4. WireGuard VPN

Two separate WireGuard interfaces exist:

**Admin VPN** (your Mac connects here for infra access):
- Endpoint: `192.168.0.100:51820`
- Server public key: `9bsqzSBR2wel/fGYAuqg4X7N/0cHexhFlE58Xo5RNGo=`
- Your Mac tunnel IP: `10.99.0.2/32`
- AllowedIPs: `10.0.1.0/24, 10.0.2.0/24, 10.0.4.0/24`

**User VPN** (managed by the portal, for dev server users):
- Endpoint: `192.168.0.100:51821` (WireGuard on vpn-gateway VM)
- Tunnel subnet: `10.99.1.0/24`
- Gateway/DNS IP: `10.99.1.1`
- User tunnel IPs start at `10.99.1.2`
- Per-user configs generated automatically on user creation in the portal
- Client configs include `DNS = 10.99.1.1`; dnsmasq on the vpn-gateway resolves reserved dev servers by hostname.
- User VPN traffic is **not NATed** on the vpn-gateway. `demo-router` has a static route for `10.99.1.0/24` via the vpn-gateway demo-net IP `10.0.0.41`, so dev VMs see the real user tunnel IP and per-user security groups work.

The admin VPN must be active whenever you SSH to 10.0.1.x or access the OpenStack API.

### SSH over the user tunnel hangs / times out (MTU)

If SSH to a dev VM over the user tunnel hangs (with `ssh -vvv` freezing at
`expecting SSH2_MSG_KEX_ECDH_REPLY`), it is an **MTU black hole**, not auth.
The VXLAN tenant nets must have MTU **1350** (1400 underlay − 50 VXLAN); if a
net shows 1450 the underlay-MTU mismatch silently drops large packets. See
DEVLOG Challenge 34. Checklist:

- `openstack network show demo-net -f value -c mtu` → must be **1350** (not 1450).
  Fix: `openstack network set --mtu 1350 demo-net mgmt-net` (new VMs pick it up
  at once; running VMs on reboot / DHCP renewal).
- `global_physnet_mtu: 1400` must be set in `globals.yml` (matches `eth0.40xx`
  MTU in host_vars) so fresh deploys are correct.
- Client `.conf` `[Interface]` block must contain `MTU = 1350` (portal emits this
  automatically; add by hand to older configs). This alone unblocks SSH even if
  the network MTU hasn't been corrected yet.

---

## 7. Full platform redeploy (all phases)

Only needed from scratch. Phase 6 is NOT idempotent — skip it if resources already exist.

```bash
cd /Users/tudu/Uni/Master/Disertatie/resources/openstack-automation/cloud-deployment

./deploy.sh                  # all phases (fresh install only)
./deploy.sh --phase 7        # portal only via deploy.sh wrapper
```

Individual phases:
```bash
# Phase 1: bootstrap nodes
ansible-playbook -i inventory/inventory.ini --vault-password-file .vault_pass bootstrap-nodes.yml

# Phases 3-5: Ceph + Kolla config + OpenStack deploy
ansible-playbook -i inventory/inventory.ini --vault-password-file .vault_pass deploy-openstack.yml \
  --tags prep_openstack_nodes,install_helm,deploy_ingress_nginx,deploy_rook,prepare_ceph
ansible-playbook -i inventory/inventory.ini --vault-password-file .vault_pass deploy-openstack.yml \
  --tags install_kolla,configure_kolla
ansible-playbook -i inventory/inventory.ini --vault-password-file .vault_pass deploy-openstack.yml \
  --tags kolla_bootstrap,kolla_prechecks,kolla_deploy,kolla_post

# Phase 6: one-time resources (skip if already done)
ansible-playbook -i inventory/inventory.ini --vault-password-file .vault_pass deploy-openstack.yml \
  --tags kolla_init,init_vpn_gateway,init_resources
```

---

## 8. OpenStack access

**Dashboard (Horizon):** `http://10.0.1.254:8080` — requires admin WireGuard VPN
- Username: `admin` / Password: see `SECRETS.md`

**CLI via controller node:**
```bash
ssh -i ~/.ssh/openstack_key -o StrictHostKeyChecking=no sysoperator@10.0.1.2
sudo -i
source /etc/kolla/admin-openrc.sh
openstack server list
openstack network list
openstack image list
openstack flavor list
```

**Get current Keystone password:**
```bash
ssh -i ~/.ssh/openstack_key -o StrictHostKeyChecking=no sysoperator@10.0.1.2 \
  "sudo grep 'keystone_admin_password' /etc/kolla/passwords.yml | awk '{print \$2}'"
```

---

## 11. Key secrets locations

| Secret | Where to find it |
|---|---|
| OpenStack admin password | `SECRETS.md` or run the `grep` command in §8 |
| Portal DB password | `cloud-deployment/group_vars/all/vault.yaml` (encrypted) |
| Portal JWT secret | same vault file |
| Ansible vault password | `cloud-deployment/.vault_pass` (plain text, not in git) |
| Admin WireGuard private key | `SECRETS.md` |
| SSH key for all nodes | `~/.ssh/openstack_key` |
| vpn-gateway management key | Controller `/root/.ssh/id_ecdsa`; copied by `deploy-portal.yml` to `/opt/portal/keys/vpn_gateway.key` and mounted in backend as `/run/secrets/vpn_gateway_key` |

To decrypt the vault manually:
```bash
ansible-vault view \
  /Users/tudu/Uni/Master/Disertatie/resources/openstack-automation/cloud-deployment/group_vars/all/vault.yaml \
  --vault-password-file /Users/tudu/Uni/Master/Disertatie/resources/openstack-automation/cloud-deployment/.vault_pass
```
