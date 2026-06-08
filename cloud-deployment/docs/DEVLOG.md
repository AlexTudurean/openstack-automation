# Project Devlog — OpenStack Cloud Deployment & PaaS Portal

> Scope: **cloud deployment / infrastructure** (Proxmox, OpenStack, Ceph, K3S, networking).
> Portal/app development log: see `portal/docs/DEVLOG.md`.

**Author**: George-Alexandru Tudurean
**University**: University POLITEHNICA of Bucharest
**Started**: June 2026

This is a living document. It captures architecture decisions, implementation details, challenges encountered and how they were solved, and the reasoning behind every major choice. It serves both as a project journal and as a reference for the dissertation.

---

## Project Goal

Build an automated, cost-efficient private cloud using OpenStack, deployed on commodity hardware, and expose it as a self-service PaaS product where companies can give their developers on-demand access to pre-configured development environments.

The project has three tracks:
1. **Infrastructure** — automated OpenStack deployment (the dissertation core)
2. **Product** — web portal for self-service dev environment reservation
3. **Dissertation** — written documentation, comparison with existing products, evaluation

---

## Technology Stack

| Layer | Technology | Why |
|---|---|---|
| Hypervisor (local) | Proxmox VE 9 | Free, Debian-based, excellent VM management, VLAN-aware networking |
| VM OS | Ubuntu 24.04 LTS | Required by Kolla-Ansible 2026.1; LTS = stability |
| Automation | Ansible (core 2.18) | Agentless, SSH-based, already used in the project |
| OpenStack deployment | Kolla-Ansible 2026.1 | Containerized OpenStack, simplifies multi-node deployment |
| OpenStack version | 2026.1 "Gazpacho" | Current release as of June 2026 |
| Distributed storage | Rook Ceph on K3S | Provides block storage for OpenStack (Glance, Cinder, Nova) |
| Kubernetes | K3S v1.36.1 | Lightweight, used only to run Rook Ceph operator |
| Container engine | Docker | Required by Kolla-Ansible |
| Networking | OVN (Open Virtual Network) | Default and recommended Neutron backend since OpenStack 2023.x |
| Portal backend | FastAPI + openstacksdk | Python-native OpenStack integration |
| Portal frontend | React + Tailwind | Component-based, good ecosystem |
| Portal database | PostgreSQL | Stores companies, users, reservations |
| Remote access | WireGuard | VPN for accessing the lab from anywhere |

---

## Infrastructure Architecture

### Physical Setup

One beefy laptop (Intel engineering sample CPU QTJ1 "Intel Genuine 0000", 64 GB RAM, two M.2 NVMe disks) running:
- **Disk 0**: Windows (kept for dual boot, selected via UEFI F7 boot menu)
- **Disk 1** (500 GB): Proxmox VE 9

### Proxmox Host

- IP: `192.168.0.100` (home network, static)
- Kernel: `7.0.2-6-pve` (Proxmox 9, Debian 13 Trixie)
- Network bridge: `vmbr0` — VLAN-aware, connected to physical NIC
- Web UI: `https://192.168.0.100:8006`

### Virtual Machines (4 total)

All VMs on Proxmox local-lvm storage (thin provisioned):

| VM | Role | Home IP | CPU | RAM | Disk 1 (OS) | Disk 2 (Ceph) |
|---|---|---|---|---|---|---|
| controller | OpenStack control plane | 192.168.0.101 | 4 vCPU (host) | 16 GB | 60 GB | 60 GB |
| compute | Nova compute + Neutron | 192.168.0.102 | 4 vCPU (host) | 16 GB | 60 GB | 60 GB |
| storage | K3S master + Ceph + Cinder | 192.168.0.103 | 4 vCPU (host) | 16 GB | 60 GB | 60 GB |
| portal | PaaS portal (outside OpenStack) | 192.168.0.104 | 2 vCPU (host) | 4 GB | 30 GB | — |

**VM settings rationale**:
- CPU type `host`: passes through real CPU flags (VT-x) enabling nested virtualization — required for Nova to boot VMs inside VMs
- Ballooning disabled: prevents Proxmox from reclaiming VM memory, which causes OpenStack services to crash
- KSM disabled: avoids unpredictable memory performance and side-channel risks between VMs
- Machine type q35 + OVMF: modern UEFI, required for Ubuntu 24.04
- VirtIO SCSI + VirtIO NIC: paravirtualized drivers, significantly better performance than emulated hardware
- Disk 2 left completely raw/unformatted: Rook Ceph requires a raw block device for its OSD

### Internal Networking (VLANs)

All inter-VM traffic runs over VLANs on `vmbr0`. Netplan on each VM creates VLAN sub-interfaces on top of the single `enp6s18` NIC:

| VLAN ID | Interface | Subnet | Purpose |
|---|---|---|---|
| 4000 | `enp6s18.4000` | 10.0.1.0/24 | Management — Ansible, Kolla-Ansible, K3S |
| 4001 | `enp6s18.4001` | 10.0.2.0/24 | Services — OpenStack APIs, Horizon |
| 4002 | `enp6s18.4002` | 10.0.3.0/24 | Storage — Ceph replication traffic |

The home network (192.168.0.x) interface is only used for SSH access from the Mac and package downloads. All OpenStack and K3S communication happens over the VLANs.

Internal VIP (Kolla-Ansible): `10.0.1.254` — virtual IP for OpenStack API endpoints.

---

## Automation Architecture

All automation lives in `resources/openstack-automation/cloud-deployment/`.

### Entry Point

`deploy.sh` orchestrates everything in sequence:
1. `ansible-playbook bootstrap-nodes.yml` — configures network and creates sysoperator user
2. `ansible-playbook cloud-deployment/k3s-ansible/playbooks/site.yml` — deploys K3S cluster
3. `ansible-playbook deploy-openstack.yml` — deploys Rook Ceph + Kolla-Ansible

### Ansible Roles

| Role | Hosts | What it does |
|---|---|---|
| `bootstrap_nodes` | all | Netplan VLAN setup, /etc/hosts, creates sysoperator user + SSH keys |
| `prep_openstack_nodes` | openstack_nodes | Installs pip and docker Python SDK (>=7.0) on all nodes |
| `deploy_ceph` | storage_nodes | Installs Helm, deploys ingress-nginx, deploys Rook Ceph, creates pools and keyrings for OpenStack |
| `install_kolla` | management_nodes | Creates Python venv, installs ansible-core + kolla-ansible, writes /etc/ansible/ansible.cfg |
| `deploy_openstack` | management_nodes | Configures /etc/kolla (globals.yml, keyrings, ceph.conf), runs full kolla-ansible pipeline |

The management node is currently the controller VM. The `[management_nodes]` inventory group is separate — switching to a dedicated 4th node only requires updating that group.

### Kolla-Ansible Pipeline (inside deploy_openstack)

Runs 5 commands in sequence on the controller node:
1. `kolla-ansible bootstrap-servers` — prepares nodes (installs Docker, sets up users)
2. `kolla-ansible prechecks` — validates configuration before deployment
3. `kolla-ansible deploy` — deploys all OpenStack service containers
4. `kolla-ansible post-deploy` — generates clouds.yaml, finalises config
5. `kolla-ansible init-runonce` — creates demo network, uploads base image, creates default flavors

### OpenStack Services Deployed

Keystone, Glance (Ceph backend), Nova (Ceph backend), Neutron (OVN), Cinder (Ceph backend), Heat, Horizon.

### Ceph Integration

Rook Ceph runs on K3S (storage node is the K3S server, controller and compute are agents). Ceph pools:
- `images` — Glance VM images
- `volumes` — Cinder block volumes
- `backups` — Cinder volume backups
- `vms` — Nova ephemeral storage

Each OpenStack service gets its own Ceph auth key (`client.glance`, `client.cinder`, `client.nova`, etc.).

---

## Key Configuration Files

| File | Purpose |
|---|---|
| `ansible.cfg` | Project-wide Ansible settings — host key checking, pipelining, vault password file |
| `inventory/inventory.ini` | Ansible inventory — hostnames resolved via host_vars |
| `inventory/inventory-k3s.yaml` | K3S cluster inventory — server (storage) + agents (controller, compute) |
| `host_vars/controller.yaml` | controller home IP + Netplan VLAN config |
| `host_vars/compute.yaml` | compute home IP + Netplan VLAN config |
| `host_vars/storage.yaml` | storage home IP + Netplan VLAN config |
| `group_vars/all/vars.yaml` | Shared vars: ansible_user, SSH key, Python interpreter, vault references |
| `group_vars/all/vault.yaml` | Ansible-vault encrypted secrets (passwords, K3S token) |
| `roles/install_kolla/defaults/main.yml` | Kolla venv path, release, repo, dep lists |
| `roles/deploy_openstack/defaults/main.yml` | Ceph key paths, /etc/kolla/config dirs, keyring file list |
| `roles/deploy_openstack/files/globals.yml` | Kolla-Ansible OpenStack configuration (~900 lines) |
| `roles/install_kolla/files/multinode` | Kolla-Ansible inventory mapping services to nodes |
| `.ansible-lint` | Lint config — excludes k3s-ansible and globals.yml from yamllint; skips var-naming[no-role-prefix] |

---

## Kolla-Ansible 2026.1 Breaking Changes (from 2024.1)

| Change | Impact | Status |
|---|---|---|
| Ubuntu 22.04 host support dropped | VMs must run Ubuntu 24.04 | Done — VMs use 24.04 |
| Ceph keyring variable names removed | `ceph_cinder_keyring` etc. gone; filenames now auto-derived as `$cluster.client.$user.keyring` | Done — removed from globals.yml |
| `om_enable_rabbitmq_high_availability` removed | Must be removed from globals.yml | N/A — was never in globals.yml |
| Ansible core 2.17+ required | Must be met in the Kolla venv | Done — venv installs `>=2.17` |
| OVN SB DB relay containers added | New `[ovn-sb-db-relay:children]` group in multinode; relay containers deploy automatically | Done — group added to multinode pointing to `ovn-database` (control) |
| Redis → Valkey migration complete | `redis_master_password` removed from passwords.yml; `[valkey:children]` added, `[redis:children]` kept temporarily with a TODO comment | Done — both groups in multinode; valkey/redis both disabled by default for our minimal setup |
| Kolla-Ansible install method | Must install from stable branch, not `@master` | Done — pinned to `stable/2026.1` |
| Prometheus upgraded v2 → v3 | Breaking changes; ensure v2.5.5+ before upgrading | Pending — globals.yml review |
| MariaDB InnoDB log file size | Increased from 96MB to 2GB | No action needed — Kolla handles this |

---

## OpenStack 2026.1 "Gazpacho" — Notable New Features

Relevant to the dissertation:
- **Parallel live migrations** in Nova — multiple memory connections simultaneously, faster VM migration
- **OVN BGP support** in Neutron — improved routing capabilities
- **Native Python threading** replacing eventlet across services — better performance and maintainability
- **IOThread per QEMU instance** now default — disk I/O offloaded from vCPU threads

---

## Automation Code Quality Improvements

During the update to 2026.1, the automation was reviewed and improved. All fixes apply production best practices to what was previously a working-but-rough codebase.

| # | Fix | Why | How | Improvement |
|---|---|---|---|---|
| 1 | `ansible.cfg` updated | Had invalid config keys, `scp_if_ssh` deprecated | Removed invalid keys, added `pipelining`, `interpreter_python`, `vault_password_file` | Faster SSH, no warnings, vault automatic |
| 2 | Venv path variabilized | `/opt/venv/kolla` hardcoded in 5 files | Added `kolla_venv_path` to defaults, `pyvenv` converted to Jinja2 template | Single source of truth |
| 3 | `with_items` → `loop` | Deprecated in Ansible 2.5+ | Replaced in 3 task files | Future-proof syntax |
| 4 | `createhome` → `create_home` | Deprecated parameter name | One-line change | Eliminates deprecation warning |
| 5 | `upgrade: dist` → `upgrade: safe` | `dist` can upgrade kernel unexpectedly on live servers | One word change in install-dependencies.yaml | Safe for running nodes |
| 6 | Debug tasks behind guard | Ran on every execution, cluttered logs | `when: debug_mode \| default(false)` | Enable with `-e debug_mode=true` when needed |
| 7 | ansible-core version constraint | Capped at 2.16, incompatible with Kolla 2026.1 | Changed to `>=2.17` | Kolla-Ansible 2026.1 works correctly |
| 8 | Constraints URL | Pinned to 2023.2 | Uses `{{ openstack_release }}` variable | Correct packages, easy to update |
| 9 | `kolla-genpwd` idempotency | Re-running regenerated all passwords, breaking deployments | Added `creates: /etc/kolla/passwords.yml` | Safe to re-run playbooks |
| 10 | `init-runonce` absolute path | Relative path fragile, breaks if cwd is wrong | `{{ kolla_venv_path }}/share/kolla-ansible/init-runonce` | Always resolves correctly |
| 11 | `/tmp` → `/var/tmp` variables | `/tmp` wiped on reboot — keyrings lost if node reboots mid-deploy | Added `ceph_keyrings_tmp_dir` and `ceph_fsid_tmp_file` variables | Survives reboots, configurable |
| 12 | Pin kolla-ansible to stable | `@master` not reproducible | `@stable/{{ openstack_release }}` | Same code every run |
| 13 | `config-kolla.yaml` cleanup | Wrong indentation, trailing whitespace, blank lines | Full rewrite with consistent 4-space indent | Readable, no lint warnings |
| 14 | ansible-vault for secrets | Passwords and K3S token in plaintext | Encrypted `vault.yaml`, references in `vars.yaml`, `.vault_pass` in `.gitignore` | Safe to push to GitHub |
| 15 | Docker SDK version pinned | Ubuntu 24.04 apt ships python3-docker 5.0.3 (broken with requests>=2.32) | `prep_openstack_nodes` role installs `docker>=7.0` via pip `--break-system-packages` | Docker modules work; fix baked into automation |
| 16 | kolla-ansible CLI syntax | `-i INVENTORY` goes after subcommand in 2026.1 (cliff migration) | Updated all command tasks | Commands actually run |
| 17 | kolla-ansible PATH | `ansible-playbook` not found when kolla internally calls it | `environment: PATH: "{{ kolla_venv_path }}/bin:..."` on all kolla tasks | kolla-ansible can find its own tooling |
| 18 | Host key checking disabled | kolla-ansible SSH from controller to other nodes fails on first contact | `/etc/ansible/ansible.cfg` with `host_key_checking = False` deployed to controller | kolla-ansible bootstrap-servers succeeds |
| 19 | kolla-genpwd idempotency | `creates:` guard skipped genpwd because passwords.yml exists but is empty | Removed `creates:` guard; genpwd only fills missing keys, never regenerates | passwords.yml populated correctly |
| 20 | Role naming and structure refactor | Hyphens in role names (lint violation), `prep-management-node` does too much | Renamed all roles to snake_case; split into `install_kolla` + `deploy_openstack`; merged bootstrap roles | 0 ansible-lint failures (production profile) |
| 21 | All task files snake_case | Mixed `.yaml`/`.yml`, hyphens in filenames | Standardised to `.yml`, underscores | Consistent naming |
| 22 | `changed_when:` on all commands | `no-changed-when` lint violations on 12 tasks | Set `changed_when: true/false` semantically per task | Accurate change reporting |
| 23 | keepalived drops VIP due to ProxySQL check | `check_alive_proxysql.sh` uses socat plain-text on a MySQL-protocol socket → connection reset → keepalived loses MASTER → VIP removed → "No route to host" to `10.0.1.254:3306` | Set `keepalived_track_script_enabled: "no"` in globals.yml; regenerate keepalived.conf via `kolla-ansible reconfigure` | VIP held unconditionally; ProxySQL reachable |
| 24 | nova-compute cannot register hypervisor | `ceph.conf.j2` template had no trailing newline → rendered file rejected by RADOS `conf_read_file()` with `InvalidArgumentError` → nova-compute fails `get_available_resource()` → hypervisor never appears in placement | Added trailing newline to `ceph.conf.j2` template; added `kolla_reconfigure` tag to `deploy_kolla.yml` for automation-driven config updates | nova-compute registers on next reconfigure |
| 25 | Nova reports full Ceph pool per hypervisor | All 3 compute nodes share one Ceph `vms` pool (180 GB). Each node reports full pool size to Placement → Placement thinks 540 GB is available. Known open Nova bug ([#1522307](https://bugs.launchpad.net/nova/+bug/1522307), unfixed since 2015) | Set `disk_allocation_ratio = 0.33` (1/N_nodes) in `/etc/kolla/config/nova/nova-compute.conf`. Scales each node's effective DISK_GB to 60 GB so aggregate = real pool size. **Note:** update ratio when adding/removing compute nodes | Placement sees correct aggregate disk; scheduling works |
| 26 | Only 1 of 3 VMs was a Nova compute node | multinode `[compute]` group only had `compute` — `controller` and `storage` not included | Added `controller` and `storage` to `[compute]` in `roles/install_kolla/files/multinode` | All 3 VMs are hypervisors (full convergence) |
| 27 | nova-compute never deployed to storage despite being in [compute] | Ansible host pattern `hosts: compute` in kolla-ansible's `nova.yml` resolves to the **HOST** named "compute" (not the **GROUP** named "compute") when both a host and group share the same name. This is a known Ansible limitation: when `hosts: <name>` is evaluated and both a group and a host exist with that name, the host takes precedence. `stor01` (storage) was only reachable via groups like `nova-conductor` (controller only), so nova-cell silently skipped it. | Renamed `compute` → `cmp01 ansible_host=10.0.1.3` and `storage` → `stor01 ansible_host=10.0.1.4` in multinode. Nova registers using `ansible_facts.hostname` (the actual OS hostname), not the inventory alias, so hypervisor names are unchanged. Added comment in multinode warning about host/group name collisions. | All 3 hypervisors (compute, controller, storage) registered in Nova Placement |
| 28 | `bootstrap-nodes.yml` targeted `hosts: all` | Inventory includes `localhost` (Mac) in `[localhost]` group for deploy-openstack.yml delegate tasks. `all` includes localhost so Ansible tried to create a sysoperator user and apply netplan on macOS — hanging on `become: true` sudo prompt | Changed `hosts: all` → `hosts: openstack_nodes` | Bootstrap only runs on actual OpenStack nodes |
| 29 | `Apply netplan` handler blocking on SSH drop | `netplan apply` restarts management NIC briefly, dropping the Ansible SSH connection. Synchronous handler waits indefinitely | Added `async: 60, poll: 5` to handler; added `retries = 5` in `ansible.cfg [ssh_connection]` | Handler polls every 5s with auto-SSH retry; connection drop is tolerated |

---

## Challenges & Solutions

### Challenge 1: Proxmox on Engineering Sample CPU
**Problem**: Intel engineering sample CPU (QTJ1, "Intel Genuine 0000") caused initramfs built in `hostonly` mode to miss the NVMe controller driver → kernel panic (`VFS: Unable to mount root fs on unknown-block(0,0)`) on every boot.

**Solution**: Booted into rescue shell from Proxmox installer USB (Ctrl+Alt+F3), activated LVM (`vgchange -ay`), mounted installed root (`mount /dev/pve/root /mnt`), chrooted in, added `MODULES=most` to `/etc/initramfs-tools/initramfs.conf`, ran `update-initramfs -u -k 7.0.2-6-pve`.

### Challenge 2: Ventoy rdinit Injection
**Problem**: Proxmox installed while booted from Ventoy USB. Ventoy injected `rdinit=/vtoy/vtoy` into GRUB via `/etc/default/grub.d/installer.cfg` — every boot tried to use Ventoy's init process instead of the real one.

**Discovery**: Found by pressing `e` at GRUB menu and seeing `rdinit=/vtoy/vtoy` on the linux line. Removing it manually booted the system successfully.

**Fix**: Deleted `/etc/default/grub.d/installer.cfg`, ran `update-grub` to regenerate clean config.

**Lesson**: Ventoy modifies the boot environment in ways that can persist into the installed system. Use balenaEtcher or `dd` for Proxmox installs.

### Challenge 3: UEFI Boot Not Detecting Rufus USB
**Problem**: Rufus DD mode produced a USB that appeared in the UEFI boot menu but failed with `/boot doesn't exist`.

**Solution**: Switched to Ventoy — installs its own EFI bootloader, ISOs are simply copied as files. More reliable for UEFI systems.

### Challenge 4: Dual Booting Two NVMe Drives
**Problem**: Two M.2 NVMe drives. Proxmox must go on disk 1 without touching Windows on disk 0.

**Solution**: Carefully selected disk 1 in the Proxmox installer. UEFI F7 boot menu selects between OSes — no GRUB chainloading needed, each OS has its own EFI entry.

### Challenge 6: Rook Ceph Cluster Stuck at "Detecting Ceph Version"
**Problem**: The Rook cluster installation kept timing out. The Helm `--wait` flag gave up after 10 minutes, but Ceph image pull + OSD initialisation takes 15-20 minutes on first install. Repeated retries left immutable StorageClass resources behind, blocking future Helm upgrades.

**Root cause chain**: First install used wrong Ceph image (v18.2.2, too old) → version check failed → Helm timed out → left StorageClasses in broken state → second install couldn't patch immutable StorageClasses → repeated cleanup attempts created more conflicting state.

**Fix**: Decoupled Helm install from readiness wait (`wait: false` on install, separate `k8s_info` task with 30-minute timeout). Properly cleaned up using the official Rook teardown procedure before retrying.

**Lesson**: For Kubernetes operator deployments, never use `--wait` on the Helm install. Operators work asynchronously — let the install complete immediately, then poll for readiness separately with a generous timeout.

### Challenge 7: Rook Ceph CPU Requests Saturating 4 vCPU VMs
**Problem**: Production default CPU requests (mon: 1000m, osd: 1000m, mgr: 500m) saturated all 4 vCPUs on the controller node, leaving pending pods unable to schedule.

**Fix**: Added `cephClusterSpec.resources` overrides in `rook-cluster-overrides.yaml` reducing all component CPU requests to 25-250m appropriate for a dev setup.

**Lesson**: Always override resource requests when running production Helm charts on dev hardware. Defaults are sized for production clusters.

### Challenge 8: Ceph Dashboard 502 Bad Gateway
**Problem**: The Rook Helm chart auto-creates an Ingress referencing port name `http-dashboard`, but the dashboard service only exposes `https-dashboard` (port 8443) when SSL is enabled. The Ingress silently broke because the port name didn't match.

**Fix**: Added `cephClusterSpec.dashboard.ssl: false` to overrides. With SSL disabled, Rook creates the service with `http-dashboard` (port 7000) which matches the auto-generated Ingress. Traffic is plain HTTP from ingress-nginx to the backend, with TLS termination handled at the ingress level if needed.

**Lesson**: When the Ingress references a service port by name, name mismatches cause silent routing failures. Always verify port names match between the Ingress backend and the actual service.

### Challenge 9: Ubuntu 24.04 python3-docker Incompatible with requests>=2.32
**Problem**: Kolla-Ansible 2026.1 uses the `docker` Python SDK for its Ansible modules. Ubuntu 24.04 ships `python3-docker` 5.0.3 via apt. That version registers a custom `http+docker://` URL scheme which `requests>=2.32` silently dropped, causing all kolla-ansible module invocations to fail with connection errors.

**Root cause**: The `http+docker` scheme was removed from the `requests` library in 2.32 as part of a security hardening pass. The apt package (5.0.3) was never updated on Ubuntu 24.04 and is now permanently incompatible with any modern pip environment.

**Fix**: Created the `prep_openstack_nodes` role that runs on all OpenStack nodes before any kolla work. It installs `docker>=7.0` via pip with `--break-system-packages`. Version 7.x dropped the http+docker scheme entirely and uses a unix socket approach that doesn't depend on `requests`.

**Lesson**: Never rely on apt-packaged Python SDKs for tools with rapid release cycles (Docker, Kubernetes). Always pin via pip with a version constraint and bake the fix into automation from day one — ad-hoc `pip install` on a live node is lost the moment the node is rebuilt.

### Challenge 10: kolla-ansible 2026.1 CLI Syntax Change
**Problem**: kolla-ansible 2026.1 migrated its CLI to `cliff`. The `-i INVENTORY` flag moved from before the subcommand to after it. Old invocations like `kolla-ansible -i /etc/kolla/inventory bootstrap-servers` silently failed.

**Fix**: Updated all kolla-ansible command tasks to use the new syntax: `kolla-ansible bootstrap-servers -i /etc/kolla/inventory`.

### Challenge 11: kolla-ansible prechecks Failing — `--use-test-images` Required
**Problem**: Prechecks failed with errors about not using official Kolla images. The `quay.io/openstack.kolla` registry is the official source, but kolla-ansible requires explicit acknowledgement of this to avoid accidentally using unofficial or modified images in production contexts.

**Fix**: Added `--use-test-images` flag to all kolla-ansible commands (bootstrap-servers, prechecks, deploy, post-deploy). This flag acknowledges the use of pre-built images from the official registry.

### Challenge 12: ansible-playbook Not Found When kolla-ansible Runs
**Problem**: kolla-ansible internally invokes `ansible-playbook`, but on the controller node that binary only existed inside the kolla venv (`/opt/venv/kolla/bin`). Without setting `PATH`, the shell looked for it system-wide, found nothing, and failed.

**Fix**: Added `environment: PATH: "{{ kolla_venv_path }}/bin:/usr/local/sbin:..."` to all kolla-ansible command tasks.

### Challenge 13: SSH Host Key Verification Failed from Controller
**Problem**: When kolla-ansible runs on the controller and connects to compute/storage nodes via SSH, those host keys had not been accepted. The SSH client's strict host key checking blocked the connection.

**Fix**: Created `/etc/ansible/ansible.cfg` on the controller with `host_key_checking = False` and `pipelining = True`. This is placed in `/etc/ansible/` (the system-wide location) rather than the kolla-ansible project directory, so it applies to all ansible invocations including those kolla-ansible makes internally.

### Challenge 14: kolla-genpwd Skipping — passwords.yml Already Exists
**Problem**: The `creates: /etc/kolla/passwords.yml` guard on the `kolla-genpwd` task prevented it from running on re-runs. The file exists (from the kolla config copy step) but is empty of actual values. kolla-genpwd checks for missing keys and fills them in; it does not overwrite existing values. Skipping it leaves passwords.yml empty.

**Fix**: Removed the `creates:` guard. kolla-genpwd is idempotent — it only fills in keys that are missing, never regenerates keys that already have values. Running it unconditionally is safe.

### Challenge 15: keepalived Drops VIP — ProxySQL Health Check Protocol Mismatch
**Problem**: After ProxySQL was enabled, kolla-ansible `deploy` failed with `[Errno 113] No route to host` when trying to connect to `10.0.1.254:3306`. ProxySQL was running and bound to that address, but `ip addr show enp6s18.4000` showed the VIP was not on the interface. keepalived logs showed: `Script 'check_alive' now returning 1 → VRRP_Script(check_alive) failed → MASTER→BACKUP`.

**Root cause**: kolla-ansible ships `check_alive_proxysql.sh` which does:
```bash
echo "show info" | socat unix-connect:/var/lib/kolla/proxysql/admin.sock stdio > /dev/null
```
This copies the pattern from `check_alive_haproxy.sh`, but HAProxy's admin socket uses a **plain-text protocol** while ProxySQL's admin socket uses the **MySQL wire protocol**. On connection, ProxySQL immediately sends a binary MySQL HandshakeV10 packet. socat's plain-text `echo "show info"` is not a valid MySQL handshake response, so ProxySQL resets the connection (`ECONNRESET`). socat exits 1. keepalived marks the track script as failed, transitions from MASTER to BACKUP, and removes the VIP from the interface. This is an unfiled bug in kolla-ansible 2026.1.

**Fix**: Set `keepalived_track_script_enabled: "no"` in globals.yml. This causes the keepalived template to omit the `vrrp_script` block and `track_script` from `keepalived.conf` — keepalived holds the VIP unconditionally. For a single-controller deployment there is no failover target anyway, so health-check-based VIP failover provides no benefit.

Applied via `kolla-ansible reconfigure -i /etc/kolla/inventory --tags loadbalancer`.

**Lesson**: When kolla-ansible adds a new service (ProxySQL in 2026.1), its associated health checks may not be correctly implemented. Always verify the keepalived check scripts actually work against the services they target before running `deploy`.

### Challenge 16: Nova Reports Full Ceph Pool Size per Hypervisor

**Problem**: After enabling all 3 nodes as compute nodes, `openstack hypervisor list` showed each hypervisor reporting 180 GB available disk — the full size of the shared Ceph `vms` pool. With 3 nodes, Placement believed 540 GB was schedulable when only 180 GB physically exists.

**Root cause**: This is a known, open Nova bug ([Launchpad #1522307](https://bugs.launchpad.net/nova/+bug/1522307), open since 2015). Nova's resource tracker calls `ceph df` to report available disk. Since all compute nodes share the same RBD pool, each independently reports the full pool capacity. Nova has no concept of "these N nodes share a pool" — there is no automated fix. Nova core developer Dan Smith: *"this has always been broken in this way with Nova and shared storage."*

**Fix**: Set `disk_allocation_ratio = 0.33` (= 1/3 nodes) in `/etc/kolla/config/nova/nova-compute.conf`. This is the operator workaround described by Nova developer Sean Mooney on the openstack-discuss mailing list. The ratio scales each node's reported DISK_GB as seen by Placement:

```
effective_per_node = pool_size × ratio = 180 × 0.33 = ~60 GB
total_across_3_nodes = 3 × 60 = 180 GB ✓
```

The `nova-compute.conf` override file is pushed to `/etc/kolla/config/nova/` by the `configure_kolla` Ansible task, and applied via `kolla-ansible reconfigure`.

**Caveats**: This is a hardcoded workaround, not an architectural fix. If compute nodes are added or removed, `disk_allocation_ratio` must be updated to `1/N_nodes` and reconfigure run. The comment in `nova-compute.conf` documents this requirement. The architecturally correct fix (Placement shared resource provider with `MISC_SHARES_VIA_AGGREGATE` trait) requires manual Placement API calls with fake allocations and is not automated by Nova itself.

---

### Challenge 17: Floating IP Network Not Routable from Proxmox

**Problem**: After OpenStack deployed, floating IPs (`10.0.2.0/24`) were assigned and visible in Horizon but completely unreachable from outside the controller VM. Attempts to ping `10.0.2.x` from the Mac or Proxmox timed out.

**Root cause**: Floating IPs live inside a `qrouter` network namespace managed by the Neutron L3 agent. The namespace applies DNAT rules via iptables but only sees packets that enter through the OVS `br-ex` bridge. OVS cannot loop traffic that originates from the Linux host network stack (the controller VM's own interfaces) back into the namespace — ARP for the qrouter MAC fails, packets are dropped. Static routes pointing at the controller's home NIC (`enp6s18`) never reached `br-ex` correctly. VLAN subinterfaces on Proxmox (`vmbr0.4001`) don't forward to VM bridge ports — confirmed by tcpdump showing 0 packets at the NIC level.

**Fix**: Created a dedicated internal bridge `vmbr1` on Proxmox (`10.0.2.1/24`, no physical uplink). Hot-added a second NIC to the controller VM connected to `vmbr1`. Inside the controller, this NIC appears as `enp6s19`. Changed `neutron_external_interface` in `globals.yml` from `enp6s18.4001` to `enp6s19`. Ran `kolla-ansible reconfigure`. OVS now puts `enp6s19` into `br-ex`, giving it a proper L2 uplink. Proxmox at `10.0.2.1` becomes the upstream gateway — it can ARP against OVS normally, and routing from WireGuard clients flows: `Mac → Proxmox vmbr1 → br-ex → qrouter namespace → VM`.

**Proxmox changes (documented in PLATFORM_GUIDE.md Step 4, not automated):**
```bash
# Add to /etc/network/interfaces:
# auto vmbr1
# iface vmbr1 inet static
#     address 10.0.2.1/24
#     bridge-ports none
#     bridge-stp off
#     bridge-fd 0
ifup vmbr1
qm set 100 --net1 virtio,bridge=vmbr1
```

**Automation changes baked in:**
- `host_vars/controller.yaml`: added `enp6s19` as a raw ethernet interface (no addresses — OVS manages it)
- `roles/bootstrap_nodes/templates/netplan_config.j2`: made `addresses` and `routes` optional for ethernet entries so raw interfaces render correctly
- `roles/deploy_openstack/files/globals.yml`: `neutron_external_interface: enp6s19`

### Challenge 18: OpenStack VMs Cannot Reach the Internet

**Problem**: After creating the `vpn-gateway` VM and trying to install packages, `apt-get update` failed with DNS and connection errors. The VM had a floating IP but no internet access.

**Root cause**: `vmbr1` is an internal-only bridge — it has no physical uplink. When a VM does outbound traffic, qrouter SNATs it to the floating IP (`10.0.2.x`), which arrives at Proxmox on `vmbr1`. But Proxmox had no rule to forward this traffic onward to `vmbr0` (the home network bridge), so packets were dropped.

**Fix**: Enabled IP forwarding on Proxmox and added a MASQUERADE rule:
```bash
echo net.ipv4.ip_forward=1 >> /etc/sysctl.conf && sysctl -p
iptables -t nat -A POSTROUTING -s 10.0.2.0/24 -o vmbr0 -j MASQUERADE
```
Traffic path: VM → qrouter SNAT → Proxmox vmbr1 → MASQUERADE via vmbr0 → home router → internet. Double-NAT, but works correctly in a home lab.

### Challenge 19: WireGuard PostUp Fails — `iptables: command not found`

**Problem**: After configuring WireGuard on the `vpn-gateway` VM (Ubuntu 24.04), `wg-quick up wg0` failed immediately. Logs showed: `/usr/bin/wg-quick: line 295: iptables: command not found`.

**Root cause**: Ubuntu 24.04 minimal cloud image does not include the `iptables` package. The `nftables` package was present (pulled in as a dnsmasq dependency) but the `iptables` binary itself was absent. wg-quick's PostUp rules use `iptables` syntax.

**Fix**: `apt install -y iptables` before starting WireGuard. Bake this into the provisioning automation when the vpn-gateway setup is added to phase 6.

### Challenge 20: `delegate_to: localhost` Task Hanging — `become: true` Inherited from Play

**Problem**: The `init_vpn_gateway` Ansible role has a task that saves the WireGuard server public key to the Mac using `ansible.builtin.copy` with `delegate_to: localhost`. The task hung indefinitely, blocking the entire playbook run.

**Root cause**: `deploy-openstack.yml` sets `become: true` at the play level. With `import_tasks`, this is inherited by all tasks in the imported file — including the `delegate_to: localhost` copy task. Ansible therefore tried to `sudo` on the Mac to write the file, and waited for a password prompt that never came (running in the background via Claude Code's Bash tool).

**Fix**: Added `become: false` explicitly to the copy task to override the play-level setting.

**Lesson**: Any `delegate_to: localhost` task in a play with `become: true` must explicitly set `become: false` to prevent Ansible from trying to sudo on the Ansible controller.

### Challenge 21: Stale Proxmox DNAT Rule Blocking WireGuard Handshake

**Problem**: After recreating the vpn-gateway VM and reassigning the floating IP to `10.0.2.150`, the user WireGuard tunnel connected at the interface level but no handshake completed — routes for `10.0.0.0/24` never appeared in the Mac routing table, and all pings timed out.

**Root cause**: The Proxmox PREROUTING chain had three DNAT rules for port 51821: one stale rule pointing to `10.0.2.187` (the original manual IP, long gone) and two duplicates pointing to `10.0.2.150`. iptables applies the **first matching rule** — so all WireGuard handshake packets were being forwarded to `10.0.2.187`, which no longer existed.

**Fix**: Flushed the entire PREROUTING chain (`iptables -t nat -F PREROUTING`) and added a single clean DNAT rule to `10.0.2.150`. On the next WireGuard tunnel toggle, the handshake completed immediately.

**Lesson**: When debugging WireGuard connectivity, always check `iptables -t nat -L PREROUTING -n` for duplicate or stale DNAT rules — iptables silently takes the first match, so duplicate rules with different destinations are a common silent failure mode.

**Prevention**: Floating IP hardcoded to `10.0.2.150` in automation defaults so the Proxmox DNAT rule never needs changing after a redeploy. PREROUTING is now documented as a one-time setup step in PLATFORM_GUIDE.md.

### Challenge 22: Bootstrap Playbook Hanging on Localhost — `hosts: all` Includes Mac

**Problem**: `deploy.sh` Phase 1 appeared to hang indefinitely after "Gathering Facts" on the three nodes. The three SSH `notty` Ansible pipelining sessions were visible on the nodes, but no Python tasks were running — yet the deployment was stuck.

**Root cause**: `bootstrap-nodes.yml` targeted `hosts: all`. The inventory includes `localhost` in the `[localhost]` group (used by deploy-openstack.yml for local Ansible controller tasks). `all` includes every host in the inventory, so Ansible tried to run the `bootstrap_nodes` role on the Mac: creating a `sysoperator` user, writing a netplan config, running `netplan apply`. None of these make sense on macOS, and `become: true` with `sudo` on the Mac would hang waiting for a password.

**Fix**: Changed `hosts: all` → `hosts: openstack_nodes` in `bootstrap-nodes.yml`. The bootstrap role only belongs on the three OpenStack VMs.

**Lesson**: `hosts: all` in a playbook is almost always wrong unless you genuinely want every host including the Ansible controller. Check `ansible-inventory --list` to see what `all` expands to in your inventory.

### Challenge 23: Ansible Hangs After `netplan apply` — SSH Connection Drops During Handler

**Problem**: The `Apply netplan` handler ran `netplan apply` synchronously. When netplan restarted the management interface (`enp6s18`) to add new VLAN sub-interfaces (4000/4001/4002), the SSH connection briefly dropped. Ansible waited for the connection to recover but the default poll mechanism blocked.

**Fix**:
1. Added `async: 60, poll: 5` to the handler — Ansible launches `netplan apply` in the background and polls via SSH every 5 seconds. If SSH drops briefly, it retries before the next poll.
2. Added `retries = 5` to `[ssh_connection]` in `ansible.cfg` so Ansible automatically retries dropped SSH connections before failing a task.

### Challenge 24: Ceph Dashboard Accessible Without VPN — Three Failed Approaches

**Problem**: `ceph.tudu.io` was reachable directly from the home network without any VPN. The ingress-nginx pod was exposed via K3S Klipper LoadBalancer on `192.168.0.103:80/443` (the storage node's Proxmox LAN IP). Wanted: dashboard accessible only via admin VPN, blocked otherwise.

**Approach 1 — nginx-ingress `whitelist-source-range` annotation (failed)**
Added `nginx.ingress.kubernetes.io/whitelist-source-range: "10.0.1.0/24,10.99.0.0/24"` to the Ceph dashboard Ingress. Ingress appeared correctly annotated in `kubectl describe`. But the restriction had no effect — requests from `192.168.0.x` still reached the dashboard.

Root cause: K3S uses Flannel as the CNI. Flannel SNATs all traffic arriving at the node (from outside the cluster) to a pod CIDR address (`10.42.0.x`) before it enters the nginx-ingress pod. The `whitelist-source-range` annotation is evaluated inside the nginx pod, so it sees the SNAT'd address, not the real client IP. It can never block external traffic this way.

**Approach 2 — nginx-ingress `controller.extraArgs.bind-address` (failed)**
Attempted to bind nginx-ingress only to the management VLAN IP (`10.0.1.4`) so it never listens on `192.168.0.103`. Set via `helm upgrade --set 'controller.extraArgs.bind-address=10.0.1.4'`. The updated pod crashed immediately: `unknown flag: --bind-address`. The flag does not exist in nginx-ingress — it was confused with a flag from a different project. Rolled back with `helm upgrade --reset-then-reuse-values --set-json 'controller.extraArgs={}'`.

**Approach 3 — iptables INPUT chain DROP (failed)**
Added INPUT chain DROP rules for ports 80 and 443 on `eth0`. Rules appeared correctly in `iptables -L INPUT`. Traffic still passed through.

Root cause: K3S Klipper LoadBalancer applies DNAT in the `nat` table `PREROUTING` chain — it rewrites the destination from `192.168.0.103:80` to the nginx-ingress NodePort before the packet reaches INPUT. Packets never hit the INPUT chain. Rule counter stayed at 0.

**Working fix — `raw` table PREROUTING DROP**
The `raw` table runs before `nat` in Netfilter's processing order. A DROP in `raw PREROUTING` fires before Klipper's DNAT rewrite:
```bash
iptables -t raw -I PREROUTING -i eth0 -p tcp --dport 80 -j DROP
iptables -t raw -I PREROUTING -i eth0 -p tcp --dport 443 -j DROP
netfilter-persistent save
```
Traffic via `eth0` (home LAN) is now dropped before DNAT. Traffic via `eth0.4000` (management VLAN) is a different interface and is unaffected — admin VPN traffic arrives there and reaches the dashboard normally.

`/etc/hosts` on the Mac also updated from `192.168.0.103 ceph.tudu.io` → `10.0.1.4 ceph.tudu.io` so the hostname resolves to the management VLAN IP. With this change: admin VPN → `10.0.1.4` reachable → dashboard works; without admin VPN → `10.0.1.4` unreachable → connection refused at network level (no VPN route exists).

Automation (`deploy_ingress_nginx.yml`) updated to use `table: raw, chain: PREROUTING` in the `ansible.builtin.iptables` task.

**Lesson**: K3S Klipper LoadBalancer intercepts traffic at the `nat PREROUTING` level. Any iptables restriction that runs after `nat PREROUTING` (INPUT, FORWARD) will never see traffic destined to a Klipper-managed service. For port-level filtering on a K3S node, use `raw PREROUTING` (runs before nat) or filter at the CNI/network policy level.

### Challenge 25: User VPN AllowedIPs Too Broad

**Problem**: The initial user VPN client config had `AllowedIPs = 10.0.0.0/16`. This routed the entire `10.0.0.0/16` range through the tunnel — including `10.0.1.0/24` (management VLAN) and `10.0.2.0/24` (services VLAN), giving user VPN clients access to Horizon, OpenStack APIs, and the Ceph dashboard.

**Fix**: Changed client `AllowedIPs` to `10.0.0.0/24, 10.99.1.0/24` — only the tenant VM network and the VPN tunnel subnet. Updated the vpn-gateway iptables `FORWARD` rules in `vpn_gateway_userdata.j2` to only forward packets destined for `10.0.0.0/24` (via `-d {{ vpn_gateway_routed_subnet }}` on ingress and `-s {{ vpn_gateway_routed_subnet }}` on egress). Added `vpn_gateway_routed_subnet: "10.0.0.0/24"` to `deploy_openstack/defaults/main.yml`.

**Result**: User VPN clients can only reach `10.0.0.0/24` (their dev VMs). Management VLAN, services VLAN, and all OpenStack/Ceph management interfaces are unreachable. Admin VPN (separate server on Proxmox, port 51820) retains full access.

### Challenge 5: K3S Inventory Using VLAN IPs Unreachable from Mac
**Problem**: k3s-ansible inventory uses 10.0.1.x IPs as host identifiers for K3S cluster-internal communication. Mac only has access to 192.168.0.x.

**Solution**: Added `ansible_host: 192.168.0.10x` per host in the inventory — Ansible SSHes via home network while K3S registers and communicates over the VLAN IPs.

### Challenge 29: VMs Don't Auto-Start After Proxmox Host Reboot — Missing `onboot`

**Problem**: After rebooting the Proxmox host, none of the lab VMs (100–103) came back up; the whole stack stayed down until each VM was started by hand.

**Root cause**: `proxmox-setup.sh` created every VM with `qm create` but never set the `onboot` flag. Proxmox defaults `onboot` to 0, so VMs only run until the next host reboot and then stay stopped. The provisioning succeeded and the lab worked, so the gap was invisible until the first host reboot.

**Fix**: Added `--onboot 1` to both `create_openstack_vm` and `create_portal_vm` in `proxmox-setup.sh`, so future provisioning persists boot-on-start. Because the create functions skip VMs that already exist, the flag does **not** get retrofitted by re-running the script — existing VMs were fixed and started in one pass on the host:

```bash
for v in 100 101 102 103; do
  qm set "$v" --onboot 1
  [ "$(qm status "$v" | awk '{print $2}')" = running ] || qm start "$v"
done
```

**Lesson**: `qm create` does not enable autostart by default — VMs meant to survive a host reboot need an explicit `--onboot 1`. Provisioning scripts should set it at create time, and the reboot-recovery loop is documented in `AGENT_RUNBOOK.md` §3.1.

---

## Decisions Log

**Why Proxmox instead of bare KVM/libvirt?**
Proxmox provides a clean web UI, handles VLAN-aware bridging out of the box, and the automation was already validated on Proxmox VMs. No additional setup overhead vs raw KVM.

**Why local laptop instead of Hetzner bare metal?**
Hetzner pricing increased significantly. Local setup costs nothing and the dissertation cost-efficiency argument is stronger: the same stack runs on existing commodity hardware with zero recurring cloud cost.

**Why Ubuntu 24.04 for VMs?**
Kolla-Ansible 2026.1 dropped Ubuntu 22.04 support. 24.04 is the current LTS and the only supported option.

**Why 4 vCPU per VM instead of 8?**
16 physical cores ÷ 3 VMs = 5.3. 8 vCPU per VM (24 total) would be 150% oversubscription risking CPU contention. 4 per VM (12 total) leaves 4 cores for the Proxmox host.

**Why thin provisioning for VM disks?**
Total allocated disk is 360 GB which exactly matches available storage. Thin provisioning means actual usage at deploy time is ~150-180 GB — comfortable headroom in practice.

**Why single NIC with VLANs instead of multiple NICs per VM?**
Matches the original Hetzner setup exactly — the networking model is unchanged, only the backing infrastructure differs (Proxmox VLAN-aware bridge replaces Hetzner vSwitches). One NIC per VM keeps Proxmox config simple.

**Why CPU type `host` in Proxmox VMs?**
Nova needs to boot VMs inside VMs (nested virtualization). CPU type `host` passes VT-x through to the VM. Without it Nova cannot create instances.

**Why `sysoperator` as the initial Ubuntu install user?**
The `create-sysoperator` Ansible role expects this user. Creating it during Ubuntu install means the role just configures the existing user (SSH keys, sudo) rather than creating from scratch.

**Why separate SSH key (`openstack_key`)?**
Keeps the OpenStack lab key isolated from personal SSH keys. Easier to rotate or revoke without affecting other SSH access.

**Why minimal Helm overrides instead of full values files?**
A 30KB values file copied from an older chart version caused most of the Rook Ceph pain — when the chart format changed, nothing was compatible. A minimal overrides file (~50 lines) only expresses what differs from chart defaults, survives upgrades cleanly, and makes the actual customisations obvious. Run `helm show values` to see defaults; only override what you need.

**Why decouple Helm install from readiness wait for operators?**
Kubernetes operators (Rook, etc.) deploy resources asynchronously over many minutes. Helm's `--wait` flag gives up before they finish. The correct pattern: `wait: false` on the Helm install task, then a separate wait task polling the operator's custom resource with a generous timeout (30+ minutes).

**Why disable dashboard SSL at the Ceph level?**
The Rook Helm chart auto-creates an Ingress referencing port name `http-dashboard`. When dashboard SSL is enabled, the service only exposes `https-dashboard` — a name mismatch that causes silent 502 errors. Disabling SSL at the Ceph level is correct when TLS is already terminated at the ingress layer.

**Why run kolla-ansible from the controller VM instead of a separate management node?**
The original Hetzner design had a 4th dedicated management VM that only ran kolla-ansible. For the local Proxmox setup, that 4th VM was eliminated to save RAM. The controller VM now serves dual duty: it runs kolla-ansible (which deploys OpenStack to all three nodes, including itself via `ansible_connection=local`) and then runs the resulting OpenStack control plane containers. This is standard for small/dev deployments — kolla-ansible handles self-bootstrapping correctly.

**Why ansible-vault for secrets?**
Plaintext passwords committed to a repo are readable by anyone with access. Vault encrypts secrets at rest — the vault password is shared out-of-band (e.g. password manager). Demonstrates production security practice even in a dissertation context.

**Why split `install_kolla` and `deploy_openstack` into separate roles?**
Installing a tool (the kolla-ansible venv) and deploying a service (OpenStack via kolla) are different lifecycle events. `install_kolla` runs once during initial setup; `deploy_openstack` may be re-run when changing configuration, updating globals.yml, or redeploying services. Keeping them separate means you can re-run just the configuration/deploy phase without reinstalling the tooling.

**Why merge `bootstrap-nodes` + `create-sysoperator` into `bootstrap_nodes`?**
Both roles are day-0 node setup, always run together in the same bootstrap playbook, and both target all nodes. There was no functional reason to keep them separate — it just added a level of indirection that made the playbook harder to read. One role, one clear responsibility: get a raw Ubuntu node ready for Ansible management.

**Why disable `keepalived_track_script_enabled`?**
kolla-ansible 2026.1 introduced ProxySQL support and added a `check_alive_proxysql.sh` script that the keepalived VRRP track script runs. The script sends plain text via socat to the ProxySQL admin Unix socket, but that socket uses the MySQL wire protocol — it sends a binary handshake immediately and resets any non-MySQL client. This causes the track script to always exit 1, keepalived to transition from MASTER to BACKUP, and the VIP to be dropped from the interface. Setting `keepalived_track_script_enabled: "no"` removes the track script from the keepalived configuration so the VIP is held unconditionally. For a single-controller deployment this is correct — there is nothing to fail over to.

**Why `vmbr1` (dedicated internal bridge) instead of static routes for floating IP routing?**
Floating IPs (10.0.2.0/24) live inside an OVS `qrouter` network namespace on the controller. The namespace handles DNAT/SNAT via iptables rules internal to OVS. Packets arriving on the host side of `br-ex` need ARP resolution for the qrouter MAC — OVS cannot loop host-originated traffic back through the namespace, so static routes from Proxmox pointing at the controller's home NIC (`enp6s18`) just died silently. A VLAN subinterface on Proxmox (`vmbr0.4001`) doesn't forward to VM bridge ports (confirmed by tcpdump: 0 packets on nic0). The only working approach: give OVS a real L2 uplink via a dedicated Proxmox bridge (`vmbr1`, `10.0.2.1/24`) connected directly to the controller VM as a second NIC (`enp6s19`). This gives OVS a proper upstream "router" it can ARP against and forward packets through.

**Why a WireGuard gateway VM inside OpenStack for the user VPN?**
Employees need to connect from anywhere and SSH directly to their dev server by hostname — no Proxmox access, no knowledge of floating IPs. Options considered: (1) give VMs a "public" IP in the `192.168.0.x` space — impossible without bridging the VM NIC directly to the home network, which loses Neutron networking entirely; (2) port-forward SSH per VM — scales badly, exposes all VMs publicly; (3) WireGuard gateway VM — employees connect to a single endpoint (port 51821), get a tunnel IP in `10.99.1.0/24` and a route to `10.0.0.0/24`, then SSH any dev VM by IP or hostname. This is the correct pattern: one public surface (the VPN endpoint), everything else private. The gateway runs inside OpenStack so it's provisioned as a regular VM and benefits from the same security group model.

**Why run the portal VM on Proxmox instead of inside OpenStack?**
The portal manages OpenStack — it calls the Nova, Neutron, and Glance APIs to provision, rebuild, and resize dev VMs. If the portal ran as an OpenStack VM, any OpenStack failure (kolla container crash, OVN routing issue, VIP loss) would take the portal down too, leaving no way to diagnose or recover via the portal UI. Running the portal as a Proxmox VM (VM 103, `192.168.0.104`) keeps the management plane independent of what it manages. The portal can reach the OpenStack API via its VLAN 4000 interface (10.0.1.200 → 10.0.1.254) and floating IPs via static routes through Proxmox — no OpenStack networking required.

**Why put the portal on VLAN 4000 rather than giving it a second NIC on vmbr1?**
The OpenStack API endpoint (`kolla_internal_vip_address: 10.0.1.254`) is only reachable on VLAN 4000. A vmbr1 NIC would give direct access to floating IPs (10.0.2.x) but not the management VLAN. VLAN 4000 access via the trunk on vmbr0 covers both the API (directly on-subnet) and floating IPs/mgmt-net (via static routes through Proxmox, which already forwards between vmbr0 and vmbr1).

**Why keep management (`10.0.1.0/24`) inaccessible to user VPN clients?**
The management VLAN is the control plane — Ansible, Kolla-Ansible, K3S, and OpenStack API endpoints live here. Exposing it to all VPN users would mean any employee could hit the OpenStack API or K3S API directly. Users need access to `10.0.0.0/24` (their dev VMs) only. Sysadmins access `10.0.1.0/24` via the separate sysadmin WireGuard on Proxmox (port 51820), which is never exposed to employees.

**Why `disk_allocation_ratio = 1/N_nodes` for Ceph-backed Nova?**
Nova has no native support for shared storage pools across compute nodes. Each node independently queries `ceph df` and reports the full pool size to Placement, causing N-fold overcount. Setting `disk_allocation_ratio = 1/N` in `nova.conf` scales each node's effective DISK_GB down so the aggregate across all nodes equals the real pool capacity. This is the operator workaround described by Nova core developers for [bug #1522307](https://bugs.launchpad.net/nova/+bug/1522307), which has been open since 2015. The value must be updated when compute nodes are added or removed.

**Why `raw PREROUTING DROP` instead of INPUT rules to block K3S services?**
K3S Klipper LoadBalancer applies DNAT in the `nat PREROUTING` chain — packets for port 80/443 get their destination rewritten to a NodePort before Netfilter's INPUT or FORWARD chains run. INPUT rules are therefore never evaluated for those packets (counter stays at 0). The `raw` table is the only table that runs before `nat` in Netfilter's hook ordering, so `raw PREROUTING DROP` fires before the DNAT rewrite and correctly discards the packet.

**Why use separate `create_openstack_vm` / `create_portal_vm` functions in `proxmox-setup.sh`?**
The portal VM does not need the resources sized for OpenStack workloads. OpenStack nodes (controller, compute, storage) each need 16 GB RAM for Kolla containers, 4 vCPUs for nested virtualisation, 60 GB OS disk, and a raw 60 GB Ceph OSD disk. The portal is a Docker Compose stack (nginx, FastAPI, PostgreSQL) — 4 GB RAM and 2 cores are sufficient, it needs 30 GB for OS + containers, and no Ceph disk at all. Using a single `create_vm` function for all four nodes wastes ~90 GB of storage on the Proxmox host (a Ceph OSD that does nothing) and overprovisioned the portal's compute resources. Separate functions express the different roles clearly.

**Why separate Proxmox scripts (`lab/`) from the Ansible automation (`deploy.sh`)?**
`deploy.sh` and all the Ansible roles are the production-portable artifact — run them against any three Ubuntu 24.04 nodes with the right IPs and you get a working OpenStack cloud. They don't know or care about Proxmox. The `lab/` scripts encode the lab-specific scaffolding: creating the VMs, the internal bridge, and injecting cloud-init config. This separation means the Ansible automation can be taken to any environment (bare metal, another hypervisor, a cloud provider) without modification, while the Proxmox scripts remain clearly labelled as local lab tooling.

**Why are the Proxmox scripts run ON Proxmox rather than from the Mac via Ansible?**
Proxmox doesn't expose the `qm` CLI via SSH in the same way a managed node does — the root account on Proxmox is not an Ansible-managed node and the `qm`/`pvesh` tools only exist there. Running setup.sh directly on Proxmox is simpler and more reliable than trying to drive it remotely. It also keeps the distinction clear: Proxmox scripts are one-time manual lab setup, not repeatable automation.

**Why skip `var-naming[no-role-prefix]` in ansible-lint?**
This rule is designed for public Galaxy roles where variable name collisions between roles are a real risk. In a private project, shared variables like `kolla_venv_path` and `openstack_release` are intentionally used across multiple roles (`install_kolla` and `deploy_openstack`). Prefixing them with the role name (e.g. `install_kolla_kolla_venv_path`) would make templates and tasks unreadable and require either duplication across roles or moving everything to group_vars. The skip is documented in `.ansible-lint` with a comment.

**Why use vpn-gateway dnsmasq instead of showing VM IPs in the portal?**
Users should not need to copy changing tenant IPs or understand the OpenStack network layout. The WireGuard client config already advertises `DNS = 10.99.1.1`, and dnsmasq runs on the vpn-gateway, so reservation can register `devserver-...` hostnames there. The portal now writes both the short name and `cloud.internal` FQDN to `/etc/hosts` on the vpn-gateway and reloads dnsmasq. The UI returns `ssh ubuntu@devserver-...`; users can optionally add an SSH client rule (`Host devserver-*`, `User ubuntu`) to make it just `ssh devserver-...`.

**Why is `10.99.1.1` reserved?**
`10.99.1.1` is the vpn-gateway's WireGuard interface and DNS address. User tunnel IPs must start at `10.99.1.2`. The bootstrap admin row was corrected from `10.99.1.1` to `10.99.1.2`, and `sg-user-1` was repaired to allow SSH from `10.99.1.2/32`.

**Why remove MASQUERADE from the user vpn-gateway?**
Per-user VM isolation is enforced with OpenStack security groups (`sg-user-<id>`) that allow SSH only from the assigned user's WireGuard tunnel IP. If the vpn-gateway NATs user traffic, all SSH attempts arrive at the dev VM as `10.0.0.41` instead of `10.99.1.x`, so Neutron drops them and SSH hangs. The correct design is routed VPN traffic: remove the `10.99.1.0/24 -> ens3 MASQUERADE` rule and add a Neutron route on `demo-router`: `10.99.1.0/24 via 10.0.0.41`. This preserves the real user source IP and keeps per-user security groups meaningful.

**Release lifecycle verification (2026-06-07)**
`devserver-medium-001` was reserved to the admin user, then released through the live backend route. The release path removed the vpn-gateway DNS entries, restored `pool-sg`, cleared the reservation fields, rebuilt the VM to the base Ubuntu image, and the `rebuild_watcher` promoted it back to `available`. `/api/vms/pool` then reported `medium` with `available = 1`.

**Reservation SSH debugging (2026-06-07)**
`devserver-medium-001` initially resolved correctly through vpn-gateway dnsmasq but SSH hung. The first root cause was vpn-gateway NAT: dev VMs saw SSH traffic as `10.0.0.41`, while per-user SGs allowed `10.99.1.x`. The fix was routed user VPN traffic: remove MASQUERADE, add the `demo-router` route `10.99.1.0/24 via 10.0.0.41`, and allow the vpn-gateway Neutron port to source `10.99.1.0/24`.

After routing worked, SSH reached the VM but rejected the key. The VM console showed cloud-init falling back to `DataSourceNone` because `sg-user-<id>` had been repaired by deleting all rules and adding only SSH ingress. That removed default egress, blocking metadata/user-data. The portal now repairs user SGs with IPv4 egress to `0.0.0.0/0` plus TCP/22 ingress from the user's WireGuard tunnel IP.

Cloud-init metadata then worked, but the top-level `ssh_authorized_keys` path was still not reliable enough for the Ubuntu image/rebuild flow. Reservation user-data now also writes `/home/ubuntu/.ssh/authorized_keys` explicitly in `runcmd`. A debug SSH attempt showed `Server accepts key`, proving the VM has the stored public key. The remaining non-interactive test failure was local-client-side: `BatchMode=yes` cannot sign with the private key when the SSH agent/passphrase is unavailable. The stale rebuilt-host entry for `devserver-medium-001` was removed from `~/.ssh/known_hosts`.

Known remaining platform bootstrap issue: cloud-init still reports `Failure when attempting to install packages: ['chef']`, and the cookbook download path returns data that is not a gzip archive. SSH access is now the first priority fixed; Chef packaging/cookbook delivery is the next platform bug to address.

**Normal-user reservation fix (2026-06-07)**
Normal users could see available VMs but received `409 Conflict` on reservation when they had no SSH public key registered. Previously, only admins could add keys on behalf of users. Added self-service key endpoints under `/api/vms/ssh-keys` and updated the Reserve page to let users add/delete their own SSH keys, disable reservation until a key exists, and display the backend conflict message.

**SSH connection delay experiment (2026-06-07)**
Reserved devservers accepted SSH but sometimes took around 15 seconds to reach the banner/auth stage. Because sessions were fast after login, this looked more like guest-side SSH startup/auth delay than raw VPN throughput. The devserver cloud-init user-data was moved into a shared helper and now applies `UseDNS no`, `GSSAPIAuthentication no`, disables `ssh.socket`, enables `ssh.service`, and restarts SSH. Admin-created pool VMs, pool replenisher VMs, reservation rebuilds, release rebuilds, and migration rebuilds now all use the same devserver user-data path.

---

## Current Status

- [x] Proxmox VE 9 installed on beefy laptop (dual boot with Windows)
- [x] 3 VMs created (controller, compute, storage) with Ubuntu 24.04
- [x] SSH key authentication configured from Mac to all 3 VMs
- [x] Ansible connectivity verified — all 3 VMs responding, no warnings
- [x] NIC name verified (`enp6s18`), host_vars updated with correct IPs and gateway
- [x] Bootstrap playbook run — VLANs up, nodes pinging each other over management VLAN
- [x] K3S v1.36.1 cluster deployed — all 3 nodes Ready, using VLAN IPs (10.0.1.x)
- [x] Automation code quality improvements — 14 fixes applied (see table above)
- [x] Rook Ceph v1.20.0 deployed on K3S — 3 OSDs, 3 MONs, HEALTH_OK
- [x] Ceph dashboard exposed via ingress-nginx at http://ceph.tudu.io
- [x] Automation code quality pass 2 — FQCN, octal modes, flat task files, include→import, interpreter scope, rook vars to defaults, netplan routes fix, deploy.sh error handling
- [x] globals.yml and multinode fully rewritten for Kolla-Ansible 2026.1
- [x] Ceph keyring flow redesigned — registered vars written directly to Mac via delegate_to: localhost, no roundtrip through storage node; mon addresses derived dynamically from ceph mon dump
- [x] Ceph OpenStack pools and keyrings created (prepare-ceph step)
- [x] Kolla-Ansible installed on controller, config generated, passwords populated, keyrings + ceph.conf pushed to /etc/kolla/config
- [x] kolla-ansible bootstrap-servers passed
- [x] kolla-ansible prechecks passed (exit=0, clean)
- [x] Docker SDK incompatibility fixed and baked into automation (prep_openstack_nodes role)
- [x] Automation refactored: roles renamed, merged, split; 0 ansible-lint failures (production profile)
- [x] kolla-ansible deploy (OpenStack containers) — 0 failures, all services healthy
- [x] OpenStack deployed via Kolla-Ansible (2026.1 "Gazpacho")
- [x] OpenStack validated — Horizon accessible (HTTP 302→login), Cinder@rbd-1 up, Cirros image active, demo-net created
- [x] Full convergence — all 3 VMs (controller, compute, storage) are Nova compute nodes; each reports ~60 GB disk to Placement via `disk_allocation_ratio = 0.33`. Fixed Ansible host/group naming conflict in kolla multinode (cmp01/stor01 aliases).
- [x] Floating IP routing fixed — dedicated `vmbr1` bridge on Proxmox (`10.0.2.1/24`), second NIC hot-added to controller VM as `enp6s19`, `neutron_external_interface` changed to `enp6s19`, `kolla reconfigure` run. Floating IPs now reachable from Proxmox and WireGuard clients.
- [x] Sysadmin WireGuard configured on Proxmox (port 51820, tunnel `10.99.0.0/24`, routes to `10.0.1.0/24` + `10.0.2.0/24`)
- [x] VM internet access fixed — MASQUERADE rule on Proxmox (`-s 10.0.2.0/24 -o vmbr0`) enables double-NAT: VM → qrouter SNAT → Proxmox → home router
- [x] `vpn-gateway` VM provisioned (Ubuntu 24.04, `m1.small`, private `10.0.0.125`, floating `10.0.2.150`), security group `vpn-gateway-sg` applied
- [x] User WireGuard configured on `vpn-gateway` (port 51821, tunnel `10.99.1.0/24`, routes `10.0.0.0/24` to clients), dnsmasq for hostname resolution
- [x] Proxmox DNAT configured: UDP 51821 → `10.0.2.150:51821` (hardcoded — survives redeployment)
- [x] vpn-gateway floating IP hardcoded to `10.0.2.150` (first in pool) — Proxmox DNAT rule never needs updating after redeploy
- [x] vpn-gateway provisioning baked into `deploy.sh` phase 6 via `init_vpn_gateway` Ansible role — tested end-to-end on live redeploy (exit 0, VM came up, WireGuard running)
- [x] End-to-end test passed: Mac (user WireGuard) → vpn-gateway → `test-vm-1` SSH (`cirros@10.0.0.16`)
- [x] Teardown + lab scaffolding scripts written:
  - `teardown.sh` — software-only teardown from Mac (kolla-ansible destroy → K3S reset → wipe /dev/sdb → clean config dirs)
  - `lab/proxmox-setup.sh` — creates Proxmox lab from scratch (vmbr1, cloud image, VMs 100-102 with cloud-init)
  - `lab/proxmox-teardown.sh` — destroys VMs and removes vmbr1, returns Proxmox to clean state
- [x] Bootstrap playbook hang fixed: `hosts: all` → `hosts: openstack_nodes`; `Apply netplan` handler made async; `retries = 5` in ansible.cfg

### End-to-end automation test (fresh VM run — 2026-06-07)

- [x] Phase 1 (bootstrap) — passed clean
- [x] Phase 2 (K3S) — passed clean
- [x] Phase 3 (Ceph) — passed clean
- [x] Phase 4 (install kolla) — passed clean
- [x] Phase 5 (deploy OpenStack) — passed clean (0 failures); three bugs found and fixed:
  - **Bug**: `kolla-ansible prechecks` blocks on `quay.io/openstack.kolla` image check even though `--use-test-images` CLI flag was removed in 2026.1. **Fix**: add `kolla_test_images: "yes"` to `globals.yml` — the precheck is guarded by `when: not kolla_test_images | bool`.
  - **Bug**: kolla-ansible tasks (`bootstrap-servers`, `prechecks`, `deploy`, `post-deploy`) failed with permission denied on `/etc/kolla/passwords.yml` (owned `root:root` 0640, Ansible runs as `sysoperator`). **Fix**: add `become: true` to all kolla-ansible command tasks in `deploy_kolla.yml`.
  - **Bug**: kolla `kolla_container_facts` module crashes on storage/compute with `URLSchemeUnknown: Not supported URL scheme http+docker`. Root cause: Ubuntu 24.04 ships `python3-docker` 5.0.3 (APT) which registers `http+docker://` adapter; `requests` 2.34.2 (pip) uses newer urllib3 that no longer supports custom URL schemes. **Fix**: upgrade docker SDK to ≥7.0.0 via `pip3 install --break-system-packages`. Already in `prep_openstack_nodes` role but tasks lacked the `prep_openstack_nodes` tag — added the tag so `--tags prep_openstack_nodes` actually executes them.
- [x] Phase 6 (init resources + vpn-gateway) — passed clean; vpn-gateway floating IP `10.0.2.150`, WireGuard pubkey printed, public key saved to `~/.cloud-vpn-pubkey`
- [x] Full end-to-end automation test: phases 1-6 all pass on fresh VMs — `deploy.sh` is fully automated from bare Ubuntu cloud images to a running OpenStack cluster with VPN access
- [x] Ceph dashboard restricted to admin VPN only — `raw PREROUTING DROP` on `eth0` blocks home LAN access; `/etc/hosts` updated to `10.0.1.4 ceph.tudu.io` (management VLAN, only reachable via admin VPN); automation updated in `deploy_ingress_nginx.yml`
- [x] User VPN scope restricted to `10.0.0.0/24` only — client AllowedIPs and vpn-gateway FORWARD rules tightened; management VLAN and services VLAN no longer reachable via user VPN
- [x] User VPN changed from NATed to routed mode — removed vpn-gateway MASQUERADE for `10.99.1.0/24`, added `demo-router` return route `10.99.1.0/24 via 10.0.0.41`, preserving user tunnel IPs for per-user security groups
- [x] User VPN verified end-to-end: Mac (user WireGuard) → `test-vm-1` (`cirros@10.0.0.31`) SSH works; tenant VMs not reachable via admin VPN (expected — `10.0.0.0/24` is OVN-internal, admin VPN routes only `10.0.1.0/24` + `10.0.2.0/24`)
- [x] mgmt-net Neutron network added (10.0.4.0/24) — dev VMs get a second NIC; admin can SSH via 10.0.4.x; mgmt-router at fixed external IP 10.0.2.200
- [x] Static route persisted on Proxmox: `post-up ip route add 10.0.4.0/24 via 10.0.2.200` in vmbr1 block of `/etc/network/interfaces`; baked into `proxmox-setup.sh`
- [x] Admin WireGuard AllowedIPs updated on Mac to include `10.0.4.0/24` — admin VPN can now reach dev VM mgmt NICs
- [x] pool-sg security group added — SSH from portal IP (192.168.0.104) only; applied to available VMs in pool
- [x] Portal architecture decision: portal VM runs on Proxmox (192.168.0.104) outside OpenStack — eliminates chicken-and-egg dependency on OpenStack health
- [x] PaaS portal implemented as git submodule at `openstack-automation/portal/`:
  - Backend: FastAPI + SQLAlchemy async + Alembic + APScheduler pool poller
  - Frontend: React 18 + TypeScript + Tailwind + TanStack Query
  - Deployment: Docker Compose (nginx + fastapi + postgres) on portal Proxmox VM
  - Chef: chef-solo base profile (core tools, Docker, Python, Node.js, Go) — cookbooks served by portal nginx
  - Ansible: `deploy-portal.yml` playbook (Phase 7 in deploy.sh); portal bootstrapped in Phase 1
  - Networking: portal at 192.168.0.104, VLAN 4000 interface at 10.0.1.200 (reaches OpenStack API at 10.0.1.254), static routes via Proxmox for 10.0.2.0/24 (floating IPs) and 10.0.4.0/24 (mgmt-net)
  - Security: httpOnly JWT cookies, per-user WireGuard SGs, SSH key isolation, SSH hardening via Chef
  - VM lifecycle: reserve, release (rebuild), resize (Nova resize), migrate (snapshot → new VM slot)
  - DNS lifecycle: reserve registers `devserver-*` in vpn-gateway dnsmasq; release removes the entry
  - Portal secrets (DB password, JWT key) stored in Ansible vault
- [x] Phase 7 (portal deployment) tested end-to-end on live deployment — `./deploy.sh --phase 7` passes clean (ok=10, changed=2)
  - Fixed Docker build failure: PyPI package is `openstacksdk` not `openstack`; updated `requirements.txt` to `openstacksdk==4.14.0`
  - Fixed frontend build failure: unused TypeScript import (`RefreshCw`) in `MyServers.tsx` caused `tsc -b` to exit 1; removed the import
  - `app/scripts/create_admin.py` created — interactive bootstrap script for the first admin user; run inside the backend container after Phase 7
  - `proxmox-setup.sh` refactored: separate `create_openstack_vm` / `create_portal_vm` functions; portal gets 4 GB RAM / 2 cores / 30 GB disk / no Ceph OSD — correct specs instead of the OpenStack node spec
- [x] Portal reserve/release lifecycle tested on live `devserver-medium-001` — reserve repairs per-user SG and registers DNS, release removes DNS, restores `pool-sg`, rebuilds cleanly, and returns the VM to the available pool
- [x] Reserved devserver SSH path debugged — routed user VPN, per-user SG egress for metadata, DNS hostname, and SSH key injection all verified up to server accepting the user's key
- [ ] Dissertation writing completed
