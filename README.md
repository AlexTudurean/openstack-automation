![image](https://github.com/AlexTudurean/openstack-automation/assets/44097593/416a9d18-c8c8-47e4-a1f0-d0357eb224d9)My bachelor's degree project: Automating Cloud Deployments.

Automates the deployment of OpenStack using Ansible. 
Uses Kolla-Ansible to deploy OpenStack.
For storage I used Rook Ceph on top of a K3S cluster.

There's a bunch of configs to change in the Ansible roles (either in vars or files) (there's only 5 files that you need to modify actually).

This is the network architecture I used, but you can change it to match yours:
![image](https://github.com/AlexTudurean/openstack-automation/assets/44097593/4f0e80c3-d63e-4a16-a185-ae67e57a17fc)
