# Mole

Proxy subscription manager for Podkop on OpenWrt routers. Runs over SSH as an interactive TUI.

Fetches and parses proxy subscription URLs, auto-groups nodes by provider, maintains refreshable link pools, and pushes them into Podkop's URLTest sections — keeping your VPN node lists up to date automatically.

![Shell Script](https://img.shields.io/badge/shell-ash%2Fbusybox-blue)
![Platform](https://img.shields.io/badge/platform-OpenWrt%2024.10-green)
![License](https://img.shields.io/badge/license-MIT-purple)

## Preview

<center>
<img width="1960" height="1618" alt="Untitled" src="https://github.com/user-attachments/assets/9598ac0d-40d0-49cf-8bf6-f050fe5cf3c0" />
</center>

## What it does

Manages proxy subscriptions end-to-end: fetch → parse → group → filter → push to Podkop.

### Subscriptions

- Add by URL — fetches the subscription, parses all node URIs (ss, vless, trojan, hysteria2, socks5 and more), stores pool locally
- Profile metadata extracted from response headers: title, traffic usage, expiry, update interval, announce banner
- Auto-grouped by profile-title — subscriptions from the same provider always share one group, groups materialise on add and vanish on last removal
- Manual link pool editor — paste raw URIs directly without a remote URL
- Per-subscription refresh with metadata update; cron auto-refreshes all enabled subscriptions on a schedule

### Groups

- Subscriptions from the same provider are grouped automatically; group display name follows the profile-title
- Rename groups; group list shown on the main screen with per-group node counts

### Podkop sections

- Adopt existing Podkop URLTest sections into Mole management with one key press
- Assign source groups — the link pool for a section is built from all subscriptions in the chosen groups
- Flush to Podkop — writes the resolved URI set into `urltest_proxy_links` and restarts Podkop; no-op if already in sync
- Dirty indicator — warns when planned links differ from what is currently in Podkop
- URLTest settings per section: Check Interval, Tolerance (ms), Testing URL — written directly to Podkop UCI
- Latency probe — triggers Podkop's clash API group test and shows per-node ping results on the next render
- Unadopt — removes Mole management without touching Podkop state

### Filtering

- Protocol exclusion — exclude entire protocols (ss, vmess, tuic, etc.) per subscription
- Per-node batch exclude/include — toggle individual nodes by index or range (`1 3 5-8`), or exclude/include all at once
- Exclusions are applied at flush time; protocol filters and per-link filters stack

### Cron

- Schedule auto-refresh with presets (every 1h / 3h / 6h / 12h / daily) or a custom cron expression
- Server-suggested interval shown as a hint when subscriptions advertise `profile-update-interval`
- Cron entry written to `/etc/crontabs/root`, cron service reloaded automatically
- Last-run info and log tail visible in the cron menu
- Warning shown when the script is not installed at `/usr/bin/mole` (cron needs it there)

### Install / Update

- Install from current running file or download latest directly from GitHub
- Self-update: downloads `mole.sh` from the repo, installs to `/usr/bin/mole`
- Main menu shows `Install Script ⚠ cron needs this` when not yet installed at the expected path

### Other

- Log viewer with live tail and clear
- Settings: user-agent, download/connect timeouts, ASN enrichment source and TTL
- Full reset — wipes all UCI config, pool files, cache, log and crontab entry with two-step confirmation

## Install

```bash
wget -O /usr/bin/mole https://raw.githubusercontent.com/tickcount/podkop-subscriptions/main/mole.sh
chmod +x /usr/bin/mole
mole
```

Or run once without installing:

```bash
sh <(wget -O - https://raw.githubusercontent.com/tickcount/podkop-subscriptions/main/mole.sh)
```

## Requirements

- OpenWrt 24.10+ (BusyBox ash)
- [Podkop](https://github.com/itdoginfo/podkop)

Optional (installable from the menu): `curl`, `jq`, `coreutils-base64`, `flock`.

## Usage

1. Run `mole`
2. Press `+` to add a subscription URL
3. Go to `p › Podkop Sections`, adopt a section, assign source groups
4. Press `f` to flush the link pool into Podkop
5. Optionally configure cron (`c`) for automatic refresh

## How it works

Each subscription is stored as a UCI section in `/etc/config/mole`. The parsed node URIs are cached as plain-text pool files in `/etc/mole/pool/`. When a Podkop section is flushed, Mole resolves the union of all source groups' pools, applies protocol and per-link exclusions, and writes the resulting URI list into Podkop's `urltest_proxy_links` option — then restarts Podkop once.

A canonical hash of the planned URI set is compared against what is currently in Podkop before every flush; if they match the operation is a no-op, so restarting Podkop unnecessarily is avoided.

## License

MIT
