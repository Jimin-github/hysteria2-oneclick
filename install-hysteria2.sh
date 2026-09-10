#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

PROGRAM_NAME="install-hysteria2"
DOMAIN="${1:-}"
ACME_EMAIL="${2:-}"
HY2_UP_MBPS="${HY2_UP_MBPS:-100}"
HY2_DOWN_MBPS="${HY2_DOWN_MBPS:-500}"
HY2_PORT="${HY2_PORT:-443}"

HYSTERIA_BIN="/usr/local/bin/hysteria"
HYSTERIA_CONFIG="/etc/hysteria/config.yaml"
HYSTERIA_SERVICE="/etc/systemd/system/hysteria-server.service"
HYSTERIA_ENABLE_LINK="/etc/systemd/system/multi-user.target.wants/hysteria-server.service"
HYSTERIA_SYSCTL="/etc/sysctl.d/99-hysteria2.conf"
CLASH_OUTPUT="/root/hysteria2-clash.yaml"
HIDDIFY_OUTPUT="/root/hysteria2-hiddify.txt"
WORK_DIR=""

log() {
  printf '[%s] %s\n' "$PROGRAM_NAME" "$*"
}

die() {
  printf '[%s] ERROR: %s\n' "$PROGRAM_NAME" "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
    # Deletes only the private temporary directory created by this run.
    rm -rf -- "$WORK_DIR"
  fi
}

trap cleanup EXIT

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  die "run this script as root"
fi

[[ -n "$DOMAIN" ]] || die "usage: bash install-hysteria2.sh <domain> [acme-email]"
[[ "$DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || die "invalid domain: $DOMAIN"
[[ "$DOMAIN" == *.* ]] || die "domain must contain at least one dot"
(( ${#DOMAIN} <= 253 )) || die "domain is too long"
IFS='.' read -r -a DOMAIN_LABELS <<< "$DOMAIN"
for label in "${DOMAIN_LABELS[@]}"; do
  [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] \
    || die "invalid domain label: $label"
done
[[ "$HY2_PORT" =~ ^[0-9]+$ ]] && (( HY2_PORT >= 1 && HY2_PORT <= 65535 )) || die "HY2_PORT must be 1-65535"
[[ "$HY2_UP_MBPS" =~ ^[0-9]+$ ]] && (( HY2_UP_MBPS > 0 )) || die "HY2_UP_MBPS must be a positive integer"
[[ "$HY2_DOWN_MBPS" =~ ^[0-9]+$ ]] && (( HY2_DOWN_MBPS > 0 )) || die "HY2_DOWN_MBPS must be a positive integer"
if [[ -n "$ACME_EMAIL" && ! "$ACME_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,63}$ ]]; then
  die "invalid ACME email: $ACME_EMAIL"
fi

command -v systemctl >/dev/null 2>&1 || die "systemd is required"
[[ -r /etc/os-release ]] || die "cannot detect operating system"
# shellcheck disable=SC1091
source /etc/os-release
case "${ID:-}" in
  debian|ubuntu) ;;
  *) die "supported systems: Debian 11+ and Ubuntu 22.04+" ;;
esac

TARGETS=(
  "$HYSTERIA_BIN"
  "$HYSTERIA_CONFIG"
  "$HYSTERIA_SERVICE"
  "$HYSTERIA_ENABLE_LINK"
  "$HYSTERIA_SYSCTL"
  "$CLASH_OUTPUT"
  "$HIDDIFY_OUTPUT"
)
for target in "${TARGETS[@]}"; do
  [[ ! -e "$target" && ! -L "$target" ]] || die "refusing to overwrite existing target: $target"
done

log "installing required packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl openssl python3 iproute2

for command_name in curl openssl python3 sha256sum getent ss install groupadd useradd base64; do
  command -v "$command_name" >/dev/null 2>&1 || die "required command not found: $command_name"
done

if ss -H -ltn | awk '{print $4}' | grep -Eq '(^|:|\])80$'; then
  die "TCP port 80 is already in use; ACME HTTP-01 requires it during certificate issuance"
fi
if ss -H -lun | awk '{print $4}' | grep -Eq "(^|:|\])${HY2_PORT}$"; then
  die "UDP port $HY2_PORT is already in use"
fi

PUBLIC_IP="$(curl -4fsSL --connect-timeout 10 --max-time 20 https://api.ipify.org)"
PUBLIC_IP="$PUBLIC_IP" python3 - <<'PY' || die "could not determine this server's public IPv4 address"
import ipaddress
import os

ipaddress.IPv4Address(os.environ["PUBLIC_IP"])
PY
mapfile -t DOMAIN_IPS < <(getent ahostsv4 "$DOMAIN" | awk '{print $1}' | sort -u)
(( ${#DOMAIN_IPS[@]} > 0 )) || die "domain has no IPv4 address: $DOMAIN"
printf '%s\n' "${DOMAIN_IPS[@]}" | grep -Fxq "$PUBLIC_IP" || {
  printf '[%s] Domain resolves to: %s\n' "$PROGRAM_NAME" "${DOMAIN_IPS[*]}" >&2
  die "$DOMAIN does not resolve to this server ($PUBLIC_IP), or a CDN proxy is enabled"
}

case "$(uname -m)" in
  x86_64|amd64) HY2_ARCH="amd64" ;;
  aarch64|arm64) HY2_ARCH="arm64" ;;
  *) die "unsupported architecture: $(uname -m)" ;;
esac

WORK_DIR="$(mktemp -d -t hysteria2-install.XXXXXXXX)"
chmod 700 "$WORK_DIR"

log "querying the official Hysteria release API"
UPDATE_JSON="$(curl -fsSL --connect-timeout 10 --max-time 30 \
  "https://api.hy2.io/v1/update?cver=installscript&plat=linux&arch=${HY2_ARCH}&chan=release&side=server")"
HY2_VERSION="$(UPDATE_JSON="$UPDATE_JSON" python3 - <<'PY'
import json
import os
import re

version = json.loads(os.environ["UPDATE_JSON"])["lver"]
if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", version):
    raise SystemExit("invalid release version")
print(version)
PY
)"

RELEASE_JSON="$(curl -fsSL --connect-timeout 10 --max-time 30 \
  -H 'Accept: application/vnd.github+json' \
  -H 'User-Agent: hysteria2-oneclick-installer' \
  "https://api.github.com/repos/apernet/hysteria/releases/tags/app/${HY2_VERSION}")"

readarray -t RELEASE_INFO < <(RELEASE_JSON="$RELEASE_JSON" HY2_ARCH="$HY2_ARCH" python3 - <<'PY'
import json
import os
import re

asset_name = f"hysteria-linux-{os.environ['HY2_ARCH']}"
release = json.loads(os.environ["RELEASE_JSON"])
asset = next((item for item in release.get("assets", []) if item.get("name") == asset_name), None)
if asset is None:
    raise SystemExit(f"release asset not found: {asset_name}")
digest = asset.get("digest") or ""
if not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
    raise SystemExit("release asset is missing a valid SHA-256 digest")
print(asset["browser_download_url"])
print(digest.removeprefix("sha256:"))
PY
)
(( ${#RELEASE_INFO[@]} == 2 )) || die "failed to read verified release metadata"
DOWNLOAD_URL="${RELEASE_INFO[0]}"
EXPECTED_SHA256="${RELEASE_INFO[1]}"
DOWNLOAD_FILE="$WORK_DIR/hysteria-linux-${HY2_ARCH}"

log "downloading Hysteria $HY2_VERSION"
curl -fL --retry 4 --retry-delay 3 --connect-timeout 15 --max-time 180 \
  -o "$DOWNLOAD_FILE" "$DOWNLOAD_URL"
ACTUAL_SHA256="$(sha256sum "$DOWNLOAD_FILE" | awk '{print $1}')"
[[ "$ACTUAL_SHA256" == "$EXPECTED_SHA256" ]] || die "binary SHA-256 verification failed"

AUTH_PASSWORD="$(openssl rand -hex 32)"
NODE_NAME="HY2-${DOMAIN}"

if ! getent group hysteria >/dev/null 2>&1; then
  groupadd --system hysteria
fi
if ! id hysteria >/dev/null 2>&1; then
  useradd --system --gid hysteria --home-dir /var/lib/hysteria --create-home --shell /usr/sbin/nologin hysteria
fi
install -d -o hysteria -g hysteria -m 0750 /var/lib/hysteria
install -d -o root -g hysteria -m 0750 /etc/hysteria
install -o root -g root -m 0755 "$DOWNLOAD_FILE" "$HYSTERIA_BIN"

cat > "$HYSTERIA_CONFIG" <<EOF
listen: :${HY2_PORT}

acme:
  domains:
    - ${DOMAIN}
  email: ${ACME_EMAIL}
  ca: letsencrypt
  type: http

auth:
  type: password
  password: ${AUTH_PASSWORD}

masquerade:
  type: proxy
  proxy:
    url: https://news.ycombinator.com/
    rewriteHost: true
EOF
chown root:hysteria "$HYSTERIA_CONFIG"
chmod 0640 "$HYSTERIA_CONFIG"

cat > "$HYSTERIA_SERVICE" <<'EOF'
[Unit]
Description=Hysteria 2 Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=hysteria
Group=hysteria
WorkingDirectory=/var/lib/hysteria
ExecStart=/usr/local/bin/hysteria server --config /etc/hysteria/config.yaml
Environment=HYSTERIA_LOG_LEVEL=info
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=true
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
chmod 0644 "$HYSTERIA_SERVICE"

cat > "$HYSTERIA_SYSCTL" <<'EOF'
# Hysteria 2 / QUIC buffers for high-bandwidth, high-latency links.
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
EOF
chmod 0644 "$HYSTERIA_SYSCTL"
sysctl -p "$HYSTERIA_SYSCTL"

cat > "$CLASH_OUTPUT" <<EOF
mixed-port: 7890
allow-lan: false
mode: rule
log-level: info
ipv6: false

proxies:
  - name: "${NODE_NAME}"
    type: hysteria2
    server: ${DOMAIN}
    port: ${HY2_PORT}
    password: "${AUTH_PASSWORD}"
    sni: ${DOMAIN}
    skip-cert-verify: false
    up: "${HY2_UP_MBPS} Mbps"
    down: "${HY2_DOWN_MBPS} Mbps"
    udp: true

proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - "${NODE_NAME}"
      - DIRECT

rules:
  - DOMAIN,${DOMAIN},DIRECT
  - IP-CIDR,${PUBLIC_IP}/32,DIRECT,no-resolve
  - GEOIP,CN,DIRECT
  - MATCH,PROXY
EOF
chmod 0600 "$CLASH_OUTPUT"

HY2_URI="hysteria2://${AUTH_PASSWORD}@${DOMAIN}:${HY2_PORT}/?sni=${DOMAIN}&insecure=0#${NODE_NAME}"
printf '%s' "$HY2_URI" | base64 -w 0 > "$HIDDIFY_OUTPUT"
printf '\n' >> "$HIDDIFY_OUTPUT"
chmod 0600 "$HIDDIFY_OUTPUT"

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
  log "UFW is active; adding ACME and Hysteria ingress rules"
  ufw allow 80/tcp
  ufw allow "${HY2_PORT}/udp"
fi

systemctl daemon-reload
systemctl enable --now hysteria-server.service

log "waiting for ACME certificate issuance and service readiness"
READY=0
for _ in $(seq 1 30); do
  if journalctl -u hysteria-server.service --since '-2 minutes' --no-pager \
      | grep -Fq 'server up and running'; then
    READY=1
    break
  fi
  sleep 2
done

if [[ "$READY" -ne 1 ]] || ! systemctl is-active --quiet hysteria-server.service; then
  journalctl -u hysteria-server.service -n 80 --no-pager >&2 || true
  die "Hysteria did not become ready; check DNS, TCP 80 and UDP ${HY2_PORT} firewall rules"
fi

ss -H -lunp | grep -E "(^|:)${HY2_PORT}[[:space:]]" >/dev/null \
  || die "service is active but UDP ${HY2_PORT} is not listening"

cat <<EOF

Hysteria 2 deployment completed.
  Version:       ${HY2_VERSION}
  Server:        ${DOMAIN}:${HY2_PORT}/udp
  Public IP:     ${PUBLIC_IP}
  Clash YAML:    ${CLASH_OUTPUT}
  Hiddify TXT:   ${HIDDIFY_OUTPUT}
  Server config: ${HYSTERIA_CONFIG}

The client files contain the authentication secret and are mode 0600.
Keep TCP 80 open for ACME renewal and UDP ${HY2_PORT} open for Hysteria.
EOF
