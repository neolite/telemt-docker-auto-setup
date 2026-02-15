#!/usr/bin/env bash

set -euo pipefail

FORCE=0
NO_UP=0

TLS_DOMAIN="${TLS_DOMAIN:-auto}"
PROXY_USER="${PROXY_USER:-hello}"
PORT="${PORT:-443}"
METRICS_PORT="${METRICS_PORT:-}"
PUBLIC_IP="${PUBLIC_IP:-auto}"
IMAGE="${IMAGE:-whn0thacked/telemt-docker:latest}"
CONTAINER_NAME="${CONTAINER_NAME:-telemt}"
RUST_LOG="${RUST_LOG:-info}"
CONFIG_PATH="${CONFIG_PATH:-./telemt.toml}"
COMPOSE_PATH="${COMPOSE_PATH:-./docker-compose.yml}"

usage() {
  cat <<'EOF'
Usage: ./bootstrap.sh [options]

Options:
  --tls-domain <domain|auto>  TLS masking domain (default: auto)
                              auto/example.com = pick reachable domain from popular list
  --user <name>               Username in [access.users] (default: hello)
  --port <port>               Telemt listen port (default: 443)
  --metrics-port <port>       Enable metrics port in config and compose
  --public-ip <ip|auto|none>  announce_ip behavior (default: auto)
                              auto = detect external IPv4, none = disable announce_ip
  --image <image:tag>         Docker image (default: whn0thacked/telemt-docker:latest)
  --container-name <name>     Docker container name (default: telemt)
  --rust-log <level>          RUST_LOG value (default: info)
  --config-path <path>        telemt config path on host (default: ./telemt.toml)
  --compose-path <path>       docker-compose path (default: ./docker-compose.yml)
  --force                     Overwrite existing config/compose files
  --no-up                     Only create files, do not run docker compose up -d
  -h, --help                  Show this help
EOF
}

TLS_DOMAIN_CANDIDATES="${TLS_DOMAIN_CANDIDATES:-yandex.ru,vk.com,ozon.ru,wildberries.ru,avito.ru,mail.ru,dzen.ru,kinopoisk.ru,sberbank.ru,gosuslugi.ru}"
SELECTED_TLS_DOMAIN=""
PUBLIC_IP_SOURCES="${PUBLIC_IP_SOURCES:-https://api64.ipify.org,https://ifconfig.me/ip,https://ipv4.icanhazip.com,https://checkip.amazonaws.com}"
SELECTED_PUBLIC_IP=""

resolve_tls_domain() {
  if [[ "$TLS_DOMAIN" != "auto" && "$TLS_DOMAIN" != "example.com" ]]; then
    SELECTED_TLS_DOMAIN="$TLS_DOMAIN"
    return
  fi

  IFS=',' read -r -a candidates <<< "$TLS_DOMAIN_CANDIDATES"
  if [[ "${#candidates[@]}" -eq 0 ]]; then
    echo "TLS_DOMAIN_CANDIDATES is empty." >&2
    exit 1
  fi

  if ! command -v curl >/dev/null 2>&1; then
    SELECTED_TLS_DOMAIN="${candidates[0]}"
    echo "Warning: curl not found. Fallback tls_domain=$SELECTED_TLS_DOMAIN"
    return
  fi

  for raw_domain in "${candidates[@]}"; do
    domain="$(echo "$raw_domain" | tr -d '[:space:]')"
    if [[ -z "$domain" ]]; then
      continue
    fi

    if curl -fsS -L --max-time 6 --connect-timeout 3 "https://$domain" -o /dev/null 2>/dev/null; then
      SELECTED_TLS_DOMAIN="$domain"
      return
    fi
  done

  SELECTED_TLS_DOMAIN="$(echo "${candidates[0]}" | tr -d '[:space:]')"
  echo "Warning: couldn't verify reachable domains. Fallback tls_domain=$SELECTED_TLS_DOMAIN"
}

is_valid_ipv4() {
  local ip="$1"
  if ! [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    return 1
  fi

  IFS='.' read -r o1 o2 o3 o4 <<< "$ip"
  for oct in "$o1" "$o2" "$o3" "$o4"; do
    if (( oct < 0 || oct > 255 )); then
      return 1
    fi
  done
  return 0
}

resolve_public_ip() {
  if [[ "$PUBLIC_IP" == "none" ]]; then
    SELECTED_PUBLIC_IP=""
    return
  fi

  if [[ -n "$PUBLIC_IP" && "$PUBLIC_IP" != "auto" ]]; then
    SELECTED_PUBLIC_IP="$PUBLIC_IP"
    return
  fi

  if ! command -v curl >/dev/null 2>&1; then
    echo "Warning: curl not found, cannot auto-detect public IP." >&2
    SELECTED_PUBLIC_IP=""
    return
  fi

  IFS=',' read -r -a sources <<< "$PUBLIC_IP_SOURCES"
  for src in "${sources[@]}"; do
    url="$(echo "$src" | tr -d '[:space:]')"
    if [[ -z "$url" ]]; then
      continue
    fi

    candidate="$(curl -fsS --max-time 5 --connect-timeout 3 "$url" 2>/dev/null | tr -d '\r\n[:space:]' || true)"
    if is_valid_ipv4 "$candidate"; then
      SELECTED_PUBLIC_IP="$candidate"
      return
    fi
  done

  echo "Warning: could not auto-detect external IPv4, announce_ip disabled." >&2
  SELECTED_PUBLIC_IP=""
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tls-domain)
      TLS_DOMAIN="$2"
      shift 2
      ;;
    --user)
      PROXY_USER="$2"
      shift 2
      ;;
    --port)
      PORT="$2"
      shift 2
      ;;
    --metrics-port)
      METRICS_PORT="$2"
      shift 2
      ;;
    --public-ip)
      PUBLIC_IP="$2"
      shift 2
      ;;
    --image)
      IMAGE="$2"
      shift 2
      ;;
    --container-name)
      CONTAINER_NAME="$2"
      shift 2
      ;;
    --rust-log)
      RUST_LOG="$2"
      shift 2
      ;;
    --config-path)
      CONFIG_PATH="$2"
      shift 2
      ;;
    --compose-path)
      COMPOSE_PATH="$2"
      shift 2
      ;;
    --force)
      FORCE=1
      shift
      ;;
    --no-up)
      NO_UP=1
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

if ! command -v openssl >/dev/null 2>&1; then
  echo "openssl is required." >&2
  exit 1
fi

if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
  echo "Invalid --port value: $PORT" >&2
  exit 1
fi

if [[ -n "$METRICS_PORT" ]] && ( ! [[ "$METRICS_PORT" =~ ^[0-9]+$ ]] || (( METRICS_PORT < 1 || METRICS_PORT > 65535 )) ); then
  echo "Invalid --metrics-port value: $METRICS_PORT" >&2
  exit 1
fi

mkdir -p "$(dirname "$CONFIG_PATH")"
mkdir -p "$(dirname "$COMPOSE_PATH")"
resolve_tls_domain
resolve_public_ip

SECRET="$(openssl rand -hex 16)"
USED_SECRET=""

if [[ -e "$CONFIG_PATH" && "$FORCE" -ne 1 ]]; then
  echo "Skip: $CONFIG_PATH already exists (use --force to overwrite)."
else
  cat >"$CONFIG_PATH" <<EOF
# Generated by bootstrap.sh
show_link = ["$PROXY_USER"]

[general]
prefer_ipv6 = false
fast_mode = true
use_middle_proxy = false

[general.modes]
classic = false
secure = false
tls = true

[server]
port = $PORT
listen_addr_ipv4 = "0.0.0.0"
listen_addr_ipv6 = "::"
EOF

  if [[ -n "$METRICS_PORT" ]]; then
    cat >>"$CONFIG_PATH" <<EOF
metrics_port = $METRICS_PORT
metrics_whitelist = ["127.0.0.1", "::1"]
EOF
  fi

  cat >>"$CONFIG_PATH" <<'EOF'

[[server.listeners]]
ip = "0.0.0.0"
EOF

  if [[ -n "$SELECTED_PUBLIC_IP" ]]; then
    cat >>"$CONFIG_PATH" <<EOF
announce_ip = "$SELECTED_PUBLIC_IP"
EOF
  fi

  cat >>"$CONFIG_PATH" <<EOF

[[server.listeners]]
ip = "::"

[timeouts]
client_handshake = 15
tg_connect = 10
client_keepalive = 60
client_ack = 300

[censorship]
tls_domain = "$SELECTED_TLS_DOMAIN"
mask = true
mask_port = 443
fake_cert_len = 2048

[access]
replay_check_len = 65536
ignore_time_skew = false

[access.users]
EOF

  cat >>"$CONFIG_PATH" <<EOF
"$PROXY_USER" = "$SECRET"
EOF

  cat >>"$CONFIG_PATH" <<'EOF'

[[upstreams]]
type = "direct"
enabled = true
weight = 10
EOF

  USED_SECRET="$SECRET"
  echo "Created: $CONFIG_PATH"
fi

if [[ -e "$COMPOSE_PATH" && "$FORCE" -ne 1 ]]; then
  echo "Skip: $COMPOSE_PATH already exists (use --force to overwrite)."
else
  cat >"$COMPOSE_PATH" <<EOF
services:
  telemt:
    image: $IMAGE
    container_name: $CONTAINER_NAME
    restart: unless-stopped
    environment:
      RUST_LOG: "$RUST_LOG"
    volumes:
      - $CONFIG_PATH:/etc/telemt.toml:ro
    ports:
      - "$PORT:$PORT/tcp"
EOF

  if [[ -n "$METRICS_PORT" ]]; then
    cat >>"$COMPOSE_PATH" <<EOF
      - "127.0.0.1:$METRICS_PORT:$METRICS_PORT/tcp"
EOF
  fi

  cat >>"$COMPOSE_PATH" <<EOF
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
EOF

  if (( PORT < 1024 )); then
    cat >>"$COMPOSE_PATH" <<'EOF'
    cap_add:
      - NET_BIND_SERVICE
EOF
  fi

  cat >>"$COMPOSE_PATH" <<'EOF'
    read_only: true
    tmpfs:
      - /tmp:rw,nosuid,nodev,noexec,size=16m
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
EOF

  echo "Created: $COMPOSE_PATH"
fi

if [[ "$NO_UP" -eq 1 ]]; then
  echo "Done. Files created, container not started (--no-up)."
  echo "TLS domain: $SELECTED_TLS_DOMAIN"
  if [[ -n "$SELECTED_PUBLIC_IP" ]]; then
    echo "Public IP (announce_ip): $SELECTED_PUBLIC_IP"
  else
    echo "Public IP (announce_ip): disabled"
  fi
  if [[ -n "$USED_SECRET" ]]; then
    echo "User: $PROXY_USER"
    echo "Secret: $USED_SECRET"
  fi
  exit 0
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required." >&2
  exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "docker compose plugin is required." >&2
  exit 1
fi

docker compose -f "$COMPOSE_PATH" up -d
echo "Telemt is running."
echo "Config: $CONFIG_PATH"
echo "Compose: $COMPOSE_PATH"
echo "TLS domain: $SELECTED_TLS_DOMAIN"
if [[ -n "$SELECTED_PUBLIC_IP" ]]; then
  echo "Public IP (announce_ip): $SELECTED_PUBLIC_IP"
else
  echo "Public IP (announce_ip): disabled"
fi
echo "User: $PROXY_USER"
if [[ -n "$USED_SECRET" ]]; then
  echo "Secret: $USED_SECRET"
else
  echo "Secret was not regenerated (existing config kept)."
fi
