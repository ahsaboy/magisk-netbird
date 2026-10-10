import test from "node:test";
import assert from "node:assert/strict";
import { daemonValue, formatBytes, parseNetworks, statusModel } from "../../webroot/view-model.mjs";

test("daemon states normalize booleans and connection strings", () => {
  assert.equal(daemonValue({ daemonStatus: "running" }), "running");
  assert.equal(daemonValue({ daemonStatus: "offline" }), "stopped");
  assert.equal(daemonValue({ daemonStatus: false }), "stopped");
});

test("status model reads summary and peer connection details", () => {
  const model = statusModel({
    daemonStatus: "running",
    netbirdIp: "100.64.0.2",
    peers: [{ fqdn: "phone.example", netbirdIp: "100.64.0.3", status: "Connected" }]
  });
  assert.equal(model.daemon, "running");
  assert.equal(model.ip, "100.64.0.2");
  assert.equal(model.peers.length, 1);
  assert.equal(model.connected, 1);
});

test("peer model retains connection type and handshake metadata", () => {
  const peer = { fqdn: "relay.example", status: "Connected", connectionType: "Relayed", lastHandshake: "2m ago" };
  const [result] = statusModel({ peers: [peer] }).peers;
  assert.equal(result.connectionType, "Relayed");
  assert.equal(result.lastHandshake, "2m ago");
});

test("network parser handles routes and selection state", () => {
  assert.deepEqual(parseNetworks("- ID: network-1\n  Network: 10.0.0.0/24\n  Status: Selected"), [
    { id: "network-1", network: "10.0.0.0/24", domains: "-", resolvedIps: "-", status: "Selected" }
  ]);
});

test("byte formatter preserves unknown data and formats numeric values", () => {
  assert.equal(formatBytes(1024), "1 KB");
  assert.equal(formatBytes("n/a"), "n/a");
});
