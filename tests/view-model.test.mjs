import assert from "node:assert/strict";
import fs from "node:fs";
import { formatBytes, parseNetworks, statusModel } from "../webroot/view-model.mjs";

const status = JSON.parse(fs.readFileSync(new URL("./fixtures/netbird-status.json", import.meta.url)));
const model = statusModel(status);
assert.deepEqual(
  {
    daemon: model.daemon,
    management: model.management,
    signal: model.signal,
    total: model.total,
    connected: model.connected,
    peers: model.peers.length
  },
  { daemon: "running", management: "Connected", signal: "Disconnected", total: 8, connected: 4, peers: 2 }
);
assert.equal(statusModel({ daemonStatus: "Disconnected", peers: { total: 0, connected: 0, details: [] } }).daemon, "stopped");

const networks = parseNetworks(fs.readFileSync(new URL("./fixtures/netbird-networks.txt", import.meta.url), "utf8"));
assert.deepEqual(networks, [
  { id: "network-route-srvs-site", network: "192.168.100.0/24", domains: "-", resolvedIps: "-", status: "Selected" },
  { id: ".nb.test", network: "-", domains: ".nb.test", resolvedIps: "[srv.nb.test.]: 192.168.100.10", status: "Not Selected" },
  { id: "internal-mixed", network: "10.10.0.0/16", domains: "grafana.internal, .lab.internal", resolvedIps: "[grafana.internal]: 10.10.0.20 [db.lab.internal]: 10.10.0.21", status: "Selected" }
]);
assert.equal(/^selected$/i.test(networks[0].status.trim()), true);
assert.equal(/^selected$/i.test(networks[1].status.trim()), false);
assert.equal(formatBytes(0), "0 B");
assert.equal(formatBytes(1024), "1 KB");
assert.equal(formatBytes(1024 * 1024), "1 MB");
assert.equal(formatBytes(5 * 1024 * 1024 * 1024), "5 GB");
assert.equal(formatBytes("-"), "-");

console.log("view-model fixtures: passed");
