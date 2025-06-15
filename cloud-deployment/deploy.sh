#!/bin/bash

# Bootstrap nodes
ansible-playbook -i inventory/inventory.ini bootstrap-nodes.yml 

# Deploy k3s
cp inventory/inventory-k3s.yaml cloud-deployment/k3s-ansible/inventory.yml
cd cloud-deployment/k3s-ansible
ansible-playbook -i inventory.yml playbooks/site.yml

# Deploy openstack
cd ../../
ansible-playbook -i inventory/inventory.ini deploy-openstack.yml