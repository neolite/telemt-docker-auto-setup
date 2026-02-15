#!/usr/bin/env bash

set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/whn0thacked/telemt-docker.git}"
REF="${REF:-master}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/telemt-docker}"

usage() {
  cat <<'EOF'
Usage: ./install-telemt.sh [installer options] [bootstrap options]

Installer options:
  --repo-url <url>      Git repository URL
  --ref <branch|tag>    Git ref to checkout (default: master)
  --dir <path>          Install directory (default: ~/telemt-docker)
  --help                Show this help

Bootstrap options:
  Any option supported by ./bootstrap.sh, for example:
    --tls-domain auto
    --port 443
    --public-ip 1.2.3.4
    --force
    --no-up

Note:
  If --tls-domain is not provided, installer sets --tls-domain auto.
EOF
}

BOOTSTRAP_ARGS=()
HAS_TLS_DOMAIN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-url)
      REPO_URL="$2"
      shift 2
      ;;
    --ref)
      REF="$2"
      shift 2
      ;;
    --dir)
      INSTALL_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --tls-domain)
      HAS_TLS_DOMAIN=1
      BOOTSTRAP_ARGS+=("$1" "$2")
      shift 2
      ;;
    *)
      BOOTSTRAP_ARGS+=("$1")
      shift
      ;;
  esac
done

if ! command -v git >/dev/null 2>&1; then
  echo "git is required." >&2
  exit 1
fi

if [[ -d "$INSTALL_DIR/.git" ]]; then
  if ! git -C "$INSTALL_DIR" diff --quiet || ! git -C "$INSTALL_DIR" diff --cached --quiet; then
    echo "Local changes found in $INSTALL_DIR. Commit/stash them first." >&2
    exit 1
  fi

  git -C "$INSTALL_DIR" fetch --depth 1 origin "$REF"
  git -C "$INSTALL_DIR" checkout "$REF"
  if git -C "$INSTALL_DIR" show-ref --verify --quiet "refs/remotes/origin/$REF"; then
    git -C "$INSTALL_DIR" pull --ff-only origin "$REF"
  fi
else
  git clone --depth 1 --branch "$REF" "$REPO_URL" "$INSTALL_DIR"
fi

if [[ ! -f "$INSTALL_DIR/bootstrap.sh" ]]; then
  echo "bootstrap.sh not found in $INSTALL_DIR" >&2
  exit 1
fi

chmod +x "$INSTALL_DIR/bootstrap.sh"

if [[ "$HAS_TLS_DOMAIN" -ne 1 ]]; then
  BOOTSTRAP_ARGS=(--tls-domain auto "${BOOTSTRAP_ARGS[@]}")
fi

(
  cd "$INSTALL_DIR"
  ./bootstrap.sh "${BOOTSTRAP_ARGS[@]}"
)
