// Pure helpers for the coreySean.warp-vpn panel: parsing the backend's
// key=value block and deriving everything the UI shows from it. No QML types
// and no side effects, so the panel stays declarative.

// Operation modes, in the order the panel lists them. `id` is exactly what
// `warp-cli mode` accepts.
const MODES = [
  { id: "warp", label: "WARP", description: "VPN tunnel with Cloudflare DNS" },
  { id: "warp+doh", label: "WARP + DoH", description: "VPN tunnel, DNS over HTTPS" },
  { id: "warp+dot", label: "WARP + DoT", description: "VPN tunnel, DNS over TLS" },
  { id: "doh", label: "DoH", description: "DNS over HTTPS only, no tunnel" },
  { id: "dot", label: "DoT", description: "DNS over TLS only, no tunnel" },
  { id: "proxy", label: "Proxy", description: "Local SOCKS5 proxy" },
  { id: "tunnel_only", label: "Tunnel only", description: "VPN tunnel, keep system DNS" }
];

// Parse `key=value` lines. Later duplicates win, missing keys stay undefined
// so callers can tell "absent" from "empty".
function parseBlock(text) {
  const out = {};
  const lines = String(text || "").split("\n");
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    if (line === "") continue;
    const eq = line.indexOf("=");
    if (eq <= 0) continue;
    out[line.slice(0, eq)] = line.slice(eq + 1);
  }
  return out;
}

function isConnected(state) {
  return String(state || "") === "Connected";
}

function isUnavailable(state) {
  return String(state || "") === "Unavailable";
}

// Turn a parsed block into the panel's view state. A block that reports
// ok=0 keeps whatever `state` it carried and surfaces `error`, so a failure
// shows up in the panel instead of silently reading as "disconnected".
function parseStatus(text) {
  const block = parseBlock(text);
  const ok = block.ok !== "0";
  return {
    state: block.state || "Unknown",
    mode: block.mode || "warp",
    detail: block.detail || "",
    error: ok ? "" : (block.error || "warp-cli failed"),
    available: !isUnavailable(block.state)
  };
}

// Uppercase line under the hero title. The backend already sends a
// human-readable `detail` (reason token, split into words), so this only has
// to name the connection state.
function statusLine(view) {
  if (!view.available) return "UNAVAILABLE";
  if (view.error !== "") return "ERROR";
  if (isConnected(view.state)) return "CONNECTED";
  if (view.state === "Connecting") return "CONNECTING";
  return "DISCONNECTED";
}

// Secondary sentence under the status line, or "" when there is nothing
// useful to add. An absent warp-cli outranks the raw error, because the
// actionable half of that message is "install it", not the raw reason.
function detailLine(view) {
  if (!view.available) return "warp-cli is not installed";
  if (view.error !== "") return view.error;
  if (view.detail === "") return "";
  if (isConnected(view.state)) {
    const d = view.detail.toLowerCase();
    if (d === "network healthy") return "Traffic is routed through Cloudflare";
    return view.detail;
  }
  return view.detail.charAt(0).toUpperCase() + view.detail.slice(1);
}

function modeById(id) {
  const wanted = String(id || "");
  for (let i = 0; i < MODES.length; i++)
    if (MODES[i].id === wanted) return MODES[i];
  return MODES[0];
}

function modeIndex(id) {
  const wanted = String(id || "");
  for (let i = 0; i < MODES.length; i++)
    if (MODES[i].id === wanted) return i;
  return 0;
}

// Bar and hero icons. Codepoints verified against the bar's icon font
// (JetBrainsMono Nerd Font, via `oct-`/`fa-` glyph names):
//   U+F510 oct-shield_check   U+F468 oct-circle_slash
//   U+F06A fa-exclamation_circle   U+F00C fa-check
const ICON = {
  connected: "\u{F510}",   // shield with a check — traffic is tunnelled
  disconnected: "\u{F468}", // circle-slash — tunnel is down
  unavailable: "\u{F06A}",  // exclamation in a circle — warp-cli is gone
  check: "\u{F00C}"         // marks the active mode row
};

// Bar icon. The unavailable mark outranks everything: a panel that cannot
// reach warp-cli should not claim to be connected or disconnected.
function icon(view, busy) {
  if (!view.available) return ICON.unavailable;
  return isConnected(view.state) ? ICON.connected : ICON.disconnected;
}

// One-line bar tooltip.
function tooltip(view) {
  if (!view.available) return "WARP VPN - warp-cli not installed";
  const label = statusLine(view);
  if (label === "ERROR") return "WARP VPN - " + view.error;
  return "WARP VPN - " + label.charAt(0) + label.slice(1).toLowerCase() +
    " (" + modeById(view.mode).label + ")";
}
