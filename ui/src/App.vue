<script setup>
import { computed, nextTick, onMounted, onUnmounted, ref, watch } from "vue";
import {
  Activity, ArrowDownToLine, ArrowUpFromLine, Check, ChevronRight,
  CircleAlert, Clock3, Globe2, Languages, ListFilter, LoaderCircle, Network, Palette, Plus, Power, RefreshCw,
  Route, ShieldCheck, Signal, Stethoscope, Users, Wifi, WifiOff, X
} from "@lucide/vue";
import {
  DropdownMenuContent, DropdownMenuItemIndicator, DropdownMenuPortal,
  DropdownMenuRadioGroup, DropdownMenuRadioItem, DropdownMenuRoot,
  DropdownMenuTrigger
} from "reka-ui";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { runAction, runRead } from "./api.js";
import { firstValue, formatBytes, parseNetworks, statusModel } from "./view-model.mjs";
import { messages } from "./i18n.js";

const savedLanguage = localStorage.getItem("netbird.language");
const systemLanguage = String(navigator.language || "").toLowerCase();
const language = ref(savedLanguage || (systemLanguage.startsWith("en") ? "en" : "zh"));
const themeIds = ["green", "ocean", "amber", "rose"];
const theme = ref(themeIds.includes(localStorage.getItem("netbird.theme")) ? localStorage.getItem("netbird.theme") : "green");
const progressMessages = {
  operationInProgress: { zh: "操作中…", en: "Working…" },
  reconnectingNetwork: { zh: "正在重连网络…", en: "Reconnecting…" },
  disconnectingNetwork: { zh: "正在断开网络…", en: "Disconnecting…" }
};
const t = (key) => progressMessages[key]?.[language.value] || messages[language.value][key] || messages.zh[key] || key;
const themeChoices = computed(() => [
  { id: "green", label: t("themeGreen"), color: "#277a5d" },
  { id: "ocean", label: t("themeOcean"), color: "#3475a8" },
  { id: "amber", label: t("themeAmber"), color: "#a95d29" },
  { id: "rose", label: t("themeRose"), color: "#b14e68" }
]);
const navItems = computed(() => [
  { id: "overview", label: t("overview"), icon: Globe2 },
  { id: "peers", label: t("peers"), icon: Users },
  { id: "networks", label: t("networks"), icon: Network },
  { id: "diagnostics", label: t("diagnostics"), icon: Stethoscope },
  { id: "automation", label: t("automation"), icon: Clock3 }
]);
const peerFilter = ref("all");
const peerSort = ref("name");
const peerItems = computed(() => {
  const rows = model.value.peers.filter((peer) => {
    const status = String(firstValue(peer, ["status", "state"])).toLowerCase();
    const connected = status.includes("connected") && !status.includes("disconnected") || status === "online";
    return peerFilter.value === "all" || (peerFilter.value === "connected" ? connected : !connected);
  });
  const metric = (value) => {
    const number = Number.parseFloat(String(value ?? "").replace(/,/g, ""));
    return Number.isFinite(number) ? number : Number.POSITIVE_INFINITY;
  };
  rows.sort((a, b) => {
    const byName = String(firstValue(a, ["fqdn", "name"])).localeCompare(String(firstValue(b, ["fqdn", "name"])));
    if (peerSort.value === "latency") return metric(firstValue(a, ["latencyMs", "latency"])) - metric(firstValue(b, ["latencyMs", "latency"])) || byName;
    if (peerSort.value === "traffic") {
      const traffic = metric(firstValue(b, ["transferReceived", "rx"])) + metric(firstValue(b, ["transferSent", "tx"])) - metric(firstValue(a, ["transferReceived", "rx"])) - metric(firstValue(a, ["transferSent", "tx"]));
      return traffic || byName;
    }
    return byName;
  });
  return rows;
});
const pageOrder = ["overview", "peers", "networks", "diagnostics", "automation"];
const active = ref("overview");
const pageTransition = ref("page-slide-forward");
const busy = ref(false);
const statusLoading = ref(true);
const networksLoaded = ref(false);
const refreshedAt = ref("");
const statusError = ref("");
const notice = ref("");
const noticeType = ref("success");
let noticeTimer = 0;
const lastLoaded = new Map();
const model = ref({ daemon: "error", connection: "-", fqdn: "-", ip: "-", ipv6: "-", management: "-", signal: "-", interfaceType: "-", port: "-", version: "-", total: "-", connected: "-", peers: [] });
const networkItems = ref([]);
const networksError = ref("");
const diagnosticItems = ref([]);
const diagnosticLoading = ref("");
const profileName = ref("");
const health = ref({ live: "", ready: "", startup: "" });
const automationRules = ref([]);
const automationLogs = ref([]);
const automationForm = ref({ id: "", name: "", action: "disconnect", conditions: [{ type: "daily", value: "22:00", weekday: 1 }], mode: "all", enabled: false, priority: 10 });
const automationError = ref("");
const automationLoading = ref(false);
const automationFilterRule = ref("all");
const automationFilterAction = ref("all");
const automationFilterEvent = ref("all");
const automationLogPageSize = 10;
const automationLogLimit = ref(automationLogPageSize);
const visibleAutomationLogs = computed(() => automationLogs.value.filter((entry) =>
  (automationFilterRule.value === "all" || entry.rule === automationFilterRule.value) &&
  (automationFilterAction.value === "all" || entry.action === automationFilterAction.value) &&
  (automationFilterEvent.value === "all" || entry.event === automationFilterEvent.value)
));
const displayedAutomationLogs = computed(() => visibleAutomationLogs.value.slice(0, automationLogLimit.value));
watch([automationFilterRule, automationFilterAction, automationFilterEvent], () => {
  automationLogLimit.value = automationLogPageSize;
});
const confirmOpen = ref(false);
const confirmMessage = ref("");
const pendingAction = ref(null);
const pendingProgressMessage = ref("");
const pendingPaintBeforeAction = ref(false);
let touchStartX = 0;
let touchStartY = 0;
let diagnosticRequestId = 0;
const CONNECTION_LABELS = { connected: "connected", disconnected: "disconnected", connecting: "connecting", "needs-login": "needsLogin" };
const statusLabel = computed(() => {
  if (statusLoading.value) return t("checking");
  if (model.value.daemon !== "running") return t(model.value.daemon === "stopped" ? "stopped" : "failed");
  return t(CONNECTION_LABELS[model.value.connection] || "running");
});
const statusTone = computed(() => {
  if (model.value.daemon !== "running") return model.value.daemon;
  return model.value.connection === "connected" ? "connected" : "stopped";
});
const connectedCount = computed(() => model.value.connected !== "-" ? model.value.connected : model.value.peers.filter((peer) => String(firstValue(peer, ["status", "state"])).toLowerCase().includes("connected")).length);

function connectionText(value) {
  const normalized = String(value ?? "").toLowerCase();
  if (normalized.includes("disconnected") || normalized.includes("offline")) return t("disconnected");
  if (normalized.includes("connected") || normalized === "online") return t("connected");
  if (normalized.includes("connecting")) return t("connecting");
  return value ?? "-";
}
function parseJson(result) { try { return JSON.parse(result.stdout); } catch { return null; } }
function tell(message, type = "success") {
  window.clearTimeout(noticeTimer);
  notice.value = message;
  noticeType.value = type;
  if (type !== "progress") {
    noticeTimer = window.setTimeout(() => { notice.value = ""; }, 4000);
  }
}
function throwOnError(result) {
  if (result.errno !== 0) throw new Error(result.stderr || result.stdout || `Command failed (${result.errno})`);
  return result;
}
async function loadStatus() {
  statusLoading.value = true;
  try {
    const result = await runRead("status");
    const data = parseJson(result);
    model.value = data ? statusModel(data) : { ...model.value, daemon: result.errno === 1 ? "stopped" : "error" };
    refreshedAt.value = new Date().toLocaleTimeString();
    // Bridge failures surface inside the banner (in-page, not a toast).
    statusError.value = result.errno !== 0 && model.value.daemon === "error"
      ? (result.stderr || result.stdout || "").trim()
      : "";
    // A stopped daemon cannot serve reads; drop dependent caches so a view
    // never shows rows from before the stop (even inside the cooldown).
    if (model.value.daemon === "stopped") {
      networkItems.value = [];
      networksLoaded.value = false;
      networksError.value = "";
    }
    return result;
  } finally { statusLoading.value = false; }
}
const inFlight = new Set();
async function load(action, force = false) {
  // One shell per action: a double-tapped retry/refresh must not spawn a
  // second identical root command while the first is still running.
  if (inFlight.has(action)) return false;
  // A stopped daemon can only fail reads; show the stopped placeholder and
  // drop cached rows instead of firing a doomed command. A running daemon
  // that is not connected cannot list networks either — same treatment.
  if (action === "networks" &&
      (model.value.daemon === "stopped" ||
        ["disconnected", "needs-login", "connecting"].includes(model.value.connection))) {
    networkItems.value = [];
    networksLoaded.value = true;
    networksError.value = "";
    return false;
  }
  const now = Date.now();
  // Silent cooldown for implicit loads (tab switches, prefetch); explicit
  // refreshes pass force=true and bypass it.
  if (!force && now - (lastLoaded.get(action) || 0) < 5000) return false;
  inFlight.add(action);
  lastLoaded.set(action, now);
  const isDiagnostic = ["version", "state", "profiles"].includes(action);
  const requestId = isDiagnostic ? ++diagnosticRequestId : 0;
  if (isDiagnostic) diagnosticLoading.value = action;
  if (action === "networks") { networksLoaded.value = false; networksError.value = ""; }
  try {
    if (action === "status") await loadStatus();
    else {
      const result = throwOnError(await runRead(action));
      if (isDiagnostic && requestId !== diagnosticRequestId) return false;
      if (action === "networks") { networkItems.value = parseNetworks(result.stdout); networksLoaded.value = true; }
      else if (action === "version") showDiagnostic(result.stdout || t("versionUnavailable"));
      else if (action === "state") showDiagnostic(result.stdout || t("noState"));
      else if (action === "profiles") showDiagnostic(result.stdout || t("noProfiles"));
    }
    return true;
  } catch (error) {
    if (isDiagnostic && requestId !== diagnosticRequestId) return false;
    // Implicit reads report in-page, never via toast; toasts are reserved
    // for explicit switch/confirm actions.
    if (action === "networks") { networksLoaded.value = true; networksError.value = String(error.message).replace(/^Error:\s*/i, ""); }
    else if (isDiagnostic) showDiagnostic(error.message);
    return false;
  } finally {
    inFlight.delete(action);
    if (isDiagnostic && requestId === diagnosticRequestId) diagnosticLoading.value = "";
  }
}
function parseLines(value, emptyLabel) {
  const lines = String(value || "").split(/\r?\n/).map((line) => line.trim()).filter((line) => line && !/^[-=]+$/.test(line));
  if (!lines.length || (lines.length === 1 && /no .* available/i.test(lines[0]))) return [emptyLabel];
  return lines.map((line) => line.replace(/^[-*]\s*/, ""));
}
function parseScheduleCondition(schedule) {
  const [type, value] = schedule.includes(":") ? [schedule.slice(0, schedule.indexOf(":")), schedule.slice(schedule.indexOf(":") + 1)] : ["daily", "22:00"];
  if (type === "weekly") return { type, weekday: Number(value.slice(0, value.indexOf("@")) || 1), value: value.slice(value.indexOf("@") + 1) };
  return { type, weekday: 1, value };
}
function parseAutomationRules(output) {
  return String(output || "").split(/\r?\n/).filter(Boolean).map((line) => {
    const [id, name, action, enabled, priority, mode, conditionList] = line.split("\t");
    const conditions = conditionList.split(",").map(parseScheduleCondition);
    return { id, name, action, enabled: enabled === "1", priority: Number(priority), mode, conditions, schedule: conditions.map((condition) => `${condition.type} ${condition.value}`).join(" + ") };
  });
}
function parseAutomationLog(output) {
  return String(output || "").split(/\r?\n/).filter(Boolean).map((line) => Object.fromEntries(line.split(/\s+/).map((field) => { const i = field.indexOf("="); return [field.slice(0, i), field.slice(i + 1)]; })));
}
function automationSchedule(condition) {
  if (condition.type === "once") return `once:${condition.value}`;
  if (condition.type === "weekly") return `weekly:${condition.weekday || 1}@${condition.value}`;
  return `${condition.type}:${condition.value}`;
}
function localDateTimeValue() {
  const local = new Date(Date.now() - new Date().getTimezoneOffset() * 60000).toISOString();
  return `${local.slice(0, 10)}T22:00`;
}
function newAutomationCondition() { return { type: "daily", value: "22:00", weekday: 1 }; }
function resetAutomationForm() {
  automationForm.value = { id: "", name: "", action: "disconnect", conditions: [newAutomationCondition()], mode: "all", enabled: false, priority: 10 };
}
function addAutomationCondition() {
  if (automationForm.value.conditions.length < 8) automationForm.value.conditions.push(newAutomationCondition());
}
function removeAutomationCondition(index) {
  if (automationForm.value.conditions.length > 1) automationForm.value.conditions.splice(index, 1);
}
function scheduleChanged(condition) {
  if (condition.type === "once") condition.value = localDateTimeValue();
  else if (!/^([01]\d|2[0-3]):[0-5]\d$/.test(condition.value)) condition.value = "22:00";
}
async function loadAutomation() {
  automationLoading.value = true;
  automationError.value = "";
  try {
    const [rulesResult, logResult] = await Promise.all([runRead("automation"), runRead("automationLog")]);
    throwOnError(rulesResult);
    throwOnError(logResult);
    automationRules.value = parseAutomationRules(rulesResult.stdout);
    automationLogs.value = parseAutomationLog(logResult.stdout).reverse();
    automationLogLimit.value = automationLogPageSize;
  } catch (error) { automationError.value = error.message; }
  finally { automationLoading.value = false; }
}
async function saveAutomation() {
  const form = automationForm.value;
  const validConditions = form.conditions.length > 0 && form.conditions.length <= 8 && form.conditions.every((condition) => {
    const validValue = condition.type === "once"
      ? /^\d{4}-\d{2}-\d{2}T([01]\d|2[0-3]):[0-5]\d$/.test(condition.value)
      : /^([01]\d|2[0-3]):[0-5]\d$/.test(condition.value);
    return validValue && ["once", "daily", "weekdays", "weekly"].includes(condition.type);
  });
  if (!form.name.trim() || form.name.length > 48 || !validConditions || !["all", "any"].includes(form.mode) || !Number.isInteger(Number(form.priority)) || form.priority < 0 || form.priority > 99) {
    automationError.value = t("automationInvalid");
    return;
  }
  automationLoading.value = true;
  automationError.value = "";
  try {
    const args = [form.id, form.name.trim(), form.action, form.enabled ? "1" : "0", String(form.priority), form.mode, ...form.conditions.map(automationSchedule)];
    throwOnError(await runAction("webui automation-save", args));
    resetAutomationForm();
    await loadAutomation();
  } catch (error) { automationError.value = error.message; }
  finally { automationLoading.value = false; }
}
function automationRuleName(id) {
  return automationRules.value.find((rule) => rule.id === id)?.name || id;
}
function editAutomation(rule) {
  automationForm.value = { ...rule, conditions: rule.conditions.map((condition) => ({ ...condition })) };
}
function deleteAutomation(rule) {
  return confirmAction(t("confirmDeleteRule"), async () => {
    automationLoading.value = true;
    try {
      throwOnError(await runAction("webui automation-delete", [rule.id]));
      await loadAutomation();
    } catch (error) { automationError.value = error.message; }
    finally { automationLoading.value = false; }
  });
}
function showDiagnostic(value) { diagnosticItems.value = parseLines(value, t("noData")); }
function onTabChange(name) {
  if (name === active.value) return;
  const currentIndex = pageOrder.indexOf(active.value);
  const nextIndex = pageOrder.indexOf(name);
  pageTransition.value = nextIndex >= currentIndex ? "page-slide-forward" : "page-slide-backward";
  active.value = name;
  const page = document.querySelector(".page-scroll");
  if (page) page.scrollTop = 0;
  // Switch first, load after: the incoming view already renders its loading
  // placeholder, and firing the root-command bridge during the slide
  // transition janks the animation. Wait for the ~220ms transition to finish.
  window.setTimeout(() => {
    if (active.value !== name) return;
    if (name === "peers") load("status");
    if (name === "networks") load("networks");
    if (name === "automation") loadAutomation();
  }, 240);
}
async function waitForPaint() {
  await nextTick();
  await new Promise((resolve) => window.requestAnimationFrame(() => window.requestAnimationFrame(resolve)));
}
async function withBusy(action, progressMessage = t("operationInProgress"), paintBeforeAction = false) {
  busy.value = true;
  tell(progressMessage, "progress");
  if (paintBeforeAction) await waitForPaint();
  else await nextTick();
  try {
    await action();
    if (noticeType.value === "progress") tell(t("operationDone"));
  } catch (error) { tell(error.message, "fail"); }
  finally { busy.value = false; }
}
function confirmAction(message, action, progressMessage, paintBeforeAction = false) {
  confirmMessage.value = message;
  pendingAction.value = action;
  pendingProgressMessage.value = progressMessage || t("operationInProgress");
  pendingPaintBeforeAction.value = paintBeforeAction;
  confirmOpen.value = true;
}
async function approveConfirmation() {
  const action = pendingAction.value;
  const progressMessage = pendingProgressMessage.value;
  const paintBeforeAction = pendingPaintBeforeAction.value;
  pendingAction.value = null;
  pendingProgressMessage.value = "";
  pendingPaintBeforeAction.value = false;
  confirmOpen.value = false;
  if (action) await withBusy(action, progressMessage, paintBeforeAction);
}
async function refreshData() {
  await load(active.value === "networks" ? "networks" : "status", true);
}
function runRuntimeAction(action, message) {
  return confirmAction(message, async () => { throwOnError(await runAction(action)); await load("status", true); tell(t("operationDone")); });
}
// Daemon lifecycle polls: start/stop run detached server-side (nohup) because
// the WebView may kill long shells; watch the status banner until it flips.
const DAEMON_POLL_INTERVAL_MS = 2000;
const DAEMON_POLL_MAX_TRIES = 15;
async function waitForDaemon(running) {
  for (let attempt = 0; attempt < DAEMON_POLL_MAX_TRIES; attempt++) {
    await new Promise((resolve) => window.setTimeout(resolve, DAEMON_POLL_INTERVAL_MS));
    await load("status", true);
    if (running === (model.value.daemon === "running")) return true;
  }
  return false;
}
function connectionAction(action, message) {
  return confirmAction(message, async () => {
    const result = throwOnError(await runAction(action));
    if (parseJson(result)?.started) {
      // The daemon was dead and got started detached on demand; wait for it
      // to come up (auto-connect then restores the tunnel).
      tell(t("daemonStarting"), "progress");
      if (!await waitForDaemon(true)) { tell(t("daemonTimeout"), "fail"); return; }
      tell(t("daemonStarted"));
      await load("status", true);
      return;
    }
    await load("status", true);
    tell(t("operationDone"));
  }, t(action === "webui up" ? "reconnectingNetwork" : "disconnectingNetwork"), true);
}
function changeNetwork(mode, id) {
  const action = mode === "select" ? "webui networks-select" : mode === "append" ? "webui networks-append" : "webui networks-deselect";
  const message = mode !== "deselect" ? "" : id === "all" ? t("confirmDisableAll") : `${t("confirmDisableNetwork")} ${id}?`;
  const update = async () => { throwOnError(await runAction(action, [id])); await load("networks", true); tell(t("networkUpdated")); };
  return message ? confirmAction(message, update) : withBusy(update);
}
async function checkHealth(kind) {
  await withBusy(async () => {
    const result = await runAction("webui health", [kind]);
    const data = parseJson(result) || { ok: false, exit: result.errno };
    health.value[kind] = data.ok ? t("passed") : `${t("failed")} (${data.exit ?? result.errno})`;
  });
}
function selectProfile() {
  const name = profileName.value.trim();
  if (!name) return;
  confirmAction(`${t("confirmProfile")} ${name}`, async () => {
    throwOnError(await runAction("webui profile-select", [name]));
    await load("status", true);
    tell(t("profileUpdated"));
  });
}
function setLanguage(value) {
  if (!messages[value]) return;
  language.value = value;
  localStorage.setItem("netbird.language", value);
}
function setTheme(value) {
  if (themeIds.includes(value)) theme.value = value;
}
watch(theme, (value) => {
  document.documentElement.dataset.theme = value;
  localStorage.setItem("netbird.theme", value);
}, { immediate: true });
function recordTouchStart(event) {
  touchStartX = event.touches[0]?.clientX || 0;
  touchStartY = event.touches[0]?.clientY || 0;
}
function handleTouchEnd(event) {
  const touch = event.changedTouches[0];
  if (!touch) return;
  const deltaX = touch.clientX - touchStartX;
  const deltaY = touch.clientY - touchStartY;
  if (Math.abs(deltaX) > 60 && Math.abs(deltaX) > Math.abs(deltaY) * 1.2) {
    const currentIndex = pageOrder.indexOf(active.value);
    const nextIndex = deltaX < 0 ? currentIndex + 1 : currentIndex - 1;
    if (nextIndex >= 0 && nextIndex < pageOrder.length) onTabChange(pageOrder[nextIndex]);
    return;
  }
  if (deltaY > 90 && event.currentTarget.scrollTop === 0) refreshData();
}

let networksPrefetchTimer = 0;
let viewportResizeHandler = null;
onMounted(() => {
  load("status", true);
  let stableHeight = window.innerHeight;
  let stableWidth = window.innerWidth;
  viewportResizeHandler = () => {
    const width = window.innerWidth;
    const height = window.innerHeight;
    if (width !== stableWidth) {
      stableWidth = width;
      stableHeight = height;
    } else if (height > stableHeight) {
      stableHeight = height;
    }
    document.documentElement.style.setProperty("--app-shell-height", `${stableHeight}px`);
  };
  viewportResizeHandler();
  window.addEventListener("resize", viewportResizeHandler);
  // Warm the Networks list in the background so the first tab switch is
  // instant. Only when the daemon is actually running (a prefetch against a
  // stopped daemon would pop an error toast unprompted), and skipped when the
  // user opened the tab first (cooldown + in-flight guard).
  networksPrefetchTimer = window.setTimeout(() => {
    if (model.value.daemon === "running") load("networks");
  }, 1200);
});
onUnmounted(() => {
  window.clearTimeout(networksPrefetchTimer);
  window.clearTimeout(noticeTimer);
  if (viewportResizeHandler) window.removeEventListener("resize", viewportResizeHandler);
  document.documentElement.style.removeProperty("--app-shell-height");
});
</script>

<template>
  <div class="app-shell">
    <header class="app-header">
      <div class="brand-mark" aria-label="NetBird">
        <svg width="40" height="23" viewBox="0 0 40 23" fill="none" xmlns="http://www.w3.org/2000/svg"  role="img" aria-labelledby="netbird-logo-title">
          <title id="netbird-logo-title">NetBird</title>
          <g clip-path="url(#clip0_0_3)">
            <path d="M21.4651 0.568359C17.8193 0.902835 16.0047 3.00167 15.3191 4.06363L4.66602 22.5183H17.5182L30.1949 0.568359H21.4651Z" fill="#F68330"/>
            <path d="M17.5265 22.5187L0 3.9302C0 3.9302 19.8177 -1.39633 21.7493 15.2188L17.5265 22.5187Z" fill="#F68330"/>
            <path d="M14.9255 4.75055L9.54883 14.0657L17.5177 22.5196L21.7405 15.2029C21.0715 9.49174 18.287 6.37276 14.9255 4.74219" fill="#F35E32"/>
          </g>
          <defs><clipPath id="clip0_0_3"><rect width="32" height="32" fill="white"/></clipPath></defs>
        </svg>
      </div>
      <div class="brand-copy"><p>NETBIRD / KERNELSU</p><h1>{{ t('console') }}</h1></div>
      <div class="header-controls">
        <DropdownMenuRoot>
          <DropdownMenuTrigger as-child>
            <Button variant="outline" size="icon" class="header-menu-trigger theme-menu-trigger" :aria-label="t('themeSettings')" :title="t('themeSettings')"><Palette :size="17" /></Button>
          </DropdownMenuTrigger>
          <DropdownMenuPortal>
            <DropdownMenuContent class="header-menu" align="end" side="bottom" :side-offset="8">
              <div class="header-menu-label">{{ t('themeSettings') }}</div>
              <DropdownMenuRadioGroup :model-value="theme" @update:model-value="setTheme">
                <DropdownMenuRadioItem v-for="choice in themeChoices" :key="choice.id" :value="choice.id" class="header-menu-item">
                  <span class="theme-swatch" :style="{ '--swatch': choice.color }"></span>
                  <span>{{ choice.label }}</span>
                  <DropdownMenuItemIndicator class="menu-check"><Check :size="14" /></DropdownMenuItemIndicator>
                </DropdownMenuRadioItem>
              </DropdownMenuRadioGroup>
            </DropdownMenuContent>
          </DropdownMenuPortal>
        </DropdownMenuRoot>

        <DropdownMenuRoot>
          <DropdownMenuTrigger as-child>
            <Button variant="outline" size="icon" class="header-menu-trigger language-menu-trigger" :aria-label="t('language')" :title="t('language')"><Languages :size="17" /></Button>
          </DropdownMenuTrigger>
          <DropdownMenuPortal>
            <DropdownMenuContent class="header-menu language-menu" align="end" side="bottom" :side-offset="8">
              <div class="header-menu-label">{{ t('language') }}</div>
              <DropdownMenuRadioGroup :model-value="language" @update:model-value="setLanguage">
                <DropdownMenuRadioItem value="zh" class="header-menu-item"><span>中文</span><DropdownMenuItemIndicator class="menu-check"><Check :size="14" /></DropdownMenuItemIndicator></DropdownMenuRadioItem>
                <DropdownMenuRadioItem value="en" class="header-menu-item"><span>English</span><DropdownMenuItemIndicator class="menu-check"><Check :size="14" /></DropdownMenuItemIndicator></DropdownMenuRadioItem>
              </DropdownMenuRadioGroup>
            </DropdownMenuContent>
          </DropdownMenuPortal>
        </DropdownMenuRoot>
      </div>
    </header>

    <main class="page-scroll" @touchstart.passive="recordTouchStart" @touchend.passive="handleTouchEnd">
      <div class="page-content">
        <section class="status-banner" aria-live="polite">
          <div class="status-top">
            <div class="status-icon"><Wifi :size="21" /></div>
            <div class="status-copy"><p>{{ t('daemon') }}</p><h2>{{ statusLabel }}</h2><p v-if="model.daemon === 'error' && statusError" class="status-error">{{ statusError }}</p></div>
            <span class="status-indicator" :class="statusTone"></span>
          </div>
          <div class="status-ip"><span>{{ t('ipv4') }}</span><strong>{{ model.ip }}</strong></div>
          <div class="status-metrics">
            <div class="status-metric"><span>{{ t('online') }}</span><strong>{{ connectedCount }}<small v-if="model.total !== '-'"> / {{ model.total }}</small></strong></div>
            <div class="status-metric"><span>{{ t('management') }}</span><strong>{{ connectionText(model.management) }}</strong></div>
            <div class="status-metric"><span>{{ t('signal') }}</span><strong>{{ connectionText(model.signal) }}</strong></div>
          </div>
        </section>

        <div v-if="notice" class="notice-toast" :class="{ 'notice-fail': noticeType === 'fail', 'notice-progress': noticeType === 'progress' }" role="status" aria-live="polite">
          <span v-if="noticeType === 'progress'" class="notice-spinner spinner-motion"><LoaderCircle :size="17" /></span>
          <span>{{ notice }}</span>
        </div>

        <Transition :name="pageTransition" mode="out-in">
        <div :key="active" class="view-stage">
        <template v-if="active === 'overview'">
          <section class="section-card">
            <div class="section-heading"><div><span class="section-kicker">NETWORK</span><h2>{{ t('connection') }}</h2></div><span class="updated-time">{{ refreshedAt ? `${t('updated')} ${refreshedAt}` : t('checking') }}</span></div>
            <div class="details-list">
              <div class="detail-row"><span>{{ t('fqdn') }}</span><strong>{{ model.fqdn }}</strong></div>
              <div class="detail-row"><span>{{ t('ipv6') }}</span><strong>{{ model.ipv6 }}</strong></div>
              <div class="detail-row"><span>{{ t('interface') }}</span><strong>{{ model.interfaceType }}</strong></div>
              <div class="detail-row"><span>{{ t('port') }}</span><strong>{{ model.port }}</strong></div>
              <div class="detail-row"><span>{{ t('version') }}</span><strong>{{ model.version }}</strong></div>
            </div>
          </section>
          <section class="section-card">
            <div class="section-heading"><div><span class="section-kicker">NETWORK</span><h2>{{ t('powerTitle') }}</h2></div><span class="status-indicator" :class="statusTone"></span></div>
            <div class="action-grid">
              <Button variant="default" class="justify-start" :disabled="busy || model.connection === 'connected'" @click="connectionAction('webui up', t('confirmUp'))"><RefreshCw :size="16" />{{ t('btnUp') }}</Button>
              <Button variant="outline" class="justify-start" :disabled="busy || model.daemon !== 'running' || model.connection === 'disconnected'" @click="connectionAction('webui down', t('confirmDown'))"><WifiOff :size="16" />{{ t('btnDown') }}</Button>
            </div>
          </section>
          <section class="section-card">
            <div class="section-heading"><div><span class="section-kicker">ACTIONS</span><h2>{{ t('system') }}</h2></div></div>
            <p class="section-hint">{{ t('actionHint') }}</p>
            <div class="action-grid">
              <Button variant="default" class="justify-start" :disabled="busy" @click="runRuntimeAction('refresh', t('confirmRefresh'))"><RefreshCw :size="16" />{{ t('refreshRules') }}</Button>
              <Button variant="outline" class="justify-start" :disabled="busy" @click="runRuntimeAction('route', t('confirmRoutes'))"><Route :size="16" />{{ t('refreshRoutes') }}</Button>
            </div>
          </section>
        </template>

        <template v-else-if="active === 'peers'">
          <section class="section-card">
            <div class="section-heading peer-section-heading"><div><span class="section-kicker">MESH NETWORK</span><h2>{{ t('peerTitle') }}</h2></div><div class="peer-heading-actions">
              <DropdownMenuRoot>
                <DropdownMenuTrigger as-child><Button variant="outline" size="icon" class="peer-filter-trigger" :class="{ 'peer-filter-active': peerFilter !== 'all' || peerSort !== 'name' }" :aria-label="t('filterSort')" :title="t('filterSort')"><ListFilter :size="16" /></Button></DropdownMenuTrigger>
                <DropdownMenuPortal>
                  <DropdownMenuContent class="header-menu peer-filter-menu" align="end" side="bottom" :side-offset="8">
                    <div class="header-menu-label">{{ t('filterByStatus') }}</div>
                    <DropdownMenuRadioGroup v-model="peerFilter">
                      <DropdownMenuRadioItem v-for="option in [{ id: 'all', label: t('allPeers') }, { id: 'connected', label: t('connectedOnly') }, { id: 'disconnected', label: t('disconnectedOnly') }]" :key="option.id" :value="option.id" class="header-menu-item"><span>{{ option.label }}</span><DropdownMenuItemIndicator class="menu-check"><Check :size="14" /></DropdownMenuItemIndicator></DropdownMenuRadioItem>
                    </DropdownMenuRadioGroup>
                    <div class="header-menu-label sort-menu-label">{{ t('sortBy') }}</div>
                    <DropdownMenuRadioGroup v-model="peerSort">
                      <DropdownMenuRadioItem v-for="option in [{ id: 'name', label: t('sortName') }, { id: 'latency', label: t('sortLatency') }, { id: 'traffic', label: t('sortTraffic') }]" :key="option.id" :value="option.id" class="header-menu-item"><span>{{ option.label }}</span><DropdownMenuItemIndicator class="menu-check"><Check :size="14" /></DropdownMenuItemIndicator></DropdownMenuRadioItem>
                    </DropdownMenuRadioGroup>
                  </DropdownMenuContent>
                </DropdownMenuPortal>
              </DropdownMenuRoot>
              <Button variant="outline" size="icon" class="peer-refresh-trigger" :aria-label="t('refresh')" :title="t('refresh')" :disabled="busy || statusLoading" @click="load('status', true)"><span :class="statusLoading ? 'spinner-motion' : ''"><RefreshCw :size="15" /></span></Button>
            </div></div>
            <div v-if="model.daemon === 'stopped' && !statusLoading" class="empty-state" role="status"><div class="empty-icon"><Users :size="19" /></div><p>{{ t('daemonStoppedHint') }}</p></div>
            <div v-else-if="statusLoading && !model.peers.length" class="empty-state" role="status"><span class="spinner-motion"><LoaderCircle :size="21" /></span><p>{{ t('checking') }}</p></div>
            <div v-else-if="!model.peers.length" class="empty-state"><div class="empty-icon"><Users :size="19" /></div><p>{{ t('noPeers') }}</p></div>
            <div v-else-if="!peerItems.length" class="empty-state"><div class="empty-icon"><ListFilter :size="18" /></div><p>{{ t('filterNoMatches') }}</p></div>
            <article v-for="(peer, index) in peerItems" :key="firstValue(peer, ['fqdn', 'name']) + index" class="peer-row">
              <div class="peer-main"><div class="peer-ident"><strong>{{ firstValue(peer, ['fqdn', 'name']) }}</strong><span>{{ firstValue(peer, ['netbirdIp', 'netbirdIP']) }}</span></div><Badge variant="outline" :class="String(firstValue(peer, ['status', 'state'])).toLowerCase().includes('connected') ? 'border-primary/30 bg-secondary text-primary' : ''">{{ connectionText(firstValue(peer, ['status', 'state'])) }}</Badge></div>
              <div class="peer-stats">
                <div class="peer-stat"><span>{{ t('connectionType') }}</span><strong>{{ firstValue(peer, ['connectionType', 'type']) }}</strong></div>
                <div class="peer-stat"><span>{{ t('latency') }}</span><strong>{{ firstValue(peer, ['latency', 'latencyMs']) }}</strong></div>
                <div class="peer-stat"><span>{{ t('rx') }}</span><strong><ArrowDownToLine :size="12" class="inline" /> {{ formatBytes(firstValue(peer, ['transferReceived', 'rx'])) }}</strong></div>
                <div class="peer-stat"><span>{{ t('tx') }}</span><strong><ArrowUpFromLine :size="12" class="inline" /> {{ formatBytes(firstValue(peer, ['transferSent', 'tx'])) }}</strong></div>
                <div v-if="firstValue(peer, ['lastHandshake', 'last_handshake', 'handshake', 'lastSeen']) !== '-'" class="peer-stat"><span>{{ t('handshake') }}</span><strong><Clock3 :size="12" class="inline" /> {{ firstValue(peer, ['lastHandshake', 'last_handshake', 'handshake', 'lastSeen']) }}</strong></div>
              </div>
            </article>
          </section>
        </template>

        <template v-else-if="active === 'networks'">
          <section class="section-card">
            <div class="section-heading"><div><span class="section-kicker">ROUTES</span><h2>{{ t('networkTitle') }}</h2></div><Button variant="outline" size="sm" :disabled="busy" @click="load('networks', true)"><RefreshCw :size="14" />{{ t('refresh') }}</Button></div>
            <div v-if="model.daemon === 'stopped'" class="empty-state" role="status"><div class="empty-icon"><Power :size="19" /></div><p>{{ t('daemonStoppedHint') }}</p></div>
            <div v-else-if="model.connection === 'disconnected' || model.connection === 'needs-login'" class="empty-state" role="status"><div class="empty-icon"><WifiOff :size="19" /></div><p>{{ t('networkNeedsConnection') }}</p></div>
            <div v-else-if="model.connection === 'connecting'" class="empty-state" role="status"><span class="spinner-motion"><LoaderCircle :size="20" /></span><p>{{ t('connecting') }}</p></div>
            <div v-else-if="networksError" class="empty-state" role="alert"><CircleAlert :size="18" /><p>{{ networksError }}</p><Button variant="ghost" size="sm" @click="load('networks', true)">{{ t('retry') }}</Button></div>
            <template v-else>
              <p class="section-hint">{{ t('routeHint') }}</p>
              <div class="bulk-actions"><Button size="sm" :disabled="busy" @click="changeNetwork('select', 'all')"><Check :size="14" />{{ t('acceptAll') }}</Button><Button variant="outline" size="sm" :disabled="busy" @click="changeNetwork('deselect', 'all')"><X :size="14" />{{ t('disableAll') }}</Button></div>
              <div v-if="!networkItems.length" class="empty-state" role="status"><span v-if="!networksLoaded" class="spinner-motion"><LoaderCircle :size="20" /></span><div v-else class="empty-icon"><Route :size="19" /></div><p>{{ networksLoaded ? t('noData') : t('checking') }}</p><Button v-if="networksLoaded" variant="ghost" size="sm" @click="load('networks', true)">{{ t('retry') }}</Button></div>
              <article v-for="item in networkItems" :key="item.id" class="network-row">
                <div class="network-ident"><strong>{{ item.id }}</strong><span>{{ item.network }}</span><span v-if="item.domains !== '-'">{{ t('domains') }}: {{ item.domains }}</span><span v-if="item.resolvedIps !== '-'">{{ t('resolved') }}: {{ item.resolvedIps }}</span></div>
                <Badge variant="outline" :class="item.status.toLowerCase() === 'selected' ? 'border-primary/30 bg-secondary text-primary' : 'border-accent-foreground/20 bg-accent text-accent-foreground'">{{ item.status.toLowerCase() === 'selected' ? t('selected') : t('notSelected') }}</Badge>
                <Button class="network-action" variant="outline" size="sm" :disabled="busy" @click="changeNetwork(item.status.toLowerCase() === 'selected' ? 'deselect' : 'append', item.id)">{{ item.status.toLowerCase() === 'selected' ? t('disable') : t('enable') }}<ChevronRight :size="14" /></Button>
              </article>
            </template>
          </section>
        </template>

        <template v-else-if="active === 'automation'">
          <section class="section-card">
            <div class="section-heading"><div><span class="section-kicker">SCHEDULE</span><h2>{{ t('automation') }}</h2></div><Button variant="outline" size="icon" :aria-label="t('refresh')" :title="t('refresh')" :disabled="automationLoading" @click="loadAutomation"><span :class="automationLoading ? 'spinner-motion' : ''"><RefreshCw :size="15" /></span></Button></div>
            <form class="automation-form" @submit.prevent="saveAutomation">
              <input v-model="automationForm.name" :placeholder="t('ruleName')" maxlength="48" required aria-label="Rule name">
              <select v-model="automationForm.action" aria-label="Action"><option value="connect">{{ t('btnUp') }}</option><option value="disconnect">{{ t('btnDown') }}</option></select>
              <label class="automation-mode">{{ t('conditionMode') }} <select v-model="automationForm.mode" aria-label="Condition mode"><option value="all">{{ t('matchAll') }}</option><option value="any">{{ t('matchAny') }}</option></select></label>
              <div v-for="(condition, index) in automationForm.conditions" :key="index" class="automation-condition-row">
                <select v-model="condition.type" :aria-label="`${t('condition')} ${index + 1}`" @change="scheduleChanged(condition)"><option value="once">{{ t('once') }}</option><option value="daily">{{ t('daily') }}</option><option value="weekdays">{{ t('weekdays') }}</option><option value="weekly">{{ t('weekly') }}</option></select>
                <select v-if="condition.type === 'weekly'" v-model.number="condition.weekday" aria-label="Weekday"><option v-for="day in 7" :key="day" :value="day">{{ t(`weekday${day}`) }}</option></select>
                <input v-model="condition.value" :type="condition.type === 'once' ? 'datetime-local' : 'time'" required aria-label="Scheduled time">
                <Button v-if="automationForm.conditions.length > 1" type="button" variant="ghost" size="icon" :aria-label="t('removeCondition')" :title="t('removeCondition')" @click="removeAutomationCondition(index)"><X :size="14" /></Button>
              </div>
              <Button type="button" variant="outline" size="sm" class="automation-add-condition" :disabled="automationForm.conditions.length >= 8" @click="addAutomationCondition"><Plus :size="14" />{{ t('addCondition') }}</Button>
              <div class="automation-options"><label>{{ t('priority') }} <input v-model.number="automationForm.priority" type="number" min="0" max="99"></label><label><input v-model="automationForm.enabled" type="checkbox"> {{ t('enabled') }}</label></div>
              <div class="automation-form-actions"><Button type="submit" :disabled="automationLoading">{{ automationForm.id ? t('saveRule') : t('addRule') }}</Button><Button v-if="automationForm.id" type="button" variant="outline" @click="resetAutomationForm">{{ t('cancel') }}</Button></div>
            </form>
            <p v-if="automationError" class="automation-error" role="alert">{{ automationError }}</p>
            <div v-if="automationLoading && !automationRules.length" class="empty-state" role="status"><span class="spinner-motion"><LoaderCircle :size="19" /></span><p>{{ t('checking') }}</p></div>
            <article v-for="rule in automationRules" :key="rule.id" class="automation-row">
              <div class="automation-rule-copy"><strong>{{ rule.name }}</strong><span>{{ rule.action === 'connect' ? t('btnUp') : t('btnDown') }} · {{ rule.schedule }}</span><small>{{ t('priority') }} {{ rule.priority }}</small></div>
              <label class="automation-enabled" :aria-label="t('enabled')"><input type="checkbox" :checked="rule.enabled" @change="editAutomation({ ...rule, enabled: $event.target.checked }); saveAutomation()"></label>
              <Button variant="ghost" size="icon" :aria-label="t('editRule')" :title="t('editRule')" @click="editAutomation(rule)"><Activity :size="15" /></Button>
              <Button variant="ghost" size="icon" :aria-label="t('deleteRule')" :title="t('deleteRule')" @click="deleteAutomation(rule)"><X :size="15" /></Button>
            </article>
            <div v-if="!automationLoading && !automationRules.length" class="empty-state"><p>{{ t('noRules') }}</p></div>
          </section>
          <section class="section-card">
            <div class="section-heading"><div><span class="section-kicker">JOURNAL</span><h2>{{ t('executionHistory') }}</h2></div></div>
            <div class="automation-log-filters">
              <select v-model="automationFilterRule" :aria-label="t('filterRule')"><option value="all">{{ t('allRules') }}</option><option v-for="rule in automationRules" :key="rule.id" :value="rule.id">{{ rule.name }}</option></select>
              <select v-model="automationFilterAction" :aria-label="t('filterAction')"><option value="all">{{ t('allActions') }}</option><option value="connect">{{ t('btnUp') }}</option><option value="disconnect">{{ t('btnDown') }}</option></select>
              <select v-model="automationFilterEvent" :aria-label="t('filterResult')"><option value="all">{{ t('allResults') }}</option><option value="success">{{ t('eventSuccess') }}</option><option value="skipped">{{ t('eventSkipped') }}</option><option value="failed">{{ t('eventFailed') }}</option><option value="conflict">{{ t('eventConflict') }}</option><option value="started">{{ t('eventStarted') }}</option></select>
            </div>
            <article v-for="(entry, index) in displayedAutomationLogs" :key="`${entry.key}-${index}`" class="automation-log-row"><strong>{{ t(`event${entry.event?.[0]?.toUpperCase()}${entry.event?.slice(1)}`) }}</strong><span>{{ automationRuleName(entry.rule) }} · {{ entry.action }} · {{ entry.key?.replace(/^.*:/, '') }}</span><small>{{ entry.ts }}</small></article>
            <div v-if="!visibleAutomationLogs.length" class="empty-state"><p>{{ automationLogs.length ? t('noMatches') : t('noHistory') }}</p></div>
            <Button v-else-if="displayedAutomationLogs.length < visibleAutomationLogs.length" variant="outline" size="sm" class="automation-log-more" @click="automationLogLimit += automationLogPageSize">{{ t('loadMore') }}</Button>
          </section>
        </template>
        <template v-else>
          <section class="section-card">
            <div class="section-heading"><div><span class="section-kicker">DAEMON</span><h2>{{ t('health') }}</h2></div><ShieldCheck :size="19" class="text-primary" /></div>
            <div class="health-list">
              <div v-for="kind in ['live', 'ready', 'startup']" :key="kind" class="health-row"><div><strong>{{ t(kind) }}</strong><span>{{ health[kind] || t('unknown') }}</span></div><Badge v-if="health[kind] === t('passed')" variant="outline" class="border-primary/30 bg-secondary text-primary"><Check :size="12" />{{ t('passed') }}</Badge><Button v-else variant="outline" size="sm" :disabled="busy" @click="checkHealth(kind)"><span v-if="busy" class="spinner-motion"><LoaderCircle :size="13" /></span><Activity v-else :size="13" />{{ t('check') }}</Button></div>
            </div>
          </section>
          <section class="section-card">
            <div class="section-heading"><div><span class="section-kicker">DETAILS</span><h2>{{ t('versionState') }}</h2></div><Signal :size="18" class="text-muted-foreground" /></div>
            <div class="diagnostic-actions"><Button variant="outline" size="sm" :disabled="busy" @click="load('version', true)">{{ t('readVersion') }}</Button><Button variant="outline" size="sm" :disabled="busy" @click="load('state', true)">{{ t('readState') }}</Button><Button variant="outline" size="sm" class="col-span-2" :disabled="busy" @click="load('profiles', true)">{{ t('readProfiles') }}</Button></div>
            <div v-if="diagnosticLoading" class="empty-state min-h-[72px]" role="status"><span class="spinner-motion"><LoaderCircle :size="19" /></span><p>{{ t('checking') }}</p></div>
            <div v-else-if="diagnosticItems.length" class="diagnostic-output" aria-live="polite"><div v-for="(item, index) in diagnosticItems" :key="index">{{ item }}</div></div>
            <div v-else class="empty-state min-h-[72px]"><div class="empty-icon"><CircleAlert :size="18" /></div><p>{{ t('chooseDiagnostic') }}</p></div>
            <form class="profile-control" @submit.prevent="selectProfile"><label class="text-xs font-medium" for="profile-name">{{ t('profile') }}</label><Input id="profile-name" v-model="profileName" :placeholder="t('profile')" autocomplete="off" /><Button type="submit" :disabled="busy || !profileName.trim()"><Users :size="15" />{{ t('switchProfile') }}</Button></form>
          </section>
        </template>
        </div>
        </Transition>
      </div>
    </main>

    <nav class="bottom-nav" :aria-label="t('console')">
      <button v-for="item in navItems" :key="item.id" type="button" :data-tab="item.id" :aria-current="active === item.id ? 'page' : undefined" @click="onTabChange(item.id)"><component :is="item.icon" :size="19" :stroke-width="active === item.id ? 2.2 : 1.8" /><span>{{ item.label }}</span></button>
    </nav>

    <Dialog v-model:open="confirmOpen">
      <DialogContent :close-label="t('cancel')" class="w-[calc(100%-32px)] max-w-sm rounded-lg">
        <DialogHeader><DialogTitle>{{ t('confirm') }}</DialogTitle><DialogDescription>{{ confirmMessage }} {{ t('confirmHint') }}</DialogDescription></DialogHeader>
        <DialogFooter class="grid grid-cols-2 gap-2 sm:flex-row">
          <Button variant="outline" @click="confirmOpen = false; pendingAction = null">{{ t('cancel') }}</Button>
          <Button @click="approveConfirmation">{{ t('confirm') }}</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  </div>
</template>
