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
./tmp-proxy.sh
```

Minimal dependencies:

- Bash
- Python 3

The full package includes Xray, but it does not include Bash or Python. On minimal Alpine, install them first:

```bash
apk add --no-cache bash python3
```

Choose menu option 1 for the recommended wizard:

```text
1) 推荐向导：启动/切换代理并选择生效范围
```

The wizard does three things in order:

- Paste a new share link, or press Enter to reuse the last one.
- Start the local Xray proxy.
- Choose where proxy environment variables should take effect.

You can also run the wizard directly:

```bash
./tmp-proxy.sh wizard
```

For one-off usage in the current shell:

```bash
eval "$(./tmp-proxy.sh env)"
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
./tmp-proxy.sh wizard
./tmp-proxy.sh restart-last
./tmp-proxy.sh status
./tmp-proxy.sh logs
./tmp-proxy.sh set-ports 10808 10809
./tmp-proxy.sh system-proxy enable
./tmp-proxy.sh system-proxy disable
./tmp-proxy.sh system-proxy status
./tmp-proxy.sh user-proxy enable
./tmp-proxy.sh user-proxy disable
./tmp-proxy.sh user-proxy status
```

The menu is organized around the common workflow: use option 1 first, then option 5 if you later want to change where proxy variables take effect.

Runtime files are kept in `/tmp/tmp-proxy`. Saved ports and the last successful link are kept in `~/.tmp-proxy`, so they survive a normal reboot.

## Proxy Scopes

tmp-proxy supports three proxy environment scopes from menu option 9.

Root-level system proxy writes `/etc/profile.d/tmp-proxy.sh` and requires root:

```bash
sudo ./tmp-proxy.sh system-proxy enable
source /etc/profile.d/tmp-proxy.sh
```

User-level proxy writes `~/.tmp-proxy/user-proxy.sh` and adds a managed source block to the current user's shell rc file, such as `~/.bashrc` or `~/.zshrc`. It does not require root:

```bash
./tmp-proxy.sh user-proxy enable
source ~/.tmp-proxy/user-proxy.sh
```

Current-shell temporary proxy does not write files:

```bash
eval "$(./tmp-proxy.sh env)"
```

All three scopes use the same generated variables:

```bash
export http_proxy=http://127.0.0.1:10809
export https_proxy=http://127.0.0.1:10809
export HTTP_PROXY=http://127.0.0.1:10809
export HTTPS_PROXY=http://127.0.0.1:10809
export all_proxy=socks5h://127.0.0.1:10808
export ALL_PROXY=socks5h://127.0.0.1:10808
```

Disable root-level proxy:

```bash
sudo ./tmp-proxy.sh system-proxy disable
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY
```

Disable user-level proxy:

```bash
./tmp-proxy.sh user-proxy disable
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY
```

If root-level or user-level proxy is already enabled, changing ports with `set-ports` or menu option 8 automatically rewrites the corresponding profile with the new ports.

Proxy environment profiles only write shell environment variables. They do not start Xray by themselves, so start the proxy first with menu option 1 or `./tmp-proxy.sh start '<link>'`.

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
tar -xzf tmp-proxy-v1.0.6-linux-amd64-full.tar.gz
cd tmp-proxy
./tmp-proxy.sh
eval "$(./tmp-proxy.sh env)"
```

## Notes

If a server cannot access GitHub, use the full release package. It already includes `xray`, `geoip.dat`, and `geosite.dat`, so you can extract it and start the proxy directly.

The `install-xray` command and the Xray update menu option are optional. They require GitHub access and are only useful when you want to update or repair the local Xray binary.

The script needs Bash, Python 3, and the local `xray` binary included in the release package.
