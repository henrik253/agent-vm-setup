#!/usr/bin/env bash
# setup-agent-vm.sh — provision an Ubuntu 26.04 VM as an AI-agent workstation.
#
# Re-runnable: every step checks before acting, so running it again only fills gaps
# and refreshes packages.
#
# Usage (as your normal user, NOT root; it calls sudo itself):
#   ./setup-agent-vm.sh                 full setup, then the check
#   ./setup-agent-vm.sh --check         only print versions / service status
#   ./setup-agent-vm.sh --reset-identity NEW_HOSTNAME
#                                       run once on a CLONED VM: new hostname,
#                                       machine-id, SSH host keys, xrdp keys
#   ./setup-agent-vm.sh --yes           skip the snapshot confirmation prompt
#
# Tunables (environment variables):
#   SWAP_GB=6                 swap file size if the VM has < 4 GB swap (4–8 recommended)
#   RDP_ALLOW_FROM="192.168.178.0/24 100.64.0.0/10"
#                             CIDRs allowed to reach RDP (3389). Default: the VM's own
#                             subnet, plus the Tailscale range if INSTALL_TAILSCALE=1.
#   INSTALL_TAILSCALE=0|1     install tailscale (you still run `sudo tailscale up` yourself)
#   NEW_HOSTNAME=agent-vm1    optionally set the hostname during setup
#   NVM_VERSION=v0.40.3       nvm release to install
#   CDP_PORT=9222             Chrome remote-debugging port for Hermes (localhost only)

set -euo pipefail

SWAP_GB="${SWAP_GB:-6}"
INSTALL_TAILSCALE="${INSTALL_TAILSCALE:-0}"
NVM_VERSION="${NVM_VERSION:-v0.40.3}"
CDP_PORT="${CDP_PORT:-9222}"
FALLBACK_CODENAME="noble"
CHROME_PROFILE="$HOME/.hermes-chrome"
LOG="$HOME/setup-agent-vm.log"

FALLBACKS=()   # third-party repos that had to use the noble suite
WARNINGS=()

c_bold=$'\e[1m'; c_green=$'\e[32m'; c_yellow=$'\e[33m'; c_red=$'\e[31m'; c_off=$'\e[0m'
step() { printf '\n%s==> %s%s\n' "$c_bold" "$*" "$c_off"; }
warn() { printf '%sWARN: %s%s\n' "$c_yellow" "$*" "$c_off"; WARNINGS+=("$*"); }
die()  { printf '%sERROR: %s%s\n' "$c_red" "$*" "$c_off" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
APT=(sudo -E apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

# --------------------------------------------------------------------------- helpers

load_user_path() {
  export PATH="$HOME/.local/bin:$PATH"
  export NVM_DIR="$HOME/.nvm"
  if [[ -s "$NVM_DIR/nvm.sh" ]]; then
    set +u; . "$NVM_DIR/nvm.sh"; set -u
  fi
}

# Download a signing key into /etc/apt/keyrings, de-armoring it if needed.
fetch_key() {
  local url=$1 dest=$2 tmp
  tmp=$(mktemp)
  curl -fsSL "$url" -o "$tmp"
  if grep -q 'BEGIN PGP' "$tmp"; then
    gpg --dearmor <"$tmp" | sudo tee "$dest" >/dev/null
  else
    sudo install -m 0644 "$tmp" "$dest"
  fi
  sudo chmod 0644 "$dest"
  rm -f "$tmp"
}

# Sets SUITE to this release's codename if the repo publishes it, else to noble.
pick_suite() {
  local name=$1 base=$2
  if curl -fsIL "$base/dists/$CODENAME/InRelease" >/dev/null 2>&1 \
     || curl -fsIL "$base/dists/$CODENAME/Release" >/dev/null 2>&1; then
    SUITE=$CODENAME
  else
    SUITE=$FALLBACK_CODENAME
    FALLBACKS+=("$name ($base): no '$CODENAME' suite, using '$FALLBACK_CODENAME'")
  fi
}

# write_sources FILE URI SUITE COMPONENTS KEYRING [ARCH]
write_sources() {
  local file=$1 uri=$2 suite=$3 comps=$4 key=$5 arch=${6:-$ARCH}
  sudo tee "/etc/apt/sources.list.d/$file.sources" >/dev/null <<EOF
Types: deb
URIs: $uri
Suites: $suite
Components: $comps
Architectures: $arch
Signed-By: $key
EOF
}

ensure_line() {  # ensure_line FILE LINE  (sudo, idempotent)
  sudo grep -qxF -- "$2" "$1" 2>/dev/null || echo "$2" | sudo tee -a "$1" >/dev/null
}

chrome_bin() {
  command -v google-chrome-stable || command -v chromium || command -v chromium-browser || true
}

# --------------------------------------------------------------------------- check

run_check() {
  load_user_path
  local fmt='  %-20s %s\n'
  ver() {  # ver LABEL CMD...
    local label=$1; shift
    local out
    if out=$("$@" 2>/dev/null | head -n1) && [[ -n $out ]]; then
      printf "$fmt" "$label" "$out"
    else
      printf "$fmt" "$label" "${c_red}NOT FOUND${c_off}"
    fi
  }
  pkgver() { dpkg-query -W -f='${Version}' "$1" 2>/dev/null; }

  step "Installed tools"
  ver "Claude Code"   claude --version
  ver "Codex CLI"     codex --version
  ver "Antigravity"   pkgver antigravity
  ver "Hermes Agent"  hermes --version
  if command -v google-chrome-stable >/dev/null; then
    ver "Google Chrome" google-chrome-stable --version
  else
    ver "Chromium"      chromium --version
  fi
  ver "Node.js"       node --version
  ver "npm"           npm --version
  ver "nvm"           bash -c '. "$HOME/.nvm/nvm.sh" && nvm --version'
  ver "uv"            uv --version
  ver "Python (uv)"   uv run --no-project python --version
  ver "gh"            gh --version
  ver "Docker"        docker --version
  ver "Docker Compose" docker compose version
  ver "git"           git --version
  ver "ripgrep"       rg --version
  ver "fd"            fdfind --version
  ver "jq"            jq --version
  ver "tmux"          tmux -V
  ver "htop"          htop --version
  ver "xrdp"          pkgver xrdp
  ver "xubuntu-core"  pkgver xubuntu-core
  ver "gnome-keyring" pkgver gnome-keyring
  if command -v tailscale >/dev/null; then ver "Tailscale" tailscale version; fi

  step "Services"
  svc() {
    local state; state=$(systemctl is-active "$1" 2>/dev/null || true)
    if [[ $state == active ]]; then printf "$fmt" "$1" "${c_green}running${c_off}"
    else printf "$fmt" "$1" "${c_red}${state:-missing}${c_off}"; fi
  }
  svc ssh
  svc xrdp
  svc xrdp-sesman
  svc docker
  svc containerd
  svc unattended-upgrades
  if command -v tailscale >/dev/null; then svc tailscaled; fi
  if sudo ufw status | grep -q 'Status: active'; then
    printf "$fmt" "ufw" "${c_green}active${c_off}"
  else
    printf "$fmt" "ufw" "${c_red}inactive${c_off}"
  fi

  step "System"
  printf "$fmt" "hostname" "$(hostname)"
  printf "$fmt" "machine-id" "$(cat /etc/machine-id)"
  printf "$fmt" "swap" "$(free -h | awk '/^Swap:/{print $2" total, "$3" used"}')"
  printf "$fmt" "auto-upgrades" "$(apt-config dump APT::Periodic::Unattended-Upgrade | awk -F'"' '{print $2}')"
  if id -nG "$USER" | grep -qw docker; then
    printf "$fmt" "docker group" "${c_green}$USER is a member${c_off}"
    docker info >/dev/null 2>&1 || printf "$fmt" "" "(log out/in once so this shell picks it up)"
  else
    printf "$fmt" "docker group" "${c_red}$USER NOT a member${c_off}"
  fi

  step "Hermes browser (CDP on 127.0.0.1:$CDP_PORT)"
  local listen; listen=$(ss -Hltn "sport = :$CDP_PORT" | awk '{print $4}' | sort -u)
  if [[ -z $listen ]]; then
    printf "$fmt" "Chrome CDP" "not running (start 'Hermes Chrome' from the desktop or run hermes-chrome)"
  elif grep -qvE '^(127\.0\.0\.1|\[::1\]):' <<<"$listen"; then
    printf "$fmt" "Chrome CDP" "${c_red}EXPOSED on $listen — stop it!${c_off}"
  else
    printf "$fmt" "Chrome CDP" "${c_green}listening on $(echo $listen) (localhost only)${c_off}"
    curl -fs "http://127.0.0.1:$CDP_PORT/json/version" | jq -r '"  " + .Browser' 2>/dev/null || true
  fi
  printf "$fmt" "Hermes CDP config" "$(grep -h '^BROWSER_CDP_URL=' "$HOME/.hermes/.env" 2>/dev/null || echo "${c_red}missing${c_off}")"
  if sudo ufw status | grep -q "$CDP_PORT.*DENY"; then printf "$fmt" "ufw $CDP_PORT" "explicitly denied"; fi
}

# --------------------------------------------------------------------------- clone reset

reset_identity() {
  local new=${1:-}
  [[ -n $new ]] || die "usage: $0 --reset-identity NEW_HOSTNAME"
  step "Resetting machine identity for a cloned VM -> $new"

  sudo hostnamectl set-hostname "$new"
  if grep -q '^127\.0\.1\.1' /etc/hosts; then
    sudo sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$new/" /etc/hosts
  else
    echo -e "127.0.1.1\t$new" | sudo tee -a /etc/hosts >/dev/null
  fi

  # machine-id (also drives the DHCP client ID, so clones stop fighting over one IP)
  sudo rm -f /etc/machine-id /var/lib/dbus/machine-id
  sudo systemd-machine-id-setup
  sudo ln -sf /etc/machine-id /var/lib/dbus/machine-id

  # SSH host keys
  sudo rm -f /etc/ssh/ssh_host_*
  sudo ssh-keygen -A
  sudo systemctl restart ssh

  # xrdp TLS cert (snakeoil) + RSA keys
  if dpkg -s xrdp >/dev/null 2>&1; then
    sudo make-ssl-cert generate-default-snakeoil --force-overwrite
    sudo xrdp-keygen xrdp auto >/dev/null 2>&1 || true
    sudo systemctl restart xrdp
  fi

  # Tailscale node identity must not be shared
  if sudo test -f /var/lib/tailscale/tailscaled.state; then
    sudo systemctl stop tailscaled
    sudo rm -f /var/lib/tailscale/tailscaled.state
    sudo systemctl start tailscaled
    echo "Tailscale state cleared: run 'sudo tailscale up' to register this VM as a new node."
  fi

  cat <<EOF

Done. Reboot now (sudo reboot) so DHCP, journald and D-Bus pick up the new identity.
From your client, remove the old host key:  ssh-keygen -R <old-ip-or-hostname>
If you cloned AFTER signing in to tools, both VMs now share those sessions/tokens
(~/.claude*, ~/.codex, ~/.hermes, ~/.config/gh, $CHROME_PROFILE, keyring).
Sign out and back in on this VM, or wipe those dirs, so each VM has its own credentials.
EOF
}

# --------------------------------------------------------------------------- setup steps

preflight() {
  [[ $EUID -ne 0 ]] || die "run as your normal user (it uses sudo where needed), not as root"
  . /etc/os-release
  [[ ${ID:-} == ubuntu ]] || die "this script targets Ubuntu (found ${ID:-unknown})"
  CODENAME=$VERSION_CODENAME
  ARCH=$(dpkg --print-architecture)
  [[ $VERSION_ID == 26.04 ]] || warn "written for Ubuntu 26.04, this is $VERSION_ID ($CODENAME) — continuing"
  case $ARCH in amd64|arm64) ;; *) die "unsupported architecture $ARCH" ;; esac
  echo "Ubuntu $VERSION_ID ($CODENAME), $ARCH, user $USER"
  sudo -v
  # keep sudo alive for the run
  while true; do sudo -n true; sleep 50; kill -0 "$$" 2>/dev/null || exit; done 2>/dev/null &
}

snapshot_reminder() {
  cat <<EOF

${c_yellow}${c_bold}SNAPSHOT REMINDER${c_off}
Take a VM snapshot NOW (before setup) so you can roll back.
Take another one after the script finishes and the check looks good.
EOF
  if [[ ${ASSUME_YES:-0} != 1 && -t 0 ]]; then
    read -r -p "Snapshot taken? Press Enter to continue, Ctrl-C to abort. " _
  fi
}

set_hostname() {
  [[ -n ${NEW_HOSTNAME:-} && $(hostname) != "$NEW_HOSTNAME" ]] || return 0
  step "Setting hostname to $NEW_HOSTNAME"
  sudo hostnamectl set-hostname "$NEW_HOSTNAME"
  sudo sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$NEW_HOSTNAME/" /etc/hosts
}

base_packages() {
  step "Base packages"
  "${APT[@]}" update
  "${APT[@]}" upgrade
  "${APT[@]}" install \
    git curl wget ca-certificates gnupg build-essential unzip xdg-utils \
    ripgrep fd-find jq tmux htop openssh-server \
    fonts-noto fonts-noto-color-emoji \
    software-properties-common apt-transport-https libatomic1 \
    unattended-upgrades ufw
  mkdir -p "$HOME/.local/bin"
  ln -sf "$(command -v fdfind)" "$HOME/.local/bin/fd"
  sudo install -d -m 0755 /etc/apt/keyrings
  sudo systemctl enable --now ssh
}

setup_swap() {
  step "Swap"
  local have_mb; have_mb=$(free -m | awk '/^Swap:/{print $2}')
  if (( have_mb >= 4096 )); then
    echo "Already ${have_mb} MB swap, leaving it alone."
    return
  fi
  if [[ ! -f /swapfile ]]; then
    sudo fallocate -l "${SWAP_GB}G" /swapfile || sudo dd if=/dev/zero of=/swapfile bs=1M count=$((SWAP_GB*1024))
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
  fi
  swapon --show=NAME --noheadings | grep -qx /swapfile || sudo swapon /swapfile
  ensure_line /etc/fstab '/swapfile none swap sw 0 0'
  echo 'vm.swappiness=10' | sudo tee /etc/sysctl.d/99-swappiness.conf >/dev/null
  sudo sysctl -q --system
}

setup_unattended_upgrades() {
  step "Unattended security upgrades"
  sudo tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
  sudo systemctl enable --now unattended-upgrades
}

setup_desktop() {
  step "XFCE desktop + xrdp + keyring"
  "${APT[@]}" install xubuntu-core xrdp xorgxrdp gnome-keyring libsecret-1-0 libsecret-tools seahorse dbus-x11

  sudo adduser xrdp ssl-cert >/dev/null
  # xrdp sessions start XFCE
  echo "startxfce4" >"$HOME/.xsession"
  chmod +x "$HOME/.xsession"
  cat >"$HOME/.xsessionrc" <<'EOF'
export XDG_SESSION_DESKTOP=xubuntu
export XDG_CURRENT_DESKTOP=XFCE
export XDG_DATA_DIRS=/usr/share/xfce4:/usr/local/share:/usr/share:/var/lib/snapd/desktop
export XDG_CONFIG_DIRS=/etc/xdg/xdg-xubuntu:/etc/xdg
EOF

  # Unlock gnome-keyring with the xrdp login password, so Chrome/Antigravity/gh logins persist
  local pam=/etc/pam.d/xrdp-sesman
  if ! grep -q pam_gnome_keyring "$pam"; then
    sudo sed -i '/^@include common-auth/a auth optional pam_gnome_keyring.so' "$pam"
    sudo sed -i '/^@include common-session/a session optional pam_gnome_keyring.so auto_start' "$pam"
  fi

  # Stop the "authentication required to create a color managed device" popups in xrdp
  sudo tee /etc/polkit-1/rules.d/45-xrdp-colord.rules >/dev/null <<'EOF'
polkit.addRule(function(action, subject) {
  if (action.id.indexOf("org.freedesktop.color-manager.") == 0 && subject.local !== true) {
    return polkit.Result.YES;
  }
});
EOF

  sudo systemctl enable --now xrdp xrdp-sesman
  sudo systemctl restart xrdp
}

setup_chrome() {
  step "Browser"
  if [[ $ARCH == amd64 ]]; then
    if dpkg -s google-chrome-stable >/dev/null 2>&1; then
      echo "Google Chrome already installed (updates come via its own apt repo)."
    else
      local d; d=$(mktemp -d); chmod 755 "$d"
      curl -fsSL -o "$d/chrome.deb" https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
      "${APT[@]}" install "$d/chrome.deb"   # postinst adds Google's 'stable' apt repo
      rm -rf "$d"
    fi
  else
    # ARM: Google ships no Linux arm64 Chrome; Ubuntu's chromium is a snap.
    # xtradeb/apps PPA provides a real chromium .deb.
    if ! compgen -G "/etc/apt/sources.list.d/xtradeb-*" >/dev/null; then
      sudo add-apt-repository -y -n ppa:xtradeb/apps || true
    fi
    pick_suite "xtradeb/apps PPA (chromium)" "https://ppa.launchpadcontent.net/xtradeb/apps/ubuntu"
    sudo sed -i "s/^Suites: .*/Suites: $SUITE/" /etc/apt/sources.list.d/xtradeb-*.sources
    sudo tee /etc/apt/preferences.d/xtradeb-chromium >/dev/null <<'EOF'
Package: chromium*
Pin: release o=LP-PPA-xtradeb-apps
Pin-Priority: 1001
EOF
    "${APT[@]}" update
    "${APT[@]}" install chromium
  fi
}

setup_antigravity() {
  step "Google Antigravity"
  # Suite is 'antigravity-debian' (release-independent), so no noble fallback needed.
  fetch_key https://us-central1-apt.pkg.dev/doc/repo-signing-key.gpg /etc/apt/keyrings/antigravity-repo-key.gpg
  write_sources antigravity https://us-central1-apt.pkg.dev/projects/antigravity-auto-updater-dev/ \
    antigravity-debian main /etc/apt/keyrings/antigravity-repo-key.gpg
  "${APT[@]}" update
  "${APT[@]}" install antigravity || warn "Antigravity package failed to install on $ARCH — see output above"
}

setup_gh() {
  step "GitHub CLI"
  fetch_key https://cli.github.com/packages/githubcli-archive-keyring.gpg /etc/apt/keyrings/githubcli-archive-keyring.gpg
  write_sources github-cli https://cli.github.com/packages stable main /etc/apt/keyrings/githubcli-archive-keyring.gpg
  "${APT[@]}" update
  "${APT[@]}" install gh
}

setup_docker() {
  step "Docker Engine"
  for p in docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc; do
    dpkg -s "$p" >/dev/null 2>&1 && "${APT[@]}" remove "$p"
  done
  fetch_key https://download.docker.com/linux/ubuntu/gpg /etc/apt/keyrings/docker.gpg
  pick_suite "Docker" https://download.docker.com/linux/ubuntu
  write_sources docker https://download.docker.com/linux/ubuntu "$SUITE" stable /etc/apt/keyrings/docker.gpg
  "${APT[@]}" update
  "${APT[@]}" install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  sudo systemctl enable --now docker containerd
  sudo usermod -aG docker "$USER"
}

setup_tailscale() {
  [[ $INSTALL_TAILSCALE == 1 ]] || return 0
  step "Tailscale"
  pick_suite "Tailscale" https://pkgs.tailscale.com/stable/ubuntu
  fetch_key "https://pkgs.tailscale.com/stable/ubuntu/$SUITE.noarmor.gpg" /etc/apt/keyrings/tailscale-archive-keyring.gpg
  write_sources tailscale https://pkgs.tailscale.com/stable/ubuntu "$SUITE" main /etc/apt/keyrings/tailscale-archive-keyring.gpg
  "${APT[@]}" update
  "${APT[@]}" install tailscale
  sudo systemctl enable --now tailscaled
}

setup_node() {
  step "Node.js LTS via nvm $NVM_VERSION"
  export NVM_DIR="$HOME/.nvm"
  if [[ ! -s $NVM_DIR/nvm.sh ]]; then
    curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_VERSION/install.sh" | PROFILE="$HOME/.bashrc" bash
  fi
  set +u
  . "$NVM_DIR/nvm.sh"
  nvm install --lts --latest-npm
  nvm alias default 'lts/*'
  nvm use default >/dev/null
  set -u
}

setup_uv() {
  step "Python via uv"
  if command -v uv >/dev/null || [[ -x $HOME/.local/bin/uv ]]; then
    "$HOME/.local/bin/uv" self update || true
  else
    curl -LsSf https://astral.sh/uv/install.sh | sh
  fi
  load_user_path
  uv python install
}

setup_claude() {
  step "Claude Code"
  load_user_path
  if command -v claude >/dev/null; then
    echo "Already installed (native install auto-updates)."
  else
    curl -fsSL https://claude.ai/install.sh | bash
  fi
}

setup_codex() {
  step "OpenAI Codex CLI"
  load_user_path
  npm i -g @openai/codex   # global into the nvm node, no sudo
}

setup_hermes() {
  step "Hermes Agent"
  load_user_path
  if command -v hermes >/dev/null; then
    hermes update || warn "hermes update failed"
  else
    # --skip-setup: don't run the interactive provider/login wizard (you do that later)
    curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh \
      | bash -s -- --skip-setup
  fi
}

setup_hermes_chrome() {
  step "Dedicated Chrome profile for Hermes (CDP on 127.0.0.1:$CDP_PORT)"
  local bin; bin=$(chrome_bin)
  [[ -n $bin ]] || { warn "no Chrome/Chromium found, skipping Hermes browser setup"; return; }
  mkdir -p "$CHROME_PROFILE" "$HOME/.local/bin" "$HOME/.local/share/applications" "$HOME/.config/autostart"
  chmod 700 "$CHROME_PROFILE"

  cat >"$HOME/.local/bin/hermes-chrome" <<EOF
#!/usr/bin/env bash
# Chrome for Hermes: separate profile, CDP on localhost only.
# Chrome binds the debug port to 127.0.0.1 by default; we never pass
# --remote-debugging-address, and ufw denies $CDP_PORT as a second layer.
if curl -fs http://127.0.0.1:$CDP_PORT/json/version >/dev/null 2>&1; then
  echo "Hermes Chrome already running on 127.0.0.1:$CDP_PORT"; exit 0
fi
exec "$bin" \\
  --user-data-dir="$CHROME_PROFILE" \\
  --remote-debugging-port=$CDP_PORT \\
  --password-store=gnome-libsecret \\
  --no-first-run --no-default-browser-check \\
  "\$@"
EOF
  chmod +x "$HOME/.local/bin/hermes-chrome"

  local desktop="[Desktop Entry]
Type=Application
Name=Hermes Chrome
Comment=Chrome profile for Hermes Agent (CDP 127.0.0.1:$CDP_PORT)
Exec=$HOME/.local/bin/hermes-chrome
Icon=$( [[ $bin == *google-chrome* ]] && echo google-chrome || echo chromium )
Terminal=false
Categories=Network;WebBrowser;"
  echo "$desktop" >"$HOME/.local/share/applications/hermes-chrome.desktop"
  echo "$desktop" >"$HOME/.config/autostart/hermes-chrome.desktop"

  # Point Hermes' browser tools at that Chrome
  mkdir -p "$HOME/.hermes"
  touch "$HOME/.hermes/.env"; chmod 600 "$HOME/.hermes/.env"
  sed -i '/^BROWSER_CDP_URL=/d' "$HOME/.hermes/.env"
  echo "BROWSER_CDP_URL=http://127.0.0.1:$CDP_PORT" >>"$HOME/.hermes/.env"
  load_user_path
  hermes config set browser.cdp_url "http://127.0.0.1:$CDP_PORT" >/dev/null 2>&1 || true
}

detect_lan() {
  local dev; dev=$(ip route show default | awk '{print $5; exit}')
  ip -o -f inet route show dev "$dev" scope link | awk '{print $1; exit}'
}

setup_firewall() {
  step "ufw firewall"
  local allow=${RDP_ALLOW_FROM:-}
  if [[ -z $allow ]]; then
    allow=$(detect_lan)
    [[ $INSTALL_TAILSCALE == 1 ]] && allow="$allow 100.64.0.0/10"
    warn "RDP_ALLOW_FROM not set; allowing RDP from auto-detected: $allow (behind NAT this is the VM network, not your LAN — set RDP_ALLOW_FROM if needed)"
  fi
  sudo ufw default deny incoming
  sudo ufw default allow outgoing
  sudo ufw allow OpenSSH comment 'ssh'
  # Drop old RDP rules so re-runs with a different RDP_ALLOW_FROM don't accumulate
  while sudo ufw status numbered | grep -q '3389/tcp'; do
    local n; n=$(sudo ufw status numbered | grep '3389/tcp' | head -n1 | sed -E 's/^\[ *([0-9]+)\].*/\1/')
    sudo ufw --force delete "$n" >/dev/null
  done
  for cidr in $allow; do
    sudo ufw allow from "$cidr" to any port 3389 proto tcp comment 'rdp'
  done
  sudo ufw deny "$CDP_PORT"/tcp comment 'never expose Chrome CDP'
  sudo ufw --force enable
}

final_notes() {
  step "Repo notes"
  if ((${#FALLBACKS[@]})); then
    echo "These third-party repos have no '$CODENAME' suite yet and were set to '$FALLBACK_CODENAME':"
    printf '  - %s\n' "${FALLBACKS[@]}"
  else
    echo "All codename-based third-party repos support '$CODENAME' natively (no noble fallback)."
  fi
  echo "Release-independent repos (no fallback needed): Google Chrome 'stable', GitHub CLI 'stable', Antigravity 'antigravity-debian'."
  if ((${#WARNINGS[@]})); then echo; echo "Warnings:"; printf '  - %s\n' "${WARNINGS[@]}"; fi

  cat <<EOF

${c_bold}Sign-ins left for you (none were done by this script):${c_off}
  Claude Code   run 'claude' in a terminal -> follow the browser/OAuth prompt (or /login)
  Codex CLI     run 'codex' -> "Sign in with ChatGPT" (or 'codex login'; API key: 'codex login --with-api-key')
  Antigravity   open it from the XFCE menu over RDP -> sign in with your Google account
  Hermes        'hermes setup' (full wizard) or 'hermes model' to pick provider + key/OAuth
                ('hermes setup --portal' for Nous Portal). Then in 'hermes': /browser status
  gh            'gh auth login' (GitHub.com -> HTTPS -> login with a web browser), then 'gh auth setup-git'
  Chrome        the 'Hermes Chrome' window (profile $CHROME_PROFILE): sign in to the sites the
                agent should use. Keep it a dedicated agent account, not your personal one.
  Tailscale     $( [[ $INSTALL_TAILSCALE == 1 ]] && echo "'sudo tailscale up' and open the printed URL" || echo "(not installed; re-run with INSTALL_TAILSCALE=1)" )

${c_bold}Next:${c_off}
  - Log out/in (or reboot) once so the docker group and PATH (nvm, ~/.local/bin) apply.
  - Connect with Remote Desktop to $(hostname -I | awk '{print $1}'):3389 and log in as $USER.
    Log out of any local console desktop session for $USER first — xrdp can't share it.
  - Docker-published ports (-p) bypass ufw; bind them to 127.0.0.1 unless you mean to expose them.
  ${c_yellow}${c_bold}- Take the post-setup VM snapshot now.${c_off}
EOF
}

# --------------------------------------------------------------------------- main

main() {
  case ${1:-} in
    --check) . /etc/os-release; CODENAME=$VERSION_CODENAME; run_check; exit ;;
    --reset-identity) reset_identity "${2:-}"; exit ;;
    --yes) ASSUME_YES=1 ;;
    "") ;;
    -h|--help) sed -n '2,25p' "$0"; exit ;;
    *) die "unknown option $1 (see --help)" ;;
  esac

  exec > >(tee -a "$LOG") 2>&1
  echo "=== setup-agent-vm.sh $(date -Is) ==="
  preflight
  snapshot_reminder
  set_hostname
  base_packages
  setup_swap
  setup_unattended_upgrades
  setup_desktop
  setup_chrome
  setup_antigravity
  setup_gh
  setup_docker
  setup_tailscale
  setup_node
  setup_uv
  setup_claude
  setup_codex
  setup_hermes
  setup_hermes_chrome
  setup_firewall
  run_check
  final_notes
  echo "Log: $LOG"
}

main "$@"
