# Palworld Proxmox LXC Helper

A small, self-hosted Proxmox VE helper that creates a Debian 13 LXC for a standalone Palworld dedicated server. It does not use Pterodactyl, alter DDNS, or require a third-party control panel.

## What it provides

- Interactive Proxmox host installer for a new, unprivileged LXC.
- Console menu inside the container for status, start/stop/restart, settings, and manual game updates.
- SteamCMD update check whenever the server starts, plus a scheduled daily update/restart window.
- Public IPv4 check every five minutes. When it detects a changed address, it writes the new literal IP to `PublicIP` in `PalWorldSettings.ini` and restarts Palworld.
- `CrossplayPlatforms=(Steam,Xbox,PS5,Mac)` and `-publiclobby` by default.
- LAN-only HTTPS web panel with login, live status, start/stop/restart, settings, logs, game/helper updates, password changes, and save/config backups.
- Web panel includes a persistent light/dark theme toggle, backup download, and upload/import restore for offsite archives.
- Helper updater refreshes the management scripts and service definitions from GitHub while preserving the world, settings, backup files, and web login.
- Root auto-login on the Proxmox LXC console; `pct enter <CTID>` also opens a root shell directly.

The public-IP watcher only reads the current external IPv4 from `api.ipify.org`. It does not configure or update DDNS. Your DDNS client can continue running separately.

## Requirements

- Proxmox VE host with `pct`, `pvesh`, `pvesm`, `pveam`, and a Linux bridge such as `vmbr0`.
- Internet access from both the Proxmox host and the LXC.
- A Debian 13 standard LXC template (the installer downloads the newest available template if needed).
- Allow at least 4 CPU cores and 16 GiB RAM for a comfortable Palworld server. The install wizard's minimum is 2 cores and 8 GiB.
- A stable LAN address for the container. Use a static address or a DHCP reservation before configuring router forwarding.

## Install

Upload the contents of this project folder to the `SloeberX/palworld-proxmox-helper` GitHub repository, keeping the `ct` and `guest` folders at the repository root. Then run this on the Proxmox host as root:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/SloeberX/palworld-proxmox-helper/main/ct/palworld-server.sh)"
```

The entry script downloads the guest installer, helper updater, console manager, and web panel files from the same public repository, then asks for the container ID, hostname, bridge, storage, resources, network settings, game port, and server name. The container uses DHCP by default. For a static address, supply IPv4/CIDR and the LAN gateway. Choose clean progress screens or verbose console output before installation; if guest setup fails, the installer offers a verbose retry, an LXC shell, or leaving the container in place for debugging.

The helper creates an unprivileged LXC with nesting enabled, installs Debian dependencies and SteamCMD, downloads Palworld App ID `2394010`, writes the systemd units, and starts the server. It selects the newest available Debian 13 standard template and provides separate storage pickers for the container disk and template, showing storage type and correctly converted free capacity.

At first installation, the completion screen and Proxmox console show the LXC's local IP, game address/UDP port, web panel address, and login details. The default web username is `admin`; the installer generates a unique initial password and prints it at the end. Save it, sign in, and then change it from the **Web login** card. There is no shared hard-coded default password. The panel uses a local self-signed certificate, so your browser will show a certificate warning on first access. Visit `https://<LXC-LAN-IP>:8443` from a device on your LAN. The web service binds to the container's LAN address; do not forward TCP 8443 on your router. A stable DHCP reservation or static LXC address is recommended.

The Proxmox console is set to auto-login as root. This applies to the local Proxmox console only; it does not enable passwordless SSH. `pct enter <CTID>` already opens a root shell without a guest username or password.

Open the in-container menu from the Proxmox host:

```bash
pct enter <CTID>
palworld-manager
```

## Network setup

Palworld gameplay uses UDP `8211` by default. If you choose another game port, forward that UDP port instead. On your router, forward the WAN UDP port to the LXC's stable LAN IP and the same UDP port. Allow it through any Proxmox, host, or router firewalls that apply.

The Proxmox host allocation/bind address and Palworld's advertised public address are separate concepts. This helper uses a directly bridged LXC, so it does not configure Docker port mappings or Pterodactyl allocations. The helper updates the Palworld `PublicIP` value when your public IPv4 changes; it cannot make a router forward work, bypass CGNAT, or open provider firewalls.

If your ISP uses CGNAT, ordinary router port forwarding will not make the server reachable from the public internet. Ask the ISP for a public IPv4 or use a suitable tunnel/VPN solution.

## Updating the helper from GitHub

In the web panel, choose **Update helper only** to refresh the manager, web app, helper commands, and systemd units from GitHub. **Update game + helper** does that first, then updates Palworld through SteamCMD. To create another LXC with the latest host installer, run the one-line curl command again from the README.

The game server is updated separately through SteamCMD: on startup, through the daily timer, or with **Update game + helper** in the web panel. That action refreshes helper files from GitHub first, then updates the Palworld server. **Update helper only** refreshes management files without downloading game files.

## Data and backups

Palworld files and saves are under `/opt/palworld/server`. Back up at least:

- `Pal/Saved/SaveGames/`
- `Pal/Saved/Config/LinuxServer/PalWorldSettings.ini`

Take a Proxmox container backup before major upgrades or changes. The installer will not overwrite an existing config file if rerun, but this project is currently designed for first-time LXC creation rather than repairing/upgrading arbitrary existing containers.

The web panel's **Backups** page can create and download consistent archives containing the world saves and `PalWorldSettings.ini`. Creating an archive briefly stops and restarts Palworld to avoid capturing a save while it is being written. Store downloaded copies offsite. To recover on this manager, open **Backups**, choose the archive file, and select **Upload and restore backup**. The import makes a safety backup of the current world/config before replacing it. The archive does not include SteamCMD or the installed game binaries; those are downloaded by the manager, which keeps offsite backups smaller and lets an archive restore into a fresh Palworld manager install.

## Limitations

- Helper self-update targets the configured public GitHub branch (default `main`) and refreshes guest management code and systemd units. It does not update the Proxmox host installer.
- The web panel uses a generated self-signed HTTPS certificate bound to the LXC's private LAN IPv4. Browsers will not trust it until you explicitly trust that certificate; the panel is not configured for public internet access.
- Dynamic-IP checks require outbound HTTPS to `api.ipify.org`. If lookup fails, the current config is left unchanged and the next check retries.
- A detected public IP change restarts the server so it can advertise the new address. Players may be disconnected at that moment.
- The scheduled daily update job stops the server, checks/validates files, and starts it again. It may cause a brief daily interruption even if SteamCMD finds no game update.
- No RCON or REST API port is opened to the internet.
- Backups contain world saves and server configuration, not the Palworld game installation or Debian LXC image.

The post-install address summary follows the useful completion-screen pattern used by [Community Scripts' Pulse installer](https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/pulse.sh), adapted for the Palworld LXC and LAN-only manager.

## License

MIT. See [LICENSE](LICENSE).
