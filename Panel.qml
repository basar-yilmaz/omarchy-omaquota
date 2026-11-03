import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// OmaQuota: limits, reset times and account switching for coding agents, on
// top of Omarchy's own `omarchy agent account` registry and usage collectors.
// The plugin never reads or writes a login; Omarchy owns every token.
Panel {
  id: root
  moduleName: "io.github.basar-yilmaz.omaquota"
  ipcTarget: "io.github.basar-yilmaz.omaquota"

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  readonly property string home: Quickshell.env("HOME")
  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || (home + "/.local/state")
  readonly property string usageDir: stateHome + "/omarchy/agents/usage"
  readonly property string accountsDir: stateHome + "/omarchy/agents/accounts"
  readonly property string resetsScript: String(Qt.resolvedUrl("bin/codex-resets")).replace(/^file:\/\//, "")
  readonly property string applyScript: String(Qt.resolvedUrl("bin/apply-settings")).replace(/^file:\/\//, "")

  // ---------- Settings (shell.json inline entry) ----------
  readonly property var extras: Model.parseExtras(setting("extraProviders", ""))
  readonly property int refreshSec: Math.max(60, Math.min(3600, Number(setting("refreshIntervalSec", 900)) || 900))
  readonly property int alertAt: Math.max(50, Math.min(100, Number(setting("alertAt", 90)) || 90))
  readonly property bool cards: setting("style", "Cards") !== "Compact"
  readonly property bool showPercent: setting("showPercent", true) !== false
  readonly property string valueMode: ["Left", "Used", "Both"].indexOf(setting("valueMode", "Left")) >= 0 ? setting("valueMode", "Left") : "Left"
  // Both shows what's left as the main number, with what's used beside it.
  readonly property bool leftMode: valueMode !== "Used"
  readonly property bool bothMode: valueMode === "Both"
  readonly property bool monoLogos: setting("logoStyle", "Colour") === "Mono"
  readonly property bool barReset: setting("barReset", false) === true
  readonly property var barMap: Model.parseBarItems(setting("barItems", ""))
  readonly property var accountSettings: Model.cleanAccountSettings(setting("accountSettings", {}))
  readonly property var barAll: Model.parseIdSet(setting("barAllAccounts", ""))
  readonly property var barEntries: Model.barEntries(providers, barMap, barAll)
  // Demo mode: every number comes from a JSON file (see demo/accounts.json),
  // for screenshots and layout checks. Nothing is switched or written.
  readonly property string demoFile: String(setting("demoFile", "") || "")
  readonly property bool demo: /^\/[^\0]+\.json$/.test(demoFile)

  // ---------- Live state ----------
  property var providers: []
  property string settingsPath: ""
  property var claudeSettings: null
  property double nowMs: Date.now()
  property double readAt: 0
  property bool updating: false
  property bool readAgain: false
  property string applyFailed: ""
  // shortcut: warned limits live in memory, so a shell restart can warn once more about a limit still over; persist them if that gets noisy.
  property var notified: ({})
  property int cursor: -1
  // Master-detail: providers down the left, the picked one on the right, so
  // the panel is as tall as the longer column, not every provider stacked.
  property string selectedId: ""
  // Codex's banked resets, listed on demand: asking starts a Codex app-server.
  property var resetList: []
  property double resetListAt: 0
  property bool resetLoading: false
  property string resetError: ""
  // Folded/unfolded state shared by every agent: the banked list and the
  // Settings tab's sections stay as you left them when you switch agents.
  property bool bankedOpen: false
  property var openSections: ({})
  function sectionOpen(key) { return openSections[key] === true }
  function flipSection(key) {
    var next = Object.assign({}, openSections)
    next[key] = !next[key]
    openSections = next
  }
  property string detailView: "limits"  // limits | settings | display
  readonly property var emptyProvider: ({ id: "", name: "", plan: "", windows: [], accounts: [], details: null, switchable: false, noData: true, peak: 0, auto: false, threshold: 95 })
  readonly property var selected: {
    for (var i = 0; i < providers.length; i++) if (providers[i].id === selectedId) return providers[i]
    return providers.length > 0 ? providers[0] : null
  }
  readonly property real railWidth: sp(236)
  readonly property real detailWidth: sp(cards ? 470 : 440)
  readonly property real columnGap: sp(26)

  // Panel size: Small, Medium or Large scales the panel's text and spacing
  // together. The bar keeps Omarchy's own sizes so it matches its neighbours.
  readonly property string uiSize: ["Small", "Medium", "Large"].indexOf(setting("uiSize", "Medium")) >= 0 ? setting("uiSize", "Medium") : "Medium"
  readonly property real uiScale: ({ Small: 0.88, Medium: 1.0, Large: 1.15 })[uiSize]
  function sp(n) { return Math.round(Style.space(n) * uiScale) }
  function fs(px) { return Math.round(px * uiScale) }

  function selectProvider(providerId) {
    selectedId = providerId
    if (detailView === "display") detailView = "limits"
    cursor = -1
  }

  function stepProvider(dy) {
    if (providers.length === 0) return
    var at = selected ? providers.indexOf(selected) : 0
    selectProvider(providers[Math.max(0, Math.min(providers.length - 1, at + dy))].id)
  }

  function toggleDisplay() { detailView = detailView === "display" ? "limits" : "display" }

  readonly property color fg: bar ? bar.foreground : Commons.Color.foreground
  readonly property color dim: Qt.darker(fg, 1.55)
  readonly property color accent: Commons.Color.accent
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Provider logos come from Omarchy's own agents plugin at runtime, so this
  // plugin ships no brand files. White marks have an `<id>-light.svg` twin
  // for light surfaces; a provider without a logo shows its initial.
  readonly property string logoDir: "file://" + (Quickshell.env("OMARCHY_PATH") || "/usr/share/omarchy") + "/shell/plugins/agents/assets/"
  readonly property string logoPath: logoDir.replace(/^file:\/\//, "")
  // Which logo files exist, so a provider without one never asks for a file.
  property var logoFiles: ({})

  function logoFile(providerId, lightSurface) {
    if (!Model.validId(providerId)) return ""
    var light = logoFiles[providerId + "-light.svg"] === true
    var plain = logoFiles[providerId + ".svg"] === true
    if (lightSurface && light) return providerId + "-light.svg"
    if (plain) return providerId + ".svg"
    return light ? providerId + "-light.svg" : ""
  }

  readonly property bool lightPopup: luminance(Commons.Color.popups.background) >= 0.5
  // The glassy bar has no single background colour, so read its text instead:
  // dark text (below the black/white contrast midpoint) means a light bar.
  readonly property bool lightBar: luminance(bar ? bar.barForeground : fg) < 0.179

  function channel(v) { return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4) }
  function luminance(c) { return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b) }

  // One widget per monitor, but background work — the refresh timer,
  // warnings and per-account settings writes — belongs to one of them: the
  // bar on the first screen. Every widget still reads and shows the data.
  // shortcut: with no bar on the first screen nothing refreshes in the background; elect by bar presence if that setup appears.
  readonly property var hostScreen: button.QsWindow.window ? button.QsWindow.window.screen : null
  readonly property bool owner: !hostScreen || Quickshell.screens.length === 0 || hostScreen.name === Quickshell.screens[0].name

  readonly property real topPeak: {
    var best = 0
    for (var i = 0; i < providers.length; i++) best = Math.max(best, providers[i].peak)
    return best
  }
  readonly property bool alarming: topPeak * 100 >= alertAt

  // What ← → walk: the selected provider's accounts, then its add button.
  readonly property var targets: {
    var out = []
    var p = selected
    if (!p || !p.switchable || detailView !== "limits") return out
    for (var a = 0; a < p.accounts.length; a++) out.push({ p: p.id, a: p.accounts[a].id })
    out.push({ p: p.id, a: "" })
    return out
  }

  function targetIndex(providerId, accountId) {
    for (var i = 0; i < targets.length; i++)
      if (targets[i].p === providerId && targets[i].a === accountId) return i
    return -2
  }

  // ---------- Reading state ----------
  // Line 1: the account list. Line 2: Claude's settings.json (real path and
  // content). Then one usage record (or null) per id, in order.
  readonly property string stateScript: 'out=$(omarchy-agent-account-list --json 2>/dev/null | jq -c . 2>/dev/null); printf "%s\\n" "${out:-[]}"; s=$(readlink -f "$HOME/.claude/settings.json" 2>/dev/null); if [ -n "$s" ] && [ -f "$s" ]; then jq -c --arg p "$s" "{path: \\$p, settings: .}" "$s" 2>/dev/null || echo null; else echo null; fi; dir=$1; shift; for id in "$@"; do jq -c . "$dir/$id.json" 2>/dev/null || echo null; done'
  readonly property var recordIds: ["claude", "codex", "grok"].concat(extras)

  readonly property string demoScript: String(Qt.resolvedUrl("bin/demo-state")).replace(/^file:\/\//, "")

  function readState() {
    if (stateProc.running) { readAgain = true; return }
    stateProc.command = demo ? ["bash", demoScript, demoFile].concat(recordIds)
      : ["bash", "-c", stateScript, "omaquota", usageDir].concat(recordIds)
    stateProc.running = true
  }

  function parseState(text) {
    if (text.length > 4000000) return
    var lines = text.split("\n")
    var list = []
    try { list = JSON.parse(lines[0] || "[]") } catch (e) { list = [] }
    var claude = null
    try { claude = JSON.parse(lines[1] || "null") } catch (e) { claude = null }
    var ok = claude && typeof claude.path === "string" && /\/settings\.json$/.test(claude.path)
      && claude.settings && typeof claude.settings === "object"
    settingsPath = ok && !demo ? claude.path : ""
    claudeSettings = ok ? claude.settings : null
    var records = []
    for (var i = 2; i < lines.length; i++) {
      if (lines[i] === "") continue
      try { records.push(JSON.parse(lines[i])) } catch (e) { records.push(null) }
    }
    nowMs = Date.now()
    readAt = nowMs
    providers = Model.normalize(list, records, nowMs)
    if (cursor >= targets.length) cursor = targets.length - 1
    warn()
    applyOverlay()
  }

  // Omarchy's usage update also runs its own near-limit check, which notifies
  // or auto-switches for providers that have two or more accounts.
  function refresh() {
    if (demo) { readState(); return }
    if (updateProc.running) return
    updating = true
    updateProc.command = ["omarchy-agent-usage-update", "--limits-only", "claude", "codex", "grok"].concat(extras)
    updateProc.running = true
  }

  function warn() {
    if (demo || !owner) return
    var fresh = Model.alerts(providers, alertAt, notified)
    if (fresh.length === 0) return
    var seen = Object.assign({}, notified)
    for (var i = 0; i < fresh.length; i++) {
      var a = fresh[i]
      seen[a.key] = true
      var title = strings.t("notify.title").arg(a.provider).arg(pct(a.percent))
      var body = a.resetAt > 0
        ? strings.t("notify.body").arg(a.title).arg(countdownText(a.resetAt - Date.now()))
        : strings.t("notify.bodyNoReset").arg(a.title)
      Quickshell.execDetached(["notify-send", "-a", "OmaQuota", "-i", "dialog-warning", title, Model.escapeMarkup(body)])
    }
    notified = seen
  }

  // ---------- Per-account settings ----------
  // Writes the active Claude account's on/off values into settings.json
  // whenever they differ: after a switch here, an Omarchy auto-switch, or
  // `omarchy agent account use` in a terminal (the registry is watched).
  function activeAccount(providerId) {
    var p = providers.filter(function(x) { return x.id === providerId })[0]
    return p ? p.accounts.filter(function(a) { return a.active })[0] || null : null
  }

  function applyOverlay() {
    if (demo || !owner || settingsPath === "" || applyProc.running) return
    var active = activeAccount("claude")
    if (!active) return
    var diff = Model.pendingOverlay(accountSettings, "claude", active.id, claudeSettings)
    if (!diff) return
    var payload = JSON.stringify(diff)
    if (payload === applyFailed) return
    applyProc.payload = payload
    applyProc.command = ["bash", applyScript, settingsPath, payload]
    applyProc.running = true
  }

  function saveAccountSettings(next) { saveSetting("accountSettings", next) }

  onAccountSettingsChanged: applyOverlay()

  // ---------- Actions ----------
  function useAccount(providerId, accountId) {
    var p = providers.filter(function(x) { return x.id === providerId })[0]
    var acc = p ? p.accounts.filter(function(x) { return x.id === accountId })[0] : null
    if (demo || !acc || acc.active || actionProc.running) return
    actionProc.command = ["omarchy-agent-account-use", providerId, accountId]
    actionProc.running = true
  }

  function toggleAuto(p) {
    if (demo || actionProc.running) return
    actionProc.command = ["omarchy-agent-account-mode", p.id, p.auto ? "manual" : "auto"]
    actionProc.running = true
  }

  // Sign-in is interactive (browser and device codes), so it gets a terminal.
  function addAccount(providerId) {
    if (demo || Model.ACCOUNT_PROVIDERS.indexOf(providerId) < 0) return
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", "omarchy-agent-account-add " + providerId])
    close()
  }

  function activate(t) {
    if (!t) return
    if (t.a === "") addAccount(t.p)
    else useAccount(t.p, t.a)
  }

  function saveSetting(key, value) {
    var next = Object.assign({}, root.settings)
    next[key] = value
    root.settings = next
    if (bar && bar.shell) bar.shell.updateEntryInline(root.moduleName, root.settings)
  }

  function toggleStyle() { saveSetting("style", cards ? "Compact" : "Cards") }

  function setBarItem(providerId, title) {
    var next = Object.assign({}, barMap)
    if (title) next[providerId] = title
    else delete next[providerId]
    saveSetting("barItems", Model.serializeBarItems(next))
  }

  // Files only: account folders hold logins, so they get "open folder" alone.
  function editable(path) { return /\.(json|toml|md|jsonl)$/.test(path) }
  function editFile(path) {
    if (!editable(path)) return
    Quickshell.execDetached(["omarchy-launch-editor", path.replace(/^~(?=\/)/, home)])
    close()
  }

  function copyPath(path) { Quickshell.execDetached(["wl-copy", "--", path]) }
  function openFolder(path) { Quickshell.execDetached(["xdg-open", path.replace(/\/[^\/]*\.[A-Za-z]+$/, "")]); close() }

  // ---------- Formatting ----------
  // Chip-sized account names; the full name stays in the tooltip.
  function chipName(label) { return label.length > 18 ? label.slice(0, 17) + "…" : label }

  function setBarAll(providerId, on) {
    var next = Object.assign({}, barAll)
    next[providerId] = on
    saveSetting("barAllAccounts", Model.serializeIdSet(next))
  }

  function pct(value) { return Commons.I18n.formatNumber(Math.round(value * 100)) + "%" }
  function shown(used) { return leftMode ? 1 - used : used }

  function fill(text, c) {
    for (var i = 0; i < c.args.length; i++) text = text.arg(Commons.I18n.formatNumber(c.args[i]))
    return text
  }

  function countdownText(ms) {
    var c = Model.countdown(ms)
    return c ? fill(strings.t(c.key), c) : strings.t("reset.now")
  }

  function shortCountdownText(ms) {
    var c = Model.shortCountdown(ms)
    return c ? fill(strings.t(c.key), c) : ""
  }

  function resetLine(w) {
    if (w.fresh || (w.resetAt > 0 && w.resetAt <= nowMs)) return strings.t("reset.fresh")
    if (!(w.resetAt > 0)) return ""
    return strings.t("reset.in").arg(countdownText(w.resetAt - nowMs))
  }

  function agoText(ms) {
    if (!(ms > 0)) return strings.t("details.never")
    var minutes = Math.floor((nowMs - ms) / 60000)
    return minutes < 1 ? strings.t("details.justNow") : strings.t("details.ago").arg(countdownText(minutes * 60000))
  }

  function tokensText(n) {
    if (n >= 1000000) return Commons.I18n.formatNumber(n / 1000000, 1) + "M"
    if (n >= 1000) return Commons.I18n.formatNumber(n / 1000, 1) + "K"
    return Commons.I18n.formatNumber(n)
  }

  function loadResets(force) {
    if (resetsProc.running) return
    if (!force && resetListAt > Date.now() - 600000) return
    var active = activeAccount("codex")
    resetLoading = true
    resetError = ""
    resetsProc.command = demo ? ["bash", demoScript, "--resets", demoFile]
      : ["python3", "-I", resetsScript, active && active.home ? active.home : ""]
    resetsProc.running = true
  }

  function parseResets(text) {
    resetLoading = false
    var answer = null
    try { answer = JSON.parse(String(text || "").slice(0, 200000)) } catch (e) { answer = null }
    if (!answer || typeof answer !== "object") { resetError = strings.t("banked.failed"); return }
    if (typeof answer.error === "string") { resetError = answer.error.slice(0, 200); return }
    resetList = Model.resetRows(answer)
    resetListAt = Date.now()
  }

  function deadlineText(ms) {
    if (!(ms > 0)) return strings.t("banked.noDeadline")
    var when = new Date(ms).toLocaleString(Qt.locale(Commons.I18n.formatLocale), "ddd d MMM HH:mm")
    return ms > nowMs ? strings.t("banked.deadline").arg(when).arg(countdownText(ms - nowMs)) : strings.t("banked.expired").arg(when)
  }

  function bankedOf(p) { return p && p.details ? p.details.banked : null }

  // "3 banked resets · next expires in 3d 4h"
  function bankedText(b) {
    if (!b) return ""
    var text = strings.tn("banked.count", b.available).arg(Commons.I18n.formatNumber(b.available))
    if (b.nextExpiresAt > nowMs) text += "  ·  " + strings.t("banked.expires").arg(countdownText(b.nextExpiresAt - nowMs))
    return text
  }

  function levelColor(used, calm) {
    var level = Model.level(used, alertAt)
    if (level === "alert") return urgent
    if (level === "warm") return accent
    return calm
  }

  function statusText() {
    if (demo) return strings.t("status.demo")
    if (updating) return strings.t("status.updating")
    if (readAt <= 0) return ""
    var minutes = Math.floor((nowMs - readAt) / 60000)
    return minutes < 1 ? strings.t("status.justNow") : strings.t("status.updated").arg(countdownText(minutes * 60000))
  }

  // Hovering the bar answers "how much is left" without a click.
  function tooltip() {
    if (providers.length === 0) return strings.t("tooltip.none")
    var lines = []
    for (var i = 0; i < providers.length; i++) {
      var p = providers[i]
      var active = p.accounts.filter(function(x) { return x.active })[0]
      var wins = Model.visibleWindows(p.windows)
      var parts = []
      for (var j = 0; j < wins.length; j++) {
        var w = wins[j]
        var when = w.fresh ? strings.t("tooltip.fresh") : (w.resetAt > 0 ? countdownText(w.resetAt - Date.now()) : "")
        var figure = bothMode ? strings.t("tooltip.both").arg(w.title).arg(pct(1 - w.percent)).arg(pct(w.percent))
          : strings.t(leftMode ? "tooltip.left" : "tooltip.used").arg(w.title).arg(pct(shown(w.percent)))
        parts.push(figure + (when ? " (" + when + ")" : ""))
      }
      var name = p.name + (active && p.accounts.length > 1 ? " @" + active.label : "")
      var b = bankedOf(p)
      lines.push(name + "   " + (parts.length ? parts.join("  ·  ") : strings.t("noData"))
        + (b ? "  ·  " + strings.tn("banked.count", b.available).arg(Commons.I18n.formatNumber(b.available)) : ""))
    }
    return lines.join("\n")
  }

  // The files behind a provider, for its drawer. Paths only, never contents.
  function filesFor(p) {
    var out = []
    var loginFile = { claude: ".credentials.json", codex: "auth.json" }[p.id] || ""
    // One row per account: its folder, which holds its own login file.
    for (var i = 0; i < p.accounts.length; i++) {
      var a = p.accounts[i]
      if (a.home === "") continue
      out.push({ label: strings.t(loginFile !== "" ? "files.homeWithLogin" : "files.home").arg(a.label).arg(loginFile), path: a.home })
    }
    if (p.id === "claude" && settingsPath !== "") out.push({ label: strings.t("files.settings"), path: settingsPath })
    if (p.id === "codex") out.push({ label: strings.t("files.settings"), path: home + "/.codex/config.toml" })
    if (p.switchable) out.push({ label: strings.t("files.registry"), path: accountsDir + "/" + p.id + ".json" })
    out.push({ label: strings.t("files.usage"), path: usageDir + "/" + p.id + ".json" })
    return out
  }

  function handlePress(b) {
    if (b === Qt.RightButton) toggleStyle()
    else toggle()
  }

  onOpenedChanged: if (opened) { nowMs = Date.now(); cursor = -1; detailView = "limits"; readState() }
  onExtrasChanged: readState()
  Component.onCompleted: readState()

  Process {
    id: logoProc
    command: ["ls", "-1", root.logoPath]
    running: true
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var found = {}
        var names = String(text || "").split("\n")
        for (var i = 0; i < names.length && i < 500; i++) if (/^[a-z0-9-]+\.svg$/.test(names[i])) found[names[i]] = true
        root.logoFiles = found
      }
    }
  }

  Process {
    id: stateProc
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.parseState(String(text || "")) }
    onExited: if (root.readAgain) { root.readAgain = false; Qt.callLater(root.readState) }
  }

  Process {
    id: updateProc
    onExited: { root.updating = false; root.readState() }
  }

  // account-use refreshes the new account's limits in the background, so read once more shortly after.
  Process {
    id: actionProc
    onExited: { root.readState(); followUp.restart() }
  }

  Process {
    id: resetsProc
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.parseResets(text) }
    onExited: function(code) { if (code !== 0 && root.resetLoading) { root.resetLoading = false; root.resetError = strings.t("banked.failed") } }
  }

  Process {
    id: applyProc
    property string payload: ""
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: if (String(text || "") !== "") console.warn("omaquota apply-settings:", text) }
    onExited: function(code) {
      root.applyFailed = code === 0 ? "" : payload
      if (code === 0) root.readState()
    }
  }

  // A switch made anywhere (terminal, Omarchy's auto-switch) rewrites the
  // registry; reading again applies that account's settings right away.
  FileView {
    path: root.accountsDir + "/claude.json"
    watchChanges: true
    printErrors: false
    onFileChanged: { reload(); root.readState() }
  }

  Timer { id: followUp; interval: 6000; onTriggered: root.readState() }
  Timer { interval: root.refreshSec * 1000; running: root.owner; repeat: true; triggeredOnStart: true; onTriggered: root.refresh() }
  // Keeps countdowns honest while the panel is closed too.
  Timer { interval: 30000; running: true; repeat: true; onTriggered: root.nowMs = Date.now() }

  readonly property Item activeButton: barEntries.length > 0 ? multiButton : button
  implicitWidth: activeButton.implicitWidth
  implicitHeight: activeButton.implicitHeight

  // Nothing picked for the bar: one icon and the tightest limit.
  BarIconButton {
    id: button
    anchors.fill: parent
    visible: root.barEntries.length === 0
    bar: root.bar
    text: root.alarming ? "󰀦" : "󰚩"
    labelText: root.showPercent && root.providers.length > 0 && !vertical ? root.pct(root.shown(root.topPeak)) : ""
    slotSize: Style.bar.iconSlot * (labelText !== "" ? 2 : 1)
    tooltipText: root.opened ? "" : root.tooltip()
    onPressed: function(b) { root.handlePress(b) }
  }

  // Agents picked for the bar: each one's logo and its chosen limit.
  WidgetButton {
    id: multiButton
    anchors.fill: parent
    visible: root.barEntries.length > 0
    bar: root.bar
    hasVisualContent: visible
    labelVisible: false
    fixedWidth: vertical ? -1 : barItems.implicitWidth + scaledHorizontalMargin * 2
    fixedHeight: vertical ? barItems.implicitHeight + scaledVerticalPadding * 2 : -1
    tooltipText: root.opened ? "" : root.tooltip()
    onPressed: function(b) { root.handlePress(b) }

    Grid {
      id: barItems
      anchors.centerIn: parent
      scale: multiButton.pressScale
      columns: multiButton.vertical ? 1 : Math.max(1, root.barEntries.length)
      columnSpacing: Style.space(12)
      rowSpacing: Style.space(6)
      horizontalItemAlignment: Grid.AlignHCenter

      Repeater {
        model: root.barEntries
        delegate: Grid {
          required property var modelData
          columns: multiButton.vertical ? 1 : 2
          columnSpacing: Style.space(5)
          rowSpacing: Style.space(2)
          verticalItemAlignment: Grid.AlignVCenter
          horizontalItemAlignment: Grid.AlignHCenter

          Logo {
            id: barLogo
            providerId: modelData.id
            lightSurface: root.lightBar
            mono: root.monoLogos
            tint: multiButton.foreground
            size: Style.bar.iconSize
          }
          Text {
            visible: !barLogo.visible
            textFormat: Text.PlainText
            text: modelData.name.charAt(0).toUpperCase()
            font.family: multiButton.fontFamily
            font.pixelSize: multiButton.fontSize
            font.bold: true
            color: multiButton.foreground
            renderType: Text.NativeRendering
          }
          Text {
            visible: modelData.accounts.length === 0
            textFormat: Text.PlainText
            text: root.pct(root.shown(modelData.used))
              + (root.barReset && !modelData.fresh && modelData.resetAt > root.nowMs ? " · " + root.shortCountdownText(modelData.resetAt - root.nowMs) : "")
            font.family: multiButton.fontFamily
            font.pixelSize: multiButton.fontSize
            color: modelData.used * 100 >= root.alertAt ? root.urgent : multiButton.foreground
            renderType: Text.NativeRendering
          }
          // Every account: a short tag and its share, the active one in full.
          Grid {
            id: accountValues
            readonly property var entry: modelData
            visible: entry.accounts.length > 0
            columns: multiButton.vertical ? 1 : Math.max(1, entry.accounts.length)
            columnSpacing: Style.space(8)
            rowSpacing: Style.space(1)
            horizontalItemAlignment: Grid.AlignHCenter
            Repeater {
              model: accountValues.entry.accounts
              delegate: Text {
                required property var modelData
                textFormat: Text.PlainText
                text: modelData.tag + " " + (modelData.known ? root.pct(root.shown(modelData.used)) : "–")
                font.family: multiButton.fontFamily
                font.pixelSize: multiButton.fontSize
                font.bold: modelData.active
                opacity: modelData.active ? 1 : 0.62
                color: modelData.known && modelData.used * 100 >= root.alertAt ? root.urgent : multiButton.foreground
                renderType: Text.NativeRendering
              }
            }
          }
        }
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.activeButton
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(root.providers.length > 0 ? root.railWidth + root.columnGap + root.detailWidth : root.detailWidth)
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight)

    content: PanelKeyCatcher {
      anchors.fill: parent
      implicitHeight: panelHeader.implicitHeight + root.sp(18)
        + Math.max(railCol.implicitHeight, detailCol.implicitHeight, emptyText.visible ? emptyText.implicitHeight : 0)
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) { root.stepProvider(dy); return }
        if (root.targets.length === 0) return
        root.cursor = root.cursor < 0 ? 0 : Math.max(0, Math.min(root.targets.length - 1, root.cursor + dx))
      }
      onActivateRequested: if (root.cursor >= 0) root.activate(root.targets[root.cursor])
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (text === "r") root.refresh()
        else if (text === "s") root.toggleStyle()
        else if (text === "g") root.detailView = root.detailView === "settings" ? "limits" : "settings"
      }

      // ---------- Header: name, freshness, refresh and display options ----------
      Item {
        id: panelHeader
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        implicitHeight: Math.max(titleCol.implicitHeight, headButtons.implicitHeight)

        Column {
          id: titleCol
          anchors.left: parent.left
          anchors.right: headButtons.left
          anchors.verticalCenter: parent.verticalCenter
          spacing: root.sp(3)
          Label { text: "OmaQuota"; font.pixelSize: root.fs(Style.font.heading); font.bold: true; width: parent.width }
          Label {
            text: root.statusText().toUpperCase()
            visible: text !== ""
            color: root.dim
            font.pixelSize: root.fs(Style.font.caption)
            font.bold: true
            font.letterSpacing: 1.2
            width: parent.width
          }
        }

        Row {
          id: headButtons
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: root.sp(4)
          Button {
            iconText: "󰑐"
            iconSpinning: root.updating
            tooltipText: strings.t("refresh")
            foreground: root.fg
            fontFamily: root.fontFamily
            onClicked: root.refresh()
          }
          Button {
            iconText: "󰏘"
            tooltipText: strings.t("display.button")
            foreground: root.fg
            fontFamily: root.fontFamily
            active: root.detailView === "display"
            onClicked: root.toggleDisplay()
          }
        }
      }

      Label {
        id: emptyText
        visible: root.providers.length === 0
        anchors.top: panelHeader.bottom
        anchors.topMargin: root.sp(18)
        width: parent.width
        text: strings.t("empty")
        color: root.dim
        font.pixelSize: root.fs(Style.font.body)
        wrapMode: Text.Wrap
        elide: Text.ElideNone
      }

      // ---------- Left: one row per provider ----------
      Flickable {
        id: rail
        visible: root.providers.length > 0
        anchors.top: panelHeader.bottom
        anchors.topMargin: root.sp(18)
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        width: root.railWidth
        contentWidth: width
        contentHeight: railCol.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { id: railBar; policy: ScrollBar.AsNeeded }

        Column {
          id: railCol
          width: rail.width - (rail.interactive ? railBar.width + root.sp(4) : 0)
          spacing: root.sp(4)
          Repeater {
            model: root.providers
            delegate: ProviderRow {
              required property var modelData
              p: modelData
              width: railCol.width
            }
          }
        }
      }

      Rectangle {
        visible: root.providers.length > 0
        x: root.railWidth + root.columnGap / 2
        anchors.top: rail.top
        anchors.bottom: parent.bottom
        width: 1
        color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.12)
      }

      // ---------- Right: the selected provider, its settings, or display options ----------
      Flickable {
        id: detail
        visible: root.providers.length > 0
        anchors.top: panelHeader.bottom
        anchors.topMargin: root.sp(18)
        anchors.bottom: parent.bottom
        x: root.railWidth + root.columnGap
        width: Math.max(0, parent.width - x)
        contentWidth: width
        contentHeight: detailCol.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { id: detailBar; policy: ScrollBar.AsNeeded }

        Column {
          id: detailCol
          width: detail.width - (detail.interactive ? detailBar.width + root.sp(6) : 0)
          spacing: root.sp(root.cards ? 16 : 12)

          // Logo · name · plan, and the Limits / Settings tabs.
          Item {
            visible: root.detailView !== "display" && root.selected !== null
            width: parent.width
            implicitHeight: Math.max(detailName.implicitHeight, tabs.implicitHeight)
            Logo {
              id: detailLogo
              providerId: root.selected ? root.selected.id : ""
              lightSurface: root.lightPopup
              size: root.sp(22)
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }
            Column {
              id: detailName
              anchors.left: detailLogo.visible ? detailLogo.right : parent.left
              anchors.leftMargin: detailLogo.visible ? root.sp(10) : 0
              anchors.right: tabs.left
              anchors.rightMargin: root.sp(8)
              anchors.verticalCenter: parent.verticalCenter
              spacing: root.sp(2)
              Label {
                text: root.selected ? root.selected.name : ""
                font.pixelSize: root.fs(Style.font.heading)
                font.bold: true
                width: parent.width
              }
              Label {
                text: root.selected ? (root.selected.noData ? strings.t("noData") : root.selected.plan) : ""
                visible: text !== ""
                color: root.dim
                font.pixelSize: root.fs(Style.font.bodySmall)
                width: parent.width
              }
            }
            Row {
              id: tabs
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: root.sp(4)
              Button {
                text: strings.t("tab.limits")
                fontSize: root.fs(Style.font.bodySmall)
                foreground: root.fg
                fontFamily: root.fontFamily
                bordered: true
                active: root.detailView === "limits"
                onClicked: root.detailView = "limits"
              }
              Button {
                iconText: "󰒓"
                text: strings.t("tab.settings")
                tooltipText: strings.t("tab.settingsTip")
                fontSize: root.fs(Style.font.bodySmall)
                foreground: root.selected && root.barMap[root.selected.id] ? root.accent : root.fg
                fontFamily: root.fontFamily
                bordered: true
                active: root.detailView === "settings"
                onClicked: root.detailView = "settings"
              }
            }
          }

          ProviderBlock {
            visible: root.detailView === "limits" && root.selected !== null
            p: root.selected || root.emptyProvider
            width: parent.width
          }

          ProviderDrawer {
            visible: root.detailView === "settings" && root.selected !== null
            p: root.selected || root.emptyProvider
            inBar: root.selected ? (root.barMap[root.selected.id] || "") : ""
            width: parent.width
          }

          // Display options: a title, then the choices.
          Item {
            visible: root.detailView === "display"
            width: parent.width
            implicitHeight: Math.max(displayTitle.implicitHeight, displayClose.implicitHeight)
            Column {
              id: displayTitle
              anchors.left: parent.left
              anchors.right: displayClose.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: root.sp(2)
              Label { text: strings.t("display.title"); font.pixelSize: root.fs(Style.font.heading); font.bold: true; width: parent.width }
              Label { text: strings.t("side.displaySettings"); color: root.dim; font.pixelSize: root.fs(Style.font.bodySmall); width: parent.width }
            }
            Button {
              id: displayClose
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              iconText: "󰅖"
              tooltipText: strings.t("side.close")
              foreground: root.fg
              fontFamily: root.fontFamily
              onClicked: root.detailView = "limits"
            }
          }
        Column {
          id: displayCol
          visible: root.detailView === "display"
          width: parent.width
          spacing: root.sp(12)
          OptionRow {
            label: strings.t("display.style")
            options: [{ value: "Cards", text: strings.t("display.cards") }, { value: "Compact", text: strings.t("display.compact") }]
            current: root.cards ? "Cards" : "Compact"
            onPicked: function(v) { root.saveSetting("style", v) }
          }
          OptionRow {
            label: strings.t("display.size")
            options: [{ value: "Small", text: strings.t("display.small") }, { value: "Medium", text: strings.t("display.medium") }, { value: "Large", text: strings.t("display.large") }]
            current: root.uiSize
            onPicked: function(v) { root.saveSetting("uiSize", v) }
          }
          OptionRow {
            label: strings.t("display.values")
            options: [{ value: "Left", text: strings.t("display.left") }, { value: "Used", text: strings.t("display.used") }, { value: "Both", text: strings.t("display.both") }]
            current: root.valueMode
            onPicked: function(v) { root.saveSetting("valueMode", v) }
          }
          OptionRow {
            label: strings.t("display.logos")
            options: [{ value: "Colour", text: strings.t("display.colour") }, { value: "Mono", text: strings.t("display.mono") }]
            current: root.monoLogos ? "Mono" : "Colour"
            onPicked: function(v) { root.saveSetting("logoStyle", v) }
          }
          OptionRow {
            label: strings.t("display.barReset")
            options: [{ value: "off", text: strings.t("display.off") }, { value: "on", text: strings.t("display.on") }]
            current: root.barReset ? "on" : "off"
            onPicked: function(v) { root.saveSetting("barReset", v === "on") }
          }
          OptionRow {
            label: strings.t("display.warnAt")
            options: [{ value: 80, text: "80%" }, { value: 85, text: "85%" }, { value: 90, text: "90%" }, { value: 95, text: "95%" }]
            current: root.alertAt
            onPicked: function(v) { root.saveSetting("alertAt", v) }
          }
        }
        }
      }
    }
  }

  // The selected provider's limits, banked resets and accounts. Cards: large
  // figures and accent meters. Compact: one thin line per limit.
  component ProviderBlock: Item {
    id: block
    property var p
    readonly property var shownWindows: Model.visibleWindows(p.windows)
    readonly property bool manyAccounts: p.switchable && p.accounts.length > 3
    implicitHeight: inner.implicitHeight

    Column {
      id: inner
      width: block.width
      spacing: root.sp(root.cards ? 16 : 10)

      // Cards: one tile per window, up to three across.
      Grid {
        id: tiles
        visible: root.cards && block.shownWindows.length > 0
        width: parent.width
        columns: Math.max(1, Math.min(3, block.shownWindows.length))
        columnSpacing: root.sp(16)
        rowSpacing: root.sp(14)
        readonly property real cell: (width - columnSpacing * (columns - 1)) / columns
        Repeater {
          model: root.cards ? block.shownWindows : []
          delegate: Column {
            required property var modelData
            width: tiles.cell
            spacing: root.sp(5)
            Label {
              text: root.pct(root.shown(modelData.percent))
              font.pixelSize: root.fs(Style.font.display)
              font.bold: true
              color: root.levelColor(modelData.percent, root.fg)
              width: parent.width
            }
            Label {
              text: (modelData.title + "  ·  " + (root.bothMode ? strings.t("value.used").arg(root.pct(modelData.percent))
                : (root.leftMode ? strings.t("display.left") : strings.t("display.used")))).toUpperCase()
              font.pixelSize: root.fs(Style.font.caption)
              font.bold: true
              font.letterSpacing: 1.2
              color: root.dim
              width: parent.width
            }
            Meter { width: parent.width; value: root.shown(modelData.percent); fill: root.levelColor(modelData.percent, root.accent) }
            Label {
              text: root.resetLine(modelData)
              font.pixelSize: root.fs(Style.font.bodySmall)
              color: root.dim
              width: parent.width
            }
          }
        }
      }

      // Compact: title · meter · percent · reset on one line.
      Repeater {
        model: root.cards ? [] : block.shownWindows
        delegate: Item {
          required property var modelData
          width: inner.width
          implicitHeight: Math.max(winPct.implicitHeight, winReset.implicitHeight)
          Label {
            id: winTitle
            width: root.sp(68)
            text: modelData.title
            color: root.dim
            font.pixelSize: root.fs(Style.font.bodySmall)
            anchors.verticalCenter: parent.verticalCenter
          }
          Meter {
            anchors.left: winTitle.right
            anchors.right: winPct.left
            anchors.leftMargin: root.sp(8)
            anchors.rightMargin: root.sp(10)
            anchors.verticalCenter: parent.verticalCenter
            value: root.shown(modelData.percent)
            fill: root.levelColor(modelData.percent, root.fg)
          }
          Label {
            id: winPct
            anchors.right: winReset.left
            anchors.rightMargin: root.sp(12)
            anchors.verticalCenter: parent.verticalCenter
            width: root.sp(44)
            horizontalAlignment: Text.AlignRight
            text: root.pct(root.shown(modelData.percent))
            color: root.levelColor(modelData.percent, root.fg)
            font.pixelSize: root.fs(Style.font.body)
            font.bold: true
          }
          Label {
            id: winReset
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: root.sp(root.bothMode ? 200 : 140)
            text: (root.bothMode ? strings.t("value.used").arg(root.pct(modelData.percent)) + "  ·  " : "") + root.resetLine(modelData)
            color: root.dim
            font.pixelSize: root.fs(Style.font.bodySmall)
          }
        }
      }

      // Banked resets (Codex): free full resets waiting to be used. Folded
      // to a count; opening it lists each one with its deadline.
      Column {
        id: bankedBox
        visible: root.bankedOf(block.p) !== null
        width: parent.width
        spacing: root.sp(6)

        SectionToggle {
          title: strings.t("banked.label")
          summary: root.bankedText(root.bankedOf(block.p))
          expanded: root.bankedOpen
          onToggle: {
            root.bankedOpen = !root.bankedOpen
            if (root.bankedOpen) root.loadResets(false)
          }
        }
        Label {
          visible: root.bankedOpen && (root.resetLoading || root.resetError !== "")
          text: (root.resetLoading ? strings.t("banked.loading") : root.resetError) || ""
          color: root.dim
          font.pixelSize: root.fs(Style.font.bodySmall)
          wrapMode: Text.Wrap
          elide: Text.ElideNone
          width: parent.width
        }
        Repeater {
          model: root.bankedOpen && !root.resetLoading ? root.resetList : []
          delegate: Item {
            required property var modelData
            required property int index
            readonly property bool soon: modelData.expiresAt > 0 && modelData.expiresAt - root.nowMs < 3 * 86400000
            width: bankedBox.width
            implicitHeight: Math.max(resetTitle.implicitHeight, resetWhen.implicitHeight) + root.sp(4)
            Label {
              id: resetTitle
              anchors.left: parent.left
              anchors.right: resetWhen.left
              anchors.rightMargin: root.sp(10)
              anchors.verticalCenter: parent.verticalCenter
              text: (index + 1) + ".  " + modelData.title
              font.pixelSize: root.fs(Style.font.bodySmall)
            }
            Label {
              id: resetWhen
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.deadlineText(modelData.expiresAt)
              color: parent.soon ? root.accent : root.dim
              font.bold: parent.soon
              font.pixelSize: root.fs(Style.font.bodySmall)
            }
          }
        }
        Label {
          visible: root.bankedOpen && !root.resetLoading && root.resetError === "" && root.resetListAt > 0 && root.resetList.length === 0
          text: strings.t("banked.none")
          color: root.dim
          font.pixelSize: root.fs(Style.font.bodySmall)
          width: parent.width
        }
      }

      // Many accounts: one tidy row each instead of a wrapping heap of chips.
      Column {
        visible: block.manyAccounts
        width: parent.width
        spacing: root.sp(2)
        Repeater {
          model: block.manyAccounts ? block.p.accounts : []
          delegate: AccountRow {
            required property var modelData
            account: modelData
            providerId: block.p.id
            width: parent ? parent.width : 0
          }
        }
      }

      // Accounts: click (or arrows + Enter) to make one the account new sessions use.
      Flow {
        visible: block.p.switchable
        width: parent.width
        spacing: root.sp(8)
        Repeater {
          model: block.p.switchable && !block.manyAccounts ? block.p.accounts : []
          delegate: Button {
            required property var modelData
            text: root.chipName(modelData.label) + (!modelData.active ? "  ·  " + root.pct(root.shown(modelData.peak)) : "")
            iconText: modelData.active ? "󰄬" : ""
            tooltipText: modelData.active ? strings.t("account.active").arg(modelData.email || modelData.label)
              : strings.t("account.use").arg(modelData.email || modelData.label)
            fontSize: root.fs(Style.font.body)
            foreground: root.fg
            fontFamily: root.fontFamily
            bordered: true
            active: modelData.active
            hasCursor: root.cursor === root.targetIndex(block.p.id, modelData.id)
            onClicked: root.useAccount(block.p.id, modelData.id)
            onHovered: function(h) { if (h) root.cursor = root.targetIndex(block.p.id, modelData.id) }
          }
        }
        Button {
          visible: block.p.switchable
          iconText: "󰐕"
          text: block.manyAccounts ? strings.t("account.addShort") : ""
          tooltipText: strings.t("account.add")
          fontSize: root.fs(Style.font.body)
          foreground: root.fg
          fontFamily: root.fontFamily
          bordered: true
          hasCursor: root.cursor === root.targetIndex(block.p.id, "")
          onClicked: root.addAccount(block.p.id)
          onHovered: function(h) { if (h) root.cursor = root.targetIndex(block.p.id, "") }
        }
        Button {
          visible: block.p.switchable && block.p.accounts.length >= 2
          text: block.p.auto ? strings.t("auto.on") : strings.t("auto.off")
          iconText: block.p.auto ? "󰁨" : ""
          tooltipText: strings.t("auto.tooltip").arg(block.p.threshold)
          fontSize: root.fs(Style.font.bodySmall)
          foreground: block.p.auto ? root.fg : root.dim
          fontFamily: root.fontFamily
          active: block.p.auto
          onClicked: root.toggleAuto(block.p)
        }
      }
    }
  }

  // An agent's drawer: what it shows in the bar, its numbers, its files and,
  // for Claude, settings that follow the account. Every section starts folded.
  component ProviderDrawer: Rectangle {
    id: drawer
    property var p
    property string inBar: ""
    readonly property var d: p.details
    readonly property bool hasSettings: Model.SETTINGS_PROVIDERS.indexOf(p.id) >= 0 && p.accounts.length >= 2
    readonly property var managed: Model.managedKeys(root.accountSettings, p.id)
    readonly property var addable: Model.booleanKeys(root.claudeSettings).filter(function(k) { return managed.indexOf(k) < 0 })
    readonly property var files: root.filesFor(p)
    property bool adding: false
    // The account whose settings are shown: the active one until another is picked.
    property string viewId: ""
    readonly property var viewAccount: {
      var pick = null
      for (var i = 0; i < p.accounts.length; i++) {
        if (p.accounts[i].id === viewId) return p.accounts[i]
        if (p.accounts[i].active) pick = p.accounts[i]
      }
      return pick || p.accounts[0] || null
    }
    readonly property var viewValues: viewAccount ? ((root.accountSettings[p.id] || {})[viewAccount.id] || {}) : ({})

    function isOpen(key) { return root.sectionOpen(key) }
    function flip(key) { root.flipSection(key) }

    implicitHeight: drawerCol.implicitHeight
    color: "transparent"

    Column {
      id: drawerCol
      x: root.sp(6)
      width: parent.width - root.sp(12)
      spacing: root.sp(4)

      // ---------- In the bar ----------
      SectionToggle {
        visible: drawer.p.windows.length > 0
        title: strings.t("bar.title")
        summary: drawer.inBar === "" ? strings.t("bar.off")
          : (drawer.inBar === Model.TIGHTEST ? strings.t("bar.tightest") : drawer.inBar)
            + (root.barAll[drawer.p.id] && drawer.p.accounts.length > 1 ? "  ·  " + strings.t("bar.accountsAll").toLowerCase() : "")
        expanded: drawer.isOpen("bar")
        onToggle: drawer.flip("bar")
      }
      SectionBody {
        visible: drawer.p.windows.length > 0 && drawer.isOpen("bar")
        OptionRow {
          label: strings.t("bar.label")
          options: {
            var out = [{ value: "", text: strings.t("bar.off") }, { value: Model.TIGHTEST, text: strings.t("bar.tightest") }]
            for (var i = 0; i < drawer.p.windows.length; i++) out.push({ value: drawer.p.windows[i].title, text: drawer.p.windows[i].title })
            return out
          }
          current: drawer.inBar
          onPicked: function(v) { root.setBarItem(drawer.p.id, v) }
        }
        OptionRow {
          visible: drawer.inBar !== "" && drawer.p.switchable && drawer.p.accounts.length > 1
          label: strings.t("bar.accounts")
          options: [{ value: "active", text: strings.t("bar.accountsActive") }, { value: "all", text: strings.t("bar.accountsAll") }]
          current: root.barAll[drawer.p.id] ? "all" : "active"
          onPicked: function(v) { root.setBarAll(drawer.p.id, v === "all") }
        }
      }

      // ---------- Usage ----------
      SectionToggle {
        visible: drawer.d !== null
        title: strings.t("details.title")
        summary: drawer.d ? strings.tn("details.summary", drawer.d.todayPrompts).arg(Commons.I18n.formatNumber(drawer.d.todayPrompts)) : ""
        expanded: drawer.isOpen("usage")
        onToggle: drawer.flip("usage")
      }
      SectionBody {
        visible: drawer.d !== null && drawer.isOpen("usage")
        InfoPair {
          label: strings.t("details.today")
          value: drawer.d ? strings.t("details.counts").arg(Commons.I18n.formatNumber(drawer.d.todayPrompts)).arg(Commons.I18n.formatNumber(drawer.d.todaySessions)).arg(root.tokensText(drawer.d.todayTokens)) : ""
        }
        InfoPair {
          label: strings.t("details.allTime")
          value: drawer.d ? strings.t("details.totals").arg(Commons.I18n.formatNumber(drawer.d.totalPrompts)).arg(Commons.I18n.formatNumber(drawer.d.totalSessions)) : ""
        }
        InfoPair {
          visible: drawer.d !== null && drawer.d.banked !== null
          label: strings.t("banked.label")
          value: root.bankedText(drawer.d ? drawer.d.banked : null)
        }
        InfoPair {
          label: strings.t("details.checked")
          value: drawer.d ? root.agoText(drawer.d.fetchedAt) + (drawer.d.stale ? "  ·  " + strings.t("details.stale") : "") : ""
        }
        Label {
          visible: drawer.d !== null && drawer.d.note !== ""
          text: drawer.d ? drawer.d.note : ""
          color: root.dim
          font.pixelSize: root.fs(Style.font.bodySmall)
          wrapMode: Text.Wrap
          elide: Text.ElideNone
          width: parent.width
        }
      }

      // ---------- Files ----------
      SectionToggle {
        title: strings.t("files.title")
        summary: strings.tn("files.count", drawer.files.length).arg(Commons.I18n.formatNumber(drawer.files.length))
        expanded: drawer.isOpen("files")
        onToggle: drawer.flip("files")
      }
      SectionBody {
        visible: drawer.isOpen("files")
        Repeater {
          model: drawer.isOpen("files") ? drawer.files : []
          delegate: Item {
            required property var modelData
            width: drawerCol.width
            implicitHeight: Math.max(fileText.implicitHeight, fileButtons.implicitHeight)
            Column {
              id: fileText
              anchors.left: parent.left
              anchors.right: fileButtons.left
              anchors.rightMargin: root.sp(8)
              anchors.verticalCenter: parent.verticalCenter
              spacing: root.sp(1)
              Label { text: modelData.label; color: root.dim; font.pixelSize: root.fs(Style.font.caption); width: parent.width }
              Label { text: modelData.path; font.pixelSize: root.fs(Style.font.bodySmall); elide: Text.ElideMiddle; width: parent.width }
            }
            Row {
              id: fileButtons
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: root.sp(2)
              Button {
                visible: root.editable(modelData.path)
                iconText: "󰏫"
                tooltipText: strings.t("files.edit")
                iconSize: root.fs(Style.font.bodySmall)
                foreground: root.fg
                fontFamily: root.fontFamily
                onClicked: root.editFile(modelData.path)
              }
              Button {
                iconText: "󰆏"
                tooltipText: strings.t("files.copy")
                iconSize: root.fs(Style.font.bodySmall)
                foreground: root.fg
                fontFamily: root.fontFamily
                onClicked: root.copyPath(modelData.path)
              }
              Button {
                iconText: "󰉋"
                tooltipText: strings.t("files.open")
                iconSize: root.fs(Style.font.bodySmall)
                foreground: root.fg
                fontFamily: root.fontFamily
                onClicked: root.openFolder(modelData.path)
              }
            }
          }
        }
      }

      // ---------- Per-account settings (Claude) ----------
      SectionToggle {
        visible: drawer.hasSettings
        title: strings.t("acct.title")
        summary: strings.tn("acct.summary", drawer.managed.length).arg(Commons.I18n.formatNumber(drawer.managed.length))
        expanded: drawer.isOpen("acct")
        onToggle: drawer.flip("acct")
      }
      SectionBody {
        visible: drawer.hasSettings && drawer.isOpen("acct")
        Label {
          text: strings.t("acct.hint")
          color: root.dim
          font.pixelSize: root.fs(Style.font.bodySmall)
          wrapMode: Text.Wrap
          elide: Text.ElideNone
          width: parent.width
        }
        // One account at a time; the tick marks the one new sessions use.
        Flow {
          width: parent.width
          spacing: root.sp(6)
          Repeater {
            model: drawer.hasSettings ? drawer.p.accounts : []
            delegate: Button {
              required property var modelData
              text: root.chipName(modelData.label)
              iconText: modelData.active ? "󰄬" : ""
              tooltipText: strings.t("acct.view").arg(modelData.email || modelData.label)
              fontSize: root.fs(Style.font.bodySmall)
              foreground: root.fg
              fontFamily: root.fontFamily
              bordered: true
              active: drawer.viewAccount !== null && drawer.viewAccount.id === modelData.id
              onClicked: drawer.viewId = modelData.id
            }
          }
        }
        Label {
          visible: drawer.managed.length === 0
          text: strings.t("acct.empty")
          color: root.dim
          font.pixelSize: root.fs(Style.font.bodySmall)
          width: parent.width
        }
        Repeater {
          model: drawer.hasSettings && drawer.isOpen("acct") ? drawer.managed : []
          delegate: Item {
            id: keyRow
            required property var modelData
            width: drawerCol.width
            implicitHeight: Math.max(keyLabel.implicitHeight, keyControls.implicitHeight)
            Label {
              id: keyLabel
              anchors.left: parent.left
              anchors.right: keyControls.left
              anchors.rightMargin: root.sp(8)
              anchors.verticalCenter: parent.verticalCenter
              text: Model.humanizeKey(keyRow.modelData)
              font.pixelSize: root.fs(Style.font.body)
            }
            Row {
              id: keyControls
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: root.sp(6)
              ToggleSwitch {
                anchors.verticalCenter: parent.verticalCenter
                foreground: root.fg
                checked: drawer.viewValues[keyRow.modelData] === true
                onToggled: if (drawer.viewAccount) root.saveAccountSettings(Model.setAccountKey(root.accountSettings, drawer.p.id, drawer.viewAccount.id, keyRow.modelData, !checked))
              }
              Button {
                anchors.verticalCenter: parent.verticalCenter
                iconText: "󰅖"
                tooltipText: strings.t("acct.stop")
                iconSize: root.fs(Style.font.bodySmall)
                foreground: root.dim
                fontFamily: root.fontFamily
                onClicked: root.saveAccountSettings(Model.unmanageKey(root.accountSettings, drawer.p.id, keyRow.modelData))
              }
            }
          }
        }
        Button {
          visible: drawer.addable.length > 0
          iconText: drawer.adding ? "󰅖" : "󰐕"
          text: strings.t("acct.add")
          fontSize: root.fs(Style.font.bodySmall)
          foreground: root.fg
          fontFamily: root.fontFamily
          bordered: true
          active: drawer.adding
          onClicked: drawer.adding = !drawer.adding
        }
        Flow {
          visible: drawer.adding
          width: parent.width
          spacing: root.sp(6)
          Repeater {
            model: drawer.adding ? drawer.addable : []
            delegate: Button {
              required property var modelData
              text: Model.humanizeKey(modelData)
              fontSize: root.fs(Style.font.bodySmall)
              foreground: root.fg
              fontFamily: root.fontFamily
              bordered: true
              onClicked: {
                root.saveAccountSettings(Model.manageKey(root.accountSettings, drawer.p.id,
                  drawer.p.accounts.map(function(a) { return a.id }), modelData, (root.claudeSettings || {})[modelData]))
                drawer.adding = false
              }
            }
          }
        }
      }
    }
  }

  // A drawer section's header: chevron, title and a one-line summary.
  component SectionToggle: Item {
    id: section
    property string title: ""
    property string summary: ""
    property bool expanded: false
    signal toggle()
    width: parent ? parent.width : 0
    implicitHeight: Math.max(sectionTitle.implicitHeight, sectionSummary.implicitHeight) + root.sp(14)

    Rectangle {
      anchors.fill: parent
      anchors.leftMargin: -root.sp(6)
      anchors.rightMargin: -root.sp(6)
      radius: Style.cornerRadius
      color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, sectionMouse.containsMouse ? 0.06 : 0)
    }
    Text {
      id: chevron
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: section.expanded ? "󰅀" : "󰅂"
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: root.fs(Style.font.body)
    }
    Label {
      id: sectionTitle
      anchors.left: chevron.right
      anchors.leftMargin: root.sp(6)
      anchors.verticalCenter: parent.verticalCenter
      text: section.title.toUpperCase()
      font.pixelSize: root.fs(Style.font.caption)
      font.bold: true
      font.letterSpacing: 1.2
    }
    Label {
      id: sectionSummary
      anchors.left: sectionTitle.right
      anchors.leftMargin: root.sp(12)
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      horizontalAlignment: Text.AlignRight
      text: section.summary
      color: root.dim
      font.pixelSize: root.fs(Style.font.bodySmall)
    }
    MouseArea {
      id: sectionMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: section.toggle()
    }
  }

  // The content under an open section.
  component SectionBody: Column {
    width: parent ? parent.width : 0
    spacing: root.sp(10)
    topPadding: root.sp(2)
    bottomPadding: root.sp(10)
  }

  // A provider in the left list: logo, name, its tightest limit, the account
  // in use and its plan. Click (or ↑ ↓) to show it on the right.
  component ProviderRow: Item {
    id: row
    property var p
    readonly property bool picked: root.selected !== null && root.selected.id === p.id
    readonly property var activeAccount: p.accounts.filter(function(a) { return a.active })[0] || null
    readonly property var banked: root.bankedOf(p)
    readonly property string subtitle: {
      var parts = []
      if (activeAccount && p.accounts.length > 1) parts.push(activeAccount.label)
      if (p.plan) parts.push(p.plan)
      if (banked) parts.push(strings.tn("banked.short", banked.available).arg(Commons.I18n.formatNumber(banked.available)))
      if (p.noData) parts.push(strings.t("noData"))
      return parts.join("  ·  ")
    }
    implicitHeight: rowCol.implicitHeight + root.sp(18)

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, row.picked ? 0.08 : (rowMouse.containsMouse ? 0.04 : 0))
    }
    Rectangle {
      visible: row.picked
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      anchors.topMargin: root.sp(10)
      anchors.bottomMargin: root.sp(10)
      width: root.sp(3)
      radius: width / 2
      color: root.accent
    }
    Column {
      id: rowCol
      x: root.sp(14)
      y: root.sp(9)
      width: row.width - root.sp(26)
      spacing: root.sp(5)
      Item {
        width: parent.width
        implicitHeight: Math.max(rowName.implicitHeight, rowLogo.height)
        Logo {
          id: rowLogo
          providerId: row.p.id
          lightSurface: root.lightPopup
          size: root.sp(16)
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
        }
        Label {
          id: rowName
          anchors.left: rowLogo.visible ? rowLogo.right : parent.left
          anchors.leftMargin: rowLogo.visible ? root.sp(8) : 0
          anchors.right: rowPct.left
          anchors.rightMargin: root.sp(6)
          anchors.verticalCenter: parent.verticalCenter
          text: row.p.name
          font.bold: true
          font.pixelSize: root.fs(Style.font.body)
        }
        Label {
          id: rowPct
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          visible: !row.p.noData
          text: root.pct(root.shown(row.p.peak))
          color: root.levelColor(row.p.peak, root.fg)
          font.bold: true
          font.pixelSize: root.fs(Style.font.bodySmall)
        }
      }
      Label {
        visible: text !== ""
        width: parent.width
        text: row.subtitle
        color: root.dim
        font.pixelSize: root.fs(Style.font.caption)
      }
      Meter {
        visible: !row.p.noData
        width: parent.width
        implicitHeight: root.sp(4)
        value: root.shown(row.p.peak)
        fill: root.levelColor(row.p.peak, root.cards ? root.accent : root.fg)
      }
    }
    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.selectProvider(row.p.id)
    }
  }

  // One account in a long list: tick, name, plan, a small meter and its
  // tightest limit. Clicking makes it the account new sessions use.
  component AccountRow: Item {
    id: accountRow
    property var account
    property string providerId: ""
    readonly property int keyIndex: root.targetIndex(providerId, account.id)
    readonly property bool lit: rowMouse.containsMouse || root.cursor === keyIndex
    implicitHeight: Math.max(rowName.implicitHeight, rowPct.implicitHeight) + root.sp(14)

    Rectangle {
      anchors.fill: parent
      anchors.leftMargin: -root.sp(6)
      anchors.rightMargin: -root.sp(6)
      radius: Style.cornerRadius
      color: accountRow.account.active ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.14)
        : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, accountRow.lit ? 0.07 : 0)
    }
    Text {
      id: rowTick
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: root.sp(20)
      textFormat: Text.PlainText
      text: accountRow.account.active ? "󰄬" : "󰄰"
      color: accountRow.account.active ? root.accent : root.dim
      font.family: root.fontFamily
      font.pixelSize: root.fs(Style.font.body)
    }
    Label {
      id: rowName
      anchors.left: rowTick.right
      anchors.right: rowPlan.left
      anchors.rightMargin: root.sp(8)
      anchors.verticalCenter: parent.verticalCenter
      text: accountRow.account.label
      font.bold: accountRow.account.active
      font.pixelSize: root.fs(Style.font.body)
    }
    Label {
      id: rowPlan
      anchors.right: rowMeter.left
      anchors.rightMargin: root.sp(12)
      anchors.verticalCenter: parent.verticalCenter
      width: root.sp(64)
      horizontalAlignment: Text.AlignRight
      text: accountRow.account.plan
      color: root.dim
      font.pixelSize: root.fs(Style.font.bodySmall)
    }
    Meter {
      id: rowMeter
      anchors.right: rowPct.left
      anchors.rightMargin: root.sp(10)
      anchors.verticalCenter: parent.verticalCenter
      width: root.sp(72)
      value: root.shown(accountRow.account.peak)
      fill: root.levelColor(accountRow.account.peak, root.cards ? root.accent : root.fg)
    }
    Label {
      id: rowPct
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: root.sp(40)
      horizontalAlignment: Text.AlignRight
      text: root.pct(root.shown(accountRow.account.peak))
      color: root.levelColor(accountRow.account.peak, root.fg)
      font.pixelSize: root.fs(Style.font.bodySmall)
      font.bold: true
    }
    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: accountRow.account.active ? Qt.ArrowCursor : Qt.PointingHandCursor
      onEntered: root.cursor = accountRow.keyIndex
      onClicked: root.useAccount(accountRow.providerId, accountRow.account.id)
    }
    PanelToolTip {
      visible: rowMouse.containsMouse
      text: accountRow.account.active ? strings.t("account.active").arg(accountRow.account.email || accountRow.account.label)
        : strings.t("account.use").arg(accountRow.account.email || accountRow.account.label)
    }
  }

  // A label on the left and a segmented choice on the right.
  component OptionRow: Item {
    id: optionRow
    property string label: ""
    property var options: []
    property var current: ""
    signal picked(var value)
    width: parent ? parent.width : 0
    implicitHeight: Math.max(optionLabel.implicitHeight, optionButtons.implicitHeight)
    Label {
      id: optionLabel
      anchors.left: parent.left
      anchors.right: optionButtons.left
      anchors.rightMargin: root.sp(8)
      anchors.verticalCenter: parent.verticalCenter
      text: optionRow.label
      color: root.dim
      font.pixelSize: root.fs(Style.font.bodySmall)
    }
    Row {
      id: optionButtons
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: root.sp(4)
      Repeater {
        model: optionRow.options
        delegate: Button {
          required property var modelData
          text: modelData.text
          fontSize: root.fs(Style.font.bodySmall)
          foreground: root.fg
          fontFamily: root.fontFamily
          bordered: true
          active: optionRow.current === modelData.value
          onClicked: optionRow.picked(modelData.value)
        }
      }
    }
  }

  component InfoPair: Item {
    property string label: ""
    property string value: ""
    width: parent ? parent.width : 0
    implicitHeight: Math.max(infoLabel.implicitHeight, infoValue.implicitHeight)
    Label {
      id: infoLabel
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: parent.label
      color: root.dim
      font.pixelSize: root.fs(Style.font.bodySmall)
    }
    Label {
      id: infoValue
      anchors.left: infoLabel.right
      anchors.leftMargin: root.sp(12)
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      horizontalAlignment: Text.AlignRight
      text: parent.value
      font.pixelSize: root.fs(Style.font.bodySmall)
    }
  }

  component Meter: Rectangle {
    property real value: 0
    property color fill: root.fg
    implicitHeight: root.sp(root.cards ? 6 : 5)
    height: implicitHeight
    radius: height / 2
    color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.12)
    Rectangle {
      height: parent.height
      radius: parent.radius
      color: parent.fill
      width: parent.value > 0 ? Math.max(parent.height, parent.width * parent.value) : 0
      Behavior on width { NumberAnimation { duration: Style.duration(240); easing.type: Easing.OutCubic } }
    }
  }

  // An agent's mark. Mono tints it with the bar's text colour.
  component Logo: Item {
    id: logoRoot
    property string providerId: ""
    property bool lightSurface: false
    property bool mono: false
    property color tint: root.fg
    property real size: root.sp(18)
    readonly property string file: root.logoFile(providerId, lightSurface)
    width: size
    height: size
    visible: logoImage.status === Image.Ready

    Image {
      id: logoImage
      anchors.fill: parent
      sourceSize.width: logoRoot.size * 2
      sourceSize.height: logoRoot.size * 2
      fillMode: Image.PreserveAspectFit
      asynchronous: true
      smooth: true
      // Kept as a hidden layer in mono so the effect can sample it.
      visible: !logoRoot.mono
      layer.enabled: logoRoot.mono
      // Only names read from the assets folder, so it can't point anywhere else.
      source: logoRoot.file === "" ? "" : root.logoDir + logoRoot.file
    }

    MultiEffect {
      anchors.fill: logoImage
      source: logoImage
      visible: logoRoot.mono
      colorization: 1.0
      colorizationColor: logoRoot.tint
    }
  }

  component Label: Text {
    textFormat: Text.PlainText
    color: root.fg
    font.family: root.fontFamily
    font.pixelSize: root.fs(Style.font.body)
    elide: Text.ElideRight
  }
}
