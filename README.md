# Private OpenStack Cloud + Self-Service Dev-Environment Platform

Master's dissertation project (University POLITEHNICA of Bucharest): an automated,
cost-efficient **private cloud** built on OpenStack on commodity hardware, exposed as a
self-service **PaaS portal** where developers reserve pre-configured dev servers on demand.

The work is split into **two projects**, each self-contained with its own `docs/` folder.

| Project | Path | What it is | Stack |
|---|---|---|---|
| **Cloud deployment** | `cloud-deployment/` | Ansible automation that turns bare Ubuntu nodes into a running OpenStack cloud (Kolla-Ansible) with Rook Ceph storage on K3S, networking, and two WireGuard VPNs. Includes Proxmox lab scaffolding. | Ansible, Kolla-Ansible, Rook Ceph, K3S, OVN, WireGuard |
| **Portal (platform)** | `portal/` *(git submodule)* | The PaaS web app: reserve / release / resize / migrate dev VMs, inject SSH keys, manage per-user VPN access, keep a warm VM pool. | FastAPI, openstacksdk, React, PostgreSQL, Chef |

## What each project contains

**`cloud-deployment/`**
- `deploy.sh` — phased orchestrator (1 bootstrap → 2 K3S → 3 Ceph → 4 install Kolla → 5 deploy OpenStack → 6 init resources + vpn-gateway → 7 portal).
- `roles/` — `bootstrap_nodes`, `prep_openstack_nodes`, `deploy_ceph`, `install_kolla`, `deploy_openstack`.
- `deploy-openstack.yml`, `deploy-portal.yml`, `bootstrap-nodes.yml`, `teardown.sh`.
- `lab/` — Proxmox VM/bridge create + teardown (lab-only scaffolding).
- `group_vars/all/vault.yaml` — **encrypted** secrets; `.vault_pass` is gitignored.
- `k3s-ansible/` — upstream submodule (k3s-io/k3s-ansible), used only to host Rook Ceph.
- `docs/` — `PLATFORM_GUIDE.md`, `AGENT_RUNBOOK.md`, `DEVLOG.md`.

**`portal/`**
- `backend/` — FastAPI: `routers/` (auth, vms, admin), `services/` (openstack, pool, gateway, wireguard, ssh_keys, devserver_userdata), `models/`, `schemas/`, `scripts/create_admin.py`; Alembic migrations.
- `frontend/` — React + Vite + Tailwind + TanStack Query.
- `chef/` — `devserver` cookbook (base dev tooling) run on dev VMs.
- `docker-compose.yml`, `nginx/` — nginx + FastAPI + PostgreSQL deployment.
- `docs/` — `PLATFORM_GUIDE.md`, `AGENT_RUNBOOK.md`, `DEVLOG.md`, `GOLDEN_IMAGE_PLAN.md`.

## End-to-end architecture

```
                            INTERNET  /  HOME LAN 192.168.0.0/24
                                          │
                         ┌────────────────┴───────────────────┐
                         │      Proxmox VE host  .100           │  vmbr0 (LAN, VLAN-aware)
                         │                                      │  vmbr1 10.0.2.1/24 (OVS uplink)
                         │  WireGuard ADMIN VPN :51820          │
                         │  tunnel 10.99.0.0/24 ─► 10.0.1/2/4   │
                         │                                      │
                         │  ┌──────────┐ ┌──────────┐ ┌────────┴──┐ ┌──────────┐
                         │  │controller│ │ compute  │ │  storage  │ │  portal  │
                         │  │ .101     │ │ .102     │ │  .103     │ │  .104    │
                         │  │10.0.1.2  │ │10.0.1.3  │ │ 10.0.1.4  │ │10.0.1.200│
                         │  ├──────────┤ ├──────────┤ ├───────────┤ ├──────────┤
                         │  │Keystone  │ │Nova      │ │K3S + Rook │ │Docker    │
                         │  │Glance    │ │compute   │ │Ceph (OSDs)│ │Compose:  │
                         │  │Nova/Neut │ │(+compute)│ │(+compute) │ │ nginx    │
                         │  │Cinder/OVN│ │          │ │  images/  │ │ FastAPI  │
                         │  │Horizon   │ │          │ │vms/vols.. │ │ Postgres │
                         │  │VIP .254  │ │          │ │           │ │          │
                         │  └────┬─────┘ └────┬─────┘ └─────┬─────┘ └────┬─────┘
                         │       └────────────┴─────── all 3 = Nova hypervisors
                         └──────────────────────┬────────────────────────┬────────┘
                                                │ OpenStack tenant/Neutron│ openstacksdk
                                                │ (OVN)                   │ (Nova/Neutron/Glance)
        ┌───────────────────────────────────────┴─────────────────┐     │
        │  demo-net 10.0.0.0/24 (dev VM eth0)                       │     │
        │  mgmt-net 10.0.4.0/24 (dev VM admin NIC, admin VPN SSH)   │     │
        │                                                          │     │
        │   ┌────────────────┐         ┌────────────────────────┐  │     │
        │   │  vpn-gateway VM │         │   dev VMs (the pool)   │  │     │
        │   │ float 10.0.2.150│         │  devserver-<size>-NNN  │◄─┼─────┘ portal rebuilds,
        │   │ demo  10.0.0.41 │  SSH    │  10.0.0.x / 10.0.4.x   │  │       injects SSH keys,
        │   │ WireGuard :51821│◄────────│  pool-sg ─► sg-user-N  │  │       swaps security group
        │   │ dnsmasq (DNS)   │         │  Chef-configured       │  │
        │   └───────▲─────────┘         └────────────────────────┘  │
        │           │ portal SSH (paramiko): wg peers + /etc/hosts   │
        └───────────┼──────────────────────────────────────────────┘
                    │ USER VPN tunnel 10.99.1.0/24  (routed, not NATed)
                    │
        Developer laptop ── ssh ubuntu@devserver-<size>-NNN  (reserved only)
        Browser ── https://cloud.tudu.io ── reserve / release / resize / migrate
```

### Which project operates where
| Layer | Owned by |
|---|---|
| Proxmox host, VLAN bridges, admin VPN, the 4 VMs, OpenStack, Ceph/K3S, vpn-gateway provisioning | **cloud-deployment** (Ansible + lab scripts) |
| Reserve/release/resize/migrate, SSH-key injection, per-user VPN peers + DNS, VM pool, dev VM Chef config | **portal** |

## Networks

| Network | CIDR | VLAN / via | Purpose |
|---|---|---|---|
| Management | 10.0.1.0/24 | VLAN 4000 | Ansible, Kolla, K3S; OpenStack API VIP `10.0.1.254` |
| External (floating) | 10.0.2.0/24 | vmbr1 (gw `10.0.2.1`) | Floating IPs |
| Storage | 10.0.3.0/24 | VLAN 4002 | Ceph replication |
| Tenant (demo-net) | 10.0.0.0/24 | OVN | Dev VM primary NIC |
| mgmt-net | 10.0.4.0/24 | OVN (`mgmt-router` 10.0.2.200) | Dev VM admin NIC |
| Admin VPN | 10.99.0.0/24 | Proxmox :51820 | Sysadmin full access |
| User VPN | 10.99.1.0/24 | vpn-gateway :51821 | Employees → dev VMs only |

## Documentation

| Topic | Cloud deployment | Portal (platform) |
|---|---|---|
| Architecture & access | `cloud-deployment/docs/PLATFORM_GUIDE.md` | `portal/docs/PLATFORM_GUIDE.md` |
| Operate / redeploy / debug | `cloud-deployment/docs/AGENT_RUNBOOK.md` | `portal/docs/AGENT_RUNBOOK.md` |
| Decisions & journal | `cloud-deployment/docs/DEVLOG.md` | `portal/docs/DEVLOG.md` |
| Roadmap | — | `portal/docs/GOLDEN_IMAGE_PLAN.md` |

## Quick start

```bash
cd cloud-deployment
./deploy.sh                 # full build from bare Ubuntu nodes (phases 1-7)
./deploy.sh --phase 7       # portal only
```

Secrets live in the Ansible vault (`cloud-deployment/group_vars/all/vault.yaml`, encrypted)
and `Disertatie/SECRETS.md` (never committed).
