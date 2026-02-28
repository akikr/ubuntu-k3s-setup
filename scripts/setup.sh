#!/usr/bin/env bash
set -euo pipefail

MASTER_NAME="k8s-master"
WORKER_NAME="k8s-worker"
CPUS=2
MEMORY="5G"
DISK="50G"
IMAGE="lts"
CONFIGURE_KUBECONFIG=1
ENSURE_HOST_TOOLS=1
SETUP_NGINX_PROXY=1

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Provision Multipass VMs and bootstrap a 1 control-plane + 1 worker K3s cluster.

Options:
  --master-name NAME       Master VM name (default: ${MASTER_NAME})
  --worker-name NAME       Worker VM name (default: ${WORKER_NAME})
  --cpus N                 CPU count per VM (default: ${CPUS})
  --memory SIZE            RAM per VM, e.g. 4G (default: ${MEMORY})
  --disk SIZE              Disk per VM, e.g. 30G (default: ${DISK})
  --image IMAGE            Multipass image/channel (default: ${IMAGE})
  --no-host-tools          Skip host kubectl/helm check and install
  --no-kubeconfig          Skip kubeconfig export to ~/.kube/config
  --no-nginx-proxy         Skip NGINX reverse-proxy setup on host (80/443)
  -h, --help               Show this help

Examples:
  $(basename "$0")
  $(basename "$0") --cpus 2 --memory 10G --disk 50G
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --master-name)
      MASTER_NAME="$2"
      shift 2
      ;;
    --worker-name)
      WORKER_NAME="$2"
      shift 2
      ;;
    --cpus)
      CPUS="$2"
      shift 2
      ;;
    --memory)
      MEMORY="$2"
      shift 2
      ;;
    --disk)
      DISK="$2"
      shift 2
      ;;
    --image)
      IMAGE="$2"
      shift 2
      ;;
    --no-host-tools)
      ENSURE_HOST_TOOLS=0
      shift
      ;;
    --no-kubeconfig)
      CONFIGURE_KUBECONFIG=0
      shift
      ;;
    --no-nginx-proxy)
      SETUP_NGINX_PROXY=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if ! command -v multipass >/dev/null 2>&1; then
  echo "Error: multipass is not installed. Install it first:" >&2
  echo "  snap install multipass" >&2
  echo "  # or on macOS: brew install --cask multipass" >&2
  exit 1
fi

run_multipass() {
  if multipass list >/dev/null 2>&1; then
    multipass "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo multipass "$@"
  else
    echo "Error: unable to run multipass (try with sudo)." >&2
    exit 1
  fi
}

vm_exists() {
  local name="$1"
  run_multipass info "$name" >/dev/null 2>&1
}

vm_ip() {
  local name="$1"
  run_multipass info "$name" --format json | sed -n 's/.*"ipv4"[[:space:]]*:[[:space:]]*\["\([0-9.]*\)"\].*/\1/p' | head -n1
}

ensure_host_tools() {
  local missing_kubectl=0
  local missing_helm=0
  local os

  if ! command -v kubectl >/dev/null 2>&1; then
    missing_kubectl=1
  fi
  if ! command -v helm >/dev/null 2>&1; then
    missing_helm=1
  fi

  if [[ "$missing_kubectl" -eq 0 && "$missing_helm" -eq 0 ]]; then
    echo "Host tools are ready: kubectl and helm are already installed."
    return 0
  fi

  os="$(uname -s)"
  echo "Installing missing host tools..."

  if command -v brew >/dev/null 2>&1; then
    if [[ "$missing_kubectl" -eq 1 ]]; then
      brew install kubectl
    fi
    if [[ "$missing_helm" -eq 1 ]]; then
      brew install helm
    fi
    return 0
  fi

  if command -v snap >/dev/null 2>&1; then
    if [[ "$missing_kubectl" -eq 1 ]]; then
      sudo snap install kubectl --classic
    fi
    if [[ "$missing_helm" -eq 1 ]]; then
      sudo snap install helm --classic
    fi
    return 0
  fi

  if [[ "$os" == "Linux" ]] && command -v apt-get >/dev/null 2>&1; then
    echo "Could not auto-install with brew/snap on this Linux host." >&2
  fi

  echo "Error: could not auto-install missing host tools." >&2
  echo "Install kubectl and helm manually, then rerun this script." >&2
  exit 1
}

ensure_nginx_installed() {
  if command -v nginx >/dev/null 2>&1; then
    echo "NGINX is already installed on host."
    return 0
  fi

  echo "Installing NGINX on host..."
  if command -v brew >/dev/null 2>&1; then
    brew install nginx
    return 0
  fi
  if command -v snap >/dev/null 2>&1; then
    sudo snap install nginx
    return 0
  fi
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y nginx
    return 0
  fi

  echo "Error: could not auto-install NGINX (no supported package manager found)." >&2
  exit 1
}

configure_firewall_http_https() {
  echo "Checking firewall rules for ports 80 and 443..."
  if command -v ufw >/dev/null 2>&1; then
    sudo ufw allow 80/tcp
    sudo ufw allow 443/tcp
    sudo ufw status || true
    return 0
  fi

  if command -v firewall-cmd >/dev/null 2>&1 && sudo firewall-cmd --state >/dev/null 2>&1; then
    sudo firewall-cmd --add-service=http --permanent
    sudo firewall-cmd --add-service=https --permanent
    sudo firewall-cmd --reload
    sudo firewall-cmd --list-services
    return 0
  fi

  echo "No supported Linux firewall tool detected (ufw/firewalld). Open ports 80 and 443 manually if needed."
}

configure_nginx_proxy_linux() {
  local master_ip="$1"
  local conf_path="/etc/nginx/sites-available/k3s-reverse-proxy"
  local cert_dir="/etc/nginx/certs"
  local cert_path="${cert_dir}/k3s-reverse-proxy.crt"
  local key_path="${cert_dir}/k3s-reverse-proxy.key"

  sudo mkdir -p "$cert_dir"
  if [[ ! -f "$cert_path" || ! -f "$key_path" ]]; then
    sudo openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
      -keyout "$key_path" \
      -out "$cert_path" \
      -subj "/CN=k3s.local"
  fi

  sudo tee "$conf_path" >/dev/null <<EOF
server {
  listen 80;
  server_name _;

  location / {
    proxy_pass http://${master_ip}:80;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }
}

server {
  listen 443 ssl;
  server_name _;
  ssl_certificate ${cert_path};
  ssl_certificate_key ${key_path};

  location / {
    proxy_pass https://${master_ip}:443;
    proxy_ssl_server_name on;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }
}
EOF

  sudo ln -sf "$conf_path" /etc/nginx/sites-enabled/k3s-reverse-proxy
  sudo rm -f /etc/nginx/sites-enabled/default
  sudo nginx -t
  sudo systemctl enable --now nginx
  sudo systemctl reload nginx || sudo systemctl restart nginx
}

configure_nginx_proxy_macos() {
  local master_ip="$1"
  local brew_prefix
  local conf_dir
  local conf_path
  local cert_dir="$HOME/.nginx/certs"
  local cert_path="${cert_dir}/k3s-reverse-proxy.crt"
  local key_path="${cert_dir}/k3s-reverse-proxy.key"

  brew_prefix="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
  conf_dir="${brew_prefix}/etc/nginx/servers"
  conf_path="${conf_dir}/k3s-reverse-proxy.conf"

  mkdir -p "$conf_dir" "$cert_dir"
  if [[ ! -f "$cert_path" || ! -f "$key_path" ]]; then
    openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
      -keyout "$key_path" \
      -out "$cert_path" \
      -subj "/CN=k3s.local"
  fi

  cat > "$conf_path" <<EOF
server {
  listen 80;
  server_name _;

  location / {
    proxy_pass http://${master_ip}:80;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }
}

server {
  listen 443 ssl;
  server_name _;
  ssl_certificate ${cert_path};
  ssl_certificate_key ${key_path};

  location / {
    proxy_pass https://${master_ip}:443;
    proxy_ssl_server_name on;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }
}
EOF

  nginx -t
  brew services start nginx
  nginx -s reload || true
  echo "macOS firewall is not auto-managed by this script. Ensure inbound ports 80 and 443 are allowed if needed."
}

setup_nginx_reverse_proxy() {
  local master_ip="$1"
  local os

  ensure_nginx_installed
  os="$(uname -s)"
  case "$os" in
    Linux)
      configure_nginx_proxy_linux "$master_ip"
      configure_firewall_http_https
      ;;
    Darwin)
      configure_nginx_proxy_macos "$master_ip"
      ;;
    *)
      echo "Skipping NGINX reverse-proxy setup: unsupported OS '$os'."
      ;;
  esac
}

launch_vm_if_missing() {
  local name="$1"
  if vm_exists "$name"; then
    echo "VM '${name}' already exists; reusing it."
    run_multipass start "$name" >/dev/null 2>&1 || true
    return
  fi
  echo "Launching VM '${name}'..."
  run_multipass launch "$IMAGE" --name "$name" --cpus "$CPUS" --memory "$MEMORY" --disk "$DISK"
}

wait_for_vm_ip() {
  local name="$1"
  local ip=""
  local attempt=1
  local max_attempts=60

  while [[ $attempt -le $max_attempts ]]; do
    ip="$(vm_ip "$name" || true)"
    if [[ -n "$ip" ]]; then
      echo "$ip"
      return 0
    fi
    sleep 2
    attempt=$((attempt + 1))
  done

  echo "Error: timed out waiting for IP on '${name}'." >&2
  return 1
}

echo "Creating or reusing VMs..."
launch_vm_if_missing "$MASTER_NAME"
launch_vm_if_missing "$WORKER_NAME"

MASTER_IP="$(wait_for_vm_ip "$MASTER_NAME")"
WORKER_IP="$(wait_for_vm_ip "$WORKER_NAME")"

echo "Master IP: ${MASTER_IP}"
echo "Worker IP: ${WORKER_IP}"

echo "Installing K3s server on ${MASTER_NAME}..."
run_multipass exec "$MASTER_NAME" -- bash -lc "
  if ! command -v k3s >/dev/null 2>&1; then
    curl -sfL https://get.k3s.io | sh -
  fi
  sudo systemctl enable --now k3s
"

MASTER_TOKEN="$(run_multipass exec "$MASTER_NAME" -- sudo cat /var/lib/rancher/k3s/server/node-token)"

if [[ -z "$MASTER_TOKEN" ]]; then
  echo "Error: could not read K3s node token from ${MASTER_NAME}." >&2
  exit 1
fi

echo "Installing K3s agent on ${WORKER_NAME}..."
run_multipass exec "$WORKER_NAME" -- bash -lc "
  if ! command -v k3s-agent >/dev/null 2>&1; then
    curl -sfL https://get.k3s.io | K3S_URL=https://${MASTER_IP}:6443 K3S_TOKEN=${MASTER_TOKEN} sh -
  fi
  sudo systemctl enable --now k3s-agent
"

echo "Waiting for both nodes to become Ready..."
run_multipass exec "$MASTER_NAME" -- sudo kubectl wait --for=condition=Ready node/"$MASTER_NAME" --timeout=180s
run_multipass exec "$MASTER_NAME" -- sudo kubectl wait --for=condition=Ready node/"$WORKER_NAME" --timeout=180s

if [[ "$CONFIGURE_KUBECONFIG" -eq 1 ]]; then
  if [[ "$ENSURE_HOST_TOOLS" -eq 1 ]]; then
    ensure_host_tools
  fi

  echo "Configuring local kubeconfig at ~/.kube/config ..."
  mkdir -p "$HOME/.kube"
  run_multipass exec "$MASTER_NAME" -- sudo cat /etc/rancher/k3s/k3s.yaml > "$HOME/.kube/config"

  if command -v sed >/dev/null 2>&1; then
    if sed --version >/dev/null 2>&1; then
      sed -i "s/127.0.0.1/${MASTER_IP}/g" "$HOME/.kube/config"
    else
      sed -i '' "s/127.0.0.1/${MASTER_IP}/g" "$HOME/.kube/config"
    fi
  fi
  chmod 600 "$HOME/.kube/config"
fi

if [[ "$SETUP_NGINX_PROXY" -eq 1 ]]; then
  echo "Configuring host NGINX reverse proxy for ports 80 and 443..."
  setup_nginx_reverse_proxy "$MASTER_IP"
fi

echo ""
echo "Cluster is ready."
echo ""
echo "Multipass status:"
run_multipass list
echo ""
run_multipass info "$MASTER_NAME"
echo ""
run_multipass info "$WORKER_NAME"
echo ""
echo "K3s nodes:"
run_multipass exec "$MASTER_NAME" -- sudo kubectl get nodes -o wide
echo ""
echo "Check nodes again with:"
echo "  multipass exec ${MASTER_NAME} -- sudo kubectl get nodes -o wide"
if [[ "$CONFIGURE_KUBECONFIG" -eq 1 ]]; then
  echo "  kubectl get nodes -o wide"
  echo "  helm list -A"
fi
if [[ "$SETUP_NGINX_PROXY" -eq 1 ]]; then
  echo ""
  echo "Reverse proxy endpoints:"
  echo "  http://<HOST_IP_OR_DNS>   -> ${MASTER_IP}:80"
  echo "  https://<HOST_IP_OR_DNS>  -> ${MASTER_IP}:443"
fi
