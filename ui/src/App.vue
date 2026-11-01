<script setup>
import { computed, nextTick, onMounted, onUnmounted, ref, watch } from "vue";
import {
  Activity, AlertTriangle, ArrowDownToLine, ArrowUpFromLine, CalendarClock, Check, CheckCircle2, ChevronRight,
  CircleAlert, CircleX, Clock3, Copy, Globe2, Languages, ListFilter, LoaderCircle, MoreHorizontal, Network, Palette, Pencil, Plus, Power, RefreshCw,
  Route, Search, ShieldCheck, Signal, SkipForward, SlidersHorizontal, Stethoscope, Trash2, Users, Wifi, WifiOff, X
} from "@lucide/vue";
import {
  DropdownMenuContent, DropdownMenuItem, DropdownMenuItemIndicator, DropdownMenuPortal,
  DropdownMenuRadioGroup, DropdownMenuRadioItem, DropdownMenuRoot,
  DropdownMenuTrigger
} from "reka-ui";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Sheet, SheetContent, SheetDescription, SheetFooter, SheetHeader, SheetTitle } from "@/components/ui/sheet";
import { Input } from "@/components/ui/input";
import { Switch } from "@/components/ui/switch";
import { runAction, runRead } from "./api.js";
import { firstValue, formatBytes, parseNetworks, statusModel } from "./view-model.mjs";
import { messages } from "./i18n.js";

const savedLanguage = localStorage.getItem("netbird.language");
const systemLanguage = String(navigator.language || "").toLowerCase();
const language = ref(savedLanguage || (systemLanguage.startsWith("en") ? "en" : "zh"));
const themeIds = ["amber", "green", "ocean", "rose"];
const theme = ref(themeIds.includes(localStorage.getItem("netbird.theme")) ? localStorage.getItem("netbird.theme") : "amber");
const progressMessages = {
  operationInProgress: { zh: "操作中…", en: "Working…" },
  reconnectingNetwork: { zh: "正在重连网络…", en: "Reconnecting…" },
  disconnectingNetwork: { zh: "正在断开网络…", en: "Disconnecting…" }
};
const t = (key) => progressMessages[key]?.[language.value] || messages[language.value][key] || messages.zh[key] || key;
const themeChoices = computed(() => [
  { id: "amber", label: t("themeAmber"), color: "#a95d29" },
  { id: "green", label: t("themeGreen"), color: "#277a5d" },
  { id: "ocean", label: t("themeOcean"), color: "#3475a8" },
  { id: "rose", label: t("themeRose"), color: "#b14e68" }
]);
const navItems = computed(() => [
  { id: "overview", label: t("overview"), icon: Globe2 },
  { id: "peers", label: t("peers"), icon: Users },
  { id: "networks", label: t("networks"), icon: Network },
  { id: "diagnostics", label: t("diagnostics"), icon: Stethoscope },
  { id: "automation", label: t("automation"), icon: Clock3 }
]);
const activeNavIndex = computed(() => Math.max(0, navItems.value.findIndex((item) => item.id === active.value)));
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
const nativeViewTransitions = ref(false);
const pageScrollPositions = new Map();
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
const automationTab = ref("rules");
const automationSearch = ref("");
const automationRuleStatus = ref("all");
const automationRuleAction = ref("all");
const automationForm = ref({ id: "", name: "", action: "disconnect", conditions: [{ type: "daily", value: "22:00", weekday: 1 }], mode: "all", enabled: true });
const automationError = ref("");
const automationLoading = ref(false);
const automationSavingId = ref("");
const automationDialogOpen = ref(false);
const automationLogDetailOpen = ref(false);
const selectedAutomationLog = ref(null);
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
const filteredAutomationRules = computed(() => {
  const query = automationSearch.value.trim().toLowerCase();
  const rows = automationRules.value.filter((rule) => {
    const matchesQuery = !query || `${rule.name} ${automationRuleSummary(rule)} ${rule.id}`.toLowerCase().includes(query);
    const matchesStatus = automationRuleStatus.value === "all" || (automationRuleStatus.value === "enabled" ? rule.enabled : !rule.enabled);
    const matchesAction = automationRuleAction.value === "all" || rule.action === automationRuleAction.value;
    return matchesQuery && matchesStatus && matchesAction;
  });
  return rows;
});
const automationStats = computed(() => ({
  total: automationRules.value.length,
  enabled: automationRules.value.filter((rule) => rule.enabled).length,
  visibleLogs: visibleAutomationLogs.value.length,
  lastLog: automationLogs.value[0]?.ts || "-"
}));
const executionStats = computed(() => [
  { key: "success", icon: CheckCircle2, value: automationLogs.value.filter((entry) => entry.event === "success").length },
  { key: "skipped", icon: SkipForward, value: automationLogs.value.filter((entry) => entry.event === "skipped").length },
  { key: "failed", icon: CircleX, value: automationLogs.value.filter((entry) => entry.event === "failed").length },
  { key: "conflict", icon: AlertTriangle, value: automationLogs.value.filter((entry) => entry.event === "conflict").length }
]);
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
    const [id, name, action, enabled, legacyField, conditionsOrMode = "", legacyConditions = ""] = line.split("\t");
    const mode = legacyField === "all" || legacyField === "any" ? legacyField : conditionsOrMode;
    const conditionList = legacyField === "all" || legacyField === "any" ? conditionsOrMode : legacyConditions;
    const conditions = conditionList.split(",").filter(Boolean).map(parseScheduleCondition);
    return { id, name, action, enabled: enabled === "1", mode, conditions, schedule: conditions.map((condition) => `${condition.type} ${condition.value}`).join(" + ") };
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
function defaultAutomationForm() {
  return { id: "", name: "", action: "disconnect", conditions: [newAutomationCondition()], mode: "all", enabled: true };
}
function resetAutomationForm() { automationForm.value = defaultAutomationForm(); }
function cloneAutomationRule(rule) {
  return { ...rule, conditions: (rule.conditions || []).map((condition) => ({ ...condition })) };
}
function addAutomationCondition() {
  if (automationForm.value.conditions.length < 8) automationForm.value.conditions.push(newAutomationCondition());
}
function removeAutomationCondition(index) {
  if (automationForm.value.conditions.length > 1) automationForm.value.conditions.splice(index, 1);
}
function scheduleChanged(condition) {
  if (condition.type === "once" && !/^\d{4}-\d{2}-\d{2}T([01]\d|2[0-3]):[0-5]\d$/.test(condition.value)) condition.value = localDateTimeValue();
  else if (condition.type !== "once" && !/^([01]\d|2[0-3]):[0-5]\d$/.test(condition.value)) condition.value = "22:00";
}
function conditionLabel(condition) {
  if (condition.type === "once") return `${t("once")} ${String(condition.value || "").replace("T", " ")}`;
  if (condition.type === "weekly") return `${t("weekly")} ${t(`weekday${condition.weekday || 1}`)} ${condition.value}`;
  return `${t(condition.type)} ${condition.value}`;
}
function automationRuleSummary(rule) {
  const conditions = rule.conditions || [];
  return conditions.map(conditionLabel).join(" · ") || t("noConditions");
}
function automationModeLabel(rule) {
  return rule.mode === "any" ? t("matchAny") : t("matchAll");
}
function formatAutomationDate(value) {
  if (!value || value === "-") return "-";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return new Intl.DateTimeFormat(language.value === "en" ? "en-US" : "zh-CN", { month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit" }).format(date);
}
function nextConditionDate(condition, now = new Date()) {
  const value = String(condition.value || "");
  const time = condition.type === "once" ? value.slice(11) : value;
  const [hour, minute] = time.split(":").map(Number);
  if (!Number.isInteger(hour) || !Number.isInteger(minute)) return null;
  const candidate = new Date(now);
  const setTime = (date) => date.setHours(hour, minute, 0, 0);
  if (condition.type === "once") {
    const once = new Date(value);
    return Number.isNaN(once.getTime()) || once <= now ? null : once;
  }
  if (condition.type === "weekly") {
    const weekday = Number(condition.weekday || 1);
    const distance = (weekday - (candidate.getDay() || 7) + 7) % 7;
    candidate.setDate(candidate.getDate() + distance);
    setTime(candidate);
    if (candidate <= now) candidate.setDate(candidate.getDate() + 7);
    return candidate;
  }
  if (condition.type === "weekdays") {
    for (let offset = 0; offset < 8; offset += 1) {
      const weekday = candidate.getDay();
      if (weekday !== 0 && weekday !== 6) {
        setTime(candidate);
        if (candidate > now) return candidate;
      }
      candidate.setDate(candidate.getDate() + 1);
    }
    return null;
  }
  setTime(candidate);
  if (candidate <= now) candidate.setDate(candidate.getDate() + 1);
  return candidate;
}
function nextAutomationExecution(rule) {
  if (!rule.enabled) return null;
  const conditions = rule.conditions || [];
  if (conditions.length !== 1) return null;
  return nextConditionDate(conditions[0]);
}
function nextAutomationLabel(rule) {
  if (!rule.enabled) return t("disabled");
  const next = nextAutomationExecution(rule);
  return next ? formatAutomationDate(next.toISOString()) : t("multipleSchedules");
}
function automationEventLabel(event) {
  const key = `event${String(event || "").replace(/^./, (letter) => letter.toUpperCase())}`;
  return messages[language.value]?.[key] || messages.zh[key] || event || t("unknown");
}
function automationEventIcon(event) {
  return ({ success: CheckCircle2, skipped: SkipForward, failed: CircleX, conflict: AlertTriangle, started: LoaderCircle })[event] || CircleAlert;
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
function automationFormArgs(form) {
  return [form.id, form.name.trim(), form.action, form.enabled ? "1" : "0", form.mode, ...form.conditions.map(automationSchedule)];
}
function validAutomationForm(form) {
  const validConditions = form.conditions.length > 0 && form.conditions.length <= 8 && form.conditions.every((condition) => {
    const validValue = condition.type === "once"
      ? /^\d{4}-\d{2}-\d{2}T([01]\d|2[0-3]):[0-5]\d$/.test(condition.value)
      : /^([01]\d|2[0-3]):[0-5]\d$/.test(condition.value);
    return validValue && ["once", "daily", "weekdays", "weekly"].includes(condition.type);
  });
  return form.name.trim() && form.name.length <= 192 && ["connect", "disconnect"].includes(form.action) && validConditions && ["all", "any"].includes(form.mode);
}
function openAutomationDialog(rule = null, duplicate = false) {
  const form = rule ? cloneAutomationRule(rule) : defaultAutomationForm();
  if (duplicate) {
    form.id = "";
    form.name = `${form.name} ${t("copySuffix")}`.slice(0, 192);
  }
  automationForm.value = form;
  automationError.value = "";
  automationDialogOpen.value = true;
}
function closeAutomationDialog() {
  automationDialogOpen.value = false;
  automationError.value = "";
  resetAutomationForm();
}
async function saveAutomation() {
  const form = automationForm.value;
  if (!validAutomationForm(form)) {
    automationError.value = t("automationInvalid");
    return;
  }
  automationLoading.value = true;
  automationError.value = "";
  try {
    throwOnError(await runAction("webui automation-save", automationFormArgs(form)));
    await loadAutomation();
    closeAutomationDialog();
    tell(form.id ? t("ruleUpdated") : t("ruleAdded"));
  } catch (error) { automationError.value = error.message; }
  finally { automationLoading.value = false; }
}
async function toggleAutomationRule(rule, enabled) {
  if (automationSavingId.value) return;
  automationSavingId.value = rule.id;
  automationError.value = "";
  try {
    throwOnError(await runAction("webui automation-save", automationFormArgs({ ...cloneAutomationRule(rule), enabled })));
    await loadAutomation();
  } catch (error) {
    automationError.value = error.message;
    tell(error.message, "fail");
  } finally { automationSavingId.value = ""; }
}
function automationRuleName(id) {
  return automationRules.value.find((rule) => rule.id === id)?.name || id;
}
function deleteAutomation(rule) {
  return confirmAction(t("confirmDeleteRule"), async () => {
    automationLoading.value = true;
    try {
      throwOnError(await runAction("webui automation-delete", [rule.id]));
      await loadAutomation();
      tell(t("ruleDeleted"));
    } catch (error) { automationError.value = error.message; }
    finally { automationLoading.value = false; }
  });
}
function showAutomationLog(entry) {
  selectedAutomationLog.value = entry;
  automationLogDetailOpen.value = true;
}
function showDiagnostic(value) { diagnosticItems.value = parseLines(value, t("noData")); }
function savePageScrollPosition(name = active.value) {
  const page = document.querySelector(".page-scroll");
  if (page) pageScrollPositions.set(name, page.scrollTop);
}
function restorePageScrollPosition(name) {
  const page = document.querySelector(".page-scroll");
  if (page) page.scrollTop = pageScrollPositions.get(name) || 0;
}
function updateActivePage(name) {
  savePageScrollPosition();
  active.value = name;
  restorePageScrollPosition(name);
}
function runPageTransition(update) {
  if (!nativeViewTransitions.value || typeof document.startViewTransition !== "function") {
    update();
    return;
  }
  const root = document.documentElement;
  root.classList.add("is-native-view-transitioning");
  let transition;
  try {
    transition = document.startViewTransition(async () => {
      update();
      await nextTick();
    });
  } catch {
    root.classList.remove("is-native-view-transitioning");
    update();
    return;
  }
  if (transition.finished) {
    const clearNativeTransition = () => root.classList.remove("is-native-view-transitioning");
    transition.finished.then(clearNativeTransition, clearNativeTransition);
  } else root.classList.remove("is-native-view-transitioning");
}
function onTabChange(name) {
  if (name === active.value) return;
  const currentIndex = pageOrder.indexOf(active.value);
  const nextIndex = pageOrder.indexOf(name);
  pageTransition.value = nextIndex >= currentIndex ? "page-slide-forward" : "page-slide-backward";
  document.documentElement.dataset.pageDirection = nextIndex >= currentIndex ? "forward" : "backward";
  runPageTransition(() => updateActivePage(name));
  window.clearTimeout(pageLoadTimer);
  // Keep the request outside the transition. The content pane changes first,
  // then its data refreshes without delaying the first frame of navigation.
  pageLoadTimer = window.setTimeout(() => {
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
let pageLoadTimer = 0;
let visualViewportHandler = null;
let focusInHandler = null;
let keyboardViewportFrame = 0;
let dialogFocusTimer = 0;
let keyboardBaselineHeight = 0;
function syncKeyboardViewport() {
  if (keyboardViewportFrame) return;
  keyboardViewportFrame = window.requestAnimationFrame(() => {
    keyboardViewportFrame = 0;
    const visualViewport = window.visualViewport;
    const viewportHeight = visualViewport?.height || window.innerHeight;
    const viewportTop = visualViewport?.offsetTop || 0;
    const keyboardHeight = Math.max(0, keyboardBaselineHeight - viewportHeight - viewportTop);
    const keyboardOpen = window.innerWidth <= 900 && keyboardHeight >= 120;
    document.documentElement.style.setProperty("--dialog-viewport-height", `${Math.max(1, viewportHeight)}px`);
    document.documentElement.style.setProperty("--dialog-viewport-top", `${Math.max(0, viewportTop)}px`);
    document.documentElement.style.setProperty("--keyboard-height", `${keyboardHeight}px`);
    document.documentElement.toggleAttribute("data-keyboard-open", keyboardOpen);
  });
}
function revealFocusedDialogField(target) {
  if (!(target instanceof HTMLElement)) return;
  const panel = target.closest(".dialog-panel, .sheet-panel");
  if (!panel) return;
  const scrollContainer = target.closest(".automation-form-body") || panel;
  const viewport = window.visualViewport;
  const viewportTop = viewport?.offsetTop || 0;
  const viewportBottom = viewport ? viewportTop + viewport.height : window.innerHeight;
  const scrollRect = scrollContainer.getBoundingClientRect();
  const targetRect = target.getBoundingClientRect();
  const safeTop = Math.max(scrollRect.top, viewportTop) + 16;
  const safeBottom = Math.min(scrollRect.bottom, viewportBottom) - 16;
  if (targetRect.top >= safeTop && targetRect.bottom <= safeBottom) return;
  const targetOffset = targetRect.top - scrollRect.top + scrollContainer.scrollTop;
  const targetCenter = Math.max(0, targetOffset - scrollContainer.clientHeight * 0.38);
  if (typeof scrollContainer.scrollTo === "function") scrollContainer.scrollTo({ top: targetCenter, behavior: "auto" });
  else scrollContainer.scrollTop = targetCenter;
}
function handleDialogFocus(event) {
  const target = event.target;
  if (!(target instanceof HTMLElement) || !target.closest(".dialog-panel input, .dialog-panel textarea, .dialog-panel select, .sheet-panel input, .sheet-panel textarea, .sheet-panel select")) return;
  window.clearTimeout(dialogFocusTimer);
  // The visual viewport reports its final height after the keyboard animation;
  // reveal once now and once after that resize so both Android WebView paths
  // keep the focused control above the keyboard.
  window.requestAnimationFrame(() => revealFocusedDialogField(target));
  dialogFocusTimer = window.setTimeout(() => revealFocusedDialogField(target), 180);
}
onMounted(() => {
  nativeViewTransitions.value = typeof document.startViewTransition === "function" && !(window.matchMedia?.("(prefers-reduced-motion: reduce)")?.matches ?? false);
  load("status", true);
  keyboardBaselineHeight = window.innerHeight;
  let stableHeight = window.innerHeight;
  let stableWidth = window.innerWidth;
  viewportResizeHandler = () => {
    const width = window.innerWidth;
    const height = window.innerHeight;
    if (width !== stableWidth) {
      stableWidth = width;
      stableHeight = height;
      keyboardBaselineHeight = height;
    } else if (height > stableHeight) {
      stableHeight = height;
      if (!document.documentElement.hasAttribute("data-keyboard-open")) keyboardBaselineHeight = height;
    }
    document.documentElement.style.setProperty("--app-shell-height", `${stableHeight}px`);
    syncKeyboardViewport();
  };
  visualViewportHandler = syncKeyboardViewport;
  focusInHandler = handleDialogFocus;
  viewportResizeHandler();
  window.addEventListener("resize", viewportResizeHandler);
  window.visualViewport?.addEventListener("resize", visualViewportHandler);
  window.visualViewport?.addEventListener("scroll", visualViewportHandler);
  document.addEventListener("focusin", focusInHandler);
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
  window.clearTimeout(pageLoadTimer);
  window.clearTimeout(noticeTimer);
  window.clearTimeout(dialogFocusTimer);
  if (keyboardViewportFrame) window.cancelAnimationFrame(keyboardViewportFrame);
  if (viewportResizeHandler) window.removeEventListener("resize", viewportResizeHandler);
  if (visualViewportHandler) {
    window.visualViewport?.removeEventListener("resize", visualViewportHandler);
    window.visualViewport?.removeEventListener("scroll", visualViewportHandler);
  }
  if (focusInHandler) document.removeEventListener("focusin", focusInHandler);
  document.documentElement.style.removeProperty("--app-shell-height");
  document.documentElement.style.removeProperty("--dialog-viewport-height");
  document.documentElement.style.removeProperty("--dialog-viewport-top");
  document.documentElement.style.removeProperty("--keyboard-height");
  document.documentElement.removeAttribute("data-keyboard-open");
  document.documentElement.removeAttribute("data-page-direction");
  document.documentElement.classList.remove("is-native-view-transitioning");
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
      <div class="brand-copy"><p>NetBird / KernelSU</p><h1>{{ t('console') }}</h1></div>
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
        <section class="status-banner" :class="{ 'is-compact': active !== 'overview' }" aria-live="polite">
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

        <div class="page-viewport">
          <Transition :name="pageTransition" :css="!nativeViewTransitions">
          <div :key="active" class="view-stage">
        <template v-if="active === 'overview'">
          <section class="section-card">
            <div class="section-heading"><div><h2>{{ t('connection') }}</h2></div><span class="updated-time">{{ refreshedAt ? `${t('updated')} ${refreshedAt}` : t('checking') }}</span></div>
            <div class="details-list">
              <div class="detail-row"><span>{{ t('fqdn') }}</span><strong>{{ model.fqdn }}</strong></div>
              <div class="detail-row"><span>{{ t('ipv6') }}</span><strong>{{ model.ipv6 }}</strong></div>
              <div class="detail-row"><span>{{ t('interface') }}</span><strong>{{ model.interfaceType }}</strong></div>
              <div class="detail-row"><span>{{ t('port') }}</span><strong>{{ model.port }}</strong></div>
              <div class="detail-row"><span>{{ t('version') }}</span><strong>{{ model.version }}</strong></div>
            </div>
          </section>
          <section class="section-card">
            <div class="section-heading"><div><h2>{{ t('powerTitle') }}</h2></div><span class="status-indicator" :class="statusTone"></span></div>
            <div class="action-grid">
              <Button variant="default" class="justify-start" :disabled="busy || model.connection === 'connected'" @click="connectionAction('webui up', t('confirmUp'))"><RefreshCw :size="16" />{{ t('btnUp') }}</Button>
              <Button variant="outline" class="justify-start" :disabled="busy || model.daemon !== 'running' || model.connection === 'disconnected'" @click="connectionAction('webui down', t('confirmDown'))"><WifiOff :size="16" />{{ t('btnDown') }}</Button>
            </div>
          </section>
          <section class="section-card">
            <div class="section-heading"><div><h2>{{ t('system') }}</h2></div></div>
            <p class="section-hint">{{ t('actionHint') }}</p>
            <div class="action-grid">
              <Button variant="default" class="justify-start" :disabled="busy" @click="runRuntimeAction('refresh', t('confirmRefresh'))"><RefreshCw :size="16" />{{ t('refreshRules') }}</Button>
              <Button variant="outline" class="justify-start" :disabled="busy" @click="runRuntimeAction('route', t('confirmRoutes'))"><Route :size="16" />{{ t('refreshRoutes') }}</Button>
            </div>
          </section>
        </template>

        <template v-else-if="active === 'peers'">
          <section class="section-card">
            <div class="section-heading peer-section-heading"><div><h2>{{ t('peerTitle') }}</h2></div><div class="peer-heading-actions">
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
            <div class="section-heading"><div><h2>{{ t('networkTitle') }}</h2></div><Button variant="outline" size="sm" :disabled="busy" @click="load('networks', true)"><RefreshCw :size="14" />{{ t('refresh') }}</Button></div>
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
          <section class="automation-page">
            <div class="automation-page-heading">
              <div>
                <h2>{{ t('automation') }}</h2>
                <p>{{ t('automationSubtitle') }}</p>
              </div>
              <div class="automation-heading-actions">
                <Button variant="outline" size="icon" :aria-label="t('refresh')" :title="t('refresh')" :disabled="automationLoading" @click="loadAutomation"><span :class="automationLoading ? 'spinner-motion' : ''"><RefreshCw :size="15" /></span></Button>
                <Button size="sm" @click="openAutomationDialog()"><Plus :size="15" />{{ t('newRule') }}</Button>
              </div>
            </div>

            <div class="automation-summary-grid">
              <div class="automation-stat"><span>{{ t('totalRules') }}</span><strong>{{ automationStats.total }}</strong><small>{{ t('configured') }}</small></div>
              <div class="automation-stat"><span>{{ t('enabledRules') }}</span><strong>{{ automationStats.enabled }}</strong><small>{{ t('currentlyActive') }}</small></div>
              <div class="automation-stat"><span>{{ t('latestExecution') }}</span><strong>{{ formatAutomationDate(automationStats.lastLog) }}</strong><small>{{ t('fromHistory') }}</small></div>
            </div>

            <div class="automation-tabs" role="tablist" :aria-label="t('automation')">
              <button type="button" role="tab" :aria-selected="automationTab === 'rules'" :class="{ 'is-active': automationTab === 'rules' }" @click="automationTab = 'rules'"><SlidersHorizontal :size="15" />{{ t('configurationTab') }}<span>{{ automationRules.length }}</span></button>
              <button type="button" role="tab" :aria-selected="automationTab === 'logs'" :class="{ 'is-active': automationTab === 'logs' }" @click="automationTab = 'logs'"><CalendarClock :size="15" />{{ t('executionTab') }}<span>{{ automationLogs.length }}</span></button>
            </div>

            <template v-if="automationTab === 'rules'">
              <div class="automation-toolbar">
                <label class="automation-search"><Search :size="15" /><input v-model="automationSearch" type="search" :placeholder="t('searchRules')" :aria-label="t('searchRules')"></label>
                <div class="automation-filter-row">
                  <select v-model="automationRuleStatus" :aria-label="t('filterStatus')"><option value="all">{{ t('allStatuses') }}</option><option value="enabled">{{ t('enabledOnly') }}</option><option value="disabled">{{ t('disabledOnly') }}</option></select>
                  <select v-model="automationRuleAction" :aria-label="t('filterAction')"><option value="all">{{ t('allActions') }}</option><option value="connect">{{ t('btnUp') }}</option><option value="disconnect">{{ t('btnDown') }}</option></select>
                </div>
              </div>

              <p v-if="automationError" class="automation-error" role="alert">{{ automationError }}</p>
              <div v-if="automationLoading && !automationRules.length" class="empty-state" role="status"><span class="spinner-motion"><LoaderCircle :size="19" /></span><p>{{ t('checking') }}</p></div>
              <div v-else-if="!automationRules.length" class="automation-empty"><div class="empty-icon"><Clock3 :size="19" /></div><strong>{{ t('noRules') }}</strong><p>{{ t('noRulesHint') }}</p><Button size="sm" @click="openAutomationDialog()"><Plus :size="14" />{{ t('newRule') }}</Button></div>
              <div v-else-if="!filteredAutomationRules.length" class="automation-empty"><div class="empty-icon"><Search :size="18" /></div><strong>{{ t('noRuleMatches') }}</strong><p>{{ t('clearRuleFilters') }}</p></div>
              <div v-else class="automation-rule-list">
                <article v-for="rule in filteredAutomationRules" :key="rule.id" class="automation-rule-item">
                  <div class="automation-rule-icon" :class="rule.action === 'connect' ? 'is-connect' : 'is-disconnect'"><component :is="rule.action === 'connect' ? RefreshCw : WifiOff" :size="18" /></div>
                  <div class="automation-rule-copy">
                    <div class="automation-rule-title"><strong>{{ rule.name }}</strong><Badge variant="outline" :class="rule.enabled ? 'automation-badge-enabled' : 'automation-badge-disabled'">{{ rule.enabled ? t('enabled') : t('disabled') }}</Badge></div>
                    <span>{{ automationRuleSummary(rule) }}</span>
                    <small>{{ automationModeLabel(rule) }} · {{ t('nextRun') }} {{ nextAutomationLabel(rule) }}</small>
                  </div>
                  <Switch :model-value="rule.enabled" :disabled="automationLoading || automationSavingId === rule.id" :aria-label="`${t('enabled')}: ${rule.name}`" @update:model-value="toggleAutomationRule(rule, $event)" />
                  <DropdownMenuRoot>
                    <DropdownMenuTrigger as-child><Button variant="ghost" size="icon" class="automation-more" :aria-label="t('moreActions')" :title="t('moreActions')"><MoreHorizontal :size="17" /></Button></DropdownMenuTrigger>
                    <DropdownMenuPortal>
                      <DropdownMenuContent class="header-menu automation-action-menu" align="end" side="bottom" :side-offset="6">
                        <DropdownMenuItem class="header-menu-item" @select="openAutomationDialog(rule)"><Pencil :size="15" />{{ t('editRule') }}</DropdownMenuItem>
                        <DropdownMenuItem class="header-menu-item" @select="openAutomationDialog(rule, true)"><Copy :size="15" />{{ t('duplicateRule') }}</DropdownMenuItem>
                        <DropdownMenuItem class="header-menu-item automation-delete-item" @select="deleteAutomation(rule)"><Trash2 :size="15" />{{ t('deleteRule') }}</DropdownMenuItem>
                      </DropdownMenuContent>
                    </DropdownMenuPortal>
                  </DropdownMenuRoot>
                </article>
              </div>
            </template>

            <template v-else>
              <div class="automation-execution-summary">
                <div v-for="stat in executionStats" :key="stat.key" class="automation-execution-stat" :class="`is-${stat.key}`"><component :is="stat.icon" :size="15" /><span>{{ t(`event${stat.key.charAt(0).toUpperCase()}${stat.key.slice(1)}`) }}</span><strong>{{ stat.value }}</strong></div>
              </div>
              <div class="automation-log-toolbar">
                <div class="automation-filter-row">
                  <select v-model="automationFilterRule" :aria-label="t('filterRule')"><option value="all">{{ t('allRules') }}</option><option v-for="rule in automationRules" :key="rule.id" :value="rule.id">{{ rule.name }}</option></select>
                  <select v-model="automationFilterAction" :aria-label="t('filterAction')"><option value="all">{{ t('allActions') }}</option><option value="connect">{{ t('btnUp') }}</option><option value="disconnect">{{ t('btnDown') }}</option></select>
                  <select v-model="automationFilterEvent" :aria-label="t('filterResult')"><option value="all">{{ t('allResults') }}</option><option value="success">{{ t('eventSuccess') }}</option><option value="skipped">{{ t('eventSkipped') }}</option><option value="failed">{{ t('eventFailed') }}</option><option value="conflict">{{ t('eventConflict') }}</option><option value="started">{{ t('eventStarted') }}</option></select>
                </div>
              </div>
              <div v-if="!visibleAutomationLogs.length" class="automation-empty"><div class="empty-icon"><CalendarClock :size="19" /></div><strong>{{ automationLogs.length ? t('noMatches') : t('noHistory') }}</strong><p>{{ automationLogs.length ? t('clearLogFilters') : t('noHistoryHint') }}</p></div>
              <div v-else class="automation-log-list">
                <button v-for="(entry, index) in displayedAutomationLogs" :key="`${entry.key}-${index}`" type="button" class="automation-log-row" @click="showAutomationLog(entry)">
                  <span class="automation-log-icon" :class="`is-${entry.event}`"><component :is="automationEventIcon(entry.event)" :size="16" /></span>
                  <span class="automation-log-copy"><strong>{{ automationEventLabel(entry.event) }}</strong><span>{{ automationRuleName(entry.rule) }} · {{ entry.action === 'connect' ? t('btnUp') : t('btnDown') }}</span></span>
                  <span class="automation-log-time">{{ formatAutomationDate(entry.ts) }}<ChevronRight :size="15" /></span>
                </button>
                <Button v-if="displayedAutomationLogs.length < visibleAutomationLogs.length" variant="outline" size="sm" class="automation-log-more" @click="automationLogLimit += automationLogPageSize">{{ t('loadMore') }}</Button>
              </div>
            </template>
          </section>
        </template>
        <template v-else>
          <section class="section-card">
            <div class="section-heading"><div><h2>{{ t('health') }}</h2></div><ShieldCheck :size="19" class="text-primary" /></div>
            <div class="health-list">
              <div v-for="kind in ['live', 'ready', 'startup']" :key="kind" class="health-row"><div><strong>{{ t(kind) }}</strong><span>{{ health[kind] || t('unknown') }}</span></div><Badge v-if="health[kind] === t('passed')" variant="outline" class="border-primary/30 bg-secondary text-primary"><Check :size="12" />{{ t('passed') }}</Badge><Button v-else variant="outline" size="sm" :disabled="busy" @click="checkHealth(kind)"><span v-if="busy" class="spinner-motion"><LoaderCircle :size="13" /></span><Activity v-else :size="13" />{{ t('check') }}</Button></div>
            </div>
          </section>
          <section class="section-card">
            <div class="section-heading"><div><h2>{{ t('versionState') }}</h2></div><Signal :size="18" class="text-muted-foreground" /></div>
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
      </div>
    </main>

    <nav class="bottom-nav" :style="{ '--active-nav-index': activeNavIndex }" :aria-label="t('console')">
      <span class="bottom-nav-indicator" aria-hidden="true"></span>
      <button v-for="item in navItems" :key="item.id" type="button" :data-tab="item.id" :aria-current="active === item.id ? 'page' : undefined" @click="onTabChange(item.id)"><component :is="item.icon" :size="19" :stroke-width="active === item.id ? 2.2 : 1.8" /><span>{{ item.label }}</span></button>
    </nav>

    <Sheet v-model:open="automationDialogOpen">
      <SheetContent :close-label="t('cancel')" class="automation-sheet">
        <SheetHeader>
          <SheetTitle>{{ automationForm.id ? t('editRule') : t('newRule') }}</SheetTitle>
          <SheetDescription>{{ t('automationDialogHint') }}</SheetDescription>
        </SheetHeader>
        <form id="automation-form" class="automation-form" @submit.prevent="saveAutomation">
          <div class="automation-form-body">
          <div class="automation-form-section">
            <div class="automation-form-section-heading"><div><span>{{ t('basicSettings') }}</span><small>{{ t('basicSettingsHint') }}</small></div></div>
            <label class="automation-field"><span>{{ t('ruleName') }}</span><input v-model="automationForm.name" maxlength="192" :placeholder="t('ruleNamePlaceholder')" required :aria-label="t('ruleName')"></label>
            <div class="automation-field"><span>{{ t('action') }}</span><div class="automation-segmented"><button type="button" :class="{ 'is-selected': automationForm.action === 'connect' }" @click="automationForm.action = 'connect'"><RefreshCw :size="15" />{{ t('btnUp') }}</button><button type="button" :class="{ 'is-selected': automationForm.action === 'disconnect' }" @click="automationForm.action = 'disconnect'"><WifiOff :size="15" />{{ t('btnDown') }}</button></div></div>
          </div>
          <div class="automation-form-section">
            <div class="automation-form-section-heading"><div><span>{{ t('conditionSettings') }}</span><small>{{ t('conditionSettingsHint') }}</small></div></div>
            <div class="automation-field"><span>{{ t('conditionMode') }}</span><div class="automation-segmented"><button type="button" :class="{ 'is-selected': automationForm.mode === 'all' }" @click="automationForm.mode = 'all'">{{ t('matchAll') }}</button><button type="button" :class="{ 'is-selected': automationForm.mode === 'any' }" @click="automationForm.mode = 'any'">{{ t('matchAny') }}</button></div></div>
            <div class="automation-condition-list">
              <div v-for="(condition, index) in automationForm.conditions" :key="index" class="automation-condition-item">
                <div class="automation-condition-label"><span>{{ t('condition') }} {{ index + 1 }}</span><Button v-if="automationForm.conditions.length > 1" type="button" variant="ghost" size="icon" :aria-label="t('removeCondition')" :title="t('removeCondition')" @click="removeAutomationCondition(index)"><X :size="14" /></Button></div>
                <div class="automation-condition-row">
                  <select v-model="condition.type" :aria-label="`${t('condition')} ${index + 1}`" @change="scheduleChanged(condition)"><option value="once">{{ t('once') }}</option><option value="daily">{{ t('daily') }}</option><option value="weekdays">{{ t('weekdays') }}</option><option value="weekly">{{ t('weekly') }}</option></select>
                  <select v-if="condition.type === 'weekly'" v-model.number="condition.weekday" class="automation-weekday-select" :aria-label="t('weekday')"><option v-for="day in 7" :key="day" :value="day">{{ t(`weekday${day}`) }}</option></select>
                  <input v-model="condition.value" :type="condition.type === 'once' ? 'datetime-local' : 'time'" required :aria-label="t('scheduledTime')">
                </div>
              </div>
            </div>
            <Button type="button" variant="outline" size="sm" class="automation-add-condition" :disabled="automationForm.conditions.length >= 8" @click="addAutomationCondition"><Plus :size="14" />{{ t('addCondition') }}</Button>
            <div class="automation-preview"><span>{{ t('rulePreview') }}</span><strong>{{ automationForm.conditions.map(conditionLabel).join(' · ') }}</strong></div>
          </div>
          <p v-if="automationError" class="automation-error" role="alert">{{ automationError }}</p>
          </div>
        </form>
        <SheetFooter class="automation-sheet-footer"><Button type="button" variant="outline" :disabled="automationLoading" @click="closeAutomationDialog">{{ t('cancel') }}</Button><Button type="submit" form="automation-form" :disabled="automationLoading"><span v-if="automationLoading" class="spinner-motion"><LoaderCircle :size="14" /></span>{{ automationForm.id ? t('saveRule') : t('addRule') }}</Button></SheetFooter>
      </SheetContent>
    </Sheet>

    <Dialog v-model:open="automationLogDetailOpen">
      <DialogContent :close-label="t('cancel')" class="automation-detail-dialog">
        <DialogHeader><DialogTitle>{{ t('executionDetails') }}</DialogTitle><DialogDescription>{{ selectedAutomationLog ? automationRuleName(selectedAutomationLog.rule) : '' }}</DialogDescription></DialogHeader>
        <div v-if="selectedAutomationLog" class="automation-detail-list">
          <div class="automation-detail-status" :class="`is-${selectedAutomationLog.event}`"><component :is="automationEventIcon(selectedAutomationLog.event)" :size="18" /><strong>{{ automationEventLabel(selectedAutomationLog.event) }}</strong></div>
          <div class="detail-row"><span>{{ t('action') }}</span><strong>{{ selectedAutomationLog.action === 'connect' ? t('btnUp') : t('btnDown') }}</strong></div>
          <div class="detail-row"><span>{{ t('recordedAt') }}</span><strong>{{ selectedAutomationLog.ts }}</strong></div>
          <div class="detail-row"><span>{{ t('scheduledAt') }}</span><strong>{{ selectedAutomationLog.key?.replace(/^.*:/, '') || '-' }}</strong></div>
          <div class="detail-row"><span>{{ t('ruleId') }}</span><strong>{{ selectedAutomationLog.rule }}</strong></div>
        </div>
      </DialogContent>
    </Dialog>

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
