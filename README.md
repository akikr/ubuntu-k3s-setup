# Ubuntu K3s Cluster Setup

## K3s a lightweight Kubernetes: [k3s.io](https://github.com/k3s-io/k3s)

This repository provides a repeatable way to:
1. Create local Ubuntu VMs with Multipass.
2. Build a small Kubernetes-style cluster using K3s (1 control-plane + 1 worker).
3. Check/install host `kubectl` and `helm`, then configure `~/.kube/config` for host access.
4. Configure an NGINX reverse proxy on host ports `80` and `443` to reach the cluster from outside the host VM.

## What You Get

- `k8s-master` VM running K3s server
- `k8s-worker` VM running K3s agent
- A two-node K3s cluster for local testing/lab use

## Prerequisites

Install Multipass first.

Linux (Snap):
```bash
sudo snap install multipass
```

macOS (Homebrew):
```bash
brew install --cask multipass
```

Host tools used by this setup:
```bash
# kubectl
sudo snap install kubectl --classic

# helm
sudo snap install helm --classic
```

Note: the setup script also checks these tools and installs missing ones automatically (using `brew` or `snap` when available).

---
