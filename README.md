My bachelor's degree project: Automating Cloud Deployments.

Automates the deployment of OpenStack using Ansible. 
Uses Kolla-Ansible to deploy OpenStack.
For storage I used Rook Ceph on top of a K3S cluster.

There's a bunch of configs to change in the Ansible roles (either in vars or files) (there's only 5 files that you need to modify actually + 2 inventory files, one for the project itself and another for k3s-ansible).

This is the network architecture I used, but you can change it to match yours:
![image](https://github.com/AlexTudurean/openstack-automation/assets/44097593/4f0e80c3-d63e-4a16-a185-ae67e57a17fc)


Am sa pun aici prostiile:
- [x] neaparat pip de pus pe storage + pachetul kubernetes, bubuie face ca toti dracii - FIXED: Added install-python-deps.yml task
- [x] handle mai bun la openstack ca e un jeg - da, rabbitmq trebuie sa dureze 12 minute, jeg de openstack