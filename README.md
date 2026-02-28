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

## Step-by-Step (Automated Setup)

### Step 1: Make the script executable

#### Using [setup-script](./scripts/setup.sh)

```bash
chmod +x ./scripts/setup.sh
```

### Step 2: Run the setup

```bash
./scripts/setup.sh
```

What this step does:
- creates/reuses `k8s-master` and `k8s-worker`
- installs K3s server/agent
- checks and installs host `kubectl` and `helm` (unless disabled)
- configures host kubeconfig at `~/.kube/config`
- installs/configures host NGINX reverse proxy for ports `80` and `443` (unless disabled)
- checks Linux firewall and opens `80/tcp` + `443/tcp` when supported

Default VM sizing:
- CPU: `2`
- Memory: `5G`
- Disk: `50G`
- Image: `lts`

### Step 3: Verify cluster nodes

First print Multipass inventory/details:
```bash
multipass list
multipass info k8s-master
multipass info k8s-worker
```

Using the master VM directly:
```bash
multipass exec k8s-master -- sudo kubectl get nodes -o wide
```

If kubeconfig was exported to host (`~/.kube/config`):
```bash
kubectl get nodes -o wide
kubectl get all -A -o wide
```

## Script Options

```bash
./scripts/setup.sh \
  --master-name k8s-master \
  --worker-name k8s-worker \
  --cpus 2 \
  --memory 5G \
  --disk 50G \
  --image lts
```

Useful flags:
- `--no-host-tools` to skip host `kubectl`/`helm` check and install
- `--no-kubeconfig` to skip writing `~/.kube/config`
- `--no-nginx-proxy` to skip NGINX reverse-proxy setup
- `-h` or `--help` for usage

## Step-by-Step (Manual)

Use this if you want to run each command yourself.

### 1. Launch VMs

```bash
multipass launch lts --name k8s-master --cpus 2 --memory 5G --disk 50G
multipass launch lts --name k8s-worker --cpus 2 --memory 5G --disk 50G
multipass list
```

### 2. Install K3s server on master

```bash
multipass exec k8s-master -- bash -lc 'curl -sfL https://get.k3s.io | sh -'
```

Get the node token:
```bash
multipass exec k8s-master -- sudo cat /var/lib/rancher/k3s/server/node-token
```

Get master IP:
```bash
multipass info k8s-master
```

### 3. Install K3s agent on worker

Replace `<MASTER_IP>` and `<TOKEN>`:
```bash
multipass exec k8s-worker -- bash -lc 'curl -sfL https://get.k3s.io | K3S_URL=https://<MASTER_IP>:6443 K3S_TOKEN=<TOKEN> sh -'
```

### 4. Verify from master

```bash
multipass exec k8s-master -- sudo kubectl get nodes -o wide
```

### 5. Install kubectl and helm on host (manual if needed)

macOS (Homebrew):
```bash
brew install kubectl
brew install helm
```

Linux (Snap):
```bash
sudo snap install kubectl --classic
sudo snap install helm --classic
```

### 6. Configure kubeconfig on host

```bash
mkdir -p ~/.kube
multipass exec k8s-master -- sudo cat /etc/rancher/k3s/k3s.yaml > ~/.kube/config
```

Replace loopback server address with master VM IP:

Linux:
```bash
sed -i 's/127.0.0.1/<MASTER_IP>/g' ~/.kube/config
```

macOS:
```bash
sed -i '' 's/127.0.0.1/<MASTER_IP>/g' ~/.kube/config
```

Set secure permissions:
```bash
chmod 600 ~/.kube/config
```

Validate:
```bash
kubectl get nodes
kubectl get all -A -o wide
helm list -A
```

### 7. Configure NGINX reverse proxy on host (ports 80/443)

The setup script does this automatically by default.

What it configures:
- HTTP reverse proxy: host `:80` -> `${MASTER_IP}:80`
- HTTPS reverse proxy: host `:443` -> `${MASTER_IP}:443`
- Linux firewall check/open for `80/tcp` and `443/tcp` (when `ufw` or `firewalld` is available)

Manual Linux example:
```bash
sudo apt-get update && sudo apt-get install -y nginx
sudo mkdir -p /etc/nginx/certs
sudo openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
  -keyout /etc/nginx/certs/k3s-reverse-proxy.key \
  -out /etc/nginx/certs/k3s-reverse-proxy.crt \
  -subj "/CN=k3s.local"
sudo tee /etc/nginx/sites-available/k3s-reverse-proxy >/dev/null <<'EOF'
server {
  listen 80;
  server_name _;
  location / {
    proxy_pass http://<MASTER_IP>:80;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
  }
}
server {
  listen 443 ssl;
  server_name _;
  ssl_certificate /etc/nginx/certs/k3s-reverse-proxy.crt;
  ssl_certificate_key /etc/nginx/certs/k3s-reverse-proxy.key;
  location / {
    proxy_pass https://<MASTER_IP>:443;
    proxy_ssl_server_name on;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
  }
}
EOF
sudo ln -sf /etc/nginx/sites-available/k3s-reverse-proxy /etc/nginx/sites-enabled/k3s-reverse-proxy
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t
sudo systemctl restart nginx
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw status
```

Manual macOS example:
```bash
brew install nginx
mkdir -p "$(brew --prefix)/etc/nginx/servers" "$HOME/.nginx/certs"
openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
  -keyout "$HOME/.nginx/certs/k3s-reverse-proxy.key" \
  -out "$HOME/.nginx/certs/k3s-reverse-proxy.crt" \
  -subj "/CN=k3s.local"
cat > "$(brew --prefix)/etc/nginx/servers/k3s-reverse-proxy.conf" <<'EOF'
server {
  listen 80;
  server_name _;
  location / {
    proxy_pass http://<MASTER_IP>:80;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
  }
}
server {
  listen 443 ssl;
  server_name _;
  ssl_certificate $HOME/.nginx/certs/k3s-reverse-proxy.crt;
  ssl_certificate_key $HOME/.nginx/certs/k3s-reverse-proxy.key;
  location / {
    proxy_pass https://<MASTER_IP>:443;
    proxy_ssl_server_name on;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
  }
}
EOF
nginx -t
brew services start nginx
nginx -s reload
```

## Common Operations

Check VM status:
```bash
multipass list
multipass info k8s-master
multipass info k8s-worker
```

Open shell into a VM:
```bash
multipass shell k8s-master
multipass shell k8s-worker
```

## Cleanup

Delete the cluster VMs:
```bash
multipass delete -p k8s-master k8s-worker
```

If you exported kubeconfig and want to remove it:
```bash
rm -f ~/.kube/config
```

## Troubleshooting

- If `multipass` requires elevated permissions on your system, run commands with `sudo`.
- If worker does not join, verify master IP and token are correct and reachable on port `6443`.
- If `kubectl` on host fails, confirm `~/.kube/config` points to the master VM IP instead of `127.0.0.1`.
- If `helm` fails from host, verify the kubeconfig context is set correctly and cluster API is reachable.
- If VMs already exist, the script reuses them instead of recreating.
- If reverse-proxy HTTPS shows certificate warnings, this is expected with the generated self-signed cert.
- If ports `80/443` are not reachable externally, verify host firewall rules and network-level security settings.

---