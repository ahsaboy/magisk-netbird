import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { flushPromises, mount } from "@vue/test-utils";
import { nextTick } from "vue";
import App from "../src/App.vue";

const commands = [];
let wrapper;

beforeEach(() => {
  commands.length = 0;
  localStorage.clear();
  document.documentElement.removeAttribute("data-theme");
  localStorage.setItem("netbird.language", "zh");
  window.ksu = {
    exec(command, _options, callbackName) {
      commands.push(command);
      let stdout = "";
      if (command.endsWith("webui status")) {
        stdout = JSON.stringify({
          daemonStatus: "running",
          netbirdIp: "100.64.0.2",
          peers: [{
            fqdn: "relay.example", netbirdIp: "100.64.0.3", status: "Connected",
            connectionType: "P2P", latency: "10 ms", transferReceived: 1024,
            transferSent: 2048, lastHandshake: "1 min ago"
          }, {
            fqdn: "offline.example", netbirdIp: "100.64.0.4", status: "Disconnected",
            connectionType: "Relayed", latency: "42 ms", transferReceived: 4096,
            transferSent: 8192, lastHandshake: "5 min ago"
          }]
        });
      } else if (command.endsWith("webui networks")) {
        stdout = "- ID: network-a\n  Network: 10.10.0.0/24\n  Status: Not selected";
      } else if (command.endsWith("webui forwarding")) {
        stdout = "tcp 0.0.0.0:8080 -> 100.64.0.2:80";
      } else if (command.includes("webui health")) {
        stdout = JSON.stringify({ ok: true });
      } else if (command.endsWith("webui version")) {
        stdout = "NetBird 0.80.0";
      }
      window[callbackName](0, stdout, "");
    }
  };
});

afterEach(() => {
  wrapper?.unmount();
  wrapper = undefined;
  document.body.querySelectorAll(".dialog-overlay").forEach((element) => element.remove());
  vi.restoreAllMocks();
});

async function mountApp() {
  wrapper = mount(App, { attachTo: document.body });
  await flushPromises();
  return wrapper;
}

async function openTab(id) {
  await wrapper.get(`[data-tab="${id}"]`).trigger("click");
  await nextTick();
  await new Promise((resolve) => window.requestAnimationFrame(resolve));
  await flushPromises();
}

function findButton(label, root = wrapper) {
  return root.findAll("button").find((button) => button.text().includes(label));
}

describe("mobile WebUI", () => {
  it("renders the local NetBird wordmark and four mobile destinations", async () => {
    await mountApp();
    expect(wrapper.get(".brand-mark svg").attributes("viewBox")).toBe("0 0 133 23");
    expect(wrapper.text()).toContain("运行中");
    expect(wrapper.text()).toContain("100.64.0.2");
    expect(wrapper.findAll("[data-tab]")).toHaveLength(4);
    expect(wrapper.get('[data-tab="overview"]').attributes("aria-current")).toBe("page");
  });

  it("switches destinations with navigation clicks and horizontal swipes", async () => {
    await mountApp();
    await wrapper.get('[data-tab="peers"]').trigger("click");
    await nextTick();
    expect(wrapper.get('[data-tab="peers"]').attributes("aria-current")).toBe("page");
    expect(wrapper.get(".view-stage").exists()).toBe(true);

    const page = wrapper.find(".page-scroll");
    await page.trigger("touchstart", { touches: [{ clientX: 260, clientY: 220 }] });
    await page.trigger("touchend", { changedTouches: [{ clientX: 70, clientY: 224 }] });
    await nextTick();
    expect(wrapper.get('[data-tab="networks"]').attributes("aria-current")).toBe("page");

    await page.trigger("touchstart", { touches: [{ clientX: 70, clientY: 220 }] });
    await page.trigger("touchend", { changedTouches: [{ clientX: 260, clientY: 224 }] });
    await nextTick();
    expect(wrapper.get('[data-tab="peers"]').attributes("aria-current")).toBe("page");
  });

  it("shows the selected destination before a slow bridge read completes", async () => {
    let pendingCallback;
    window.ksu.exec = (command, _options, callbackName) => {
      commands.push(command);
      pendingCallback = () => window[callbackName](0, "", "");
    };
    await mountApp();
    await wrapper.get('[data-tab="networks"]').trigger("click");
    await nextTick();
    expect(wrapper.get('[data-tab="networks"]').attributes("aria-current")).toBe("page");
    expect(wrapper.text()).toContain("Networks / Routes");
    expect(wrapper.text()).toContain("读取中");
    await new Promise((resolve) => window.requestAnimationFrame(resolve));
    expect(commands.some((command) => command.endsWith("webui networks"))).toBe(true);
    pendingCallback?.();
  });

  it("shows the empty Peer state when the daemon has no peers", async () => {
    window.ksu.exec = (_command, _options, callbackName) => {
      window[callbackName](0, JSON.stringify({ daemonStatus: "running", peers: [] }), "");
    };
    await mountApp();
    await openTab("peers");
    expect(wrapper.text()).toContain("暂无对端");
  });

  it("shows bridge errors without hiding the service status panel", async () => {
    window.ksu.exec = (_command, _options, callbackName) => {
      window[callbackName](2, "", "bridge unavailable");
    };
    await mountApp();
    expect(wrapper.text()).toContain("检查失败");
    expect(wrapper.text()).toContain("bridge unavailable");
    expect(wrapper.find(".status-banner").exists()).toBe(true);
  });

  it("renders Peer connection type, handshake, latency, and transfer data", async () => {
    await mountApp();
    await openTab("peers");
    expect(wrapper.text()).toContain("P2P");
    expect(wrapper.text()).toContain("1 min ago");
    expect(wrapper.text()).toContain("10 ms");
    expect(wrapper.text()).toContain("1 KB");
    expect(wrapper.text()).toContain("2 KB");
  });

  it("filters Peers by connection state and sorts by latency", async () => {
    await mountApp();
    await openTab("peers");
    const names = () => [...wrapper.element.querySelectorAll(".peer-ident strong")].map((node) => node.textContent);
    expect(names()).toEqual(["offline.example", "relay.example"]);

    await wrapper.find(".peer-filter-trigger").trigger("click");
    await flushPromises();
    let menu = document.body.querySelector('[role="menu"]');
    [...menu.querySelectorAll('[role="menuitemradio"]')].find((item) => item.textContent.includes("仅已连接")).click();
    await flushPromises();
    expect(names()).toEqual(["relay.example"]);

    await wrapper.find(".peer-filter-trigger").trigger("click");
    await flushPromises();
    menu = document.body.querySelector('[role="menu"]');
    [...menu.querySelectorAll('[role="menuitemradio"]')].find((item) => item.textContent.includes("仅未连接")).click();
    await flushPromises();
    expect(names()).toEqual(["offline.example"]);

    await wrapper.find(".peer-filter-trigger").trigger("click");
    await flushPromises();
    menu = document.body.querySelector('[role="menu"]');
    [...menu.querySelectorAll('[role="menuitemradio"]')].find((item) => item.textContent.includes("全部 Peer")).click();
    await flushPromises();
    await wrapper.find(".peer-filter-trigger").trigger("click");
    await flushPromises();
    menu = document.body.querySelector('[role="menu"]');
    [...menu.querySelectorAll('[role="menuitemradio"]')].find((item) => item.textContent.includes("延迟由低到高")).click();
    await flushPromises();
    expect(names()).toEqual(["relay.example", "offline.example"]);

    await wrapper.find(".peer-filter-trigger").trigger("click");
    await flushPromises();
    menu = document.body.querySelector('[role="menu"]');
    [...menu.querySelectorAll('[role="menuitemradio"]')].find((item) => item.textContent.includes("流量由高到低")).click();
    await flushPromises();
    expect(names()).toEqual(["offline.example", "relay.example"]);
  });

  it("loads Networks and invokes the append action for one route", async () => {
    await mountApp();
    await openTab("networks");
    expect(wrapper.text()).toContain("network-a");
    expect(wrapper.text()).toContain("0.0.0.0:8080");
    await findButton("全部启用").trigger("click");
    await flushPromises();
    expect(commands.some((command) => command.endsWith("webui networks-select 'all'"))).toBe(true);
    await wrapper.find(".network-action").trigger("click");
    await flushPromises();
    expect(commands.some((command) => command.endsWith("webui networks-append 'network-a'"))).toBe(true);
  });

  it("keeps destructive network deselection behind confirmation", async () => {
    await mountApp();
    await openTab("networks");
    await findButton("全部停用").trigger("click");
    await flushPromises();
    expect(document.body.querySelector('[role="alertdialog"]')).toBeTruthy();
    expect(commands.some((command) => command.includes("webui networks-deselect"))).toBe(false);
    document.body.querySelector(".dialog-footer button:last-child").click();
    await flushPromises();
    expect(commands.some((command) => command.endsWith("webui networks-deselect 'all'"))).toBe(true);
  });

  it("checks health, reads diagnostics, and confirms Profile changes", async () => {
    await mountApp();
    await openTab("diagnostics");
    expect(wrapper.text()).toContain("健康检查");
    await findButton("检查").trigger("click");
    await flushPromises();
    expect(wrapper.text()).toContain("通过");

    await findButton("读取版本").trigger("click");
    await flushPromises();
    expect(wrapper.text()).toContain("NetBird 0.80.0");

    await wrapper.get("#profile-name").setValue("work-profile");
    await findButton("切换 Profile").trigger("click");
    await flushPromises();
    const dialog = document.body.querySelector('[role="alertdialog"]');
    expect(dialog).toBeTruthy();
    expect(dialog.getAttribute("aria-modal")).toBe("true");
    expect(document.getElementById(dialog.getAttribute("aria-labelledby"))).toBeTruthy();
    expect(document.getElementById(dialog.getAttribute("aria-describedby"))).toBeTruthy();
    expect(commands.some((command) => command.includes("webui profile-select"))).toBe(false);
    document.body.querySelector(".dialog-footer button:first-child").click();
    await flushPromises();
    expect(commands.some((command) => command.includes("webui profile-select"))).toBe(false);

    await findButton("切换 Profile").trigger("click");
    await flushPromises();
    document.body.querySelector(".dialog-footer button:last-child").click();
    await flushPromises();
    expect(commands.some((command) => command.endsWith("webui profile-select 'work-profile'"))).toBe(true);
  });

  it("closes confirmations with Escape without running the protected action", async () => {
    await mountApp();
    await findButton("刷新运行时规则").trigger("click");
    await flushPromises();
    const dialog = document.body.querySelector('[role="alertdialog"]');
    expect(dialog).toBeTruthy();
    dialog.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }));
    await flushPromises();
    expect(document.body.querySelector('[role="alertdialog"]')).toBeNull();
    expect(commands.some((command) => command.endsWith("netbird.service refresh"))).toBe(false);
  });

  it("requires confirmation before refreshing runtime rules", async () => {
    await mountApp();
    await findButton("刷新运行时规则").trigger("click");
    await flushPromises();
    expect(commands.some((command) => command.endsWith("netbird.service refresh"))).toBe(false);
    document.body.querySelector(".dialog-footer button:last-child").click();
    await flushPromises();
    expect(commands.some((command) => command.endsWith("netbird.service refresh"))).toBe(true);
  });

  it("offers four persisted theme presets and restores the saved selection", async () => {
    await mountApp();
    await wrapper.find(".theme-menu-trigger").trigger("click");
    await flushPromises();
    const menu = document.body.querySelector('[role="menu"]');
    expect(menu).toBeTruthy();
    expect(menu.textContent).toContain("NetBird 绿意");
    expect(menu.textContent).toContain("海洋蓝");
    expect(menu.textContent).toContain("琥珀信号");
    expect(menu.textContent).toContain("玫瑰链路");
    const amber = [...menu.querySelectorAll('[role="menuitemradio"]')].find((item) => item.textContent.includes("琥珀信号"));
    amber.click();
    await flushPromises();
    expect(document.documentElement.dataset.theme).toBe("amber");
    expect(localStorage.getItem("netbird.theme")).toBe("amber");

    wrapper.unmount();
    wrapper = mount(App, { attachTo: document.body });
    await flushPromises();
    expect(document.documentElement.dataset.theme).toBe("amber");
  });

  it("selects language from its dropdown without changing the active view", async () => {
    await mountApp();
    await wrapper.find(".language-menu-trigger").trigger("click");
    await flushPromises();
    const menu = document.body.querySelector('[role="menu"]');
    const english = [...menu.querySelectorAll('[role="menuitemradio"]')].find((item) => item.textContent.includes("English"));
    expect(english).toBeTruthy();
    english.click();
    await nextTick();
    expect(wrapper.text()).toContain("Console");
    expect(wrapper.get('[data-tab="overview"]').attributes("aria-current")).toBe("page");
    expect(localStorage.getItem("netbird.language")).toBe("en");

    await wrapper.find(".theme-menu-trigger").trigger("click");
    await flushPromises();
    const themeMenu = document.body.querySelector('[role="menu"]');
    expect(themeMenu.textContent).toContain("Ocean Blue");
    expect(themeMenu.textContent).not.toContain("海洋蓝");
  });
});
