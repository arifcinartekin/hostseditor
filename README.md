# Hosts Editor for macOS

A small native macOS app for editing `/etc/hosts`, in the spirit of the PowerToys Hosts File Editor on Windows.

![Hosts Editor](docs/screenshot.png)

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/arifcinartekin/hostseditor/main/install.sh | bash
```

This downloads the latest release (a universal build for Apple Silicon and Intel), installs it to `/Applications`, and opens it. If no release can be downloaded, the script builds the app from source instead, which needs the Xcode Command Line Tools (`xcode-select --install`).

You need macOS 14 (Sonoma) or newer.

## Features

- Every entry in a table: an on/off switch, the address, its hosts and a comment
- Switch an entry off without deleting it (it's saved as a `#` comment line)
- Add (⌘N) and edit (double-click) entries. IPv4/IPv6 addresses and host names are checked as you type
- Right-click an entry to duplicate it, ping it, move it up or down, copy its line or delete it. Select several entries to enable, disable or ping them all at once
- Search and filter by All / Active / Inactive / Duplicates
- Entries that share a host name with another entry get a warning icon
- **Port forwarding:** send `http://myapp.test` to `127.0.0.1:8080` (see below)
- Edit the comment block at the top of the file ("Additional Lines")
- Lines you don't touch, including comments, blank lines and spacing, are written back exactly as they were
- The app notices when another program changes the file and offers to reload it
- If you quit with unsaved changes, it asks whether to save them

## Port forwarding

`/etc/hosts` maps names to IP addresses only, so it can't point a name at a port. Hosts Editor adds this on top: type a port in **Forward to port** when you add or edit an entry.

| Forward to port | Result |
| --- | --- |
| `8080` | `http://domain.mydomain` → `127.0.0.1:8080` |
| `9090, 443:9443` | port 80 → `127.0.0.1:9090` and port 443 → `127.0.0.1:9443` |

How it works:

1. Each forwarded entry gets its own loopback address (`127.0.0.2`, `127.0.0.3`, …), and the hosts line points the name at it.
2. A pf rule redirects that address's ports to your target, for example `127.0.0.2:80 → 127.0.0.1:8080`. The rules go into the `com.apple/hostseditor` anchor, which the stock `/etc/pf.conf` already loads, so `/etc/pf.conf` is never edited.
3. A LaunchDaemon (`/Library/LaunchDaemons/local.hostseditor.forwarding.plist`) sets the loopback addresses and rules up again after every reboot, so forwarding keeps working when the app isn't running.

Notes:

- Forwarding works for any TCP service, not only HTTP. The target has to be a `127.x.x.x` address on your Mac.
- Switching an entry off also turns its forwarding off.
- If an entry's forwarding icon turns orange and the status bar says "Port forwarding not active", it's saved but its loopback address isn't set up. Press **Save**, or restart your Mac, to set it up again.
- For HTTPS on 443, the service on the target port has to handle TLS itself.
- Its config is in `/Library/Application Support/HostsEditor/`. Removing the last forwarded entry deletes the folder and the LaunchDaemon.

## How saving works

`/etc/hosts` is owned by root. When you press **Save** (⌘S), macOS shows its own administrator password prompt. The app then:

1. copies the original file to `/etc/hosts.hostseditor.bak` (on the first save after each launch),
2. writes the new contents into `/etc/hosts`, keeping its owner and permissions,
3. if port forwarding changed, updates its config, loopback addresses and pf rules,
4. flushes the DNS cache (`dscacheutil -flushcache` and `killall -HUP mDNSResponder`).

The app never stores or sees your password.

## Build from source

```bash
git clone https://github.com/arifcinartekin/hostseditor.git
cd hostseditor
./build.sh             # builds build/Hosts Editor.app (universal)
./build.sh --install   # also copies it to /Applications
```

Run `ARCHS=arm64 ./build.sh` for a faster build that targets your Mac's architecture only. No Xcode project is needed: the build runs `swiftc` from the Command Line Tools.

## Uninstall

Delete your forwarded entries in the app and save first; that removes the pf rules, loopback addresses and LaunchDaemon. Then:

```bash
rm -rf "/Applications/Hosts Editor.app"
```
