import { exec } from "./kernelsu.js";

const SERVICE = "/data/adb/netbird/scripts/netbird.service";
const READ_COMMANDS = Object.freeze({
  status: "webui status",
  version: "webui version",
  networks: "webui networks",
  state: "webui state",
  profiles: "webui profile-list",
  automation: "webui automation-list",
  automationLog: "webui automation-log"
});

function quote(value) {
  return `'${String(value).replace(/'/g, "'\\''")}'`;
}

export function runRead(action) {
  const command = READ_COMMANDS[action];
  if (!command) throw new Error("Unsupported WebUI action");
  return exec(`${SERVICE} ${command}`);
}

export function runAction(action, args = []) {
  const allowed = new Set([
    "refresh", "route", "webui networks-append", "webui networks-select",
    "webui networks-deselect", "webui health", "webui profile-select",
    "webui up", "webui down", "webui automation-save", "webui automation-delete"
  ]);
  if (!allowed.has(action)) throw new Error("Unsupported WebUI action");
  return exec([SERVICE, action, ...args.map(quote)].join(" "));
}
