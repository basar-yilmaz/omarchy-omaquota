// node tests/model.test.js
const assert = require("assert")
const path = require("path")
const fs = require("fs")

// Model.js starts with `.pragma library` for QML; strip it so node can load it.
const src = fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8").replace(/^\.pragma library/, "")
const module_ = { exports: {} }
new Function("module", src)(module_)
const M = module_.exports

const now = Date.parse("2026-11-03T15:00:00Z")
const accountList = JSON.parse(fs.readFileSync(path.join(__dirname, "fixtures", "account-list.json"), "utf8"))
const cursor = { id: "cursor", name: "Cursor", tierLabel: "Pro", ready: true,
  limits: [{ label: "Monthly", percent: 0.93, resetsAt: "2026-11-20T00:00:00Z" }] }

// parseExtras keeps only safe, unique ids and leaves account providers out.
assert.deepStrictEqual(M.parseExtras(" Cursor, kimi,,zai,cursor,../etc,claude,a b"), ["cursor", "kimi", "zai"])
assert.deepStrictEqual(M.parseExtras(undefined), [])

assert.strictEqual(M.shortLabel("Session (5-hour)"), "5h")
assert.strictEqual(M.shortLabel("5h window"), "5h")
assert.strictEqual(M.shortLabel("Weekly (7-day)"), "Week")
assert.strictEqual(M.shortLabel("Fable Weekly"), "Fable Weekly")

// An expired window reads as fresh and empty.
const w = M.windows([{ label: "5h window", percent: 0.4, resetsAt: "2026-10-31T04:37:13Z" },
  { label: "Weekly (7-day)", percent: 1.7, resetsAt: "2026-11-04T07:25:00Z" },
  { label: "bad", percent: "x" }, null], now)
assert.strictEqual(w.length, 2)
assert.deepStrictEqual([w[0].fresh, w[0].percent], [true, 0])
assert.deepStrictEqual([w[1].fresh, w[1].percent], [false, 1])

const ps = M.normalize(accountList, [cursor, null, { id: "../x" }], now)
assert.deepStrictEqual(ps.map(p => p.id), ["claude", "codex", "cursor"], "grok is hidden while signed out")
const claude = ps[0]
assert.strictEqual(claude.accounts.length, 2)
assert.strictEqual(claude.accounts.find(a => a.active).id, "work")
assert.strictEqual(claude.peak, 0.96)
assert.strictEqual(claude.auto, true)
assert.strictEqual(ps[2].switchable, false)
assert.strictEqual(ps[2].plan, "Pro")

// Multi-account providers are Omarchy's to warn about; the rest are ours, once.
const a1 = M.alerts(ps, 90, {})
assert.deepStrictEqual(a1.map(a => a.provider), ["Cursor"])
const seen = {}; a1.forEach(a => seen[a.key] = true)
assert.strictEqual(M.alerts(ps, 90, seen).length, 0)
assert.strictEqual(M.alerts(ps, 95, {}).length, 0)

assert.deepStrictEqual(M.countdown(2 * 86400000 + 4 * 3600000), { key: "time.dh", args: [2, 4] })
assert.deepStrictEqual(M.countdown(2 * 3600000 + 13 * 60000), { key: "time.hm", args: [2, 13] })
assert.deepStrictEqual(M.countdown(20000), { key: "time.m", args: [1] })
assert.strictEqual(M.countdown(-5), null)

assert.strictEqual(M.level(0.95, 90), "alert")
assert.strictEqual(M.level(0.8, 90), "warm")
assert.strictEqual(M.level(0.2, 90), "ok")

// Markup-shaped labels reach notifications inert.
assert.strictEqual(M.escapeMarkup('<img src="https://x">&'), '&lt;img src="https://x"&gt;&amp;')

// Bar items: one window per agent, junk dropped, round-trips.
const items = M.parseBarItems(" claude:Week, codex:5h,bad,../x:5h,cursor:a:b, zai: ")
assert.deepStrictEqual(Object.assign({}, items), { claude: "Week", codex: "5h" })
assert.strictEqual(M.serializeBarItems({ claude: "Week", codex: "", cursor: "Month" }), "claude:Week,cursor:Month")
const bar = M.barEntries(ps, { claude: "Week", codex: "5h", cursor: "Month", grok: "5h" })
assert.deepStrictEqual(bar.map(b => [b.id, b.title, Math.round(b.left * 100), b.fresh]),
  [["claude", "Week", 48, false], ["codex", "5h", 100, true], ["cursor", "Month", 7, false]])
assert.strictEqual(M.barEntries(ps, { claude: "Month" }).length, 0, "a window the agent lacks shows nothing")

// The panel hides model-specific windows while they are unused.
const vis = M.visibleWindows(M.windows([{ label: "5h window", percent: 0 }, { label: "Weekly (7-day)", percent: 0.2 },
  { label: "Fable Weekly", percent: 0 }, { label: "Opus Weekly", percent: 0.3 }], now))
assert.deepStrictEqual(vis.map(w => w.title), ["5h", "Week", "Opus Weekly"])

console.log("model tests passed")

// Details keep only counts and a short note.
const d = M.details({ todayPrompts: "8", todayTotalTokens: 18462381, totalSessions: -3, authHelpText: "x".repeat(500) })
assert.deepStrictEqual([d.todayPrompts, d.todayTokens, d.totalSessions, d.note.length], [8, 18462381, 0, 200])
assert.strictEqual(M.normalize(accountList, [{ id: "claude", todayPrompts: 3 }], now)[0].details.todayPrompts, 3)
assert.strictEqual(M.normalize(accountList, [{ id: "claude" }], now).length, 2, "a core record never becomes an extra")

// Tightest follows the fullest visible window.
assert.deepStrictEqual(M.barEntries(ps, { claude: "Tightest" }).map(b => b.title), ["5h"])
assert.deepStrictEqual(M.shortCountdown(2 * 86400000 + 5), { key: "time.d", args: [2] })
assert.deepStrictEqual(M.shortCountdown(5 * 3600000), { key: "time.h", args: [5] })

// Per-account settings.
const clean = M.cleanAccountSettings({ claude: { work: { remoteControlAtStartup: false, bad: "x", "a b": true }, "../x": { y: true } }, codex: { main: { z: true } } })
assert.deepStrictEqual(clean, { claude: { work: { remoteControlAtStartup: false } } })
let map = M.manageKey({}, "claude", ["work", "main"], "remoteControlAtStartup", false)
map = M.setAccountKey(map, "claude", "main", "remoteControlAtStartup", true)
assert.deepStrictEqual(M.managedKeys(map, "claude"), ["remoteControlAtStartup"])
assert.deepStrictEqual(M.pendingOverlay(map, "claude", "main", { remoteControlAtStartup: false }), { remoteControlAtStartup: true })
assert.strictEqual(M.pendingOverlay(map, "claude", "work", { remoteControlAtStartup: false }), null)
assert.deepStrictEqual(M.unmanageKey(map, "claude", "remoteControlAtStartup"), {})
assert.deepStrictEqual(M.booleanKeys({ a: true, b: 1, c: false, "x y": true }), ["a", "c"])
assert.strictEqual(M.humanizeKey("remoteControlAtStartup"), "Remote control at startup")

console.log("settings tests passed")

// Banked resets (Codex): counted, capped, expiry parsed; none means null.
assert.deepStrictEqual(M.banked({ available: 3, nextExpiresAt: "2026-11-06T22:13:50+00:00" }), { available: 3, nextExpiresAt: Date.parse("2026-11-06T22:13:50+00:00") })
assert.strictEqual(M.banked({ available: 0 }), null)
assert.strictEqual(M.banked(null), null)
assert.strictEqual(M.banked({ available: "x" }), null)
assert.deepStrictEqual(M.banked({ available: 500, nextExpiresAt: "bad" }), { available: 99, nextExpiresAt: 0 })
assert.strictEqual(M.normalize(accountList, [null, { id: "codex", resetCredits: { available: 2 } }], now)[1].details.banked.available, 2)
console.log("banked tests passed")

// Banked reset list: available only, soonest first, unknown deadlines last.
const rows = M.resetRows({ credits: [
  { title: "B", status: "available", expiresAt: "2026-12-01T00:00:00Z" },
  { title: "", status: "available", expiresAt: "" },
  { title: "A", status: "available", expiresAt: "2026-11-06T22:13:50+00:00" },
  { title: "Used", status: "redeemed", expiresAt: "2026-11-01T00:00:00Z" }, null] })
assert.deepStrictEqual(rows.map(r => r.title), ["A", "B", "Reset"])
assert.strictEqual(rows[2].expiresAt, 0)
assert.deepStrictEqual(M.resetRows({ error: "x" }), [])
console.log("reset list tests passed")

// Long limit names from other providers get short titles.
assert.strictEqual(M.shortLabel("Premium requests (monthly)"), "Month")
assert.strictEqual(M.shortLabel("Daily requests"), "Day")
assert.strictEqual(M.shortLabel("Org seats"), "Org seats")
console.log("label tests passed")

// Several accounts in the bar.
assert.deepStrictEqual(M.accountTags(["Work", "Main"]), ["W", "M"])
assert.deepStrictEqual(M.accountTags(["Work", "Weekend", "Personal"]), ["Wo", "We", "P"])
assert.deepStrictEqual(M.accountTags(["Client · Acme", "Client · Beta"]), ["Clie", "Clie"], "capped at four letters")
assert.deepStrictEqual(M.accountTags(["", "!!"]), ["?", "?"])
const all = M.barEntries(ps, { claude: "5h", codex: "5h" }, { claude: true, codex: true })
// The fixture's work label is markup-shaped ("<b>Work</b>"): its tag is built from letters only.
assert.deepStrictEqual(all[0].accounts.map(a => [a.tag, a.active, Math.round(a.left * 100)]), [["M", false, 90], ["B", true, 4]])
assert.strictEqual(all[1].accounts.length, 0, "one account: nothing extra")
assert.strictEqual(M.barEntries(ps, { claude: "5h" }, {})[0].accounts.length, 0, "off by default")
assert.strictEqual(M.barEntries(ps, { claude: "Week" }, { claude: true })[0].accounts[0].known, false, "an account without that window is marked unknown")
assert.deepStrictEqual(M.parseIdSet("claude, codex,,../x"), { claude: true, codex: true })
assert.strictEqual(M.serializeIdSet({ claude: true, codex: false }), "claude")
console.log("multi-account bar tests passed")

// Viewing another account's limits never changes which one is active.
const claudeP = ps[0]
assert.strictEqual(M.viewedAccount(claudeP, "").id, "work", "the active account by default")
assert.strictEqual(M.viewedAccount(claudeP, "main").id, "main")
assert.strictEqual(M.viewedAccount(claudeP, "gone").id, "work", "an unknown id falls back to the active one")
assert.strictEqual(claudeP.accounts.find(a => a.active).id, "work")
assert.strictEqual(M.viewedAccount(ps[2], "x"), null, "providers without accounts have nothing to view")
console.log("viewing tests passed")
