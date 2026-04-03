# DDNS Updater

`ddns-updater.sh` runs on a remote Linux machine, detects its public IP address, and sends that IP to one or more HTTP endpoints so your server can keep track of how to reach the device.

- software owner: `MDSolutions Miljantejs`
- current version: `0.1`

The project includes:

- `ddns-updater.sh`: checks the current public IP and POSTs updates when it changes
- `ddns-updater`: installed command on `PATH`
- `ddns-updater.service`: low-priority `systemd` oneshot service
- `ddns-updater.timer`: runs the updater every minute and survives reboots
- `install.sh`: installs `curl` if needed, installs the service/timer, and enables the timer
- `uninstall.sh`: removes the installed files, config, and state
- `ddns-updater.env`: packaged runtime configuration
- `build-tar.sh`: builds a clean `.tar.gz` release archive
- `build-deb.sh`: builds a Debian `.deb` package

## How It Works

Each run does the following:

1. Fetches the device's public IP from `IP_API_URL`
2. Compares it with the last successfully reported IP stored in `SAVE_FILE`
3. If the IP changed, POSTs JSON to each configured endpoint
4. Updates `SAVE_FILE` if at least one endpoint responds with HTTP `2xx`

The JSON payload contains:

- `ip`
- `device_id`
- `hostname`

If any endpoint returns `404`, `500`, times out, or otherwise fails:

- the script still tries every configured endpoint in that run
- the service does not fail just because callbacks failed
- if at least one endpoint succeeds, the IP is stored as delivered
- if no endpoint succeeds, the saved IP is not updated
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
- failed POST request: future minute-based runs continue automatically without the service entering a failed state
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

Choose one of these distribution formats:

- `.tar.gz`: recommended when you want one archive that can be unpacked on many Linux distributions and installed either automatically or manually
- `.deb`: recommended for Debian, Ubuntu, and Raspberry Pi OS when you want package-managed installation and removal

## Tarball Distribution

Build a clean `.tar.gz` archive:

```bash
./build-tar.sh
```

The archive will be created in `dist/`, for example:

```bash
dist/ddns-updater_0.1_linux.tar.gz
```

Extract it:

```bash
tar -xzf dist/ddns-updater_0.1_linux.tar.gz
cd DDNS-Updater
```

From the extracted tarball, end users have both install options:

- automatic install: `sudo ./install.sh`
- manual install: follow the manual installation steps below

Automatic installation:

```bash
sudo ./install.sh
```

This will:

- install `curl` if needed
- copy the updater to `/usr/local/lib/ddns-updater/ddns-updater.sh`
- create `/usr/local/bin/ddns-updater`
- install the `systemd` unit files into `/etc/systemd/system/`
- install `ddns-updater.env` to `/etc/default/ddns-updater` if that file does not already exist
- enable and start `ddns-updater.timer`

Manual installation:

1. Install `curl`
2. Copy `ddns-updater.sh` to `/usr/local/lib/ddns-updater/ddns-updater.sh`
3. Make it executable
4. Create a symlink: `sudo ln -sf /usr/local/lib/ddns-updater/ddns-updater.sh /usr/local/bin/ddns-updater`
5. Copy `ddns-updater.service` to `/etc/systemd/system/ddns-updater.service`
6. Copy `ddns-updater.timer` to `/etc/systemd/system/ddns-updater.timer`
7. Copy `ddns-updater.env` to `/etc/default/ddns-updater`
8. Create `/var/lib/ddns-updater`
9. Run `sudo systemctl daemon-reload`
10. Run `sudo systemctl enable --now ddns-updater.timer`

## Debian Package

Build a `.deb` package:

```bash
./build-deb.sh
```

The package will be created in `dist/`, for example:

```bash
dist/ddns-updater_0.1_all.deb
```

Install it on Debian, Ubuntu, or Raspberry Pi OS:

```bash
sudo apt install ./dist/ddns-updater_0.1_all.deb
```

Or with `dpkg`:

```bash
sudo dpkg -i ./dist/ddns-updater_0.1_all.deb
sudo apt-get install -f
```

What the package does:

- installs the command to `/usr/bin/ddns-updater`
- installs the script to `/usr/lib/ddns-updater/ddns-updater.sh`
- installs the config to `/etc/default/ddns-updater`
- installs the unit files to `/lib/systemd/system/`
- enables and starts `ddns-updater.timer` in `postinst`

Remove the package:

```bash
sudo apt remove ddns-updater
```

Purge config and state too:

```bash
sudo apt purge ddns-updater
```

## Installed Paths

Tarball install paths:

- command: `/usr/local/bin/ddns-updater`
- executable script: `/usr/local/lib/ddns-updater/ddns-updater.sh`
- config file: `/etc/default/ddns-updater`
- service unit: `/etc/systemd/system/ddns-updater.service`
- timer unit: `/etc/systemd/system/ddns-updater.timer`
- state file: `/var/lib/ddns-updater/last_ip.txt`

Debian package install paths:

- command: `/usr/bin/ddns-updater`
- executable script: `/usr/lib/ddns-updater/ddns-updater.sh`
- config file: `/etc/default/ddns-updater`
- service unit: `/lib/systemd/system/ddns-updater.service`
- timer unit: `/lib/systemd/system/ddns-updater.timer`
- state file: `/var/lib/ddns-updater/last_ip.txt`

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
ddns-updater run
```

CLI commands:

```bash
ddns-updater help
ddns-updater version
ddns-updater list-urls
ddns-updater test-connection
ddns-updater test-endpoints
ddns-updater doctor
sudo ddns-updater add-url https://example.com/api/update-gate-ip
sudo ddns-updater remove-url https://example.com/api/update-gate-ip
```

What they do:

- `ddns-updater run`: normal updater run; also what the `systemd` service executes
- `ddns-updater list-urls`: prints the currently configured endpoint URLs from the active config file
- `ddns-updater add-url`: adds one endpoint URL to `EXTERNAL_SERVER_URLS`
- `ddns-updater remove-url`: removes one endpoint URL from `EXTERNAL_SERVER_URLS`
- `ddns-updater test-connection`: verifies `curl` and public IP lookup only
- `ddns-updater test-endpoints`: sends a real test POST to each configured endpoint but does not update the local state file
- `ddns-updater doctor`: checks whether the installed command, config, timer, and service are present and active
- `ddns-updater version`: prints the installed version

For installed systems, use `sudo` with `add-url` and `remove-url` because they modify `/etc/default/ddns-updater`.

## Uninstall

```bash
sudo ./uninstall.sh
```

This removes:

- `/usr/local/bin/ddns-updater`
- `/usr/local/lib/ddns-updater`
- `/etc/systemd/system/ddns-updater.service`
- `/etc/systemd/system/ddns-updater.timer`
- `/etc/default/ddns-updater`
- `/var/lib/ddns-updater`

## Notes

- Do not commit real production secrets unless you intentionally want them distributed with the package.
- If you change `SAVE_FILE`, keep it under `/var/lib/ddns-updater` unless you also adjust the service sandbox settings.
