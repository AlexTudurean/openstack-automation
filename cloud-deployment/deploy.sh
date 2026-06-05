#!/bin/bash
set -euo pipefail
trap 'echo "ERROR: Deployment failed at line $LINENO"' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Bootstrap nodes
ansible-playbook -i "$SCRIPT_DIR/inventory/inventory.ini" "$SCRIPT_DIR/bootstrap-nodes.yml"

# Deploy k3s
cd "$SCRIPT_DIR/cloud-deployment/k3s-ansible"
ansible-playbook playbooks/site.yml -i "$SCRIPT_DIR/inventory/inventory-k3s.yaml"

# Deploy openstack
cd "$SCRIPT_DIR"
ansible-playbook -i "$SCRIPT_DIR/inventory/inventory.ini" "$SCRIPT_DIR/deploy-openstack.yml"
