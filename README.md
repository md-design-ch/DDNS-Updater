# DDNS Updater

`ddns-updater.sh` runs on a remote Linux machine, detects its public IP address, and sends that IP to one or more HTTP endpoints so your server can keep track of how to reach the device.

The project includes:

- `ddns-updater.sh`: checks the current public IP and POSTs updates when it changes
- `ddns-updater.service`: low-priority `systemd` oneshot service
- `ddns-updater.timer`: runs the updater every minute and survives reboots
- `install.sh`: installs `curl` if needed, installs the service/timer, and enables the timer
- `uninstall.sh`: removes the installed files, config, and state
- `ddns-updater.env`: packaged runtime configuration

## How It Works

Each run does the following:

1. Fetches the device's public IP from `IP_API_URL`
2. Compares it with the last successfully reported IP stored in `SAVE_FILE`
3. If the IP changed, POSTs JSON to each configured endpoint
4. Only updates `SAVE_FILE` if every endpoint responds with HTTP `2xx`

The JSON payload contains:

- `ip`
- `device_id`
- `hostname`

If any endpoint returns `404`, `500`, times out, or otherwise fails:

- the script still tries every configured endpoint in that run
- the service run is marked failed
- the saved IP is not updated
- the next timer run retries the same IP automatically

## Reliability Behavior

The `systemd` timer is configured so the updater keeps running after normal service failures and after reboots:

- `ddns-updater.timer` is enabled instead of the service directly
- `OnCalendar=minutely` schedules one run every minute
- `Persistent=true` tells `systemd` to catch up after downtime
- each network request is bounded by the script's `curl` time limits
- the service uses low CPU and I/O priority via `Nice=19`, `IOSchedulingClass=idle`, and `CPUSchedulingPolicy=batch`

What this means in practice:

- reboot: the timer comes back automatically if it was enabled
- `systemctl daemon-reload`: the enabled timer remains managed by `systemd`
- failed POST request: future minute-based runs continue automatically
- script crash or non-zero exit: the timer still invokes the next run

## Requirements

- Linux
- `bash`
- `curl`
- `systemd`

## Supported Systems

The project is designed for Linux distributions that use `systemd`, including:

- Debian
- Ubuntu
- Fedora
- RHEL
- Rocky Linux
- AlmaLinux
- CentOS Stream
- Arch Linux
- openSUSE

`install.sh` can install `curl` with these package managers when available:

- `apt-get`
- `dnf`
- `yum`
- `pacman`
- `zypper`
- `apk`

Note: the automatic `curl` install supports `apk`, but the service/timer setup still requires `systemd`. Alpine Linux does not use `systemd` by default.

## Configuration

The packaged config file is `ddns-updater.env`. It is installed to `/etc/default/ddns-updater`.

Important variables:

- `EXTERNAL_SERVER_URLS`: space-separated list of callback URLs
- `DEVICE_ID`: stable label for the remote device
- `AUTH_HEADER`: optional extra HTTP header such as a bearer token
- `IP_API_URL`: public IP lookup endpoint
- `SAVE_FILE`: where the last successful IP is stored

Example payload:

```json
{
  "ip": "203.0.113.10",
  "device_id": "remote-gate",
  "hostname": "remote-gate.example.net"
}
```

## Installation

Automatic installation:

```bash
sudo ./install.sh
```

This will:

- install `curl` if needed
- copy the updater to `/usr/local/lib/ddns-updater/ddns-updater.sh`
- install the `systemd` unit files into `/etc/systemd/system/`
- install `ddns-updater.env` to `/etc/default/ddns-updater` if that file does not already exist
- enable and start `ddns-updater.timer`

Manual installation:

1. Install `curl`
2. Copy `ddns-updater.sh` to `/usr/local/lib/ddns-updater/ddns-updater.sh`
3. Make it executable
4. Copy `ddns-updater.service` to `/etc/systemd/system/ddns-updater.service`
5. Copy `ddns-updater.timer` to `/etc/systemd/system/ddns-updater.timer`
6. Copy `ddns-updater.env` to `/etc/default/ddns-updater`
7. Create `/var/lib/ddns-updater`
8. Run `sudo systemctl daemon-reload`
9. Run `sudo systemctl enable --now ddns-updater.timer`

## Operation

Useful commands:

```bash
systemctl status ddns-updater.timer
systemctl status ddns-updater.service
systemctl list-timers ddns-updater.timer
journalctl -u ddns-updater.service -n 100 --no-pager
```

Manual run:

```bash
./ddns-updater.sh
```

## Uninstall

```bash
sudo ./uninstall.sh
```

This removes:

- `/usr/local/lib/ddns-updater`
- `/etc/systemd/system/ddns-updater.service`
- `/etc/systemd/system/ddns-updater.timer`
- `/etc/default/ddns-updater`
- `/var/lib/ddns-updater`

## Notes

- Do not commit real production secrets unless you intentionally want them distributed with the package.
- If you change `SAVE_FILE`, keep it under `/var/lib/ddns-updater` unless you also adjust the service sandbox settings.
