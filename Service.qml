import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

Item {
  id: root

  property var settings: ({})

  property bool installed: false
  property bool authenticated: false
  // The signed-in address, when we could read it. Empty whenever we're
  // signed out, or when the CLI wouldn't tell us - see refreshAccount().
  property string accountName: ""
  property bool refreshing: false
  property string statusText: "Checking…"
  property string actionStatus: ""
  property string lastError: ""

  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 60, 10, 3600)
  readonly property bool busy: whichProcess.running || statusProcess.running || loginProcess.running || logoutProcess.running
    || browseProcess.running || downloadProcess.running || uploadPickProcess.running || uploadProcess.running || openProcess.running
    || accountProcess.running

  // The proton-drive CLI keeps a local SQLite cache and does not appear to
  // tolerate two invocations running at once against it — running the
  // status probe and a folder listing concurrently (observed when the panel
  // first opens: refresh() + browse("/") firing together) surfaced as a
  // raw SQLite/JS stack trace in statusText instead of a clean result. Every
  // proton-drive invocation below is funneled through runWhenIdle() so only
  // one ever runs at a time; callers queue behind whichever is in flight.
  //
  // Funneling calls through runWhenIdle() greatly reduces how often the
  // SQLite-lock condition is hit, but does not eliminate it — the CLI's own
  // background housekeeping (or a call this widget didn't gate, e.g. a
  // manual `proton-drive` invocation elsewhere) can still collide with it.
  // When that happens the CLI crashes with a raw stack trace (see
  // Model.classifyCliFailure/sanitizeCliText) instead of a clean error, so
  // parseStatus()/applyList() below detect that specific condition and
  // retry quietly a few times rather than ever showing it — it is a
  // transient hiccup, not proof the account is unavailable or signed out.
  // loginProcess/logoutProcess included too, not just the read/write file
  // calls - `auth login`/`auth logout` hit the same CLI and the same SQLite
  // cache, so a status poll firing while a sign-in is mid-flow (the browser
  // step alone can take tens of seconds) reproduced the exact crash this
  // gating exists to prevent.
  readonly property bool cliBusy: statusProcess.running || browseProcess.running || downloadProcess.running || uploadProcess.running || openProcess.running || loginProcess.running || logoutProcess.running || accountProcess.running
  // A queue, not a single slot - a single slot silently dropped an earlier
  // queued action (e.g. "download A" clicked, then "open B" clicked before A
  // got its turn) with no error or feedback, contradicting the comment below
  // ("callers queue behind whichever is in flight").
  property var _pendingActions: []

  // Quick, bounded retry budget for the SQLite-busy condition specifically —
  // separate from the normal 60s refresh timer so the widget recovers within
  // a second or two instead of leaving "Unavailable" on screen until the
  // next scheduled poll.
  readonly property int maxBusyRetries: 5
  property int _statusBusyRetries: 0
  property int _browseBusyRetries: 0

  function _retryStatusAfterBusy() {
    if (cliBusy) { statusBusyRetryTimer.restart(); return }
    root.refresh()
  }

  function _retryBrowseAfterBusy() {
    if (cliBusy) { browseBusyRetryTimer.restart(); return }
    root._browseNow(root.currentPath)
  }

  readonly property int maxAccountRetries: 10
  property int _accountRetries: 0

  Timer { id: accountProbeTimer; interval: 300; repeat: false; onTriggered: root._probeAccountNow() }
  Timer { id: statusBusyRetryTimer; interval: 400; repeat: false; onTriggered: root._retryStatusAfterBusy() }
  Timer { id: browseBusyRetryTimer; interval: 400; repeat: false; onTriggered: root._retryBrowseAfterBusy() }

  function runWhenIdle(fn) {
    if (!cliBusy) { fn(); return }
    _pendingActions.push(fn)
  }

  // Called from the end of every gating process's onExited so a queued
  // action runs the instant the CLI is free again, rather than polling. Only
  // pulls one action per call - the process that just exited flipping
  // cliBusy back to true (because the drained action itself launches another
  // gating Process) is exactly what keeps the rest of the queue waiting its
  // turn instead of firing all at once.
  function _drainPending() {
    if (cliBusy || _pendingActions.length === 0) return
    var fn = _pendingActions.shift()
    fn()
  }

  property string _statusOutput: ""
  property string _statusError: ""
  property string _loginOutput: ""
  property string _loginError: ""
  property string _logoutOutput: ""
  property string _logoutError: ""
  property string _accountOutput: ""
  property string _accountError: ""

  // --- File browser state ---------------------------------------------
  property string currentPath: "/"
  property var entries: []
  property bool browsing: false
  property string browseError: ""
  readonly property bool canUpload: currentPath === "/my-files" || currentPath.indexOf("/my-files/") === 0

  property string _browseOutput: ""
  property string _browseError: ""
  property string _downloadOutput: ""
  property string _downloadError: ""
  property string _pickOutput: ""
  property string _pickError: ""
  property string _uploadOutput: ""
  property string _uploadError: ""
  property string _openOutput: ""
  property string _openError: ""
  property string _openLocalPath: ""

  // Dedicated cache dir for "open" downloads, kept separate from ~/Downloads
  // so a quick "open this to peek at it" doesn't clutter the user's real
  // downloads folder the way download() intentionally does.
  readonly property string openCacheDir: (Quickshell.env("HOME") || "/root") + "/.cache/omarchy/protondrive-open"

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    if (n < min) n = min
    if (n > max) n = max
    return n
  }

  function resetUnavailable(message) {
    authenticated = false
    accountName = ""
    statusText = message
  }

  function refresh() {
    if (!installed) {
      if (!whichProcess.running) {
        refreshing = true
        whichProcess.command = ["which", "proton-drive"]
        whichProcess.running = true
      }
      return
    }
    // Read-only probe only. This is the ONLY thing the refresh timer and the
    // right-click/middle-click gestures are wired to — it must never be able
    // to reach `auth login` or `auth logout`. See Model.js for why we check
    // the printed text rather than trusting the exit code.
    //
    // Skip (rather than queue) if any proton-drive call is already in
    // flight: this poll is periodic/optional and the next tick (or the
    // delayedRefresh after login/logout) will simply try again.
    if (cliBusy) return
    _statusOutput = ""
    _statusError = ""
    refreshing = true
    statusProcess.command = ["proton-drive", "filesystem", "list", "/"]
    statusProcess.running = true
    if (!pollWatchdog.running) pollWatchdog.start()
  }

  // Fetched once per sign-in rather than on every status poll: the address
  // cannot change while a session lasts, and this is a second CLI round-trip
  // against the same lock-prone SQLite cache the poll already contends for.
  // Failure is deliberately silent - not knowing the address is a cosmetic
  // gap in one caption, not something the user can act on.
  //
  // Deferred through a timer rather than runWhenIdle(): its only caller is
  // parseStatus(), which runs inside statusProcess.onExited, and a queued
  // closure would then sit in _pendingActions unread - the _drainPending()
  // at the end of that same handler has already been passed by the time
  // this queues anything. The timer sidesteps the ordering entirely, and
  // mirrors the busy-retry timers above.
  function refreshAccount() {
    if (!installed || !authenticated || accountName !== "") return
    _accountRetries = 0
    accountProbeTimer.restart()
  }

  // Re-armed while another proton-drive call holds the CLI. Bounded, because
  // a long sign-in can hold it for tens of seconds - and giving up is safe,
  // since the next status poll calls refreshAccount() again for as long as
  // the address is still unknown.
  function _probeAccountNow() {
    if (!installed || !authenticated || accountName !== "" || accountProcess.running) return
    if (cliBusy) {
      if (_accountRetries < maxAccountRetries) {
        _accountRetries++
        accountProbeTimer.restart()
      }
      return
    }
    _accountOutput = ""
    _accountError = ""
    accountProcess.command = ["proton-drive", "filesystem", "info", "-j", "/my-files"]
    accountProcess.running = true
  }

  function parseStatus(exitCode, stdout, stderr) {
    if (exitCode !== 0 && Model.classifyCliFailure(stdout, stderr) === "busy") {
      if (_statusBusyRetries < maxBusyRetries) {
        _statusBusyRetries++
        // Keep the last known authenticated state (don't flip to the
        // "Unavailable" + sign-in prompt for what is a transient, still-
        // signed-in hiccup) and retry shortly.
        statusText = authenticated ? "Refreshing…" : "Checking…"
        lastError = ""
        statusBusyRetryTimer.restart()
        return
      }
      // Retries exhausted — fall through to the normal (sanitized) failure
      // path below rather than retrying forever.
    } else {
      _statusBusyRetries = 0
    }
    var raw = stdout !== "" ? stdout : stderr
    var parsed = Model.parseStatus(exitCode, raw)
    authenticated = parsed.authenticated
    statusText = parsed.statusText
    lastError = parsed.ok ? "" : (parsed.lastError || "Failed to read Proton Drive status")
    if (!authenticated) accountName = ""
    else refreshAccount()
  }

  // `auth login` prints a sign-in URL to stdout and blocks until the browser
  // flow completes, then exits 0 — but unlike Tailscale/ProtonVPN's CLIs, the
  // Proton Drive CLI ALSO spawns its own `xdg-open` on that URL before it
  // even prints it (confirmed by reading the compiled binary: it calls
  // `spawn("xdg-open", [url], {detached:true})` from inside the login
  // action). So we must NOT also open the URL ourselves here — doing so is
  // exactly what caused duplicate browser tabs during development. We only
  // watch stdout to know when the flow finishes and to keep the URL around
  // as a plain-text fallback (shown in actionStatus) in case xdg-open had
  // nothing to hand off to.
  property string authUrl: ""

  function login() {
    if (!installed || authenticated || loginProcess.running) return
    _loginOutput = ""
    _loginError = ""
    authUrl = ""
    actionStatus = "Check your browser to finish signing in…"
    loginProcess.command = ["proton-drive", "auth", "login"]
    loginProcess.running = true
  }

  // Presumed non-interactive and headless per `auth logout --help` ("Signs
  // out and clears local credentials and caches.") — no prompts to expect.
  function logout() {
    if (!installed || !authenticated || logoutProcess.running) return
    _logoutOutput = ""
    _logoutError = ""
    actionStatus = "Signing out…"
    logoutProcess.command = ["proton-drive", "auth", "logout"]
    logoutProcess.running = true
  }

  // --- File browser -----------------------------------------------------
  // `filesystem list -j <path>` is read-only and side-effect-free, same as
  // the status probe above. Re-run with a new path to navigate. Queued via
  // runWhenIdle so it never races the status probe or another file op.
  function browse(path) {
    runWhenIdle(function() { root._browseNow(path) })
  }

  function _browseNow(path) {
    if (browseProcess.running) return
    currentPath = path || "/"
    browsing = true
    browseError = ""
    _browseOutput = ""
    _browseError = ""
    browseProcess.command = ["proton-drive", "filesystem", "list", "-j", currentPath]
    browseProcess.running = true
  }

  function goUp() {
    if (currentPath === "/") return
    browse(Model.parentPath(currentPath))
  }

  // Opens a folder's location in the Proton Drive app instead of navigating
  // the panel's own list — there is no local sync for Drive, so the
  // installed web app is the natural "default way to open it" for a
  // remote-only folder.
  //
  // If Proton Drive is installed as a browser PWA ("Install app" in a
  // Chromium-based browser), that creates a real desktop entry
  // (Name=Proton Drive) under ~/.local/share/applications/ or
  // /usr/share/applications/, named after the specific browser/profile/
  // extension-id combination that installed it - which varies per machine
  // and per browser, so it can't be hardcoded. Search for whichever desktop
  // file actually has Name=Proton Drive at the moment this runs, and launch
  // that by id via `gtk-launch` - opens the real installed app window (its
  // own icon/window class) rather than a plain browser tab. Falls straight
  // through to a plain browser tab if no such PWA is installed.
  //
  // This always opens the Drive app root rather than a deep link to `path`,
  // because there is no CLI-exposed way to turn a path into a working
  // private web-app folder URL. Investigated on this machine:
  //   - `filesystem info -j <path>` returns node metadata (uid, parentUid,
  //     name, type, timestamps, ...) but no URL field of any kind, and the
  //     `uid` it prints is this CLI's own composite shareUid~linkUid token —
  //     not the shareID/linkID pair the web app's authenticated routes use,
  //     so decoding it to fabricate a `/u/0/folder/...`-style URL would be a
  //     guess, not a fact.
  //   - `sharing status -j <path>` is read-only (confirmed by re-running
  //     `filesystem info` on a never-shared test folder before/after: it
  //     stays isSharedByUrl:false) and surfaces a real `urlAccess.url` field
  //     — but only for a node that *already* has a public share; for
  //     anything else it prints nothing usable.
  //   - `sharing set-url <path>` is the only command that mints a URL for an
  //     arbitrary folder, but doing so creates a real public share link —
  //     a meaningful, consequential action (makes the folder's contents
  //     reachable by anyone with the link) that must never fire silently as
  //     a side effect of what looks like a harmless "open" click.
  // So: no public share is created here, and no guessed deep-link URL is
  // built. Landing on the Drive app root is a deliberate, honest fallback
  // instead of a broken or fabricated link.
  // Takes a path argument for call-site symmetry with browse()/download(),
  // but per the comment above there's no way to turn it into a per-folder
  // deep link - deliberately unused, named accordingly so it doesn't read as
  // an oversight.
  function openInBrowser(_path) {
    // Self-contained: the search-and-fall-back logic lives entirely in this
    // one shell script rather than chained QML Process/onExited handlers,
    // since there's nothing here that needs the result back in QML.
    var script = "found=\"\"; " +
      "for f in \"$HOME/.local/share/applications\"/*.desktop /usr/share/applications/*.desktop; do " +
      "[ -f \"$f\" ] || continue; " +
      "if grep -qix \"Name=Proton Drive\" \"$f\" 2>/dev/null; then found=$(basename \"$f\" .desktop); break; fi; " +
      "done; " +
      "if [ -n \"$found\" ]; then exec gtk-launch \"$found\"; else exec omarchy-launch-browser https://drive.proton.me; fi"
    Quickshell.execDetached(["bash", "-c", script])
  }

  function applyList(exitCode, stdout, stderr, path) {
    if (exitCode !== 0 && Model.classifyCliFailure(stdout, stderr) === "busy") {
      if (_browseBusyRetries < maxBusyRetries) {
        _browseBusyRetries++
        // Keep showing "Loading…" and retry shortly rather than rendering
        // the CLI's raw crash dump (source excerpt / stack trace) or its
        // bare "=" banner line as if they were file rows.
        browsing = true
        browseError = ""
        browseBusyRetryTimer.restart()
        return
      }
      // Retries exhausted — fall through and show a real (sanitized) error.
    } else {
      _browseBusyRetries = 0
    }
    browsing = false
    var parsed = Model.parseList(exitCode, stdout, stderr, path)
    if (parsed.ok) {
      entries = parsed.entries
      browseError = ""
    } else {
      entries = []
      browseError = parsed.error || "Failed to list folder"
    }
  }

  // Downloads always land in ~/Downloads (never touches trash/delete). Uses
  // -f rename / -d skip so a rare local-name collision can never leave the
  // CLI blocked waiting for an interactive conflict prompt that will never
  // come — this Process has no interactive stdin hooked up.
  function download(entry) {
    if (!entry || entry.kind !== "file") return
    runWhenIdle(function() { root._downloadNow(entry) })
  }

  function _downloadNow(entry) {
    if (downloadProcess.running) return
    var home = Quickshell.env("HOME") || ""
    var dest = (home !== "" ? home : "/root") + "/Downloads"
    _downloadOutput = ""
    _downloadError = ""
    actionStatus = "Downloading " + entry.name + "…"
    downloadProcess.command = ["proton-drive", "filesystem", "download", "-f", "rename", "-d", "skip", entry.path, dest]
    downloadProcess.running = true
  }

  // No native file picker inside Quickshell's popup surfaces, and Omarchy's
  // shell has no existing file-picker convention to reuse (checked: no
  // plugin greps for zenity/kdialog/xdg-desktop-portal for this purpose).
  // `zenity` is installed on this machine, so we shell out to its GTK file
  // dialog and read the chosen path back from stdout. This intentionally
  // runs zenity directly rather than via `uwsm-app` (the convention used
  // elsewhere for fire-and-forget GUI launches, e.g. Dropbox's "open in
  // nautilus") because uwsm-app hands the launch off to a daemon over a
  // pipe and does not relay the child's stdout back to us — and we need
  // that stdout to learn which file was picked.
  function pickAndUpload() {
    if (!canUpload || uploadPickProcess.running || uploadProcess.running) return
    _pickOutput = ""
    _pickError = ""
    actionStatus = "Choose a file to upload…"
    uploadPickProcess.command = ["zenity", "--file-selection", "--title=Upload to Proton Drive"]
    uploadPickProcess.running = true
  }

  function _uploadNow(localPath) {
    if (uploadProcess.running) return
    _uploadOutput = ""
    _uploadError = ""
    uploadProcess.command = ["proton-drive", "filesystem", "upload", "-f", "rename", "-d", "merge", localPath, root.currentPath]
    uploadProcess.running = true
  }

  // "Open" a file: fetch a fresh copy into openCacheDir, then hand it to the
  // system's default handler via xdg-open. Deliberately uses -f remove
  // (rather than download()'s rename/skip) so the cache dir always holds
  // exactly one, always-current copy of the file at a path we can predict —
  // the CLI's "Transfer summary" output never echoes the resolved filename
  // when a conflict forced a rename, so `rename` would leave us guessing
  // which local file to launch. `remove` also means re-opening the same
  // file later re-fetches the current remote content instead of launching a
  // stale cached copy.
  function openFile(entry) {
    if (!entry || entry.kind !== "file") return
    runWhenIdle(function() { root._openNow(entry) })
  }

  function _openNow(entry) {
    if (openProcess.running) return
    _openOutput = ""
    _openError = ""
    // entry.name comes straight from the CLI's JSON and isn't guaranteed
    // free of "/" (a remote name can contain arbitrary characters) - joining
    // it in raw would make the local path a subdirectory+file instead of the
    // one flat file the CLI actually writes into openCacheDir, so xdg-open
    // ends up pointed at a path that doesn't exist or isn't the real file.
    var safeName = String(entry.name || "").replace(/\//g, "_")
    _openLocalPath = root.openCacheDir + "/" + safeName
    actionStatus = "Opening " + entry.name + "…"
    openProcess.command = ["proton-drive", "filesystem", "download", "-f", "remove", "-d", "merge", entry.path, root.openCacheDir]
    openProcess.running = true
  }

  function handleLoginOutput(data, isError) {
    var text = String(data || "")
    if (isError) _loginError += text + "\n"
    else _loginOutput += text + "\n"
    var match = text.match(/https?:\/\/\S+/)
    if (match && match[0]) {
      authUrl = match[0]
      actionStatus = "Continue in the browser tab that just opened…"
    }
  }

  Timer {
    id: refreshTimer
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    id: delayedRefresh
    interval: 600
    repeat: false
    onTriggered: root.refresh()
  }

  Timer {
    id: actionStatusTimer
    interval: 2200
    repeat: false
    onTriggered: root.actionStatus = ""
  }

  Timer {
    // Same role as Tailscale/ProtonVPN's pollWatchdog: reap a hung status
    // call so one bad poll doesn't silently freeze the widget forever. Only
    // ever targets statusProcess — never login/logout.
    id: pollWatchdog
    interval: 15000
    repeat: false
    onTriggered: { if (statusProcess.running) statusProcess.running = false }
  }

  Process {
    id: whichProcess
    running: false
    command: []
    onExited: function(exitCode) {
      root.installed = exitCode === 0
      if (root.installed) root.refresh()
      else {
        root.refreshing = false
        root.resetUnavailable("Not installed")
      }
    }
  }

  Process {
    id: statusProcess
    running: false
    command: []
    stdout: StdioCollector { id: statusStdout; waitForEnd: true; onStreamFinished: root._statusOutput = text }
    stderr: StdioCollector { id: statusStderr; waitForEnd: true; onStreamFinished: root._statusError = text }
    onExited: function(exitCode) {
      root.refreshing = false
      var stdout = String(statusStdout.text || root._statusOutput || "")
      var stderr = String(statusStderr.text || root._statusError || "")
      root.parseStatus(exitCode, stdout, stderr)
      root._drainPending()
    }
  }

  Process {
    id: accountProcess
    running: false
    command: []
    stdout: StdioCollector { id: accountStdout; waitForEnd: true; onStreamFinished: root._accountOutput = text }
    stderr: StdioCollector { id: accountStderr; waitForEnd: true; onStreamFinished: root._accountError = text }
    onExited: function(exitCode) {
      var stdout = String(accountStdout.text || root._accountOutput || "")
      root.accountName = Model.parseAccountEmail(exitCode, stdout)
      root._drainPending()
    }
  }

  Process {
    id: loginProcess
    running: false
    command: []
    stdout: SplitParser { onRead: function(data) { root.handleLoginOutput(data, false) } }
    stderr: SplitParser { onRead: function(data) { root.handleLoginOutput(data, true) } }
    onExited: function(exitCode) {
      var combined = String(root._loginOutput || "") + "\n" + String(root._loginError || "")
      if (exitCode !== 0) {
        root.lastError = Model.sanitizeCliText(combined, "Proton Drive login failed")
        root.actionStatus = root.lastError
        actionStatusTimer.restart()
      } else {
        root.lastError = ""
        root.actionStatus = ""
      }
      delayedRefresh.restart()
    }
  }

  Process {
    id: logoutProcess
    running: false
    command: []
    stdout: StdioCollector { id: logoutStdout; waitForEnd: true; onStreamFinished: root._logoutOutput = text }
    stderr: StdioCollector { id: logoutStderr; waitForEnd: true; onStreamFinished: root._logoutError = text }
    onExited: function(exitCode) {
      var stdout = String(logoutStdout.text || root._logoutOutput || "")
      var stderr = String(logoutStderr.text || root._logoutError || "")
      if (exitCode !== 0) {
        root.lastError = Model.sanitizeCliText(stderr || stdout, "Proton Drive logout failed")
        root.actionStatus = root.lastError
        actionStatusTimer.restart()
      } else {
        root.lastError = ""
        root.actionStatus = ""
        root.authenticated = false
        root.accountName = ""
        root.statusText = "Signed out"
      }
      delayedRefresh.restart()
    }
  }

  Process {
    id: browseProcess
    running: false
    command: []
    stdout: StdioCollector { id: browseStdout; waitForEnd: true; onStreamFinished: root._browseOutput = text }
    stderr: StdioCollector { id: browseStderr; waitForEnd: true; onStreamFinished: root._browseError = text }
    onExited: function(exitCode) {
      var stdout = String(browseStdout.text || root._browseOutput || "")
      var stderr = String(browseStderr.text || root._browseError || "")
      root.applyList(exitCode, stdout, stderr, root.currentPath)
      root._drainPending()
    }
  }

  Process {
    id: downloadProcess
    running: false
    command: []
    stdout: StdioCollector { id: downloadStdout; waitForEnd: true; onStreamFinished: root._downloadOutput = text }
    stderr: StdioCollector { id: downloadStderr; waitForEnd: true; onStreamFinished: root._downloadError = text }
    onExited: function(exitCode) {
      var stdout = String(downloadStdout.text || root._downloadOutput || "")
      var stderr = String(downloadStderr.text || root._downloadError || "")
      if (exitCode !== 0) {
        root.lastError = Model.sanitizeCliText(stderr || stdout, "Download failed")
        root.actionStatus = root.lastError
      } else {
        root.lastError = ""
        root.actionStatus = "Downloaded to ~/Downloads"
      }
      actionStatusTimer.restart()
      root._drainPending()
    }
  }

  Process {
    id: uploadPickProcess
    running: false
    command: []
    stdout: StdioCollector { id: pickStdout; waitForEnd: true; onStreamFinished: root._pickOutput = text }
    stderr: StdioCollector { id: pickStderr; waitForEnd: true; onStreamFinished: root._pickError = text }
    onExited: function(exitCode) {
      var picked = String(pickStdout.text || root._pickOutput || "").trim()
      // Non-zero exit (or empty stdout) just means the user hit Cancel —
      // that is not an error, so stay quiet.
      if (exitCode !== 0 || picked === "") {
        root.actionStatus = ""
        return
      }
      root.actionStatus = "Uploading " + picked.split("/").pop() + "…"
      root.runWhenIdle(function() { root._uploadNow(picked) })
    }
  }

  Process {
    id: uploadProcess
    running: false
    command: []
    stdout: StdioCollector { id: uploadStdout; waitForEnd: true; onStreamFinished: root._uploadOutput = text }
    stderr: StdioCollector { id: uploadStderr; waitForEnd: true; onStreamFinished: root._uploadError = text }
    onExited: function(exitCode) {
      var stdout = String(uploadStdout.text || root._uploadOutput || "")
      var stderr = String(uploadStderr.text || root._uploadError || "")
      if (exitCode !== 0) {
        root.lastError = Model.sanitizeCliText(stderr || stdout, "Upload failed")
        root.actionStatus = root.lastError
      } else {
        root.lastError = ""
        root.actionStatus = "Uploaded successfully"
        root.browse(root.currentPath)
      }
      actionStatusTimer.restart()
      root._drainPending()
    }
  }

  Process {
    id: openProcess
    running: false
    command: []
    stdout: StdioCollector { id: openStdout; waitForEnd: true; onStreamFinished: root._openOutput = text }
    stderr: StdioCollector { id: openStderr; waitForEnd: true; onStreamFinished: root._openError = text }
    onExited: function(exitCode) {
      var stdout = String(openStdout.text || root._openOutput || "")
      var stderr = String(openStderr.text || root._openError || "")
      if (exitCode !== 0) {
        root.lastError = Model.sanitizeCliText(stderr || stdout, "Failed to open file")
        root.actionStatus = root.lastError
      } else {
        root.lastError = ""
        root.actionStatus = ""
        // Login-shell exec so xdg-open sees the same PATH/session env a
        // normal launch would (same convention Util.execArgv documents
        // itself for: "GUI targets ... xdg-open ... need").
        Util.execArgv(["xdg-open", root._openLocalPath])
      }
      actionStatusTimer.restart()
      root._drainPending()
    }
  }
}
