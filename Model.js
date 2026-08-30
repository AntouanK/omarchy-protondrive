// Pure parsing helpers for the Proton Drive CLI. Kept dependency-free so they
// stay unit-testable outside Quickshell (same convention as the Tailscale and
// ProtonVPN plugins' Model.js).
//
// The CLI has no dedicated `status`/`whoami` subcommand, so login state is
// inferred from `proton-drive filesystem list /` — a fast, read-only, always
// side-effect-free call that lists the ten fixed virtual root sections
// (/my-files, /devices, ...) when signed in.
//
// Observed on this machine:
//   Signed out: prints "You need to login first" to stdout AND exits 0 —
//     the CLI does not use a non-zero exit code for this, so exit code alone
//     is not a reliable signal and the text must be checked.
//   Signed in:  prints the ten root paths (one per line) and exits 0.
function parseStatus(exitCode, raw) {
  var text = String(raw || "").trim()
  var lowered = text.toLowerCase()

  if (lowered.indexOf("you need to login") !== -1
      || lowered.indexOf("please login") !== -1
      || lowered.indexOf("not logged in") !== -1) {
    return { ok: true, authenticated: false, statusText: "Signed out" }
  }

  if (exitCode === 0 && text !== "") {
    return { ok: true, authenticated: true, statusText: "Signed in" }
  }

  return {
    ok: false,
    authenticated: false,
    statusText: "Unavailable",
    lastError: sanitizeCliText(text, "Could not read Proton Drive status")
  }
}

function elideStatus(text) {
  var value = String(text || "").replace(/\s+/g, " ").trim()
  return value.length > 140 ? value.substring(0, 137) + "…" : value
}

// The CLI's local SQLite cache is not safe for two concurrent invocations:
// hitting it while another proton-drive process holds the lock crashes with
// an uncaught Bun/SQLite exception instead of a clean error. Reproduced
// directly on this machine by firing several `proton-drive filesystem list`
// calls back-to-back:
//   exit code: 1
//   stderr:  "===============================================\n"  — exactly
//            this separator line (Bun's crash-report banner) and nothing
//            else.
//   stdout:  the actual crash body — a numbered excerpt of the CLI's own
//            compiled source ("7 | export class SQLiteCache implements
//            ProtonDriveCache<string> {"), "SQLiteError: database is
//            locked", a stack trace through bun:sqlite/src/cache/*.ts, and a
//            trailing "Error details: { code: 'SQLITE_BUSY_RECOVERY', ... }".
// This is transient and unrelated to being signed in — retrying a moment
// later (once the other invocation has released the lock) succeeds cleanly.
// It must never reach the user verbatim: that raw dump is exactly what
// produced both the "SQLiteCache ... constructor" text and the bare row of
// "=" characters the user reported.
function classifyCliFailure(stdout, stderr) {
  var combined = String(stdout || "") + "\n" + String(stderr || "")
  if (/SQLITE_BUSY|database is locked|SqliteError|SQLiteError|bun:sqlite/i.test(combined)) return "busy"
  var lowered = combined.toLowerCase()
  if (lowered.indexOf("you need to login") !== -1
      || lowered.indexOf("please login") !== -1
      || lowered.indexOf("not logged in") !== -1
      || lowered.indexOf("authentication required") !== -1) return "authRequired"
  return "unknown"
}

// True for text that is CLI/runtime internals rather than a real message: a
// bare separator line, a numbered source excerpt, or a stack frame. Used as
// a last line of defense so that even an *unclassified* failure can never
// put raw dump text in front of the user.
function looksLikeRawDump(text) {
  var t = String(text || "")
  if (/^=+$/m.test(t)) return true
  if (/^\s*\d+\s*\|/m.test(t)) return true
  if (/\bat\s+[^\s(]+\s*\([^)]*:\d+:\d+\)/.test(t)) return true
  if (/SQLiteError|SQLITE_BUSY|bun:sqlite/i.test(t)) return true
  return false
}

// Shared "sanitize CLI output for display" helper. Every user-visible text
// property fed from proton-drive's stdout/stderr should be routed through
// this instead of shown raw — it returns the (elided) CLI text only when it
// looks like an actual human-readable message, and `fallback` otherwise.
function sanitizeCliText(text, fallback) {
  var value = String(text || "").trim()
  if (value === "" || looksLikeRawDump(value)) return fallback
  return elideStatus(value)
}

// ---------------------------------------------------------------------------
// File browser helpers
//
// `proton-drive filesystem list -j <path>` (confirmed to support -j/--json,
// unlike `filesystem info`, which prints "Not implemented" for every path —
// there is no quota/usage endpoint in this CLI, so this widget cannot and
// does not show storage usage) returns two different shapes depending on
// depth:
//
//   list -j /            -> [{"path":"/my-files"}, {"path":"/devices"}, ...]
//                            (the ten fixed virtual root sections — no name/
//                            type/uid, just the full path of each)
//   list -j /my-files     -> [{"uid":...,"name":{"ok":true,"value":"Foo"},
//                              "type":"file"|"folder",...}, ...]
//                            (real nodes — path is NOT included, so child
//                            paths must be built from the parent path + name)
//
// Remote paths escape "/" inside a node name as "\/" (per `filesystem list
// --help`), so building/splitting paths has to respect that escape rather
// than naively splitting on "/".

function splitPath(path) {
  var parts = []
  var current = ""
  var s = String(path || "")
  for (var i = 0; i < s.length; i++) {
    if (s[i] === "\\" && s[i + 1] === "/") { current += "/"; i++; continue }
    if (s[i] === "/") { parts.push(current); current = ""; continue }
    current += s[i]
  }
  parts.push(current)
  return parts.filter(function(p) { return p !== "" })
}

function escapeSegment(name) {
  return String(name || "").replace(/\\/g, "\\\\").replace(/\//g, "\\/")
}

function joinPath(parentPath, childName) {
  var base = parentPath === "/" ? "" : String(parentPath || "")
  return base + "/" + escapeSegment(childName)
}

function parentPath(path) {
  var parts = splitPath(path)
  if (parts.length <= 1) return "/"
  parts.pop()
  return "/" + parts.map(escapeSegment).join("/")
}

function humanizeSegment(seg) {
  var s = String(seg || "").replace(/-/g, " ")
  return s.length ? s.charAt(0).toUpperCase() + s.slice(1) : s
}

// "/my-files/Some Folder" -> "My files › Some Folder"
function breadcrumb(path) {
  if (!path || path === "/") return "Drive"
  var parts = splitPath(path)
  if (parts.length === 0) return "Drive"
  var labels = [humanizeSegment(parts[0])].concat(parts.slice(1))
  return labels.join(" › ")
}

var IMAGE_EXTENSIONS = {
  jpg: true, jpeg: true, png: true, gif: true, webp: true, avif: true, heic: true,
  svg: true, bmp: true, tif: true, tiff: true
}

var VIDEO_EXTENSIONS = {
  mp4: true, mov: true, mkv: true, webm: true, avi: true, m4v: true, mpg: true,
  mpeg: true, wmv: true
}

var DOCUMENT_EXTENSIONS = {
  pdf: true, txt: true, md: true, doc: true, docx: true, xls: true, xlsx: true,
  ppt: true, pptx: true, odt: true, ods: true, odp: true, rtf: true, csv: true,
  pages: true, numbers: true, key: true
}

function fileExtension(name) {
  var value = String(name || "").toLowerCase()
  var index = value.lastIndexOf(".")
  return index >= 0 ? value.substring(index + 1) : ""
}

function fileGlyph(name) {
  var ext = fileExtension(name)
  if (IMAGE_EXTENSIONS[ext]) return "󰋩"
  if (VIDEO_EXTENSIONS[ext]) return "󰈫"
  if (DOCUMENT_EXTENSIONS[ext]) return "󰈙"
  return "󰈔"
}

function formatBytes(bytes) {
  var value = Number(bytes || 0)
  if (!isFinite(value) || value <= 0) return ""
  var units = ["B", "KB", "MB", "GB", "TB"]
  var index = 0
  while (value >= 1000 && index < units.length - 1) {
    value = value / 1000
    index++
  }
  var decimals = value >= 100 || index === 0 ? 0 : (value >= 10 ? 1 : 2)
  return value.toFixed(decimals).replace(/\.0+$/, "").replace(/(\.\d)0$/, "$1") + " " + units[index]
}

function relativeTime(iso) {
  var ts = Date.parse(String(iso || ""))
  if (!isFinite(ts)) return ""
  var diff = Math.max(0, Math.floor((Date.now() - ts) / 1000))
  if (diff < 60) return "Just now"
  var minutes = Math.floor(diff / 60)
  if (minutes < 60) return minutes + "m ago"
  var hours = Math.floor(minutes / 60)
  if (hours < 24) return hours + "h ago"
  var days = Math.floor(hours / 24)
  if (days < 30) return days + "d ago"
  var months = Math.floor(days / 30)
  if (months < 12) return months + "mo ago"
  return Math.floor(days / 365) + "y ago"
}

function entryMeta(entry) {
  if (!entry) return ""
  var parts = []
  if (entry.kind === "file") {
    var size = formatBytes(entry.size)
    if (size !== "") parts.push(size)
  }
  var when = relativeTime(entry.modifiedIso)
  if (when !== "") parts.push(when)
  return parts.join(" · ")
}

// Parses `proton-drive filesystem list -j <path>` output into a normalized
// list of browsable entries. `path` is the path that was listed (needed to
// build child paths, since only the root listing echoes full paths itself).
function parseList(exitCode, stdout, stderr, path) {
  var text = String(stdout || "").trim()
  if (exitCode !== 0 || text === "") {
    // On the SQLite-lock crash (see classifyCliFailure above), stdout holds
    // the real error body and stderr is only ever the bare "=" banner line —
    // preferring stderr here (as a naive "pick whichever stream is
    // non-empty" would) is exactly what turned that banner into the "row of
    // = signs instead of file rows" bug. Prefer stdout when it has content.
    var raw = String(stdout || "").trim() !== "" ? stdout : stderr
    return { ok: false, entries: [], error: sanitizeCliText(raw, "Failed to list folder") }
  }

  var data
  try {
    data = JSON.parse(text)
  } catch (e) {
    return { ok: false, entries: [], error: "Failed to parse folder listing" }
  }
  if (!Array.isArray(data)) {
    return { ok: false, entries: [], error: "Unexpected response from proton-drive" }
  }

  var entries = data.map(function(item) {
    if (!item || typeof item !== "object") return null

    // Root virtual sections: {"path": "/my-files"} with no name/type/uid.
    if (item.path !== undefined && item.name === undefined) {
      return {
        kind: "folder",
        name: humanizeSegment(lastSegment(item.path)),
        path: String(item.path),
        mediaType: "",
        size: 0,
        modifiedIso: "",
        uid: ""
      }
    }

    var nameOk = item.name && item.name.ok === true
    if (!nameOk) {
      // Name couldn't be decrypted or conflicts — not safely path-addressable.
      return {
        kind: "locked",
        name: "(name unavailable)",
        path: "",
        mediaType: "",
        size: 0,
        modifiedIso: item.modificationTime || "",
        uid: item.uid || ""
      }
    }

    var name = String(item.name.value)
    var kind = item.type === "folder" ? "folder" : "file"
    return {
      kind: kind,
      name: name,
      path: joinPath(path, name),
      mediaType: item.mediaType || "",
      size: Number(item.totalStorageSize || 0),
      modifiedIso: item.modificationTime || "",
      uid: item.uid || ""
    }
  }).filter(function(e) { return e !== null })

  // The ten virtual root sections have a meaningful fixed order from the CLI
  // (/my-files first, as your main root) — only alphabetize real folders.
  var isVirtualRoot = data.length > 0 && data[0] && data[0].path !== undefined && data[0].name === undefined
  if (!isVirtualRoot) {
    entries.sort(function(a, b) {
      if (a.kind !== b.kind) {
        var rank = { folder: 0, file: 1, locked: 2 }
        return rank[a.kind] - rank[b.kind]
      }
      return String(a.name).localeCompare(String(b.name))
    })
  }

  return { ok: true, entries: entries, error: "" }
}

function lastSegment(path) {
  var parts = splitPath(path)
  return parts.length ? parts[parts.length - 1] : String(path || "")
}

if (typeof module !== "undefined") {
  module.exports = {
    parseStatus: parseStatus,
    elideStatus: elideStatus,
    classifyCliFailure: classifyCliFailure,
    looksLikeRawDump: looksLikeRawDump,
    sanitizeCliText: sanitizeCliText,
    splitPath: splitPath,
    escapeSegment: escapeSegment,
    joinPath: joinPath,
    parentPath: parentPath,
    humanizeSegment: humanizeSegment,
    breadcrumb: breadcrumb,
    fileExtension: fileExtension,
    fileGlyph: fileGlyph,
    formatBytes: formatBytes,
    relativeTime: relativeTime,
    entryMeta: entryMeta,
    parseList: parseList,
    lastSegment: lastSegment
  }
}
