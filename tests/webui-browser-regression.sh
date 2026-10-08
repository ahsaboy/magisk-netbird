#!/bin/sh
set -eu

port="${WEBUI_TEST_PORT:-4181}"
python -m http.server "$port" --directory webroot >/tmp/netbird-webui-test-server.log 2>&1 &
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null || true' EXIT INT TERM

WEBUI_TEST_PORT="$port" browser-harness <<'PY'
import time

new_tab(f"http://127.0.0.1:{__import__('os').environ.get('WEBUI_TEST_PORT', '4181')}/index.html?browser-test=1")
wait_for_load()
mock = r'''(() => {
  const status = JSON.stringify({
    daemonStatus: "Connected",
    fqdn: "phone.example",
    netbirdIp: "100.64.0.8",
    management: { connected: true },
    signal: { connected: false },
    peers: { total: 2, connected: 1, details: [
      { fqdn: "peer-a", netbirdIp: "100.64.0.9", status: "Connected", connectionType: "P2P", transferReceived: 1536, transferSent: 5242880 }
    ] }
  });
  const networks = "Available Networks:\n\n  - ID: .nb.test\n    Domains: .nb.test\n    Status: Not Selected\n    Resolved IPs: [srv.nb.test.]: 192.168.100.10\n";
  window.ksu = { exec(command, options, callback) {
    window.__webuiCalls = (window.__webuiCalls || []).concat(command);
    let output = "";
    if (command.includes("webui status")) output = status;
    else if (command.includes("webui networks")) output = networks;
    else if (command.includes("webui forwarding")) output = "No forwarding rules available.\n";
    else if (command.includes("webui state")) output = "Stored states:\n";
    else if (command.includes("webui version")) output = "0.80.0\n";
    else if (command.includes("webui profile-list")) output = "Profiles:\n";
    setTimeout(() => window[callback](0, output, ""), 0);
  }, toast() {} };
})()'''
cdp("Page.addScriptToEvaluateOnNewDocument", source=mock)
goto_url(f"http://127.0.0.1:{__import__('os').environ.get('WEBUI_TEST_PORT', '4181')}/index.html?browser-test=2")
wait_for_load()
cdp("Emulation.setDeviceMetricsOverride", width=390, height=844, deviceScaleFactor=1, mobile=True)
time.sleep(0.3)
js("document.querySelector('#language-select').value='en'; document.querySelector('#language-select').dispatchEvent(new Event('change'))")
time.sleep(0.3)
print(js("JSON.stringify({width:innerWidth, overflow:document.documentElement.scrollWidth>innerWidth, debug:document.querySelectorAll('[data-debug]').length, option:document.querySelector('#language-select option[value=\\\"zh\\\"]').textContent, aria:document.querySelector('#language-select').getAttribute('aria-label'), nav:document.querySelector('.tabs').getAttribute('aria-label'), loading:document.querySelector('#daemon-meta').textContent})"))
js("document.querySelector('[data-tab=\\\"peers\\\"]').click(); document.querySelector('[data-tab=\\\"overview\\\"]').click(); document.querySelector('[data-tab=\\\"peers\\\"]').click()")
time.sleep(0.3)
print(js("JSON.stringify({active:document.querySelector('.view.active')?.dataset.view, statusCalls:(window.__webuiCalls||[]).filter(x=>x.includes('webui status')).length, cooldown:document.querySelector('#peers-refresh-state')?.textContent, traffic:document.querySelector('#peer-list')?.textContent.includes('1.5 KB') && document.querySelector('#peer-list')?.textContent.includes('5 MB')})"))
js("document.querySelector('[data-tab=\\\"networks\\\"]').click()")
time.sleep(0.3)
print(js("JSON.stringify({active:document.querySelector('.view.active')?.dataset.view, domains:document.querySelector('#network-list')?.textContent.includes('Domains'), resolved:document.querySelector('#network-list')?.textContent.includes('Resolved IPs'), overflow:document.documentElement.scrollWidth>innerWidth})"))
PY
