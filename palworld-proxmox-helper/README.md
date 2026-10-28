# Palworld Proxmox LXC Helper

A small, self-hosted Proxmox VE helper that creates a Debian 12 LXC for a standalone Palworld dedicated server. It does not use Pterodactyl, alter DDNS, or require a third-party control panel.

## What it provides

- Interactive Proxmox host installer for a new, unprivileged LXC.
- Console menu inside the container for status, start/stop/restart, settings, and manual game updates.
- SteamCMD update check whenever the server starts, plus a scheduled daily update/restart window.
- Public IPv4 check every five minutes. When it detects a changed address, it writes the new literal IP to `PublicIP` in `PalWorldSettings.ini` and restarts Palworld.
- `CrossplayPlatforms=(Steam,Xbox,PS5,Mac)` and `-publiclobby` by default.
- Optional manager self-update from the public GitHub repository's `main` branch.

The public-IP watcher only reads the current external IPv4 from `api.ipify.org`. It does not configure or update DDNS. Your DDNS client can continue running separately.

## Requirements

- Proxmox VE host with `pct`, `pvesh`, `pvesm`, `pveam`, and a Linux bridge such as `vmbr0`.
- Internet access from both the Proxmox host and the LXC.
- A Debian 12 standard LXC template (the installer downloads one if needed).
- Allow at least 4 CPU cores and 16 GiB RAM for a comfortable Palworld server. The install wizard's minimum is 2 cores and 8 GiB.
- A stable LAN address for the container. Use a static address or a DHCP reservation before configuring router forwarding.

## Install

Publish the repository to GitHub and replace `YOUR_GITHUB_USER` in `ct/palworld-server.sh` with your GitHub account or organization name. The repository name in that default is `palworld-proxmox-helper`; update it too if you choose another name. Then run this on the Proxmox host as root:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/YOUR_GITHUB_USER/palworld-proxmox-helper/main/ct/palworld-server.sh)"
```

The entry script downloads `guest/install-guest.sh` and `guest/palworld-manager.sh` from the same public repository, then asks for the container ID, hostname, bridge, storage, resources, network settings, game port, and server name. The container uses DHCP by default. For a static address, supply IPv4/CIDR and the LAN gateway.

The helper creates and starts the LXC, installs Debian dependencies and SteamCMD, downloads Palworld App ID `2394010`, writes the systemd units, and starts the server. The installer configures the manager to update from the same repository.

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

In the manager, choose **Update manager from GitHub**. It downloads `guest/palworld-manager.sh` from the repository's `main` branch. Keep that path and branch stable for manager updates. To create another LXC with the latest host installer, run the one-line curl command again from the README.

The game server is updated separately through SteamCMD: on startup, through the daily timer, or with **Update now** in the manager.

## Data and backups

Palworld files and saves are under `/opt/palworld/server`. Back up at least:

- `Pal/Saved/SaveGames/`
- `Pal/Saved/Config/LinuxServer/PalWorldSettings.ini`

Take a Proxmox container backup before major upgrades or changes. The installer will not overwrite an existing config file if rerun, but this project is currently designed for first-time LXC creation rather than repairing/upgrading arbitrary existing containers.

## Limitations

- Self-update currently targets the public `main` branch and updates the manager UI script only. It does not update the Proxmox host installer or guest systemd templates.
- Dynamic-IP checks require outbound HTTPS to `api.ipify.org`. If lookup fails, the current config is left unchanged and the next check retries.
- A detected public IP change restarts the server so it can advertise the new address. Players may be disconnected at that moment.
- The scheduled daily update job stops the server, checks/validates files, and starts it again. It may cause a brief daily interruption even if SteamCMD finds no game update.
- No RCON or REST API port is opened to the internet.

## License

MIT. See [LICENSE](LICENSE).
