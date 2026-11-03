.pragma library

// Pure functions behind the panel: turn Omarchy's account list and usage
// records into display rows, and decide which limits deserve a warning. No
// QML here, so node runs the same file in tests/model.test.js.

// Providers Omarchy can hold several accounts for (`omarchy agent account`).
var ACCOUNT_PROVIDERS = ["claude", "codex", "grok"]
var MAX_WINDOWS = 6
var MAX_ACCOUNTS = 12

function validId(id) {
  return /^[a-z0-9][a-z0-9-]{0,31}$/.test(String(id))
}

function str(value, max) {
  return typeof value === "string" ? value.slice(0, max || 80) : ""
}

// "cursor, kimi,zai" -> ["cursor", "kimi", "zai"]. The ids become argv and
// file names, so anything that isn't a plain collector id is dropped.
function parseExtras(text) {
  var out = []
  var parts = String(text === undefined || text === null ? "" : text).toLowerCase().split(",")
  for (var i = 0; i < parts.length; i++) {
    var id = parts[i].trim()
    if (validId(id) && ACCOUNT_PROVIDERS.indexOf(id) < 0 && out.indexOf(id) < 0) out.push(id)
  }
  return out
}

function shortLabel(label) {
  var text = str(label, 40).trim()
  if (/^(session|5h)|5-hour/i.test(text)) return "5h"
  if (/^weekly|^7-day/i.test(text)) return "Week"
  if (/^monthly|\(monthly\)|per month/i.test(text)) return "Month"
  if (/^daily|\(daily\)|per day/i.test(text)) return "Day"
  return text
}

// A window whose reset time has passed is empty until the next request opens
// a new one (Codex's 5h window sits like that between sessions).
function windows(limits, now) {
  var out = []
  if (!Array.isArray(limits)) return out
  for (var i = 0; i < limits.length && out.length < MAX_WINDOWS; i++) {
    var l = limits[i]
    if (!l || typeof l !== "object") continue
    var percent = Number(l.percent)
    if (!isFinite(percent)) continue
    var resetAt = Date.parse(str(l.resetsAt, 64))
    var fresh = isFinite(resetAt) && resetAt <= now
    out.push({
      title: shortLabel(l.label),
      percent: fresh ? 0 : Math.max(0, Math.min(1, percent)),
      resetAt: isFinite(resetAt) ? resetAt : 0,
      fresh: fresh
    })
  }
  return out
}

function peak(wins) {
  var best = 0
  for (var i = 0; i < (wins || []).length; i++) best = Math.max(best, wins[i].percent)
  return best
}

function count(value) {
  var n = Number(value)
  return isFinite(n) && n >= 0 ? Math.floor(n) : 0
}

// Banked resets: free "full reset" credits Codex hands out, each wiping the
// rate limits once on demand and lapsing after a month. null when none.
function banked(credits) {
  if (!credits || typeof credits !== "object") return null
  var available = count(credits.available)
  if (available < 1) return null
  var expires = Date.parse(str(credits.nextExpiresAt, 64))
  return { available: Math.min(available, 99), nextExpiresAt: isFinite(expires) ? expires : 0 }
}

// bin/codex-resets output -> the banked resets still available, soonest
// deadline first: [{title, expiresAt, grantedAt}] (times in ms, 0 unknown).
function resetRows(answer) {
  var out = []
  var credits = answer && Array.isArray(answer.credits) ? answer.credits : []
  for (var i = 0; i < credits.length && out.length < 50; i++) {
    var c = credits[i]
    if (!c || typeof c !== "object" || c.status !== "available") continue
    var expires = Date.parse(str(c.expiresAt, 64))
    var granted = Date.parse(str(c.grantedAt, 64))
    out.push({ title: str(c.title, 60) || "Reset", expiresAt: isFinite(expires) ? expires : 0, grantedAt: isFinite(granted) ? granted : 0 })
  }
  out.sort(function(a, b) {
    if (!a.expiresAt !== !b.expiresAt) return a.expiresAt ? -1 : 1
    return a.expiresAt - b.expiresAt
  })
  return out
}

// The display-safe part of a usage record, for the provider's details section.
function details(rec) {
  if (!rec || typeof rec !== "object") return null
  return {
    todayPrompts: count(rec.todayPrompts),
    todaySessions: count(rec.todaySessions),
    todayTokens: count(rec.todayTotalTokens),
    totalPrompts: count(rec.totalPrompts),
    totalSessions: count(rec.totalSessions),
    fetchedAt: count(rec.limitsFetchedAt),
    stale: rec.limitsStale === true,
    note: str(rec.authHelpText, 200) || str(rec.usageStatusText, 200),
    banked: banked(rec.resetCredits)
  }
}

// accountList: `omarchy agent account list --json`. records: usage records
// (null when missing). Records of account providers only add details; the
// rest are extra providers, in the order asked for.
function normalize(accountList, records, now) {
  var out = []
  var list = Array.isArray(accountList) ? accountList : []
  var recs = Array.isArray(records) ? records : []
  var byId = {}
  for (var k = 0; k < recs.length; k++)
    if (recs[k] && typeof recs[k] === "object" && validId(recs[k].id)) byId[recs[k].id] = recs[k]
  for (var i = 0; i < list.length; i++) {
    var p = list[i]
    if (!p || !validId(p.provider) || !Array.isArray(p.accounts)) continue
    var accounts = []
    var active = null
    for (var a = 0; a < p.accounts.length && accounts.length < MAX_ACCOUNTS; a++) {
      var raw = p.accounts[a]
      if (!raw || !validId(raw.id)) continue
      var wins = windows(raw.limits, now)
      var acc = {
        id: raw.id,
        label: str(raw.label, 40) || raw.id,
        plan: str(raw.plan, 40),
        email: str(raw.email, 120),
        active: raw.active === true,
        signedIn: raw.signedIn === true,
        primary: raw.primary === true,
        home: str(raw.home, 300),
        windows: wins,
        peak: peak(wins)
      }
      if (acc.active) active = acc
      accounts.push(acc)
    }
    if (!accounts.some(function(x) { return x.signedIn })) continue
    if (!active) active = accounts[0]
    out.push({
      id: p.provider,
      name: str(p.name, 40) || p.provider,
      plan: active.plan,
      switchable: true,
      auto: p["switch"] === "auto",
      threshold: Math.max(1, Math.min(100, Number(p.threshold) || 95)),
      accounts: accounts,
      windows: active.windows,
      peak: active.peak,
      noData: false,
      details: details(byId[p.provider])
    })
  }
  for (var r = 0; r < recs.length; r++) {
    var rec = recs[r]
    if (!rec || typeof rec !== "object" || !validId(rec.id) || ACCOUNT_PROVIDERS.indexOf(rec.id) >= 0) continue
    var w = windows(rec.limits, now)
    out.push({
      id: rec.id,
      name: str(rec.name, 40) || rec.id,
      plan: str(rec.tierLabel, 40),
      switchable: false,
      auto: false,
      threshold: 0,
      accounts: [],
      windows: w,
      peak: peak(w),
      noData: w.length === 0,
      details: details(rec)
    })
  }
  return out
}

// Limits at or over the threshold that nobody has warned about yet. Providers
// with two or more accounts are left to Omarchy, whose own check notifies (or
// switches) for them on every usage update.
function alerts(providers, thresholdPct, seen) {
  var out = []
  for (var i = 0; i < (providers || []).length; i++) {
    var p = providers[i]
    if (p.accounts.length >= 2) continue
    for (var j = 0; j < p.windows.length; j++) {
      var w = p.windows[j]
      if (w.fresh || w.percent * 100 < thresholdPct) continue
      var key = p.id + "|" + w.title + "|" + w.resetAt
      if (seen && seen[key]) continue
      out.push({ key: key, provider: p.name, title: w.title, percent: w.percent, resetAt: w.resetAt })
    }
  }
  return out
}

// Milliseconds to a translation key plus its arguments: 2d 4h, 2h 13m, 9m.
function countdown(ms) {
  if (!(ms > 0)) return null
  var minutes = Math.ceil(ms / 60000)
  var d = Math.floor(minutes / 1440)
  var h = Math.floor((minutes % 1440) / 60)
  var m = minutes % 60
  if (d > 0) return { key: "time.dh", args: [d, h] }
  if (h > 0) return { key: "time.hm", args: [h, m] }
  return { key: "time.m", args: [Math.max(1, m)] }
}

function level(percent, thresholdPct) {
  if (percent * 100 >= thresholdPct) return "alert"
  if (percent >= 0.75) return "warm"
  return "ok"
}

// Notification bodies may be read as markup by the daemon.
function escapeMarkup(text) {
  return String(text).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
}

// The panel always shows the plan-wide windows, and a model-specific one
// (Claude's "Fable Weekly") only once it has been used.
function visibleWindows(wins) {
  return (wins || []).filter(function(w) {
    return w.title === "5h" || w.title === "Day" || w.title === "Week" || w.title === "Month" || w.percent > 0
  })
}

// Which limit each agent shows in the bar, as one setting:
// "claude:Week,codex:5h". The value is a window title from shortLabel().
function parseBarItems(text) {
  var out = {}
  var parts = String(text === undefined || text === null ? "" : text).split(",")
  for (var i = 0; i < parts.length; i++) {
    var pair = parts[i].split(":")
    if (pair.length !== 2) continue
    var id = pair[0].trim().toLowerCase()
    var title = pair[1].trim()
    if (validId(id) && /^[^,:]{1,24}$/.test(title)) out[id] = title
  }
  return out
}

function serializeBarItems(map) {
  var out = []
  for (var id in map) if (map[id]) out.push(id + ":" + map[id])
  return out.join(",")
}

// What the bar shows: per chosen agent, how much of that limit is left.
// The window a bar choice points at: by title, or "Tightest" for whichever
// is closest to running out.
function pickWindow(wins, title) {
  var pick = null
  var pool = title === TIGHTEST ? visibleWindows(wins) : (wins || [])
  for (var j = 0; j < pool.length; j++) {
    var w = pool[j]
    if (title === TIGHTEST) { if (!pick || w.percent > pick.percent) pick = w }
    else if (w.title === title) return w
  }
  return pick
}

// Shortest tags that tell accounts apart: Work, Main -> W, M; Work, Weekend
// -> Wo, We. Capped at four letters.
function accountTags(labels) {
  var out = []
  for (var i = 0; i < labels.length; i++) {
    var label = String(labels[i] || "").replace(/[^A-Za-z0-9]/g, "") || "?"
    var n = 1
    for (; n < 4; n++) {
      var tag = label.slice(0, n).toLowerCase()
      var clash = false
      for (var k = 0; k < labels.length; k++) {
        if (k === i) continue
        var other = String(labels[k] || "").replace(/[^A-Za-z0-9]/g, "") || "?"
        if (other.slice(0, n).toLowerCase() === tag) { clash = true; break }
      }
      if (!clash) break
    }
    out.push(label.charAt(0).toUpperCase() + label.slice(1, n))
  }
  return out
}

// What the bar shows: per chosen agent, how much of that limit is left. With
// the agent in `allAccounts`, every account's share rides along.
function barEntries(providers, map, allAccounts) {
  var out = []
  for (var i = 0; i < (providers || []).length; i++) {
    var p = providers[i]
    var title = map ? map[p.id] : ""
    if (!title) continue
    var pick = pickWindow(p.windows, title)
    if (!pick) continue
    var entry = { id: p.id, name: p.name, title: pick.title, used: pick.percent, left: 1 - pick.percent, fresh: pick.fresh, resetAt: pick.resetAt, accounts: [] }
    if (allAccounts && allAccounts[p.id] && p.accounts.length > 1) {
      var tags = accountTags(p.accounts.map(function(a) { return a.label }))
      for (var k = 0; k < p.accounts.length; k++) {
        var a = p.accounts[k]
        var w = pickWindow(a.windows, title)
        entry.accounts.push({ id: a.id, label: a.label, tag: tags[k], active: a.active,
          used: w ? w.percent : 0, left: w ? 1 - w.percent : 1, known: w !== null })
      }
    }
    out.push(entry)
  }
  return out
}

// "claude,codex" -> {claude: true, codex: true}
function parseIdSet(text) {
  var out = {}
  var parts = String(text === undefined || text === null ? "" : text).toLowerCase().split(",")
  for (var i = 0; i < parts.length; i++) if (validId(parts[i].trim())) out[parts[i].trim()] = true
  return out
}

function serializeIdSet(set) {
  var out = []
  for (var id in set) if (set[id] && validId(id)) out.push(id)
  return out.join(",")
}

var TIGHTEST = "Tightest"

// One unit for tight spots like the bar: 2d, 5h, 42m.
function shortCountdown(ms) {
  if (!(ms > 0)) return null
  var minutes = Math.ceil(ms / 60000)
  if (minutes >= 1440) return { key: "time.d", args: [Math.floor(minutes / 1440)] }
  if (minutes >= 60) return { key: "time.h", args: [Math.floor(minutes / 60)] }
  return { key: "time.m", args: [minutes] }
}

// ---- Per-account settings -------------------------------------------------
// Claude Code reads one settings.json that every Omarchy account home links
// to. A per-account setting is an overlay: on/off values written into that
// file when the account becomes active. Only top-level true/false keys.
var SETTINGS_PROVIDERS = ["claude"]

function validKey(key) {
  return /^[A-Za-z][A-Za-z0-9_]{0,63}$/.test(String(key))
}

// {"claude": {"work": {"remoteControlAtStartup": false}}} with junk removed.
function cleanAccountSettings(value) {
  var out = {}
  if (!value || typeof value !== "object") return out
  for (var i = 0; i < SETTINGS_PROVIDERS.length; i++) {
    var p = SETTINGS_PROVIDERS[i]
    var accounts = value[p]
    if (!accounts || typeof accounts !== "object") continue
    for (var acc in accounts) {
      if (!validId(acc) || !accounts[acc] || typeof accounts[acc] !== "object") continue
      for (var key in accounts[acc]) {
        if (!validKey(key) || typeof accounts[acc][key] !== "boolean") continue
        if (!out[p]) out[p] = {}
        if (!out[p][acc]) out[p][acc] = {}
        out[p][acc][key] = accounts[acc][key]
      }
    }
  }
  return out
}

function managedKeys(map, provider) {
  var keys = []
  var accounts = (map && map[provider]) || {}
  for (var acc in accounts)
    for (var key in accounts[acc]) if (keys.indexOf(key) < 0) keys.push(key)
  return keys.sort()
}

// The keys whose value in settings.json differs from the account's overlay.
function pendingOverlay(map, provider, accountId, settings) {
  var overlay = (map && map[provider] && map[provider][accountId]) || {}
  var out = {}
  var any = false
  for (var key in overlay) {
    if (!settings || settings[key] !== overlay[key]) { out[key] = overlay[key]; any = true }
  }
  return any ? out : null
}

// Start managing a key: every account gets the value settings.json has now.
function manageKey(map, provider, accountIds, key, current) {
  var next = JSON.parse(JSON.stringify(map || {}))
  if (!validKey(key)) return next
  if (!next[provider]) next[provider] = {}
  for (var i = 0; i < accountIds.length; i++) {
    if (!next[provider][accountIds[i]]) next[provider][accountIds[i]] = {}
    next[provider][accountIds[i]][key] = current === true
  }
  return next
}

function unmanageKey(map, provider, key) {
  var next = JSON.parse(JSON.stringify(map || {}))
  var accounts = next[provider] || {}
  for (var acc in accounts) {
    delete accounts[acc][key]
    if (Object.keys(accounts[acc]).length === 0) delete accounts[acc]
  }
  if (next[provider] && Object.keys(next[provider]).length === 0) delete next[provider]
  return next
}

function setAccountKey(map, provider, accountId, key, value) {
  var next = JSON.parse(JSON.stringify(map || {}))
  if (!next[provider]) next[provider] = {}
  if (!next[provider][accountId]) next[provider][accountId] = {}
  next[provider][accountId][key] = value === true
  return next
}

function booleanKeys(settings) {
  var out = []
  if (!settings || typeof settings !== "object") return out
  for (var key in settings) if (validKey(key) && typeof settings[key] === "boolean") out.push(key)
  return out.sort()
}

// remoteControlAtStartup -> Remote control at startup
function humanizeKey(key) {
  var words = String(key).replace(/([a-z0-9])([A-Z])/g, "$1 $2").replace(/_/g, " ").toLowerCase()
  return words.charAt(0).toUpperCase() + words.slice(1)
}

// Loaded by node for the tests; QML never sees `module`.
if (typeof module !== "undefined") module.exports = {
  validId: validId, parseExtras: parseExtras, shortLabel: shortLabel, windows: windows,
  peak: peak, normalize: normalize, alerts: alerts, countdown: countdown, level: level,
  escapeMarkup: escapeMarkup, parseBarItems: parseBarItems, serializeBarItems: serializeBarItems,
  barEntries: barEntries, pickWindow: pickWindow, accountTags: accountTags, parseIdSet: parseIdSet, serializeIdSet: serializeIdSet, visibleWindows: visibleWindows, details: details, banked: banked, resetRows: resetRows, shortCountdown: shortCountdown,
  cleanAccountSettings: cleanAccountSettings, managedKeys: managedKeys, pendingOverlay: pendingOverlay,
  manageKey: manageKey, unmanageKey: unmanageKey, setAccountKey: setAccountKey, booleanKeys: booleanKeys,
  humanizeKey: humanizeKey, TIGHTEST: TIGHTEST
}
