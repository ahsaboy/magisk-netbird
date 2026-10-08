export function firstValue(object, keys) {
  for (const key of keys) {
    if (object && object[key] !== undefined && object[key] !== null && object[key] !== "") return object[key];
  }
  return "-";
}

export function connectionValue(value) {
  if (value && typeof value === "object") {
    if (typeof value.connected === "boolean") return value.connected ? "Connected" : "Disconnected";
    return firstValue(value, ["state", "status", "value"]);
  }
  if (typeof value === "boolean") return value ? "Connected" : "Disconnected";
  return value ?? "-";
}

export function daemonValue(data) {
  const value = firstValue(data, ["daemonStatus", "daemonState", "daemon"]);
  const normalized = String(value && typeof value === "object" ? firstValue(value, ["state", "status", "value"]) : value).toLowerCase();
  if (["stopped", "disconnected", "offline", "down"].some((item) => normalized.includes(item))) return "stopped";
  if (["connected", "running", "ready", "started", "online"].some((item) => normalized.includes(item))) return "running";
  if (value === true) return "running";
  if (value === false || value === "-") return "stopped";
  return "error";
}

export function collectPeers(value, output = [], seen = new Set()) {
  if (!value || typeof value !== "object" || seen.has(value)) return output;
  seen.add(value);
  if (Array.isArray(value)) value.forEach((item) => collectPeers(item, output, seen));
  else {
    if ((value.status || value.state) && (value.fqdn || value.netbirdIp)) output.push(value);
    Object.values(value).forEach((item) => collectPeers(item, output, seen));
  }
  return output;
}

export function statusModel(data) {
  const peers = collectPeers(data);
  const peerSummary = data?.peers && !Array.isArray(data.peers) ? data.peers : {};
  const total = firstValue(peerSummary, ["total", "count"]);
  const connected = firstValue(peerSummary, ["connected", "connectedCount"]);
  const fallbackConnected = peers.filter((peer) => String(firstValue(peer, ["status", "state"])).toLowerCase().includes("connected")).length;
  return {
    daemon: daemonValue(data),
    fqdn: firstValue(data, ["fqdn", "hostname"]),
    ip: firstValue(data, ["netbirdIp", "netbirdIPv4", "netbirdIpv4"]),
    ipv6: firstValue(data, ["netbirdIpV6", "netbirdIPv6", "netbirdIpv6"]),
    management: connectionValue(firstValue(data, ["management", "managementState"])),
    signal: connectionValue(firstValue(data, ["signal", "signalState"])),
    interfaceType: firstValue(data, ["interfaceType", "interface"]),
    port: firstValue(data, ["wireguardPort", "wireguard_port"]),
    version: firstValue(data, ["daemonVersion", "version"]),
    total: total !== "-" ? total : (peers.length || "-"),
    connected: connected !== "-" ? connected : (peers.length ? fallbackConnected : "-"),
    peers
  };
}

export function parseNetworks(text) {
  const networks = [];
  let current = null;
  for (const rawLine of String(text ?? "").split(/\r?\n/)) {
    const line = rawLine.trim();
    const idMatch = line.match(/^-\s+ID:\s*(\S+)/i);
    if (idMatch) {
      if (current) networks.push(current);
      current = { id: idMatch[1], network: "-", status: "-" };
      continue;
    }
    if (!current) continue;
    const networkMatch = line.match(/^Network:\s*(.+)$/i);
    if (networkMatch) current.network = networkMatch[1].trim();
    const statusMatch = line.match(/^Status:\s*(.+)$/i);
    if (statusMatch) current.status = statusMatch[1].trim();
  }
  if (current) networks.push(current);
  return networks;
}
