# agent-vm-setup

One re-runnable script that turns a fresh **Ubuntu 26.04** VM into an AI-agent workstation:

- **Agents:** Claude Code (native installer), OpenAI Codex CLI, Google Antigravity, Hermes Agent (Nous Research)
- **Browser:** Google Chrome stable `.deb` (Chromium `.deb` from the xtradeb PPA on ARM, never the snap),
  plus a dedicated `~/.hermes-chrome` profile with CDP on `127.0.0.1:9222` wired into Hermes
- **Desktop:** XFCE (`xubuntu-core`) + xrdp, gnome-keyring/libsecret unlocked at RDP login
- **Runtimes & tools:** Node.js LTS via nvm, Python via uv, gh, Docker Engine (official repo), git, ripgrep, fd, jq, tmux, htop
- **System:** swap file, unattended security upgrades, ufw (SSH open, RDP only from given CIDRs, 9222 denied), optional Tailscale

Third-party apt repos that don't publish a 26.04 suite yet automatically fall back to `noble`;
the script lists which ones it did that for.

## Usage

Take a VM snapshot first. Run as your normal user (not root):

```bash
curl -fsSLO https://raw.githubusercontent.com/henrik253/agent-vm-setup/main/setup-agent-vm.sh
chmod +x setup-agent-vm.sh
RDP_ALLOW_FROM="192.168.178.0/24 100.64.0.0/10" INSTALL_TAILSCALE=1 NEW_HOSTNAME=agent-vm1 ./setup-agent-vm.sh
```

Then log out/in once (docker group, PATH) and verify:

```bash
./setup-agent-vm.sh --check     # tool versions + service status
```

| Variable | Default | Meaning |
|---|---|---|
| `RDP_ALLOW_FROM` | VM's own subnet | Space-separated CIDRs allowed to reach RDP (3389) |
| `INSTALL_TAILSCALE` | `0` | `1` installs Tailscale (you run `sudo tailscale up`) |
| `NEW_HOSTNAME` | – | Set the hostname during setup |
| `SWAP_GB` | `6` | Swap file size, only if the VM has < 4 GB swap |
| `NVM_VERSION` | `v0.40.3` | nvm release |
| `CDP_PORT` | `9222` | Chrome remote-debugging port (localhost only) |

## Second VM

Easiest: run the same script on a fresh install. If you clone instead, boot the clone and run once:

```bash
./setup-agent-vm.sh --reset-identity agent-vm2 && sudo reboot
```

This regenerates hostname, machine-id, SSH host keys, xrdp keys and clears Tailscale state.
Clone *before* signing in to anything, or sign in again on the clone.

## Sign-ins (not automated)

| Tool | How |
|---|---|
| Claude Code | `claude` → browser sign-in |
| Codex | `codex` → "Sign in with ChatGPT" (or `codex login --with-api-key`) |
| Antigravity | open over RDP → Google sign-in |
| Hermes | `hermes setup` / `hermes model`, then `/browser status` |
| gh | `gh auth login`, `gh auth setup-git` |
| Chrome | sign in to sites in the "Hermes Chrome" window (use a dedicated account) |
| Tailscale | `sudo tailscale up` |

> Docker-published ports bypass ufw — bind them to `127.0.0.1` unless you mean to expose them.
