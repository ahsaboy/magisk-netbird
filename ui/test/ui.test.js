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
  // tab data loads after the ~240ms slide transition (switch first, load after)
  await new Promise((resolve) => window.setTimeout(resolve, 260));
  await flushPromises();
}

function findButton(label, root = wrapper) {
  return root.findAll("button").find((button) => button.text().includes(label));
}

describe("mobile WebUI", () => {
  it("renders the local NetBird wordmark and five mobile destinations", async () => {
    await mountApp();
    expect(wrapper.get(".brand-mark svg").attributes("viewBox")).toBe("0 0 40 23");
    expect(wrapper.text()).toContain("运行中");
    expect(wrapper.text()).toContain("100.64.0.2");
    expect(wrapper.findAll("[data-tab]")).toHaveLength(5);
    expect(wrapper.get('[data-tab="overview"]').attributes("aria-current")).toBe("page");
  });

  it("keeps the app shell height stable when the WebView resizes for the keyboard", async () => {
    const originalHeight = window.innerHeight;
    const heightDescriptor = Object.getOwnPropertyDescriptor(window, "innerHeight");
    await mountApp();
    const baselineHeight = document.documentElement.style.getPropertyValue("--app-shell-height");
    expect(baselineHeight).toBe(`${originalHeight}px`);

    Object.defineProperty(window, "innerHeight", { configurable: true, value: originalHeight - 280 });
    window.dispatchEvent(new Event("resize"));
    expect(document.documentElement.style.getPropertyValue("--app-shell-height")).toBe(baselineHeight);

    if (heightDescriptor) Object.defineProperty(window, "innerHeight", heightDescriptor);
    else delete window.innerHeight;
    window.dispatchEvent(new Event("resize"));
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
    // the view switched instantly; the read fires after the slide transition
    await new Promise((resolve) => window.setTimeout(resolve, 260));
    await flushPromises();
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
    expect(wrapper.find(".peer-avatar").exists()).toBe(false);
    expect(wrapper.findAll(".peer-ident strong").map((node) => node.text())).toContain("relay.example");
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
    expect(wrapper.text()).toContain("10.10.0.0/24");
    await findButton("全部启用").trigger("click");
    await flushPromises();
    expect(commands.some((command) => command.endsWith("webui networks-select 'all'"))).toBe(true);
    await wrapper.find(".network-action").trigger("click");
    await flushPromises();
    expect(commands.some((command) => command.endsWith("webui networks-append 'network-a'"))).toBe(true);
  });

  it("shows connection controls without daemon start/stop actions", async () => {
    await mountApp();
    expect(findButton("断开网络")).toBeTruthy();
    expect(findButton("重连网络")).toBeTruthy();
    expect(findButton("停止守护进程")).toBeUndefined();
    expect(findButton("启动守护进程")).toBeUndefined();
  });

  it("loads automation rules and renders the history destination", async () => {
    window.ksu.exec = (command, _options, callbackName) => {
      commands.push(command);
      const stdout = command.endsWith("automation-list")
        ? "auto-ab12cd34\tNight route\tdisconnect\t1\t10\tall\tdaily:22:00"
        : command.endsWith("automation-log") ? "v=1 ts=2026-10-26T20:30:00+08:00 rule=auto-ab12cd34 action=disconnect event=success key=auto-ab12cd34:2026-10-26T20:30" : JSON.stringify({ daemonStatus: "Connected", peers: [] });
      window[callbackName](0, stdout, "");
    };
    await mountApp();
    await openTab("automation");
    expect(wrapper.text()).toContain("Night route");
    expect(wrapper.text()).toContain("执行记录");
    expect(commands.some((command) => command.endsWith("webui automation-list"))).toBe(true);
    expect(commands.some((command) => command.endsWith("webui automation-log"))).toBe(true);
  });

  it("shows ten automation log entries at a time and loads the next batch", async () => {
    const logs = Array.from({ length: 12 }, (_, index) => {
      const minute = String(index).padStart(2, "0");
      return `v=1 ts=2026-10-26T20:${minute}:00+08:00 rule=auto-ab12cd34 action=disconnect event=success key=auto-ab12cd34:2026-10-26T20:${minute}`;
    }).join("\n");
    window.ksu.exec = (command, _options, callbackName) => {
      commands.push(command);
      const stdout = command.endsWith("automation-list")
        ? "auto-ab12cd34\tNight route\tdisconnect\t1\t10\tall\tdaily:22:00"
        : command.endsWith("automation-log") ? logs : JSON.stringify({ daemonStatus: "Connected", peers: [] });
      window[callbackName](0, stdout, "");
    };
    await mountApp();
    await openTab("automation");

    const history = wrapper.findAll(".section-card").find((section) => section.text().includes("执行记录"));
    expect(history.findAll(".automation-log-row")).toHaveLength(10);
    expect(history.find("button.automation-log-more").text()).toBe("加载更多");
    await history.find("button.automation-log-more").trigger("click");
    expect(history.findAll(".automation-log-row")).toHaveLength(12);
    expect(history.find("button.automation-log-more").exists()).toBe(false);
  });

  it("creates automation rules disabled without exposing a rule ID field", async () => {
    await mountApp();
    await openTab("automation");
    const nameInput = wrapper.find('.automation-form input[aria-label="Rule name"]');
    expect(nameInput.exists()).toBe(true);
    await nameInput.setValue("Office schedule");
    await wrapper.find(".automation-form").trigger("submit");
    await flushPromises();
    expect(commands.some((command) => command.endsWith("webui automation-save '' 'Office schedule' 'disconnect' '0' '10' 'all' 'daily:22:00'"))).toBe(true);
    expect(wrapper.find('.automation-form input[aria-label="Rule ID"]').exists()).toBe(false);
  });

  it("saves repeated schedule conditions with the selected matching mode", async () => {
    await mountApp();
    await openTab("automation");
    await wrapper.find('.automation-form input[aria-label="Rule name"]').setValue("Work hours");
    await findButton("添加条件").trigger("click");
    const conditionRows = wrapper.findAll(".automation-condition-row");
    await conditionRows[1].find("select").setValue("weekly");
    await conditionRows[1].find('select[aria-label="Weekday"]').setValue("5");
    await conditionRows[1].find('input[aria-label="Scheduled time"]').setValue("06:30");
    await wrapper.find('select[aria-label="Condition mode"]').setValue("any");
    await wrapper.find(".automation-form").trigger("submit");
    await flushPromises();
    expect(commands.some((command) => command.endsWith("webui automation-save '' 'Work hours' 'disconnect' '0' '10' 'any' 'daily:22:00' 'weekly:5@06:30'"))).toBe(true);
  });

  it("shows a persistent progress toast while a confirmed action is pending", async () => {
    let completeRefresh;
    window.ksu.exec = (command, _options, callbackName) => {
      commands.push(command);
      if (command.endsWith("netbird.service refresh")) {
        completeRefresh = () => window[callbackName](0, "", "");
      } else if (command.endsWith("webui status")) {
        window[callbackName](0, JSON.stringify({ daemonStatus: "running", peers: [] }), "");
      } else {
        window[callbackName](0, "", "");
      }
    };
    await mountApp();
    await findButton("刷新运行时规则").trigger("click");
    document.body.querySelector(".dialog-footer button:last-child").click();
    await flushPromises();

    expect(wrapper.find(".notice-toast").text()).toContain("操作中");
    expect(wrapper.find(".notice-spinner").exists()).toBe(true);
    expect(wrapper.find(".notice-spinner").classes()).toContain("spinner-motion");
    expect(findButton("刷新系统路由").element.disabled).toBe(true);

    completeRefresh();
    await flushPromises();
    expect(wrapper.find(".notice-toast").text()).toContain("操作已完成");
    expect(wrapper.find(".notice-spinner").exists()).toBe(false);
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

  it("disconnects the network from the power card after confirmation", async () => {
    await mountApp();
    await findButton("断开网络").trigger("click");
    await flushPromises();
    expect(commands.some((command) => command.endsWith("webui down"))).toBe(false);
    const dialog = document.body.querySelector('[role="alertdialog"]');
    expect(dialog).toBeTruthy();
    expect(dialog.textContent).toContain("断开 NetBird 网络");
    dialog.querySelector(".dialog-footer button:last-child").click();
    await flushPromises();
    expect(document.body.querySelector('[role="alertdialog"]')).toBeNull();
    expect(wrapper.find(".notice-toast").text()).toContain("正在断开网络");
    expect(commands.some((command) => command.endsWith("webui down"))).toBe(false);
    await new Promise((resolve) => window.requestAnimationFrame(() => window.requestAnimationFrame(resolve)));
    await flushPromises();
    expect(commands.some((command) => command.endsWith("webui down"))).toBe(true);
  });

  it("keeps daemon controls out of the WebUI after disconnecting", async () => {
    window.ksu.exec = (command, _options, callbackName) => {
      commands.push(command);
      const stdout = command.endsWith("webui status")
        ? JSON.stringify({ daemonStatus: "Disconnected", peers: [] })
        : "";
      window[callbackName](0, stdout, "");
    };
    await mountApp();
    expect(wrapper.text()).toContain("未连接");
    expect(findButton("停止守护进程")).toBeUndefined();
    expect(findButton("启动守护进程")).toBeUndefined();
    expect(findButton("断开网络").element.disabled).toBe(true);
    expect(findButton("重连网络").element.disabled).toBe(false);

    await openTab("networks");
    expect(wrapper.text()).toContain("未连接网络");
    expect(wrapper.text()).not.toContain("全部启用");
    expect(commands.some((command) => command.endsWith("webui networks"))).toBe(false);
  });

  it("drops cached networks and shows a stopped placeholder after the daemon stops", async () => {
    let stopped = false;
    window.ksu.exec = (command, _options, callbackName) => {
      commands.push(command);
      if (command.endsWith("webui status")) {
        if (stopped) return window[callbackName](1, "{\"daemon\":\"stopped\"}", "");
        return window[callbackName](0, JSON.stringify({ daemonStatus: "Connected", peers: [] }), "");
      }
      if (command.endsWith("webui networks")) {
        return window[callbackName](0, "- ID: network-a\n  Network: 10.10.0.0/24\n  Status: Not selected", "");
      }
      window[callbackName](0, "", "");
    };
    await mountApp();
    await openTab("networks");
    expect(wrapper.text()).toContain("network-a");
    const networksReadsBeforeStop = commands.filter((command) => command.endsWith("webui networks")).length;

    stopped = true;
    await openTab("peers");
    // force a status reload (the tab-switch read respects the 5s cooldown)
    const page = wrapper.find(".page-scroll");
    await page.trigger("touchstart", { touches: [{ clientX: 150, clientY: 200 }] });
    await page.trigger("touchend", { changedTouches: [{ clientX: 150, clientY: 340 }] });
    await flushPromises();
    expect(wrapper.text()).toContain("已停止");
    await openTab("networks");
    expect(wrapper.text()).toContain("守护进程已停止");
    expect(wrapper.text()).not.toContain("network-a");
    expect(commands.filter((command) => command.endsWith("webui networks")).length).toBe(networksReadsBeforeStop);
  });

  it("keeps the newest diagnostic response when requests finish out of order", async () => {
    const pending = [];
    window.ksu.exec = (command, _options, callbackName) => {
      commands.push(command);
      if (command.endsWith("webui status")) {
        window[callbackName](0, JSON.stringify({ daemonStatus: "running", peers: [] }), "");
      } else {
        pending.push({ command, complete: (stdout) => window[callbackName](0, stdout, "") });
      }
    };
    await mountApp();
    await openTab("diagnostics");
    await findButton("读取版本").trigger("click");
    await findButton("读取状态").trigger("click");
    expect(pending).toHaveLength(2);

    pending.find((request) => request.command.endsWith("webui state")).complete("newest state result");
    await flushPromises();
    pending.find((request) => request.command.endsWith("webui version")).complete("stale version result");
    await flushPromises();
    expect(wrapper.text()).toContain("newest state result");
    expect(wrapper.text()).not.toContain("stale version result");
  });

  it("shows a section error and a loading state while retrying", async () => {
    let networksAttempts = 0;
    let completeRetry;
    window.ksu.exec = (command, _options, callbackName) => {
      commands.push(command);
      if (command.endsWith("webui networks")) {
        networksAttempts += 1;
        if (networksAttempts === 1) {
          window[callbackName](2, "", "networks unavailable");
        } else {
          completeRetry = (errno, stdout, stderr) => window[callbackName](errno, stdout, stderr);
        }
      } else {
        window[callbackName](0, "", "");
      }
    };
    await mountApp();
    await openTab("networks");
    expect(wrapper.text()).toContain("networks unavailable");

    const networksSection = wrapper.findAll(".section-card").find((section) => section.text().includes("Networks / Routes"));
    await findButton("重试", networksSection).trigger("click");
    await nextTick();
    expect(wrapper.text()).toContain("读取中");
    completeRetry(0, "- ID: network-b\n  Network: 10.20.0.0/24\n  Status: Not selected", "");
    await flushPromises();
    expect(wrapper.text()).toContain("network-b");
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
