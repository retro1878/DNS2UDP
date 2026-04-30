#!/usr/bin/env bash
# ==============================================================================
# StormDNS — Unified Smart Installer v2
# Covers server and client installation with autodiscovery and guided setup.
# Usage: sudo bash install.sh [--server|--client] [OPTIONS]
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

# ══════════════════════════════════════════════════════════════════════════════
# CONSTANTS
# ══════════════════════════════════════════════════════════════════════════════
readonly INSTALLER_VER="2.0"
readonly GITHUB_REPO="retro1878/DNS2UDP"
readonly GITHUB_BASE="https://github.com/${GITHUB_REPO}"
readonly GITHUB_RAW="https://raw.githubusercontent.com/${GITHUB_REPO}"
readonly DIST_BRANCH="claude/dns-tunneling-vpn-bKdJL"
readonly SERVER_SVC="stormdns"
readonly CLIENT_SVC="stormdns-client"
readonly SERVER_UNIT="/etc/systemd/system/${SERVER_SVC}.service"
readonly CLIENT_UNIT="/etc/systemd/system/${CLIENT_SVC}.service"
readonly SYSCTL_CONF="/etc/sysctl.d/99-stormdns.conf"
readonly LIMITS_CONF="/etc/security/limits.d/99-stormdns.conf"

_TMP_LOG="" _DOWNLOAD_DIR="" _SPINNER_PID=""
_cleanup() {
  [[ -n "${_SPINNER_PID:-}" ]] && { kill "$_SPINNER_PID" 2>/dev/null; wait "$_SPINNER_PID" 2>/dev/null || true; }
  [[ -n "${_TMP_LOG:-}"      ]] && rm -f "$_TMP_LOG"     2>/dev/null || true
  [[ -n "${_DOWNLOAD_DIR:-}" && -d "${_DOWNLOAD_DIR:-}" ]] && rm -rf "$_DOWNLOAD_DIR" 2>/dev/null || true
}
trap _cleanup EXIT

# ══════════════════════════════════════════════════════════════════════════════
# COLORS & LOGGING
# ══════════════════════════════════════════════════════════════════════════════
R='\033[1;31m'  G='\033[1;32m'  Y='\033[1;33m'
B='\033[1;34m'  M='\033[1;35m'  C='\033[1;36m'
W='\033[1;37m'  BO='\033[1m'    DM='\033[2m'   NC='\033[0m'

_STEP=0 _TOTAL=0

step()  { (( _STEP++ )) || true
          echo -e "\n${C}${BO}┌─ [${_STEP}/${_TOTAL}] ─ $* ${NC}"; }
info()  { echo -e "  ${B}·${NC} $*"; }
done_() { echo -e "  ${G}✓${NC} $*"; }
warn()  { echo -e "  ${Y}⚠${NC}  $*"; }
err()   { echo -e "\n  ${R}${BO}✘  $*${NC}\n"; exit 1; }
kv()    { printf "  ${DM}%-34s${NC} ${C}%s${NC}\n" "$1" "$2"; }
hr()    { echo -e "  ${DM}$(printf '%.0s─' {1..62})${NC}"; }

# ══════════════════════════════════════════════════════════════════════════════
# SPINNER
# ══════════════════════════════════════════════════════════════════════════════
spin_start() {
  local msg="$1"
  local -a f=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  { local i=0
    while true; do
      printf "\r  ${C}%s${NC}  %s   " "${f[$((i%10))]}" "$msg"
      sleep 0.1; (( i++ )) || true
    done; } &
  _SPINNER_PID=$!
}
spin_stop() {
  [[ -n "${_SPINNER_PID:-}" ]] && { kill "$_SPINNER_PID" 2>/dev/null; wait "$_SPINNER_PID" 2>/dev/null || true; }
  printf "\r\033[K"; _SPINNER_PID=""
}

# ══════════════════════════════════════════════════════════════════════════════
# TOML HELPERS
# ══════════════════════════════════════════════════════════════════════════════
toml_str()     { sed -i -E "s|^(${1})[[:space:]]*=.*$|\1 = \"${2}\"|" "$3"; }
toml_int()     { sed -i -E "s|^(${1})[[:space:]]*=.*$|\1 = ${2}|"    "$3"; }
toml_arr_str() { sed -i -E "s|^(${1})[[:space:]]*=.*$|\1 = [\"${2}\"]|" "$3"; }
toml_get()     { grep -m1 "^${1}[[:space:]]*=" "$2" 2>/dev/null \
                 | sed -E 's/^[^=]*=[[:space:]]*//' | tr -d '"' || true; }
cfg_ver()      { toml_get CONFIG_VERSION "$1" 2>/dev/null || echo "0"; }

version_lt() {
  [[ "$1" == "$2" ]] && return 1
  [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" == "$1" ]]
}

bak_once() {
  local f="$1"
  [[ -f "$f" && ! -f "${f}.bak" ]] && cp -a "$f" "${f}.bak"
}

handle_upgrade() {
  local cfg="$1" bak="${1}.backup"
  [[ -f "$bak" ]] || return 0
  local cv bv
  cv="$(cfg_ver "$cfg")"; bv="$(cfg_ver "$bak")"
  [[ -n "$bv" ]] || err "Backup config missing CONFIG_VERSION — merge manually."
  if [[ "$bv" == "$cv" ]]; then
    mv -f "$bak" "$cfg"
    info "Previous config restored (same version $cv)."
  elif version_lt "$bv" "$cv"; then
    local arch
    arch="$(dirname "$cfg")/$(basename "$cfg" .toml)_$(date +%Y%m%d_%H%M%S).toml"
    mv -f "$bak" "$arch"
    warn "Config upgraded v${bv} → v${cv}. Old config saved: $(basename "$arch")"
  else
    err "Backup config (v${bv}) is newer than installed template (v${cv}). Merge manually."
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
# SYSTEM DETECTION
# ══════════════════════════════════════════════════════════════════════════════
OS_ID="" OS_VER="" ARCH="" IS_LEGACY=0 PM=""

detect_system() {
  [[ -f /etc/os-release ]] || err "/etc/os-release not found."
  # shellcheck disable=SC1091
  source /etc/os-release
  OS_ID="${ID:-unknown}"; OS_VER="${VERSION_ID:-0}"
  local major="${OS_VER%%.*}"
  case "$OS_ID" in
    ubuntu)                      [[ "${major:-0}" -le 20 ]] && IS_LEGACY=1 ;;
    debian)                      [[ "${major:-0}" -le 11 ]] && IS_LEGACY=1 ;;
    almalinux|rocky|rhel|centos) [[ "${major:-0}" -le  8 ]] && IS_LEGACY=1 ;;
  esac
  ARCH="$(uname -m)"
  if   command -v apt-get >/dev/null 2>&1; then PM="apt"
  elif command -v dnf     >/dev/null 2>&1; then PM="dnf"
  elif command -v yum     >/dev/null 2>&1; then PM="yum"
  else err "No supported package manager (apt/dnf/yum)."; fi
}

install_deps() {
  # Critical tools the installer relies on.
  local critical=(curl unzip ca-certificates)
  # Nice-to-have tools (missing ones are skipped gracefully).
  local extras=(lsof net-tools wget iproute2 procps irqbalance)
  command -v dig      >/dev/null 2>&1 || extras+=(dnsutils)
  command -v nslookup >/dev/null 2>&1 || extras+=(dnsutils)

  spin_start "Installing system dependencies…"
  case "$PM" in
    apt)
      apt-get update -y >/dev/null 2>&1 || true
      apt-get install -y "${critical[@]}" "${extras[@]}" >/dev/null 2>&1 || \
        apt-get install -y "${critical[@]}" >/dev/null 2>&1 || true
      ;;
    dnf)
      local c=("${critical[@]/ca-certificates/ca-certs}")
      local e=("${extras[@]/iproute2/iproute}"); e=("${e[@]/dnsutils/bind-utils}")
      dnf -y install "${c[@]}" "${e[@]}" >/dev/null 2>&1 || \
        dnf -y install "${c[@]}" >/dev/null 2>&1 || true
      ;;
    yum)
      local c=("${critical[@]/ca-certificates/ca-certs}")
      local e=("${extras[@]/iproute2/iproute}"); e=("${e[@]/dnsutils/bind-utils}")
      yum -y install "${c[@]}" "${e[@]}" >/dev/null 2>&1 || \
        yum -y install "${c[@]}" >/dev/null 2>&1 || true
      ;;
  esac
  spin_stop

  # Verify the tools the installer itself needs are present.
  local missing=()
  for t in curl unzip; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  [[ ${#missing[@]} -eq 0 ]] || err "Required tools missing after install: ${missing[*]}\nInstall them manually and re-run."
}

enable_irqbalance() {
  systemctl list-unit-files --type=service --all 2>/dev/null \
    | awk '{print $1}' | grep -qx 'irqbalance.service' || return 0
  systemctl enable --now irqbalance >/dev/null 2>&1 || true
}

# ══════════════════════════════════════════════════════════════════════════════
# NETWORK HELPERS
# ══════════════════════════════════════════════════════════════════════════════
PUBLIC_IP=""

get_public_ip() {
  local ip svc
  for svc in "https://api.ipify.org" "https://ifconfig.me" \
             "https://ipecho.net/plain" "https://icanhazip.com" \
             "https://checkip.amazonaws.com"; do
    ip="$(curl -4 -sf --max-time 5 "$svc" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
      PUBLIC_IP="$ip"; return 0
    fi
  done
  return 1
}

ip_on_local_iface() { ip addr show 2>/dev/null | grep -qF "${1:-}"; }

check_ns_delegation() {
  local domain="$1" expected="$2"
  local ns_host="" ns_ip=""
  if command -v dig >/dev/null 2>&1; then
    ns_host="$(dig +short +time=4 NS "$domain" 2>/dev/null | head -1 | sed 's/\.$//')"
    [[ -n "$ns_host" ]] && ns_ip="$(dig +short +time=4 A "$ns_host" 2>/dev/null | head -1)"
  elif command -v nslookup >/dev/null 2>&1; then
    ns_host="$(nslookup -type=NS "$domain" 2>/dev/null \
               | awk '/nameserver/{print $NF}' | head -1 | sed 's/\.$//')"
    [[ -n "$ns_host" ]] && \
      ns_ip="$(nslookup "$ns_host" 2>/dev/null | awk '/^Address.*[0-9]/{print $2}' | tail -1)"
  fi
  [[ -n "${ns_ip:-}" && "$ns_ip" == "$expected" ]]
}

test_resolver() {
  local r="${1%%:*}" domain="$2"
  if command -v dig >/dev/null 2>&1; then
    dig +short +time=3 +tries=1 "@${r}" NS "$domain" >/dev/null 2>&1
  elif command -v nslookup >/dev/null 2>&1; then
    nslookup -timeout=3 "$domain" "$r" >/dev/null 2>&1
  else
    return 0
  fi
}

discover_resolvers() {
  local domain="$1"
  local candidates=(
    "8.8.8.8"        "8.8.4.4"
    "1.1.1.1"        "1.0.0.1"
    "9.9.9.9"        "149.112.112.112"
    "208.67.222.222" "208.67.220.220"
    "94.140.14.14"   "94.140.15.15"
    "185.228.168.9"  "185.228.169.9"
  )
  local resolv_ns
  while IFS= read -r resolv_ns; do
    [[ -n "$resolv_ns" ]] && candidates+=("$resolv_ns")
  done < <(awk '/^nameserver/{print $2}' /etc/resolv.conf 2>/dev/null || true)

  local good=()
  spin_start "Testing ${#candidates[@]} resolvers against ${domain}…"
  for r in "${candidates[@]}"; do
    test_resolver "$r" "$domain" 2>/dev/null && good+=("$r") || true
  done
  spin_stop
  printf '%s\n' "${good[@]}"
}

# ══════════════════════════════════════════════════════════════════════════════
# BINARY ACQUISITION
# ══════════════════════════════════════════════════════════════════════════════
BINARY=""

binary_prefix() {
  local role="$1"
  case "$ARCH" in
    x86_64|amd64)
      [[ $IS_LEGACY -eq 1 ]] \
        && echo "StormDNS_${role}_Linux-Legacy_AMD64" \
        || echo "StormDNS_${role}_Linux_AMD64" ;;
    aarch64|arm64)
      [[ $IS_LEGACY -eq 1 ]] \
        && echo "StormDNS_${role}_Linux-Legacy_ARM64" \
        || echo "StormDNS_${role}_Linux_ARM64" ;;
    armv7l|armv7|armhf)  echo "StormDNS_${role}_Linux_ARMV7" ;;
    i386|i486|i586|i686) echo "StormDNS_${role}_Linux_X86" ;;
    *)                   err "Unsupported architecture: $ARCH" ;;
  esac
}

acquire_binary() {
  local role="$1" version="${2:-}"
  local prefix; prefix="$(binary_prefix "$role")"

  shopt -s nullglob; local existing=("${prefix}_v"*); shopt -u nullglob
  if [[ ${#existing[@]} -gt 0 ]]; then
    BINARY="$(basename "${existing[0]}")"; chmod +x "$BINARY"
    done_ "Using local binary: $BINARY"; return 0
  fi

  # ── Try GitHub Release zip first ────────────────────────────────────────────
  local url
  if [[ -n "$version" ]]; then
    url="${GITHUB_BASE}/releases/download/${version}/${prefix}.zip"
  else
    url="${GITHUB_BASE}/releases/latest/download/${prefix}.zip"
  fi

  _DOWNLOAD_DIR="$(mktemp -d /tmp/stormdns_dl.XXXXXX)"
  local zip="${_DOWNLOAD_DIR}/pkg.zip"

  local _dl_ok=0
  spin_start "Downloading ${role} binary from GitHub Releases…"
  if curl -fL --retry 2 --retry-delay 3 --connect-timeout 20 \
           -o "$zip" "$url" 2>/dev/null && [[ -s "$zip" ]]; then
    _dl_ok=1
  fi
  spin_stop

  # ── Fallback: direct binary from dist/ on branch ─────────────────────────
  if [[ $_dl_ok -eq 0 ]]; then
    warn "No Release found — falling back to pre-built binary in dist/ branch."
    local raw_name; raw_name="$(basename "$prefix")"
    local raw_url="${GITHUB_RAW}/${DIST_BRANCH}/dist/${raw_name}"
    local bin_out="${_DOWNLOAD_DIR}/${raw_name}"
    spin_start "Downloading ${role} binary from dist/ branch…"
    if curl -fL --retry 3 --retry-delay 3 --connect-timeout 20 \
             -o "$bin_out" "$raw_url" 2>/dev/null && [[ -s "$bin_out" ]]; then
      spin_stop
      cp "$bin_out" "${INSTALL_DIR}/${raw_name}"; chmod +x "${INSTALL_DIR}/${raw_name}"
      BINARY="${raw_name}"

      # Also fetch the config template files that a Release zip would have provided.
      local cfg_base="${GITHUB_RAW}/${DIST_BRANCH}/dist"
      if [[ "$role" == "Server" ]]; then
        curl -fsSL "${cfg_base}/server_config.toml" -o "${INSTALL_DIR}/server_config.toml" 2>/dev/null || true
      else
        curl -fsSL "${cfg_base}/client_config.toml"  -o "${INSTALL_DIR}/client_config.toml"  2>/dev/null || true
        curl -fsSL "${cfg_base}/client_resolvers.txt" -o "${INSTALL_DIR}/client_resolvers.txt" 2>/dev/null || true
      fi

      done_ "Binary ready: $BINARY"; return 0
    fi
    spin_stop
    err "Download failed from both GitHub Releases and dist/ branch.\nRelease URL: ${url}\nFallback URL: ${raw_url}"
  fi

  spin_start "Extracting archive…"
  unzip -q -o "$zip" -d "$INSTALL_DIR" >/dev/null 2>&1; spin_stop

  shopt -s nullglob; local found=("${INSTALL_DIR}/${prefix}_v"* "${INSTALL_DIR}/$(basename "$prefix")"*); shopt -u nullglob
  [[ ${#found[@]} -gt 0 ]] || err "Binary not found after extraction."
  BINARY="$(basename "${found[0]}")"; chmod +x "${INSTALL_DIR}/${BINARY}"

  for b in "${INSTALL_DIR}/${prefix}_v"*; do [[ "${INSTALL_DIR}/$(basename "$b")" == "${INSTALL_DIR}/${BINARY}" ]] || rm -f -- "$b"; done
  rm -f ./*.spec 2>/dev/null || true
  done_ "Binary ready: $BINARY"
}

# ══════════════════════════════════════════════════════════════════════════════
# PORT 53 MANAGEMENT
# ══════════════════════════════════════════════════════════════════════════════
port53_busy() {
  ss -H -lun "sport = :53" 2>/dev/null | grep -q ':53' ||
  ss -H -ltn "sport = :53" 2>/dev/null | grep -q ':53'
}

port53_pids() {
  { ss -H -lupn "sport = :53" 2>/dev/null
    ss -H -ltpn "sport = :53" 2>/dev/null; } \
  | sed -n 's/.*pid=\([0-9]\+\).*/\1/p' | sort -u
}

kill_graceful() {
  local pid="$1"; kill -0 "$pid" 2>/dev/null || return 0
  kill "$pid" 2>/dev/null || true
  for _ in 1 2 3; do sleep 1; kill -0 "$pid" 2>/dev/null || return 0; done
  kill -9 "$pid" 2>/dev/null || true
}

stop_unit() {
  local u="$1"
  systemctl list-unit-files 2>/dev/null | grep -q "^${u}" || return 0
  systemctl is-active --quiet "${u%.service}" 2>/dev/null || return 0
  info "Stopping conflicting unit: ${u}"
  systemctl stop    "${u%.service}" >/dev/null 2>&1 || true
  systemctl disable "${u%.service}" >/dev/null 2>&1 || true
}

free_port53() {
  if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    bak_once /etc/systemd/resolved.conf
    grep -q '^#\?DNSStubListener=' /etc/systemd/resolved.conf \
      && sed -i 's/^#\?DNSStubListener=.*/DNSStubListener=no/' /etc/systemd/resolved.conf \
      || echo 'DNSStubListener=no' >> /etc/systemd/resolved.conf
    grep -q '^DNS=' /etc/systemd/resolved.conf \
      || echo 'DNS=8.8.8.8' >> /etc/systemd/resolved.conf
    systemctl restart systemd-resolved >/dev/null 2>&1 || true
  fi
  for u in bind9.service named.service dnsmasq.service unbound.service \
            pdns.service dnscrypt-proxy.service smartdns.service coredns.service \
            pihole-FTL.service kresd@1.service systemd-resolved.socket dnsmasq.socket; do
    stop_unit "$u" 2>/dev/null || true
  done
  while IFS= read -r pid; do
    [[ -n "$pid" ]] && kill_graceful "$pid" || true
  done < <(port53_pids)
}

stop_existing_server() {
  systemctl list-unit-files 2>/dev/null | grep -q "^${SERVER_SVC}\.service" || return 0
  info "Stopping existing StormDNS server service…"
  systemctl stop "$SERVER_SVC" 2>/dev/null || true
  local mpid
  mpid="$(systemctl show "$SERVER_SVC" --property MainPID --value 2>/dev/null || echo 0)"
  [[ "$mpid" != "0" ]] && kill -0 "$mpid" 2>/dev/null && kill_graceful "$mpid" || true
  systemctl reset-failed "$SERVER_SVC" 2>/dev/null || true
}

stop_existing_client() {
  systemctl list-unit-files 2>/dev/null | grep -q "^${CLIENT_SVC}\.service" || return 0
  info "Stopping existing StormDNS client service…"
  systemctl stop "$CLIENT_SVC" 2>/dev/null || true
  local mpid
  mpid="$(systemctl show "$CLIENT_SVC" --property MainPID --value 2>/dev/null || echo 0)"
  [[ "$mpid" != "0" ]] && kill -0 "$mpid" 2>/dev/null && kill_graceful "$mpid" || true
  systemctl reset-failed "$CLIENT_SVC" 2>/dev/null || true
}

# ══════════════════════════════════════════════════════════════════════════════
# FIREWALL
# ══════════════════════════════════════════════════════════════════════════════
open_port() {
  local port="$1" proto="${2:-udp}"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qw active; then
    ufw allow "${port}/${proto}" >/dev/null 2>&1 && done_ "UFW: ${port}/${proto} allowed."
  elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --permanent --add-port="${port}/${proto}" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
    done_ "firewalld: ${port}/${proto} allowed."
  elif command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null \
      || iptables -I INPUT -p "$proto" --dport "$port" -j ACCEPT
    command -v ip6tables >/dev/null 2>&1 && {
      ip6tables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null \
        || ip6tables -I INPUT -p "$proto" --dport "$port" -j ACCEPT; }
    command -v netfilter-persistent >/dev/null 2>&1 \
      && netfilter-persistent save >/dev/null 2>&1 || true
    done_ "iptables: ${port}/${proto} allowed."
  else
    warn "No active firewall detected — open ${port}/${proto} manually if required."
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
# KERNEL TUNING
# ══════════════════════════════════════════════════════════════════════════════
apply_tuning() {
  cat > "$SYSCTL_CONF" <<'SYSCTL'
fs.file-max = 2097152
fs.nr_open = 2097152
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 16384
net.core.optmem_max = 25165824
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.udp_mem = 65536 131072 262144
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_udp_timeout = 15
net.netfilter.nf_conntrack_udp_timeout_stream = 60
net.ipv4.ip_local_port_range = 10240 65535
SYSCTL
  sysctl --system >/dev/null 2>&1 || warn "Some sysctl settings could not be applied."
  cat > "$LIMITS_CONF" <<'LIMITS'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
LIMITS
}

# ══════════════════════════════════════════════════════════════════════════════
# SYSTEMD SERVICE WRITERS
# ══════════════════════════════════════════════════════════════════════════════
write_server_service() {
  local dir="$1" bin="$2"
  cat > "$SERVER_UNIT" <<EOF
[Unit]
Description=StormDNS Server
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
WorkingDirectory=${dir}
ExecStart=${dir}/${bin}
Restart=always
RestartSec=3
User=root
LimitNOFILE=1048576
LimitNPROC=65535
TasksMax=infinity
TimeoutStopSec=15
KillMode=control-group

[Install]
WantedBy=multi-user.target
EOF
}

write_client_service() {
  local dir="$1" bin="$2"
  cat > "$CLIENT_UNIT" <<EOF
[Unit]
Description=StormDNS Client
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
WorkingDirectory=${dir}
ExecStart=${dir}/${bin} --config ${dir}/client_config.toml
Restart=always
RestartSec=5
User=root
LimitNOFILE=1048576
LimitNPROC=65535
TasksMax=infinity
TimeoutStopSec=15
KillMode=control-group

[Install]
WantedBy=multi-user.target
EOF
}

# ══════════════════════════════════════════════════════════════════════════════
# ROLE AUTODISCOVERY
# ══════════════════════════════════════════════════════════════════════════════
detect_role() {
  # Priority 1: running systemd service
  systemctl list-unit-files 2>/dev/null | grep -q "^${SERVER_SVC}\.service" \
    && { echo "server"; return; }
  systemctl list-unit-files 2>/dev/null | grep -q "^${CLIENT_SVC}\.service" \
    && { echo "client"; return; }
  # Priority 2: config file in CWD
  [[ -f "server_config.toml" ]] && { echo "server"; return; }
  [[ -f "client_config.toml" ]] && { echo "client"; return; }
  # Priority 3: binary in CWD
  shopt -s nullglob
  local srv=(StormDNS_Server_*) cli=(StormDNS_Client_*)
  shopt -u nullglob
  [[ ${#srv[@]} -gt 0 && ${#cli[@]} -eq 0 ]] && { echo "server"; return; }
  [[ ${#cli[@]} -gt 0 && ${#srv[@]} -eq 0 ]] && { echo "client"; return; }
  # Priority 4: public IP is directly bound to a local interface → server
  [[ -n "${PUBLIC_IP:-}" ]] && ip_on_local_iface "$PUBLIC_IP" \
    && { echo "server"; return; }
  echo "unknown"
}

# ══════════════════════════════════════════════════════════════════════════════
# PROMPT HELPERS
# ══════════════════════════════════════════════════════════════════════════════
ask_required() {
  local _var="$1" _msg="$2" _default="${3:-}" _val=""
  while [[ -z "${_val:-}" ]]; do
    if [[ -n "$_default" ]]; then
      printf "  ${Y}▶${NC} %s ${DM}[%s]${NC}: " "$_msg" "$_default"
    else
      printf "  ${Y}▶${NC} %s: " "$_msg"
    fi
    read -r _val </dev/tty || true
    [[ -z "$_val" && -n "$_default" ]] && _val="$_default"
    [[ -z "$_val" ]] && echo -e "  ${R}This field is required.${NC}"
  done
  printf -v "$_var" '%s' "$_val"
}

ask_optional() {
  local _var="$1" _msg="$2" _default="${3:-}"
  printf "  ${Y}▶${NC} %s ${DM}[%s]${NC}: " "$_msg" "$_default"
  local _val=""; read -r _val </dev/tty || true
  [[ -z "$_val" ]] && _val="$_default"
  printf -v "$_var" '%s' "$_val"
}

ask_yn() {
  local _var="$1" _msg="$2" _default="${3:-n}" _hint="[y/N]"
  [[ "${_default,,}" == "y" ]] && _hint="[Y/n]"
  printf "  ${Y}▶${NC} %s ${DM}%s${NC}: " "$_msg" "$_hint"
  local _ans=""; read -r _ans </dev/tty || true
  [[ -z "$_ans" ]] && _ans="$_default"
  [[ "${_ans,,}" =~ ^y ]] && printf -v "$_var" 'true' || printf -v "$_var" 'false'
}

ask_menu() {
  local _var="$1" _msg="$2" _default="$3"; shift 3; local _opts=("$@")
  echo -e "  ${Y}▶${NC} ${_msg}:"
  local i=1
  for o in "${_opts[@]}"; do
    if [[ $(( i-1 )) -eq ${_default} ]]; then
      echo -e "    ${C}${BO}[${i}]${NC} ${o} ${DM}← default${NC}"
    else
      echo -e "    ${DM}[${i}]${NC} ${o}"
    fi; (( i++ )) || true
  done
  local _choice=""
  while true; do
    printf "  ${Y}▶${NC} Enter number ${DM}[%d]${NC}: " "$(( _default+1 ))"
    read -r _choice </dev/tty || true
    [[ -z "$_choice" ]] && _choice="$(( _default+1 ))"
    if [[ "$_choice" =~ ^[0-9]+$ ]] && (( _choice >= 1 && _choice <= ${#_opts[@]} )); then
      printf -v "$_var" '%d' "$(( _choice-1 ))"; return
    fi
    echo -e "  ${R}Enter a number 1–${#_opts[@]}.${NC}"
  done
}

valid_domain()  { [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?(\.[a-zA-Z]{2,})+$ ]]; }
valid_port()    { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
valid_ipv4()    { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
valid_hexkey()  { [[ "$1" =~ ^[0-9a-fA-F]{32,64}$ ]]; }

# ══════════════════════════════════════════════════════════════════════════════
# BANNER & USAGE
# ══════════════════════════════════════════════════════════════════════════════
print_banner() {
  local role="${1:-}" mode="${2:-install}"
  echo -e "${M}${BO}"
  cat <<'ART'
   _____ _                      _____  _   _  _____
  / ____| |                    |  __ \| \ | |/ ____|
 | (___ | |_ ___  _ __ _ __ ___| |  | |  \| | (___
  \___ \| __/ _ \| '__| '_ ` _ \ |  | | . ` |\___ \
  ____) | || (_) | |  | | | | | | |__| | |\  |____) |
 |_____/ \__\___/|_|  |_| |_| |_|_____/|_| \_|_____/
ART
  echo -e "${NC}"
  local tag
  case "$mode" in
    install)   tag="Unified Smart Installer  v${INSTALLER_VER}" ;;
    uninstall) tag="Uninstaller  v${INSTALLER_VER}" ;;
    update)    tag="Updater  v${INSTALLER_VER}" ;;
    status)    tag="Status  v${INSTALLER_VER}" ;;
  esac
  if [[ -n "$role" ]]; then
    local r_cap; r_cap="$(tr '[:lower:]' '[:upper:]' <<< "${role:0:1}")${role:1}"
    echo -e "  ${C}${BO}● Role: ${W}${BO}${r_cap}${NC}  ${DM}│${NC}  ${C}${BO}${tag}${NC}"
  else
    echo -e "  ${C}${BO}${tag}${NC}"
  fi
  echo -e "  ${DM}$(printf '%.0s─' {1..68})${NC}"; echo
}

print_usage() {
  cat <<USAGE

${BO}StormDNS Unified Installer${NC}

${BO}Usage:${NC}
  sudo bash install.sh [ROLE] [OPTIONS]

${BO}Role (auto-detected if omitted):${NC}
  --server          Install / update the StormDNS server
  --client          Install / update the StormDNS client

${BO}Options:${NC}
  -v, --version TAG Install a specific release tag
  -u, --uninstall   Remove StormDNS (role auto-detected or specified)
      --status      Show current installation status
  -h, --help        Show this help

${BO}Examples:${NC}
  sudo bash install.sh                        # auto-detect role, install/update
  sudo bash install.sh --server               # server install
  sudo bash install.sh --client               # client install
  sudo bash install.sh --server --uninstall   # server uninstall
  sudo bash install.sh --status

USAGE
}

# ══════════════════════════════════════════════════════════════════════════════
# ARGUMENT PARSING
# ══════════════════════════════════════════════════════════════════════════════
ROLE="" ACTION="install" TARGET_VERSION="" INSTALL_DIR=""

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --server)        ROLE="server";     shift ;;
      --client)        ROLE="client";     shift ;;
      -u|--uninstall)  ACTION="uninstall"; shift ;;
      --status)        ACTION="status";   shift ;;
      -v|--version)
        [[ $# -ge 2 ]] || { echo "Error: $1 needs a value" >&2; exit 2; }
        TARGET_VERSION="$2"; shift 2 ;;
      --version=*)     TARGET_VERSION="${1#*=}"; shift ;;
      -h|--help)       print_usage; exit 0 ;;
      --)              shift; break ;;
      *)               echo "Unknown option: $1" >&2; print_usage; exit 2 ;;
    esac
  done
  [[ -n "$TARGET_VERSION" && ! "$TARGET_VERSION" =~ ^[A-Za-z0-9._+-]+$ ]] \
    && { echo "Error: invalid version tag: $TARGET_VERSION" >&2; exit 2; }
  [[ "$ACTION" == "uninstall" && -n "$TARGET_VERSION" ]] \
    && { echo "Error: --version and --uninstall cannot be combined." >&2; exit 2; }
  return 0
}

resolve_install_dir() {
  INSTALL_DIR="$(pwd -P)"
  [[ "$INSTALL_DIR" == /dev/fd/* || "$INSTALL_DIR" == /proc/*/fd/* ]] \
    && INSTALL_DIR="$(cd ~ && pwd -P)"
  cd "$INSTALL_DIR" || err "Cannot access: $INSTALL_DIR"
}

# ══════════════════════════════════════════════════════════════════════════════
# STATUS
# ══════════════════════════════════════════════════════════════════════════════
do_status() {
  print_banner "" status
  local show_role
  for show_role in server client; do
    local svc; [[ "$show_role" == "server" ]] && svc="$SERVER_SVC" || svc="$CLIENT_SVC"
    local cfg_file; [[ "$show_role" == "server" ]] && cfg_file="server_config.toml" || cfg_file="client_config.toml"
    echo -e "  ${C}${BO}$(tr '[:lower:]' '[:upper:]' <<< "${show_role:0:1}")${show_role:1} (${svc})${NC}"
    hr
    if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service"; then
      local state wdir
      state="$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")"
      wdir="$(systemctl show "$svc" --property WorkingDirectory --value 2>/dev/null || true)"
      local sc="$R"; [[ "$state" == "active" ]] && sc="$G"
      kv "Service:" "${sc}${state}${NC}"
      kv "Directory:" "${wdir:-unknown}"
      local cpath="${wdir:-}/${cfg_file}"
      if [[ -f "$cpath" ]]; then
        kv "Config version:"    "$(cfg_ver "$cpath")"
        if [[ "$show_role" == "server" ]]; then
          kv "Domain:"           "$(toml_get DOMAIN "$cpath")"
          kv "Encryption:"       "$(toml_get DATA_ENCRYPTION_METHOD "$cpath")"
          kv "UDP DL port:"      "$(toml_get UDP_DOWNLOAD_PORT "$cpath")"
          [[ -f "${wdir:-}/encrypt_key.txt" ]] && kv "Key file:" "present (${wdir}/encrypt_key.txt)"
        else
          kv "Domains:"          "$(toml_get DOMAINS "$cpath")"
          kv "Encryption:"       "$(toml_get DATA_ENCRYPTION_METHOD "$cpath")"
          kv "Listen port:"      "$(toml_get LISTEN_PORT "$cpath")"
          kv "Startup mode:"     "$(toml_get STARTUP_MODE "$cpath")"
        fi
      fi
    else
      kv "Service:" "${DM}not installed${NC}"
    fi
    echo
  done
}

# ══════════════════════════════════════════════════════════════════════════════
# UNINSTALL
# ══════════════════════════════════════════════════════════════════════════════
do_uninstall() {
  local role="$1"
  print_banner "$role" uninstall
  echo -e "  ${Y}${BO}All StormDNS ${role} files and the systemd service will be removed.${NC}\n"
  local confirm; ask_yn confirm "Continue?" "n"
  [[ "$confirm" == "true" ]] || { info "Aborted."; exit 0; }

  if [[ "$role" == "server" ]]; then
    _TOTAL=4
    step "Stop Server Service"
    if systemctl list-unit-files 2>/dev/null | grep -q "^${SERVER_SVC}\.service"; then
      systemctl stop "$SERVER_SVC" 2>/dev/null || true
      systemctl disable "$SERVER_SVC" 2>/dev/null || true
      systemctl reset-failed "$SERVER_SVC" 2>/dev/null || true
      rm -f "$SERVER_UNIT"; systemctl daemon-reload 2>/dev/null || true
      done_ "Service removed."
    else
      info "No server service found."
    fi

    step "Kill Stray Processes"
    local pid
    while IFS= read -r pid; do
      [[ -z "$pid" ]] && continue
      local cml; cml="$(ps -p "$pid" -o cmd= 2>/dev/null || true)"
      echo "$cml" | grep -qiE 'stormdns' && { kill_graceful "$pid" || true; warn "Killed PID $pid"; } || true
    done < <(pgrep -fi stormdns 2>/dev/null || true)
    done_ "Process cleanup done."

    step "Remove System Tuning"
    if [[ -f "$SYSCTL_CONF" ]]; then
      rm -f "$SYSCTL_CONF"; sysctl --system >/dev/null 2>&1 || true
      done_ "Removed $SYSCTL_CONF"
    fi
    [[ -f "$LIMITS_CONF" ]] && { rm -f "$LIMITS_CONF"; done_ "Removed $LIMITS_CONF"; } || true
    if [[ -f /etc/systemd/resolved.conf.bak && -f /etc/systemd/resolved.conf ]]; then
      mv -f /etc/systemd/resolved.conf.bak /etc/systemd/resolved.conf
      systemctl restart systemd-resolved 2>/dev/null || true
      done_ "Restored /etc/systemd/resolved.conf."
    fi

    step "Remove Files"
    local removed=0; shopt -s nullglob
    for f in StormDNS_Server_Linux* server_config.toml server_config.toml.backup \
              server_config_*.toml encrypt_key.txt init_logs.tmp *.spec; do
      [[ -e "$f" ]] && { rm -f -- "$f"; info "Removed: $f"; removed=1; }
    done; shopt -u nullglob
    [[ $removed -eq 0 ]] && warn "No server files found in $INSTALL_DIR."
    [[ $removed -gt 0 ]] && done_ "Files removed."

  else
    _TOTAL=2
    step "Stop Client Service"
    if systemctl list-unit-files 2>/dev/null | grep -q "^${CLIENT_SVC}\.service"; then
      systemctl stop "$CLIENT_SVC" 2>/dev/null || true
      systemctl disable "$CLIENT_SVC" 2>/dev/null || true
      systemctl reset-failed "$CLIENT_SVC" 2>/dev/null || true
      rm -f "$CLIENT_UNIT"; systemctl daemon-reload 2>/dev/null || true
      done_ "Service removed."
    else
      info "No client service found."
    fi

    step "Remove Files"
    local removed=0; shopt -s nullglob
    for f in StormDNS_Client_Linux* client_config.toml client_config.toml.backup \
              client_config_*.toml client_resolvers.txt *.spec; do
      [[ -e "$f" ]] && { rm -f -- "$f"; info "Removed: $f"; removed=1; }
    done; shopt -u nullglob
    [[ $removed -eq 0 ]] && warn "No client files found in $INSTALL_DIR."
    [[ $removed -gt 0 ]] && done_ "Files removed."
  fi

  echo
  echo -e "${C}  ══════════════════════════════════════════════════════${NC}"
  echo -e "  ${G}${BO}  StormDNS ${role} uninstalled.${NC}"
  echo -e "${C}  ══════════════════════════════════════════════════════${NC}"
  echo -e "  ${Y}Note:${NC} Firewall rules were not modified — remove them manually if needed."
  echo
}

# ══════════════════════════════════════════════════════════════════════════════
# ENCRYPTION METHOD MENU (shared)
# ══════════════════════════════════════════════════════════════════════════════
ENC_NAMES=(
  "0 — None        (no encryption, testing only)"
  "1 — XOR         (fast, minimal overhead)"
  "2 — ChaCha20    (recommended: modern stream cipher)"
  "3 — AES-128-GCM (AEAD, hardware-accelerated)"
  "4 — AES-192-GCM (AEAD, stronger key)"
  "5 — AES-256-GCM (AEAD, maximum security)"
)
ENC_DEFAULT=2

# ══════════════════════════════════════════════════════════════════════════════
# SERVER INSTALLATION
# ══════════════════════════════════════════════════════════════════════════════
do_install_server() {
  _TOTAL=12; print_banner "server" install

  # ── 1. System preparation ─────────────────────────────────────────────────
  step "System Preparation"
  detect_system
  kv "OS:"           "${OS_ID} ${OS_VER}$([[ $IS_LEGACY -eq 1 ]] && echo ' (legacy)' || true)"
  kv "Architecture:" "$ARCH"
  install_deps; enable_irqbalance
  done_ "System tools ready."

  # ── 2. Public IP ──────────────────────────────────────────────────────────
  step "Network Discovery"
  spin_start "Detecting public IP address…"
  if get_public_ip; then
    spin_stop; kv "Public IP:" "$PUBLIC_IP"
  else
    spin_stop; warn "Could not determine public IP automatically."
  fi

  # ── 3. Stop existing service ──────────────────────────────────────────────
  step "Stopping Existing Service"
  stop_existing_server; done_ "Ready to proceed."

  # ── 4. Free port 53 ───────────────────────────────────────────────────────
  step "Freeing Port 53"
  if port53_busy; then
    warn "Port 53 is occupied — running auto-cleanup…"
    free_port53; sleep 1
    if port53_busy; then
      warn "Second pass — forcing remaining processes off port 53…"
      while IFS= read -r p53; do [[ -n "$p53" ]] && kill_graceful "$p53" || true; done \
        < <(port53_pids); sleep 1
    fi
    port53_busy && err "Port 53 is still occupied. Stop the blocking process manually and retry."
  fi
  done_ "Port 53 is free."

  # ── 5. Configuration wizard ───────────────────────────────────────────────
  step "Configuration Wizard"
  echo

  # Domain
  local domain=""
  while true; do
    ask_required domain "Tunnel domain — NS-delegated subdomain (e.g. vpn.example.com)"
    valid_domain "$domain" && break
    echo -e "  ${R}Invalid domain. Example: vpn.example.com${NC}"
  done

  # Verify NS delegation
  if [[ -n "${PUBLIC_IP:-}" ]]; then
    echo
    spin_start "Checking NS delegation for ${domain}…"
    if check_ns_delegation "$domain" "$PUBLIC_IP"; then
      spin_stop; done_ "NS record verified: ${domain} → ${PUBLIC_IP}"
    else
      spin_stop
      warn "NS delegation not yet confirmed (DNS may not have propagated)."
      warn "StormDNS will start — verify NS records before connecting clients."
      warn "Expected: ${domain} NS → A record of this server (${PUBLIC_IP:-?})"
    fi
  fi

  # Encryption method
  echo
  local enc_idx="$ENC_DEFAULT"
  ask_menu enc_idx "Encryption method" "$ENC_DEFAULT" "${ENC_NAMES[@]}"

  # Protocol type
  echo
  local proto_idx=0
  ask_menu proto_idx "Protocol mode" 0 \
    "SOCKS5  — clients choose destination (standard proxy)" \
    "TCP     — all connections forward to one fixed destination"
  local proto="SOCKS5"; [[ $proto_idx -eq 1 ]] && proto="TCP"

  # Fixed forward target (TCP mode only)
  local fwd_ip="" fwd_port=0
  if [[ "$proto" == "TCP" ]]; then
    echo
    while true; do
      ask_required fwd_ip "Forward destination IP"
      valid_ipv4 "$fwd_ip" && break
      echo -e "  ${R}Enter a valid IPv4 address.${NC}"
    done
    local fwd_port_str=""
    while true; do
      ask_required fwd_port_str "Forward destination port"
      valid_port "$fwd_port_str" && break
      echo -e "  ${R}Enter a valid port (1–65535).${NC}"
    done
    fwd_port="$fwd_port_str"
  fi

  # UDP download channel
  echo
  local udp_dl_yn; ask_yn udp_dl_yn \
    "Enable parallel UDP download channel? (faster downloads, requires open port)" "n"
  local udp_dl_port=0
  if [[ "$udp_dl_yn" == "true" ]]; then
    local udp_str=""
    while true; do
      ask_required udp_str "UDP download port (e.g. 5555 — must not be 53)" "5555"
      valid_port "$udp_str" && [[ "$udp_str" != "53" ]] && break
      echo -e "  ${R}Enter a valid port between 1–65535, not 53.${NC}"
    done
    udp_dl_port="$udp_str"
  fi

  # Log level
  echo
  local log_idx=1
  ask_menu log_idx "Log level" 1 "DEBUG" "INFO" "WARN" "ERROR"
  local log_levels=("DEBUG" "INFO" "WARN" "ERROR")
  local log_level="${log_levels[$log_idx]}"

  # ── 6. Binary acquisition ─────────────────────────────────────────────────
  step "Binary Acquisition"
  [[ -f "server_config.toml" ]] && {
    cp -a "server_config.toml" "server_config.toml.backup"
    info "Existing config backed up → server_config.toml.backup"
  }
  acquire_binary "Server" "$TARGET_VERSION"

  # ── 7. Config preparation ─────────────────────────────────────────────────
  step "Config Preparation"
  [[ -f "server_config.toml" ]] || err "server_config.toml not found after extraction."
  handle_upgrade "server_config.toml"
  kv "Config version:" "$(cfg_ver server_config.toml)"

  toml_arr_str "DOMAIN"                 "$domain"       server_config.toml
  toml_int     "DATA_ENCRYPTION_METHOD" "$enc_idx"      server_config.toml
  toml_str     "PROTOCOL_TYPE"          "$proto"        server_config.toml
  toml_int     "UDP_DOWNLOAD_PORT"      "$udp_dl_port"  server_config.toml
  toml_str     "LOG_LEVEL"              "$log_level"    server_config.toml
  if [[ "$proto" == "TCP" && -n "$fwd_ip" ]]; then
    toml_str "FORWARD_IP"   "$fwd_ip"   server_config.toml
    toml_int "FORWARD_PORT" "$fwd_port" server_config.toml
  fi
  done_ "Config written."

  # ── 8. Kernel & system tuning ─────────────────────────────────────────────
  step "Kernel & System Tuning"
  apply_tuning; done_ "sysctl and ulimit configured."

  # ── 9. Firewall ───────────────────────────────────────────────────────────
  step "Firewall Configuration"
  open_port 53 udp; open_port 53 tcp
  [[ $udp_dl_port -gt 0 ]] && open_port "$udp_dl_port" udp

  # ── 10. Key generation ────────────────────────────────────────────────────
  step "Security Initialization"
  info "Starting server briefly to generate encryption key…"
  _TMP_LOG="$(mktemp /tmp/stormdns_init.XXXXXX)"
  ./"$BINARY" > "$_TMP_LOG" 2>&1 &
  local app_pid=$!
  local ready=false
  for _ in {1..12}; do
    grep -q "Active Encryption Key" "$_TMP_LOG" 2>/dev/null && { ready=true; break; }
    sleep 1
  done
  kill "$app_pid" 2>/dev/null || true; wait "$app_pid" 2>/dev/null || true

  if [[ "$ready" != "true" ]]; then
    warn "Key-gen log tail:"; tail -n 15 "$_TMP_LOG" || true
    err "Server did not produce an encryption key — is port 53 really free?"
  fi
  local enc_key=""
  [[ -f "encrypt_key.txt" ]] && enc_key="$(cat encrypt_key.txt)"
  [[ -n "$enc_key" ]] || err "encrypt_key.txt not found or empty."
  done_ "Encryption key generated."

  # ── 11. Service installation ─────────────────────────────────────────────
  step "Service Installation"
  write_server_service "$INSTALL_DIR" "$BINARY"
  systemctl daemon-reload
  systemctl enable "$SERVER_SVC" >/dev/null 2>&1
  systemctl restart "$SERVER_SVC"
  done_ "systemd service installed and started."

  # ── 12. Verification ──────────────────────────────────────────────────────
  step "Verification"
  local ok=false
  for _ in {1..6}; do
    systemctl is-active --quiet "$SERVER_SVC" 2>/dev/null && { ok=true; break; }
    sleep 1
  done
  if [[ "$ok" != "true" ]]; then
    journalctl -u "$SERVER_SVC" -n 30 --no-pager || true
    err "Service failed to start. See logs above."
  fi
  done_ "Service is active."

  # ── Summary ───────────────────────────────────────────────────────────────
  echo
  echo -e "${C}  ════════════════════════════════════════════════════════════${NC}"
  echo -e "  ${G}${BO}  SERVER INSTALLATION COMPLETE${NC}"
  echo -e "${C}  ════════════════════════════════════════════════════════════${NC}"
  hr; echo
  kv "Domain:"             "$domain"
  kv "Encryption:"         "${ENC_NAMES[$enc_idx]}"
  kv "Protocol:"           "$proto"
  [[ "$proto" == "TCP" ]] && kv "Forward target:" "${fwd_ip}:${fwd_port}"
  kv "UDP download port:"  "$([[ $udp_dl_port -gt 0 ]] && echo "${udp_dl_port}/udp" || echo "disabled")"
  kv "Log level:"          "$log_level"
  kv "Install directory:"  "$INSTALL_DIR"
  echo
  echo -e "  ${Y}${BO}  ┌─ ENCRYPTION KEY (copy this for your clients) ─────────────┐${NC}"
  echo -e "  ${G}${BO}  │  ${enc_key}  │${NC}"
  echo -e "  ${Y}${BO}  └──────────────────────────────────────────────────────────┘${NC}"
  echo
  hr; echo
  echo -e "  ${BO}Service commands:${NC}"
  echo -e "    ${DM}Start  │${NC} systemctl start   ${SERVER_SVC}"
  echo -e "    ${DM}Stop   │${NC} systemctl stop    ${SERVER_SVC}"
  echo -e "    ${DM}Restart│${NC} systemctl restart ${SERVER_SVC}"
  echo -e "    ${DM}Logs   │${NC} journalctl -u ${SERVER_SVC} -f"
  echo
  echo -e "  ${BO}Files:${NC}"
  echo -e "    ${DM}Config │${NC} ${INSTALL_DIR}/server_config.toml"
  echo -e "    ${DM}Key    │${NC} ${INSTALL_DIR}/encrypt_key.txt"
  [[ $udp_dl_port -gt 0 ]] && \
    echo -e "\n  ${Y}Note:${NC} Clients using the UDP download channel must also open port ${udp_dl_port}/udp."
  echo
}

# ══════════════════════════════════════════════════════════════════════════════
# CLIENT INSTALLATION
# ══════════════════════════════════════════════════════════════════════════════
do_install_client() {
  _TOTAL=10; print_banner "client" install

  # ── 1. System preparation ─────────────────────────────────────────────────
  step "System Preparation"
  detect_system
  kv "OS:"           "${OS_ID} ${OS_VER}$([[ $IS_LEGACY -eq 1 ]] && echo ' (legacy)' || true)"
  kv "Architecture:" "$ARCH"
  install_deps
  done_ "System tools ready."

  # ── 2. Stop existing client ───────────────────────────────────────────────
  step "Stopping Existing Client"
  stop_existing_client; done_ "Ready to proceed."

  # ── 3. Network discovery ──────────────────────────────────────────────────
  step "Network Discovery"
  spin_start "Detecting public IP address…"
  if get_public_ip; then
    spin_stop; kv "Public IP:" "$PUBLIC_IP"
  else
    spin_stop; warn "Could not determine public IP automatically."
  fi

  # ── 4. Configuration wizard ───────────────────────────────────────────────
  step "Configuration Wizard"
  echo

  # Server domain
  local domain=""
  while true; do
    ask_required domain "Server tunnel domain (must match server DOMAIN, e.g. vpn.example.com)"
    valid_domain "$domain" && break
    echo -e "  ${R}Invalid domain format.${NC}"
  done

  # Encryption method — must match server
  echo
  local enc_idx="$ENC_DEFAULT"
  ask_menu enc_idx "Encryption method (must match server setting)" "$ENC_DEFAULT" "${ENC_NAMES[@]}"

  # Encryption key
  echo
  local enc_key=""
  while true; do
    ask_required enc_key "Encryption key (paste the key shown at end of server install)"
    valid_hexkey "$enc_key" && break
    echo -e "  ${R}Key must be 32–64 hex characters (shown at server install summary).${NC}"
  done

  # Local proxy port
  echo
  local listen_port=""
  while true; do
    ask_required listen_port "Local proxy listen port" "18000"
    valid_port "$listen_port" && break
    echo -e "  ${R}Invalid port (1–65535).${NC}"
  done

  # Protocol type
  echo
  local proto_idx=0
  ask_menu proto_idx "Local proxy mode" 0 \
    "SOCKS5  — browser/app proxy (most common)" \
    "TCP     — raw TCP forward mode"
  local proto="SOCKS5"; [[ $proto_idx -eq 1 ]] && proto="TCP"

  # UDP download channel
  echo
  local udp_dl_yn; ask_yn udp_dl_yn \
    "Enable parallel UDP download channel? (server must have it enabled too)" "n"
  local udp_dl_port=0 udp_dl_ip=""
  if [[ "$udp_dl_yn" == "true" ]]; then
    local udp_str=""
    while true; do
      ask_required udp_str "UDP download port (must match server UDP_DOWNLOAD_PORT)" "5555"
      valid_port "$udp_str" && break
      echo -e "  ${R}Invalid port.${NC}"
    done
    udp_dl_port="$udp_str"

    if [[ -n "${PUBLIC_IP:-}" ]]; then
      echo
      info "Public IP auto-detected: ${PUBLIC_IP}"
      local use_ip; ask_yn use_ip "Use ${PUBLIC_IP} as the UDP download IP?" "y"
      [[ "$use_ip" == "true" ]] && udp_dl_ip="$PUBLIC_IP"
    fi
    if [[ -z "$udp_dl_ip" ]]; then
      echo
      while true; do
        ask_required udp_dl_ip "This machine's public IPv4 (server sends download packets here)"
        valid_ipv4 "$udp_dl_ip" && break
        echo -e "  ${R}Invalid IPv4 address.${NC}"
      done
    fi
  fi

  # Startup mode
  echo
  local startup_idx=0
  ask_menu startup_idx "Startup mode" 0 \
    "resolvers — full scan on each start (slow, most reliable)" \
    "logs      — reuse last-known resolvers (fast, recommended for systemd)" \
    "ask       — prompt on startup (interactive terminals only)"
  local startup_modes=("resolvers" "logs" "ask")
  local startup_mode="${startup_modes[$startup_idx]}"

  # ── 5. Binary acquisition ─────────────────────────────────────────────────
  step "Binary Acquisition"
  [[ -f "client_config.toml" ]] && {
    cp -a "client_config.toml" "client_config.toml.backup"
    info "Existing config backed up → client_config.toml.backup"
  }
  acquire_binary "Client" "$TARGET_VERSION"

  # ── 6. Config preparation ─────────────────────────────────────────────────
  step "Config Preparation"
  [[ -f "client_config.toml" ]] || err "client_config.toml not found after extraction."
  handle_upgrade "client_config.toml"
  kv "Config version:" "$(cfg_ver client_config.toml)"

  toml_arr_str "DOMAINS"                "$domain"        client_config.toml
  toml_int     "DATA_ENCRYPTION_METHOD" "$enc_idx"       client_config.toml
  toml_str     "ENCRYPTION_KEY"         "$enc_key"       client_config.toml
  toml_int     "LISTEN_PORT"            "$listen_port"   client_config.toml
  toml_str     "PROTOCOL_TYPE"          "$proto"         client_config.toml
  toml_str     "STARTUP_MODE"           "$startup_mode"  client_config.toml
  toml_int     "UDP_DOWNLOAD_PORT"      "$udp_dl_port"   client_config.toml
  [[ -n "$udp_dl_ip" ]] && toml_str "UDP_DOWNLOAD_IP" "$udp_dl_ip" client_config.toml
  done_ "Config written."

  # ── 7. Resolver discovery ─────────────────────────────────────────────────
  step "Resolver Discovery"
  info "Probing resolvers for reachability to ${domain}…"
  local good_resolvers=()
  while IFS= read -r r; do [[ -n "$r" ]] && good_resolvers+=("$r"); done \
    < <(discover_resolvers "$domain")

  if [[ ${#good_resolvers[@]} -gt 0 ]]; then
    done_ "Found ${#good_resolvers[@]} working resolver(s)."
    for r in "${good_resolvers[@]}"; do kv "  ✓" "$r"; done
  else
    warn "No resolvers confirmed reachability to the tunnel domain."
    warn "DNS may not be propagated yet. Falling back to common public resolvers."
    good_resolvers=("8.8.8.8" "8.8.4.4" "1.1.1.1" "1.0.0.1" "9.9.9.9" "149.112.112.112")
  fi

  echo "# StormDNS client resolvers — auto-generated by installer" > client_resolvers.txt
  echo "# Edit as needed. One entry per line: IP, IP:PORT, CIDR, or CIDR:PORT" >> client_resolvers.txt
  echo >> client_resolvers.txt
  for r in "${good_resolvers[@]}"; do echo "$r"; done >> client_resolvers.txt
  done_ "client_resolvers.txt written (${#good_resolvers[@]} entries)."

  # Allow user to add extra resolvers
  echo
  local extra_yn; ask_yn extra_yn "Add extra custom resolvers now?" "n"
  if [[ "$extra_yn" == "true" ]]; then
    echo -e "  ${DM}Enter one resolver per line. Empty line to finish.${NC}"
    while true; do
      local extra=""
      printf "  ${Y}▶${NC} Resolver (empty to stop): "
      read -r extra </dev/tty || true
      [[ -z "$extra" ]] && break
      echo "$extra" >> client_resolvers.txt
      done_ "Added: $extra"
    done
  fi

  # ── 8. Firewall (UDP download channel) ────────────────────────────────────
  step "Firewall Configuration"
  if [[ $udp_dl_port -gt 0 ]]; then
    open_port "$udp_dl_port" udp
  else
    info "No firewall changes needed (UDP download channel disabled)."
  fi

  # ── 9. Service installation ───────────────────────────────────────────────
  step "Service Installation"
  write_client_service "$INSTALL_DIR" "$BINARY"
  systemctl daemon-reload
  systemctl enable "$CLIENT_SVC" >/dev/null 2>&1 || warn "Could not enable $CLIENT_SVC at boot."
  systemctl restart "$CLIENT_SVC"
  done_ "systemd service installed and started."

  # ── 10. Verification ──────────────────────────────────────────────────────
  step "Verification"
  sleep 2
  local ok=false
  for _ in {1..5}; do
    systemctl is-active --quiet "$CLIENT_SVC" 2>/dev/null && { ok=true; break; }
    sleep 1
  done
  if [[ "$ok" != "true" ]]; then
    journalctl -u "$CLIENT_SVC" -n 30 --no-pager || true
    err "Service failed to start. See logs above."
  fi
  done_ "Service is active."

  # ── Summary ───────────────────────────────────────────────────────────────
  echo
  echo -e "${C}  ════════════════════════════════════════════════════════════${NC}"
  echo -e "  ${G}${BO}  CLIENT INSTALLATION COMPLETE${NC}"
  echo -e "${C}  ════════════════════════════════════════════════════════════${NC}"
  hr; echo
  kv "Server domain:"      "$domain"
  kv "Encryption:"         "${ENC_NAMES[$enc_idx]}"
  kv "Local proxy:"        "${proto} on 127.0.0.1:${listen_port}"
  kv "Startup mode:"       "$startup_mode"
  kv "Resolvers:"          "${#good_resolvers[@]} configured"
  kv "UDP download:"       "$([[ $udp_dl_port -gt 0 ]] && echo "port ${udp_dl_port} (IP: ${udp_dl_ip})" || echo "disabled")"
  kv "Install directory:"  "$INSTALL_DIR"
  echo
  hr; echo
  echo -e "  ${BO}Proxy:${NC}  Point your browser / apps to SOCKS5 → 127.0.0.1:${listen_port}"
  echo
  echo -e "  ${BO}Service commands:${NC}"
  echo -e "    ${DM}Start  │${NC} systemctl start   ${CLIENT_SVC}"
  echo -e "    ${DM}Stop   │${NC} systemctl stop    ${CLIENT_SVC}"
  echo -e "    ${DM}Restart│${NC} systemctl restart ${CLIENT_SVC}"
  echo -e "    ${DM}Logs   │${NC} journalctl -u ${CLIENT_SVC} -f"
  echo
  echo -e "  ${BO}Files:${NC}"
  echo -e "    ${DM}Config    │${NC} ${INSTALL_DIR}/client_config.toml"
  echo -e "    ${DM}Resolvers │${NC} ${INSTALL_DIR}/client_resolvers.txt"
  echo
}

# ══════════════════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════════════════
main() {
  parse_args "$@"

  [[ "${EUID:-$(id -u)}" -ne 0 ]] && err "Run as root:  sudo bash $0 $*"

  resolve_install_dir
  info "Working directory: $INSTALL_DIR"

  # Discover public IP early — used by role detection and NS verification
  get_public_ip 2>/dev/null || true

  # Auto-detect role if not specified by the user
  if [[ -z "$ROLE" ]]; then
    detect_system 2>/dev/null || true
    ROLE="$(detect_role)"

    if [[ "$ROLE" == "unknown" ]]; then
      print_banner "" install
      echo -e "  ${Y}${BO}Could not auto-detect the role. Please choose:${NC}\n"
      echo -e "    ${DM}[1]${NC} Server  — VPS or cloud machine with an NS-delegated domain"
      echo -e "    ${DM}[2]${NC} Client  — your device (behind NAT), wants internet access via the tunnel"
      echo
      local choice=""
      while true; do
        printf "  ${Y}▶${NC} Enter 1 or 2: "
        read -r choice </dev/tty || true
        case "$choice" in
          1) ROLE="server"; break ;;
          2) ROLE="client"; break ;;
          *) echo -e "  ${R}Enter 1 or 2.${NC}" ;;
        esac
      done
    else
      info "Auto-detected role: ${BO}${ROLE}${NC}"
    fi
  fi

  case "$ACTION" in
    install|update)
      if [[ "$ROLE" == "server" ]]; then
        do_install_server
      else
        do_install_client
      fi ;;
    uninstall)
      detect_system 2>/dev/null || true
      do_uninstall "$ROLE" ;;
    status)
      do_status ;;
  esac
}

main "$@"
