# WARP VPN — Omarchy bar widget

Cloudflare WARP for the Omarchy bar: see whether the tunnel is up, connect and
disconnect, and switch between WARP operation modes.

![WARP VPN panel open from the bar](screenshot.png)

## Features

- Live tunnel state in the bar — shield-with-check when connected,
  circle-slash when not
- **Click the bar icon to open the panel.** That is the only click action;
  connecting and mode selection live inside the panel
- Connect / disconnect from a switch in the panel header
- Switch between the seven operation modes `warp-cli` supports
- Flush the DNS cache and republish NetworkManager's per-link DNS, so a
  tunnel change actually shows up in name resolution
- Shows your local and global IP address at the bottom, plus a badge reporting
  whether Cloudflare saw the lookup arrive over the tunnel
- Reports what `warp-cli` actually said, so a failure shows a reason instead
  of silently reading as "disconnected"
- Polls for changes made outside the panel (a `warp-cli connect` in a
  terminal, the daemon reconnecting on its own)
- Follows your theme: colours, fonts and spacing come from the Omarchy
  component kit, so it matches the built-in panels such as Bluetooth

## Keyboard shortcuts

Inside the panel:

| Key | Action |
| --- | --- |
| `j` / `k` or arrows | move cursor |
| `enter` / `space` | activate the current row |
| `c` | toggle the connection |
| `f` | flush the DNS cache |
| `tab` | switch to the next panel |
| `esc` | close |

## Operation modes

| Mode | What it does |
| --- | --- |
| `warp` | VPN tunnel with Cloudflare DNS |
| `warp+doh` | VPN tunnel, DNS over HTTPS |
| `warp+dot` | VPN tunnel, DNS over TLS |
| `doh` | DNS over HTTPS only, no tunnel |
| `dot` | DNS over TLS only, no tunnel |
| `proxy` | local SOCKS5 proxy |
| `tunnel_only` | VPN tunnel, keep system DNS |

The list is the set `warp-cli mode` accepts; the widget validates against it
locally and never sends an unknown mode.

## Requirements

- `warp-cli` on `PATH`, plus a running `warp-svc` — on Arch:
  `omarchy pkg aur add cloudflare-warp-minimal-bin`
- `jq` and `curl` (both already Omarchy dependencies)

Connecting, disconnecting and changing mode need no privilege: the widget
drives `warp-cli` as your user and the daemon does the privileged work. The
DNS flush is the one exception — it runs under `pkexec` and asks for your
password. See [Flushing DNS](#flushing-dns).

## Install

```bash
omarchy plugin add https://github.com/coreySean/omarchy-warp-vpn.git --enable
```

`--enable` adds it to the bar, prompting for a section (default: right). To
place it later:

```bash
omarchy bar move coreySean.warp-vpn --section right
```

## Configuration

Poll interval, in seconds (default `4`):

```bash
omarchy bar set coreySean.warp-vpn pollIntervalSec 10 --json
```

Lower it for a snappier icon, raise it if you would rather `warp-cli` be
called less often.

Turn the global IP lookup off entirely, if you would rather not send the
request at all:

```bash
omarchy bar set coreySean.warp-vpn showGlobalIp false --json
```

The local address and the tunnel status are unaffected. The badge disappears
with it, since it is read from the same response.

## IP addresses

The bottom of the panel shows the address of the interface your traffic leaves
by (`Local`) and the address the internet sees (`Global`), for both IPv4 and
IPv6. Next to the section header is a badge saying what Cloudflare reported
seeing for the lookup itself:

- **WARP on** — the request that fetched your global address arrived over the
  tunnel. This is measured at the far end rather than self-reported locally, so
  it is actual evidence that traffic is being carried, and that the global
  address you see genuinely is the tunnel's.
- **WARP off** — it did not, so the global address is your real one.

That badge is the fastest way to settle "is WARP actually doing anything",
because the two addresses differ whenever the tunnel is up.

The local address is read from the kernel and costs nothing. The global one
needs a network request, so it is:

- fetched **only while the panel is open**, never on the bar's status poll;
- rate-limited to once per `ipRefreshSec`, and refetched after a connect,
  disconnect or mode change, since that is when it actually moves;
- run in its own process, so a slow lookup can never delay the tunnel status;
- fetched from **Cloudflare's own trace endpoint**, not a third-party
  "what is my IP" site. While WARP is up the request already travels through
  Cloudflare, so it reveals nothing new. While WARP is down it does disclose
  your real egress IP to Cloudflare in the clear — which is why the lookup is
  separately switchable.

## Flushing DNS

Tunnelling changes which resolver answers, and NetworkManager keeps its own
per-link view of that. Flushing the cache alone can leave those link entries
stale, so **Flush DNS cache** does three things:

1. `resolvectl flush-caches`
2. `nmcli general reload dns-full`
3. `nmcli device reapply` on each connected Wi-Fi/Ethernet link (loopback and
   P2P are skipped)

It always runs under `pkexec`, so the Omarchy polkit agent puts a **password
prompt** on screen and the whole refresh happens as one authenticated unit. The
button reads "Waiting for password…" until you answer.

**Once per click, and that is deliberate.** polkit re-prompts internally — a
single authorisation permits several password entries — so a retry loop on top
of that turns one click into a barrage of dialogs. There is exactly one
`pkexec` invocation in the code and no retry. If it cannot get a prompt, that
is reported rather than quietly retried or worked around.

Worth knowing when it does fail: `pkexec` exit `127` is deliberately vague. Per
`pkexec(1)` it covers "not authorized" **and** "authorization could not be
obtained" **and** "an error occurred", so it is not by itself evidence that a
password was wrong. The widget quotes whatever polkit actually said rather than
guessing which case it hit, so the panel shows the real reason. A common cause
of a missing prompt is a stale polkit agent registration after a shell restart;
`omarchy restart shell` re-registers it.

### Why the privileged surface is so narrow

Plugins live in `~/.config/omarchy/plugins/`, which is **user-writable**. So
`pkexec` is never pointed at this repo's own files: that would hand root to
anything able to write there. Instead the widget runs
`pkexec /bin/sh -c '<a fixed literal>'`, with nothing interpolated into the
string and the link list discovered *inside* the root shell. The only thing
running as root is a DNS flush.

## Privacy

The widget shells out to `warp-cli` and reads its output. It stores no
credentials and reads none: WARP keeps your registration, account and device
identity in the root-owned `/var/lib/cloudflare-warp`, and this plugin never
touches it. Nothing about your account is sent anywhere by this code.

The DNS flush asks for your password through polkit, the same prompt Omarchy
already uses for its own privileged helpers. No password is stored, read or
transmitted by this plugin.

The optional global IP lookup contacts `www.cloudflare.com` only — see
[IP addresses](#ip-addresses) for exactly when, and for why that is not a new
disclosure while WARP is up. Turn it off with
`omarchy bar set coreySean.warp-vpn showGlobalIp false --json`.

## How it works

- `warp-actions` — the backend. Calls `warp-cli --json`, normalises the result
  into a small `key=value` block on stdout, and reports failures as data
  (`ok=0` plus `error=...`) rather than as an empty stream.
- `Model.js` — pure parsing and formatting, no QML types.
- `Panel.qml` — the Omarchy `Panel`, `PanelHero`, `PanelKeyCatcher`,
  `CursorSurface` and `Style`/`Color` tokens.

One Quickshell detail worth knowing if you edit this: `Process.stdout` is
`null` on current Quickshell, so every process here captures its output with
an explicit `stdout: StdioCollector`. Without that the panel silently shows
nothing. Also note that saving a file under `~/.config/omarchy/plugins/`
triggers a plugin reload that does *not* recompile the QML — run
`omarchy restart shell` after editing.

## License

MIT
