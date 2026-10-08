import assert from "node:assert/strict";
import fs from "node:fs";
import { parseNetworks, statusModel } from "../webroot/view-model.mjs";

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
  { id: "K70", network: "0.0.0.0/0, ::/0", status: "Not Selected" },
  { id: "N10", network: "0.0.0.0/0, ::/0", status: "Not Selected" }
]);
assert.equal(/^selected$/i.test(networks[0].status.trim()), false);
assert.equal(/^selected$/i.test("Selected"), true);

console.log("view-model fixtures: passed");
