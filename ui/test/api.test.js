import test, { beforeEach } from "node:test";
import assert from "node:assert/strict";

globalThis.window = { ksu: { exec: null } };
const { runAction, runRead } = await import("../src/api.js");
const commands = [];

beforeEach(() => {
  commands.length = 0;
  window.ksu.exec = (command, _options, callback) => {
    commands.push(command);
    window[callback](0, "ok", "");
  };
});

test("read calls only use named WebUI commands", async () => {
  await runRead("status");
  await runRead("networks");
  assert.match(commands[0], /netbird\.service webui status$/);
  assert.match(commands[1], /netbird\.service webui networks$/);
  assert.throws(() => runRead("arbitrary command"), /Unsupported WebUI action/);
});

test("action arguments are shell-quoted and arbitrary actions are rejected", async () => {
  await runAction("webui networks-append", ["x'; echo unsafe"]);
  assert.match(commands[0], /'x'\\''; echo unsafe'$/);
  assert.throws(() => runAction("webui status"), /Unsupported WebUI action/);
});

test("the bridge exposes only fixed reads and approved actions", async () => {
  const reads = [
    ["status", "webui status"], ["version", "webui version"],
    ["networks", "webui networks"], ["forwarding", "webui forwarding"],
    ["state", "webui state"], ["profiles", "webui profile-list"]
  ];
  for (const [action] of reads) await runRead(action);
  for (const [, suffix] of reads) assert.ok(commands.some((command) => command.endsWith(suffix)));

  const actions = ["refresh", "route", "webui networks-select", "webui networks-append", "webui networks-deselect", "webui health", "webui profile-select"];
  for (const action of actions) await runAction(action, ["safe-value"]);
  for (const action of actions) assert.ok(commands.some((command) => command.includes(` ${action} 'safe-value'`)));
  for (const action of ["start", "stop", "restart", "webui start", "arbitrary shell"]) {
    assert.throws(() => runAction(action), /Unsupported WebUI action/);
  }
});
