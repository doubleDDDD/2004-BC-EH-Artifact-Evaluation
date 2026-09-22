#!/usr/bin/env bash

sudo ip link add br-iscsi type bridge
sudo ip addr add 10.66.0.1/24 dev br-iscsi
sudo ip link set br-iscsi up

sudo ip tuntap add dev tap-iscsi0 mode tap user "$USER"
sudo ip link set tap-iscsi0 master br-iscsi
sudo ip link set tap-iscsi0 up
