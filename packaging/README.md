# Debian Packaging Assets

These files are the runtime inputs for the local `.deb` builder.

## Build Locally

From the repository root:

```sh
./scripts/build-deb.sh 0.1.0
```

The package is written to `dist/broadcast-box_0.1.0_amd64.deb`, then uploaded
to the GitHub release tagged `v0.1.0`.

Build prerequisites are `go`, `npm`, `dpkg-deb`, `git`, and the GitHub CLI
(`gh`). The script runs `npm ci`, `npm run build`, `go test ./...`, builds a
Linux binary for the selected Debian architecture, and creates or updates the
matching GitHub release. Authenticate first with `gh auth login`.

To build the package without uploading it, set `SKIP_RELEASE_UPLOAD=1`:

```sh
SKIP_RELEASE_UPLOAD=1 ./scripts/build-deb.sh 0.1.0
```

The release tag defaults to `v<version>`. To use a different tag, set
`RELEASE_TAG`.

## Installed Layout

- `/usr/bin/broadcast-box`: Go backend binary
- `/usr/lib/broadcast-box/web/build`: built Vite frontend assets
- `/usr/lib/broadcast-box/update-nat-ip.sh`: Dynamic DNS NAT refresh helper
- `/usr/lib/broadcast-box/wait-for-address.sh`: startup guard that waits for an interface address
- `/etc/broadcast-box/broadcast-box.env`: administrator-owned config
- `/etc/broadcast-box/nat.env`: generated NAT IP config
- `/lib/systemd/system/broadcast-box.service`: main service
- `/lib/systemd/system/broadcast-box-nat-refresh.service`: one-shot NAT refresh
- `/lib/systemd/system/broadcast-box-nat-refresh.timer`: periodic NAT refresh

## YARP And UDP

YARP should reverse proxy the HTTP side to `HTTP_ADDRESS`, usually
`http://broadcast-box-lxc:8080`.

WebRTC media still needs a direct UDP port forward to the LXC:

```text
UDP 50000 -> Broadcast Box LXC:50000
```

Keep the external and internal UDP ports the same. The app advertises the UDP
port from `UDP_MUX_PORT`; it does not know about router port translation.

## After Install

If the server only needs LAN access, start it normally:

```sh
sudo systemctl start broadcast-box
```

If internet clients need to reach WebRTC through a Dynamic DNS hostname, set
`NAT_1_TO_1_HOST` before starting the server, run the one-shot NAT refresh, then
start Broadcast Box:

```sh
sudo nano /etc/broadcast-box/broadcast-box.env
sudo systemctl start broadcast-box-nat-refresh.service
cat /etc/broadcast-box/nat.env
sudo systemctl start broadcast-box
```

The `cat` command is only a verification step. It should show the generated
`NAT_1_TO_1_IP` that Broadcast Box will read when it starts. If you change
`broadcast-box.env` or regenerate `nat.env` after Broadcast Box is already
running, restart the server:

```sh
sudo systemctl restart broadcast-box
```

## Dynamic DNS NAT Refresh

Set `NAT_1_TO_1_HOST` in `/etc/broadcast-box/broadcast-box.env`:

```env
UDP_MUX_PORT=50000
NAT_1_TO_1_HOST=stream.example.com
```

The timer resolves the hostname every minute. When the A record changes, it
writes `/etc/broadcast-box/nat.env` with:

```env
NAT_1_TO_1_IP=<resolved-ip>
```

Then it restarts `broadcast-box.service`, because systemd environment files are
read when the process starts.

## Startup Address Wait

Broadcast Box builds its ICE UDP mux during startup, and the mux binds one UDP
socket per interface address that exists at that moment. There is no wildcard
mode. If the interface has no address yet, the mux comes up with no listeners,
reports no error, and never re-checks.

That is easy to hit in an LXC that boots with DHCP: the service starts before
the lease lands. Broadcast Box then serves HTTP normally, so nothing looks
broken, but it holds no UDP port for WebRTC media and every WHIP session is
accepted and then dies on ICE - with no indication in the HTTP layer that
anything is wrong. The service only recovers when it is restarted, which is why
it can look like a firewall or port-forwarding problem.

The packaged unit runs `wait-for-address.sh` as `ExecStartPre`, installed to
`/usr/lib/broadcast-box/wait-for-address.sh`. It waits (60 seconds by default)
for a usable non-loopback address - any IPv4, or a non-link-local IPv6 - and
fails the start if none appears. A link-local IPv6 address does not count on its
own, because it would let the IPv6 side bind while the IPv4 side stays dead.

Tune or disable the wait with `BROADCAST_BOX_ADDRESS_WAIT_SECONDS` in
`/etc/broadcast-box/broadcast-box.env`, for example a value of `0` to skip it
entirely. If the `ip` command is unavailable, the helper logs a notice and lets
the service start rather than blocking it.
