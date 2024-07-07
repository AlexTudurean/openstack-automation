#!/bin/bash

/usr/local/bin/k3s-uninstall.sh

rm -rf /var/lib/rook

wipefs -af /dev/nvme0n1
