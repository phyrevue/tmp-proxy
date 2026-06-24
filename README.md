# tmp-proxy

Temporary local proxy launcher powered by Xray-Core.

It accepts common share links:

- `vless://...`
- `ss://...`
- `trojan://...`
- `vmess://...`

It starts local listeners:

- SOCKS: `127.0.0.1:10808`
- HTTP: `127.0.0.1:10809`

## Quick Start

```bash
chmod +x tmp-proxy.sh
./tmp-proxy.sh start 'vless://...'
```

Run without arguments to open the control menu:

```bash
./tmp-proxy.sh
```

Use the proxy in the same shell:

```bash
export ALL_PROXY=socks5h://127.0.0.1:10808
export HTTPS_PROXY=http://127.0.0.1:10809
export HTTP_PROXY=http://127.0.0.1:10809
```

Or print these commands:

```bash
./tmp-proxy.sh env
```

Test:

```bash
./tmp-proxy.sh test
```

Stop:

```bash
./tmp-proxy.sh stop
```

## Control Commands

```bash
./tmp-proxy.sh menu
./tmp-proxy.sh restart-last
./tmp-proxy.sh status
./tmp-proxy.sh logs
./tmp-proxy.sh set-ports 10808 10809
```

The menu can start a new link, restart the last saved link, stop the proxy, test connectivity, show proxy environment variables, view logs, optionally update Xray, and change local listener ports.

The full release package already includes `xray`, so domestic servers usually do not need to use the Xray update option. That option is only for repairing a missing binary or downloading a newer Xray release from GitHub.

## Release Package

The release archive is a full offline package. It includes:

- `tmp-proxy.sh`
- `README.md`
- `xray`
- `geoip.dat`
- `geosite.dat`

On a server that cannot access GitHub, copy the full archive to the server and run:

```bash
tar -xzf tmp-proxy-v1.0.2-linux-amd64-full.tar.gz
cd tmp-proxy
./tmp-proxy.sh
eval "$(./tmp-proxy.sh env)"
```

## Notes

If a server cannot access GitHub, use the full release package. It already includes `xray`, `geoip.dat`, and `geosite.dat`, so you can extract it and start the proxy directly.

The `install-xray` command and the Xray update menu option are optional. They require GitHub access and are only useful when you want to update or repair the local Xray binary.

The script needs Bash, Python 3, and the local `xray` binary included in the release package.
