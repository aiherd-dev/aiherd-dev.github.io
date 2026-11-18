#!/usr/bin/env bash
# Install the private AIHerd relay under the current Linux user.
set -euo pipefail
umask 077
tag=private-linux-v1
https_port= listen_port= ts_socket=
fail() { printf 'aih-relay: %s\n' "$*" >&2; exit 1; }
usage() {
  echo 'Usage: bash install-linux.sh [--https-port PORT] [--listen-port PORT] [--tailscale-socket PATH]'
  echo 'Defaults to HTTPS 443 and loopback 18787. A repeat install reuses the existing ports and identity.'
}
while (($#)); do
  case $1 in
    --help|-h) usage; exit 0 ;;
    --https-port|--listen-port|--tailscale-socket)
      [[ $# -ge 2 && -n $2 ]] || fail "missing value for $1"
      case $1 in
        --https-port) https_port=$2 ;;
        --listen-port) listen_port=$2 ;;
        --tailscale-socket) ts_socket=$2 ;;
      esac
      shift 2 ;;
    *) usage >&2; fail "unknown option: $1" ;;
  esac
done
[[ $(uname -s) == Linux && $EUID != 0 ]] || fail 'run as the Linux user who will own the relay'
for tool in curl python3 tailscale systemctl sha256sum flock tar timeout; do
  command -v "$tool" >/dev/null || fail "missing command: $tool"
done
case $(uname -m) in
  x86_64|amd64) arch=x86_64; checksum=b066b8fdeebc8ec85f25782bba3596ba28e64f444b433aecbf536e8be42c8b87 ;;
  aarch64|arm64) arch=aarch64; checksum=76245766e174a06aca2ab9028f9ad54332fc8489fbdb31d888f89096585cf143 ;;
  *) fail 'supported architectures are x86-64 and ARM64' ;;
esac
systemctl --user show-environment >/dev/null || fail 'a running systemd user manager is required'
root="$HOME/.local/share/aih-relay"
bin="$HOME/.local/bin/aih-relay"
unitdir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
unit="$unitdir/aih-relay.service"
identity="$root/identity"
install -d -m 700 "$root"
exec 9>"$root/install.lock"
flock -n 9 || fail 'another installation is in progress'
work=$(mktemp -d "$root/.install.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
if [[ -f $root/ports ]]; then
  read -r old_https old_listen < "$root/ports"
  https_port=${https_port:-$old_https}
  listen_port=${listen_port:-$old_listen}
  [[ $https_port == "$old_https" && $listen_port == "$old_listen" ]] || fail 'existing installation uses different ports'
fi
https_port=${https_port:-443}
listen_port=${listen_port:-18787}
for port in "$https_port" "$listen_port"; do
  [[ $port =~ ^[1-9][0-9]{0,4}$ ]] && ((port <= 65535)) || fail "invalid port: $port"
done
((listen_port >= 1024)) || fail 'use an unprivileged loopback port (1024 or higher)'
if [[ -z $ts_socket && -f $root/tailscale-socket ]]; then
  IFS= read -r ts_socket < "$root/tailscale-socket"
fi
ts=(tailscale)
[[ -z $ts_socket ]] || ts+=("--socket=$ts_socket")
"${ts[@]}" status --json > "$work/status"
python3 - "$work/status" > "$work/network" <<'PY'
import json, re, sys
s = json.load(open(sys.argv[1]))
if s.get("BackendState") != "Running":
    sys.exit("Connect this Linux host to the intended Tailscale network first.")
host = (s["Self"].get("DNSName") or "").rstrip(".").lower()
suffix = (s["CurrentTailnet"].get("MagicDNSSuffix") or "").rstrip(".").lower()
dns = r"(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9-]+"
if not all(re.fullmatch(dns, x) for x in (host, suffix)) or not host.endswith("." + suffix) or not suffix.endswith(".ts.net"):
    sys.exit("Expected a Tailscale MagicDNS hostname on the current tailnet.")
print(host, suffix)
PY
read -r host suffix < "$work/network"
origin="https://$host"
[[ $https_port == 443 ]] || origin+=":$https_port"
backend="http://127.0.0.1:$listen_port"

# Other services can share this node. Inspect the requested port, including
# foreground listeners and Funnel grants, before changing Serve configuration.
serve_state() {
  "${ts[@]}" serve status --json > "$work/serve"
  python3 - "$work/serve" "$host:$https_port" "$backend" <<'PY'
import json, sys
config = json.load(open(sys.argv[1])) or {}
authority, backend = sys.argv[2:]
port = authority.rsplit(":", 1)[1]
def at_port(table):
    return {k: v for k, v in (table or {}).items() if k.rsplit(":", 1)[-1] == port}
def inspect(cfg, foreground=False):
    if any(at_port(cfg.get("AllowFunnel")).values()):
        sys.exit("This port is enabled for public Funnel. Choose another HTTPS port.")
    tcp = (cfg.get("TCP") or {}).get(port)
    web = at_port(cfg.get("Web"))
    if tcp is None and not web:
        return "free"
    ours = {"Handlers": {"/": {"Proxy": backend}}}
    if foreground or tcp != {"HTTPS": True} or web != {authority: ours}:
        sys.exit("This port already has a different Tailscale listener. Choose another --https-port.")
    return "configured"
for cfg in (config.get("Foreground") or {}).values():
    inspect(cfg, True)
print(inspect(config))
PY
}
route=$(serve_state)
marker='# Managed by the AIHerd private relay installer'
fragment=$(systemctl --user show aih-relay.service -p FragmentPath --value)
if [[ -n $fragment && $fragment != "$unit" ]]; then fail "another aih-relay unit exists at $fragment"; fi
if [[ -e $unit || -L $unit ]]; then
  [[ -f $unit && ! -L $unit ]] && grep -Fxq "$marker" "$unit" || fail "existing unit is not installer-managed: $unit"
fi
if [[ -e $bin || -L $bin ]]; then
  [[ -L $bin && $(readlink "$bin") == "$root/current/aih-relay" ]] || fail "existing command is not installer-managed: $bin"
fi
if [[ $route == configured && ! -f $unit ]]; then fail 'the selected Tailscale route is already allocated'; fi
if ! systemctl --user is-active --quiet aih-relay.service; then
  python3 - "$listen_port" <<'PY'
import socket, sys
with socket.socket() as sock:
    try:
        sock.bind(("127.0.0.1", int(sys.argv[1])))
    except OSError as e:
        sys.exit(f"Loopback port is unavailable: {e}. Select another --listen-port.")
PY
fi

asset="aih-relay-linux-$arch.tar.gz"
curl --proto '=https' --proto-redir '=https' --fail --silent --show-error --location --retry 3 \
  "https://github.com/aiherd-dev/aih-relay/releases/download/$tag/$asset" -o "$work/package"
printf '%s  %s\n' "$checksum" "$work/package" | sha256sum --check --status || fail 'downloaded package failed SHA-256 verification'
mkdir "$work/release"
tar -xzf "$work/package" -C "$work/release" aih-relay aih-swarm-admin
admin="$work/release/aih-swarm-admin"
if [[ ! -e $identity ]]; then
  mkdir "$work/identity"
  "$admin" keygen "$work/identity/relay.key" >/dev/null
  "$admin" pinned-genesis "$work/identity/genesis.json" private-relay "$suffix" "$origin" "$work/identity/relay.key" >/dev/null
  mv -T "$work/identity" "$identity"
fi
[[ -f $identity/relay.key && -f $identity/genesis.json ]] || fail "incomplete identity in $identity; restore it from backup"
"$admin" validate-profile "$identity/genesis.json" >/dev/null
python3 - "$identity/genesis.json" "$suffix" <<'PY'
import json, sys
profile = json.load(open(sys.argv[1]))
if profile.get("network", {}).get("tailscale") != sys.argv[2] or profile.get("auth") != "tailnet":
    sys.exit("The saved relay identity belongs to a different tailnet.")
PY
mkdir -p "$root/releases" "$root/state" "$(dirname "$bin")" "$unitdir"
release="$root/releases/$tag-$arch"
if [[ -d $release ]]; then
  for name in aih-relay aih-swarm-admin; do
    cmp -s "$work/release/$name" "$release/$name" || fail "installed release differs from the verified archive: $release"
  done
else
  mv -T "$work/release" "$release"
fi
old_release=$(readlink "$root/current" || true)
ln -s "$release" "$work/current"
mv -Tf "$work/current" "$root/current"
[[ -L $bin ]] || ln -s "$root/current/aih-relay" "$bin"
cat > "$work/unit" <<UNIT
$marker
[Unit]
Description=AIHerd private tailnet relay

[Service]
ExecStart="%h/.local/share/aih-relay/current/aih-relay" --listen 127.0.0.1:$listen_port --advertise $origin --swarm "%h/.local/share/aih-relay/identity/genesis.json" --node-key "%h/.local/share/aih-relay/identity/relay.key" --allow-anonymous-loopback --disable-quic-tunnel --stats-file "%h/.local/share/aih-relay/state/stats.json"
WorkingDirectory=%h/.local/share/aih-relay/state
Restart=on-failure
RestartSec=3
UMask=0077
NoNewPrivileges=yes

[Install]
WantedBy=default.target
UNIT
hash=$(sha256sum "$identity/genesis.json" | cut -d' ' -f1)
# Install the unit via a sibling tempfile so even a cross-filesystem XDG
# config directory never exposes a partially written unit to systemd.
changed=true
if [[ $old_release == "$release" ]] && cmp -s "$work/unit" "$unit"; then changed=false; fi
unit_tmp=$(mktemp "$unitdir/.aih-relay.XXXXXXXX")
install -m 644 "$work/unit" "$unit_tmp"
mv -Tf "$unit_tmp" "$unit"
printf '%s %s\n' "$https_port" "$listen_port" > "$work/ports"
mv -Tf "$work/ports" "$root/ports"
if [[ -n $ts_socket ]]; then
  printf '%s\n' "$ts_socket" > "$work/tailscale-socket"
  mv -Tf "$work/tailscale-socket" "$root/tailscale-socket"
fi
systemctl --user daemon-reload
systemctl --user enable aih-relay.service
if [[ $changed == true ]]; then
  systemctl --user restart aih-relay.service
else
  systemctl --user start aih-relay.service
fi
for _ in {1..40}; do
  if curl --noproxy '*' -fs --max-time 2 "$backend/v1/swarm/$hash" -o "$work/served" && cmp -s "$identity/genesis.json" "$work/served"; then break; fi
  sleep .25
done
systemctl --user is-active --quiet aih-relay.service && cmp -s "$identity/genesis.json" "$work/served" || fail 'relay startup failed; see journalctl --user -u aih-relay.service'
route=$(serve_state)
if [[ $route == free ]]; then
  serve_cmd=("${ts[@]}" serve --bg --yes "--https=$https_port" "$backend")
  if ! timeout 45 "${serve_cmd[@]}"; then
    printf 'Enable Tailscale Serve or run this command with operator privileges, then rerun the installer:\n  sudo' >&2
    printf ' %q' "${serve_cmd[@]}" >&2; printf '\n' >&2; exit 1
  fi
fi
[[ $(serve_state) == configured ]] || fail 'Tailscale Serve did not register the expected private route'
printf '\nRelay: %s\nPublic profile: %s\nGenesis SHA-256: %s\nService: systemctl --user status aih-relay.service\n' "$origin" "$identity/genesis.json" "$hash"
