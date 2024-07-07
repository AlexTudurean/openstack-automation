#!/bin/bash

# Bootstrap nodes
ansible-playbook -i inventory/inventory.ini bootstrap-nodes.yml 

# Deploy k3s
cd k3s-ansible
ansible-playbook playbooks/site.yml -i inventory.yml

# Deploy openstack
cd ../
ansible-playbook -i inventory/inventory.ini deploy-openstack.yml