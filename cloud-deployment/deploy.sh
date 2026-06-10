#!/bin/bash
# Full deployment script — runs every phase in order for a fresh install.
# Each phase can also be run individually; see inline comments.
#
# Usage:
#   ./deploy.sh            — full fresh deploy (safe to re-run except phase 6)
#   ./deploy.sh --phase N  — run only phase N (1-7)
set -euo pipefail
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
trap 'echo "ERROR: Deployment failed at line $LINENO"' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INVENTORY="$SCRIPT_DIR/inventory/inventory.ini"
VAULT_ARGS="--vault-password-file $SCRIPT_DIR/.vault_pass"
PHASE="${2:-all}"

# Returns 0 (run this phase) or 1 (skip). Use: if run_phase N "desc"; then ... fi
run_phase() {
  local n="$1"; shift
  [[ "$PHASE" == "all" || "$PHASE" == "$n" ]] || return 1
  echo "==> Phase $n: $*"
}

# Phase 1: Bootstrap nodes (sysoperator user, SSH keys, VLANs, /etc/hosts)
#          Targets openstack_nodes + portal_nodes (controller, compute, storage, portal)
if run_phase 1 "Bootstrap nodes"; then
  ansible-playbook -i "$INVENTORY" $VAULT_ARGS "$SCRIPT_DIR/bootstrap-nodes.yml"
fi

# Phase 2: Deploy K3S cluster (storage node is the control-plane)
if run_phase 2 "Deploy K3S"; then
  # Run from inside k3s-ansible so its ansible.cfg (roles_path = ./roles) resolves correctly.
  # group_vars/ is not found automatically here (wrong dir), so pass vault.yaml explicitly.
  (cd "$SCRIPT_DIR/k3s-ansible" && \
    ansible-playbook -i "$SCRIPT_DIR/inventory/inventory-k3s.yaml" $VAULT_ARGS \
      -e "@$SCRIPT_DIR/group_vars/all/vault.yaml" \
      playbooks/site.yml)
fi

# Phase 3: Prepare OpenStack nodes + deploy Rook Ceph + create pools/keyrings
#          Tags map to tasks in deploy_ceph role: install_helm → deploy_ingress_nginx
#          → deploy_rook (Rook operator + cluster, ~20 min) → prepare_ceph (pools/keyrings)
if run_phase 3 "Prepare Ceph"; then
  ansible-playbook -i "$INVENTORY" $VAULT_ARGS "$SCRIPT_DIR/deploy-openstack.yml" \
    --tags prep_openstack_nodes,install_helm,deploy_ingress_nginx,deploy_rook,prepare_ceph
fi

# Phase 4: Install kolla-ansible + push config (globals.yml, inventory, keyrings, ceph.conf)
if run_phase 4 "Install Kolla + configure"; then
  ansible-playbook -i "$INVENTORY" $VAULT_ARGS "$SCRIPT_DIR/deploy-openstack.yml" \
    --tags install_kolla,configure_kolla
fi

# Phase 5: Deploy OpenStack (bootstrap-servers → prechecks → deploy → post-deploy)
#          Safe to re-run: kolla-ansible deploy and post-deploy are idempotent.
if run_phase 5 "Deploy OpenStack"; then
  ansible-playbook -i "$INVENTORY" $VAULT_ARGS "$SCRIPT_DIR/deploy-openstack.yml" \
    --tags kolla_bootstrap,kolla_prechecks,kolla_deploy,kolla_post
fi

# Phase 6: One-time init (demo network, Cirros image, default flavors, VPN gateway,
#          mgmt-net, pool-sg). NOT idempotent — skip if resources already exist.
if run_phase 6 "Init demo resources (one-time only)"; then
  ansible-playbook -i "$INVENTORY" $VAULT_ARGS "$SCRIPT_DIR/deploy-openstack.yml" \
    --tags kolla_init
  ansible-playbook -i "$INVENTORY" $VAULT_ARGS "$SCRIPT_DIR/deploy-openstack.yml" \
    --tags init_vpn_gateway
  ansible-playbook -i "$INVENTORY" $VAULT_ARGS "$SCRIPT_DIR/deploy-openstack.yml" \
    --tags init_resources
fi

# Phase 7: Portal application deployment to the portal Proxmox VM (192.168.0.104).
#          Requires portal_db_password and portal_jwt_secret in vault.yaml.
#          Portal VM must be bootstrapped (Phase 1). Safe to re-run (idempotent).
if run_phase 7 "Deploy portal"; then
  ansible-playbook -i "$INVENTORY" $VAULT_ARGS "$SCRIPT_DIR/deploy-portal.yml"
fi
