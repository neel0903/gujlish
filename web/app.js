/* Gujlish PWA — UI, personal dictionary storage, WhatsApp import. */
(function () {
  "use strict";
  var G = window.Gujlish;
  var VERSION = window.GUJLISH_VERSION || "dev";
  var $ = function (id) { return document.getElementById(id); };

  // ---------- engine ----------
  var t0 = performance.now();
  var engine = new G.Engine(GUJLISH_DATA.words, GUJLISH_DATA.bigrams, window.GUJLISH_ENGLISH || []);
  var loadMs = Math.round(performance.now() - t0);

  // ---------- settings ----------
  var settings = { mode: "mixed", showDebug: false, autocorrect: true };
  try { Object.assign(settings, JSON.parse(localStorage.getItem("gujlish.settings") || "{}")); } catch (e) {}
  function saveSettings() { try { localStorage.setItem("gujlish.settings", JSON.stringify(settings)); } catch (e) {} }
  engine.mode = settings.mode;

  // ---------- personal dictionary (IndexedDB, one document) ----------
  var DB_NAME = "gujlish", STORE = "kv";
  function openDb() {
    return new Promise(function (resolve, reject) {
      if (!window.indexedDB) return reject(new Error("no IndexedDB"));
      var req = indexedDB.open(DB_NAME, 1);
      req.onupgradeneeded = function () { req.result.createObjectStore(STORE); };
      req.onsuccess = function () { resolve(req.result); };
      req.onerror = function () { reject(req.error); };
    });
  }
  function dbGet(key) {
    return openDb().then(function (db) {
      return new Promise(function (resolve, reject) {
        var r = db.transaction(STORE).objectStore(STORE).get(key);
        r.onsuccess = function () { resolve(r.result); };
        r.onerror = function () { reject(r.error); };
      });
    });
  }
  function dbSet(key, value) {
    return openDb().then(function (db) {
      return new Promise(function (resolve, reject) {
        var tx = db.transaction(STORE, "readwrite");
        tx.objectStore(STORE).put(value, key);
        tx.oncomplete = resolve;
        tx.onerror = function () { reject(tx.error); };
      });
    });
  }

  var personal = { words: {}, bigrams: {}, sources: [] };
  var saveTimer = null;
  function savePersonal() {
    clearTimeout(saveTimer);
    saveTimer = setTimeout(function () {
      var snap = engine.personalSnapshot();
      personal.words = snap.words; personal.bigrams = snap.bigrams;
      dbSet("personal", personal).catch(function () {});
      updateLearnedLine();
    }, 400);
  }
  function plural(n, word) { return n + " " + word + (n === 1 ? "" : "s"); }
  function updateLearnedLine() {
    var snap = engine.personalSnapshot();
    var nw = Object.keys(snap.words).length, nb = Object.keys(snap.bigrams).length;
    $("learnedLine").textContent = nw ? plural(nw, "word") + " and " + plural(nb, "pair") + " learned." : "Nothing learned yet.";
    $("learnedDetail").textContent = nw
      ? plural(nw, "word") + ", " + plural(nb, "word pair") + (personal.sources.length ? ", from " + plural(personal.sources.length, "chat import") + " and your typing." : ", from your typing.")
      : "Every word you take or type is counted here, on this phone only.";
  }

  // Migrate the Phase 2 tester's localStorage counts, once.
  try {
    var old = JSON.parse(localStorage.getItem("gujlish.userCounts") || "null");
    if (old) { personal.words = old; localStorage.removeItem("gujlish.userCounts"); dbSet("personal", personal); }
  } catch (e) {}

  dbGet("personal").then(function (data) {
    if (data) personal = data;
    engine.loadPersonal(personal);
    updateLearnedLine();
    render();
  }).catch(function () { engine.loadPersonal(personal); updateLearnedLine(); });

  // ---------- typing ----------
  var msg = $("msg"), strip = $("strip"), stripWrap = $("stripWrap"), debug = $("debug"), toast = $("toast");
  $("stats").textContent = GUJLISH_DATA.words.length.toLocaleString() + " words · " + loadMs + " ms";
  $("version").textContent = VERSION;
  debug.hidden = !settings.showDebug;

  function split() {
    var text = msg.value;
    var m = /(\S*)$/.exec(text);
    var current = m ? m[1] : "";
    var head = text.slice(0, text.length - current.length);
    var prevMatch = /(\S+)\s*$/.exec(head);
    return { head: head, current: current, prev: prevMatch ? prevMatch[1] : null };
  }

  function render() {
    var s = split();
    var t = performance.now();
    var res, predicted = false;
    if (s.current) {
      res = engine.suggestDetailed(s.current, s.prev);
    } else {
      res = { surfaces: engine.nextWord(s.prev), sources: {}, sk: "", lk: "", tiers: null };
      predicted = true;
    }
    var ms = (performance.now() - t).toFixed(1);

    strip.innerHTML = "";
    strip.classList.toggle("predicted", predicted);
    if (lastCorrection && !s.current) {
      var u = document.createElement("button");
      u.type = "button";
      u.className = "undo";
      u.textContent = lastCorrection.original;
      u.title = "Keep what you typed";
      u.addEventListener("mousedown", function (ev) { ev.preventDefault(); });
      u.addEventListener("touchstart", function (ev) { ev.preventDefault(); undoCorrection(); }, { passive: false });
      u.addEventListener("click", undoCorrection);
      strip.appendChild(u);
    }
    if (!res.surfaces.length && !lastCorrection) {
      var e = document.createElement("span");
      e.className = "empty";
      e.textContent = s.current ? "no match — space keeps what you typed" : (s.prev ? "" : "Start typing");
      strip.appendChild(e);
    }
    res.surfaces.forEach(function (surface, i) {
      var b = document.createElement("button");
      b.type = "button";
      b.textContent = surface;
      b.className = (i === 0 ? "first " : "") + (res.sources[surface] || "");
      b.addEventListener("mousedown", function (ev) { ev.preventDefault(); });
      b.addEventListener("touchstart", function (ev) { ev.preventDefault(); take(surface); }, { passive: false });
      b.addEventListener("click", function () { take(surface); });
      strip.appendChild(b);
    });

    if (!settings.showDebug) return;
    if (s.current) {
      var ti = res.tiers;
      debug.textContent =
        "typed " + JSON.stringify(s.current) + (s.prev ? "  after " + JSON.stringify(s.prev) : "") +
        "\nstrict " + res.sk + "  loose " + res.lk +
        "\nmatches strict " + ti.strict + " / loose " + ti.loose + " / fuzzy " + ti.fuzzy +
        " / english " + ti.english + "  " + ms + " ms";
    } else if (s.prev) {
      debug.textContent = "predicting after " + JSON.stringify(s.prev) + "  loose " +
        G.looseKey(s.prev, true) + "  " + res.surfaces.length + " followers  " + ms + " ms";
    } else debug.textContent = "";
  }

  var lastTake = 0;
  function take(surface) {
    var now = Date.now();
    if (now - lastTake < 300) return;
    lastTake = now;
    var s = split();
    msg.value = s.head + surface + " ";
    lastValue = msg.value;
    lastCorrection = null;
    engine.accept(surface, s.prev);
    savePersonal();
    msg.focus();
    render();
  }

  // Keep the typist's capitalisation: "Avi" -> "Aavi", "AVI" -> "AAVI".
  function matchCase(typed, fix) {
    if (typed.length > 1 && typed === typed.toUpperCase() && /[A-Z]/.test(typed)) return fix.toUpperCase();
    if (/^[A-Z]/.test(typed)) return fix.charAt(0).toUpperCase() + fix.slice(1);
    return fix;
  }

  // Space (or a newline) commits the typed word. With autocorrect on,
  // a wrong spelling is replaced by the word as the Gujarati script
  // spells it, and the strip offers the original back for one tap.
  // What gets learned is the committed word, so typos don't stick.
  var lastValue = "", lastCorrection = null;
  function undoCorrection() {
    var c = lastCorrection;
    if (!c) return;
    var v = msg.value, tail = c.replacement + " ";
    if (v.slice(-tail.length) === tail) msg.value = v.slice(0, -tail.length) + c.original + " ";
    lastValue = msg.value;
    lastCorrection = null;
    engine.learnWord(c.original, 2);        // twice: "I meant it" — never corrected again
    if (c.prev) engine.learnBigram(c.prev, c.original, 1);
    savePersonal();
    msg.focus();
    render();
  }
  msg.addEventListener("input", function () {
    var v = msg.value;
    var committed = v.length > lastValue.length && /\s$/.test(v) && !/\s$/.test(lastValue);
    if (!committed) lastCorrection = null;
    if (committed) {
      var m = /(\S+)(\s)$/.exec(v);
      var clean = m && G.cleanSurface(m[1]);
      if (clean) {
        var before = /(\S+)\s+\S+\s$/.exec(v);
        var prev = before ? before[1] : null;
        var fix = settings.autocorrect ? engine.correct(m[1], prev) : null;
        if (fix) {
          var shown = matchCase(m[1], fix);
          msg.value = v.slice(0, v.length - m[0].length) + shown + m[2];
          v = msg.value;
          lastCorrection = { original: m[1], replacement: shown, prev: prev };
          engine.accept(fix, prev);
        } else {
          lastCorrection = null;
          engine.accept(clean, prev);
        }
        savePersonal();
      }
    }
    lastValue = v;
    render();
  });
  msg.addEventListener("keydown", function (ev) {
    if (ev.key === "Tab") {
      var first = strip.querySelector("button");
      if (first) { ev.preventDefault(); take(first.textContent); }
    }
  });

  // ---------- strip follows the on-screen keyboard ----------
  function placeStrip() {
    var vv = window.visualViewport;
    if (!vv) return;
    var bottom = window.innerHeight - (vv.offsetTop + vv.height);
    stripWrap.style.bottom = Math.max(0, bottom) + "px";
  }
  if (window.visualViewport) {
    window.visualViewport.addEventListener("resize", placeStrip);
    window.visualViewport.addEventListener("scroll", placeStrip);
  }
  placeStrip();

  // ---------- actions ----------
  function showToast(text) {
    toast.textContent = text;
    toast.classList.add("show");
    setTimeout(function () { toast.classList.remove("show"); }, 1400);
  }
  function messageText() { return msg.value.trim(); }

  $("copy").addEventListener("click", function () {
    var text = messageText();
    if (!text) return;
    var done = function () { showToast("Copied"); };
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(done, fallback);
    } else fallback();
    function fallback() {
      msg.focus(); msg.select();
      try { document.execCommand("copy"); done(); } catch (e) {}
    }
  });
  $("share").addEventListener("click", function () {
    var text = messageText();
    if (!text) return;
    if (navigator.share) navigator.share({ text: text }).catch(function () {});
    else showToast("Sharing is not available here — use Copy");
  });
  $("whatsapp").addEventListener("click", function () {
    var text = messageText();
    if (!text) { showToast("Nothing to send yet"); return; }
    var a = document.createElement("a");
    a.href = "https://wa.me/?text=" + encodeURIComponent(text);
    a.target = "_blank"; a.rel = "noopener";
    document.body.appendChild(a); a.click(); a.remove();
  });
  $("backspace").addEventListener("mousedown", function (ev) { ev.preventDefault(); });
  $("backspace").addEventListener("click", function () {
    var s = split();
    msg.value = s.current ? s.head : s.head.replace(/\S+\s*$/, "");
    lastValue = msg.value; lastCorrection = null;
    msg.focus(); render();
  });
  $("clear").addEventListener("click", function () { msg.value = ""; lastValue = ""; lastCorrection = null; msg.focus(); render(); });

  // ---------- settings sheet ----------
  var dlg = $("settings");
  function openSettings() {
    var radios = dlg.querySelectorAll("input[name=mode]");
    radios.forEach(function (r) { r.checked = r.value === settings.mode; });
    $("showDebug").checked = settings.showDebug;
    $("autocorrect").checked = settings.autocorrect;
    if (typeof dlg.showModal === "function") dlg.showModal(); else dlg.setAttribute("open", "");
  }
  $("openSettings").addEventListener("click", openSettings);
  $("openLearn").addEventListener("click", function (ev) {
    ev.preventDefault(); openSettings();
    $("learnSection").scrollIntoView({ block: "start" });
  });
  dlg.addEventListener("change", function (ev) {
    if (ev.target.name === "mode") { settings.mode = ev.target.value; engine.mode = settings.mode; }
    if (ev.target.id === "showDebug") { settings.showDebug = ev.target.checked; debug.hidden = !settings.showDebug; }
    if (ev.target.id === "autocorrect") settings.autocorrect = ev.target.checked;
    saveSettings(); render();
  });
  dlg.addEventListener("close", function () { render(); });

  // ---------- learned data: export / import / forget ----------
  $("exportBtn").addEventListener("click", function () {
    var snap = engine.personalSnapshot();
    var data = { app: "gujlish", version: VERSION, exported: new Date().toISOString(),
                 words: snap.words, bigrams: snap.bigrams, sources: personal.sources };
    var blob = new Blob([JSON.stringify(data)], { type: "application/json" });
    var file = new File([blob], "gujlish-learned.json", { type: "application/json" });
    if (navigator.canShare && navigator.canShare({ files: [file] })) {
      navigator.share({ files: [file], title: "Gujlish learned words" }).catch(function () {});
    } else {
      var a = document.createElement("a");
      a.href = URL.createObjectURL(blob); a.download = "gujlish-learned.json";
      document.body.appendChild(a); a.click(); a.remove();
    }
  });
  $("importBtn").addEventListener("click", function () { $("importFile").click(); });
  $("importFile").addEventListener("change", function () {
    var f = this.files[0]; if (!f) return;
    f.text().then(function (text) {
      var data = JSON.parse(text);
      if (!data || data.app !== "gujlish") throw new Error("not a Gujlish export");
      engine.loadPersonal({ words: data.words, bigrams: data.bigrams });
      (data.sources || []).forEach(function (s) { personal.sources.push(s); });
      savePersonal(); render();
      $("learnedDetail").textContent = "Imported " + Object.keys(data.words || {}).length + " words.";
    }).catch(function (e) { $("learnedDetail").textContent = "Could not import: " + e.message; });
    this.value = "";
  });
  $("forgetBtn").addEventListener("click", function () {
    engine.forgetPersonal();
    personal = { words: {}, bigrams: {}, sources: [] };
    dbSet("personal", personal).catch(function () {});
    updateLearnedLine(); render();
    $("learnedDetail").textContent = "Forgotten.";
  });

  // ---------- WhatsApp chat import ----------
  // Android:  19/09/26, 10:12 - Name: message
  // iPhone:   [19/09/26, 10:12:33 AM] Name: message   (often with a U+200E prefix)
  var LINE_RE = /^‎?\[?(\d{1,2}[\/.\-]\d{1,2}[\/.\-]\d{2,4}),?\s+\d{1,2}:\d{2}(?::\d{2})?\s?(?:[APap]\.?[Mm]\.?)?\]?\s?[-–]?\s?([^:]{1,60}?):\s(.*)$/;
  var SKIP_RE = /omitted|deleted this message|message was deleted|https?:\/\/|<attached:/i;

  function parseChat(text) {
    var lines = text.split(/\r?\n/), messages = [], cur = null;
    for (var i = 0; i < lines.length; i++) {
      var m = LINE_RE.exec(lines[i]);
      if (m) { cur = { sender: m[2].replace(/^‎/, "").trim(), text: m[3] }; messages.push(cur); }
      else if (cur) cur.text += "\n" + lines[i];
    }
    return messages;
  }

  function readChatFile(file) {
    if (/\.zip$/i.test(file.name) || file.type === "application/zip") return unzipFirstText(file);
    return file.text();
  }

  // Minimal zip reader: find _chat.txt (or any .txt) in the central
  // directory and inflate it with DecompressionStream. No library.
  function unzipFirstText(file) {
    return file.arrayBuffer().then(function (buf) {
      var dv = new DataView(buf), u8 = new Uint8Array(buf);
      var eocd = -1;
      for (var i = buf.byteLength - 22; i >= Math.max(0, buf.byteLength - 66000); i--) {
        if (dv.getUint32(i, true) === 0x06054b50) { eocd = i; break; }
      }
      if (eocd < 0) throw new Error("not a zip file");
      var count = dv.getUint16(eocd + 10, true), off = dv.getUint32(eocd + 16, true);
      var dec = new TextDecoder();
      var pick = null;
      for (var n = 0; n < count; n++) {
        if (dv.getUint32(off, true) !== 0x02014b50) break;
        var method = dv.getUint16(off + 10, true);
        var csize = dv.getUint32(off + 20, true);
        var nameLen = dv.getUint16(off + 28, true), extraLen = dv.getUint16(off + 30, true), cmtLen = dv.getUint16(off + 32, true);
        var local = dv.getUint32(off + 42, true);
        var name = dec.decode(u8.subarray(off + 46, off + 46 + nameLen));
        if (/\.txt$/i.test(name) && (!pick || /_chat\.txt$/i.test(name))) pick = { method: method, csize: csize, local: local, name: name };
        off += 46 + nameLen + extraLen + cmtLen;
      }
      if (!pick) throw new Error("no .txt inside the zip");
      var lh = pick.local;
      var dataStart = lh + 30 + dv.getUint16(lh + 26, true) + dv.getUint16(lh + 28, true);
      var data = u8.subarray(dataStart, dataStart + pick.csize);
      if (pick.method === 0) return dec.decode(data);
      if (pick.method !== 8) throw new Error("unsupported zip compression");
      if (typeof DecompressionStream === "undefined") throw new Error("this browser cannot unzip; export the chat as .txt");
      var stream = new Blob([data]).stream().pipeThrough(new DecompressionStream("deflate-raw"));
      return new Response(stream).text();
    });
  }

  var pendingChat = null;
  $("chatFile").addEventListener("change", function () {
    var f = this.files[0]; if (!f) return;
    $("learnResult").textContent = "Reading…";
    $("senders").hidden = true; $("learnBtn").disabled = true;
    readChatFile(f).then(function (text) {
      var messages = parseChat(text);
      if (!messages.length) throw new Error("no messages found — is this a WhatsApp export?");
      var bySender = {};
      messages.forEach(function (m) { bySender[m.sender] = (bySender[m.sender] || 0) + 1; });
      pendingChat = { name: f.name, messages: messages };
      var box = $("senders");
      box.innerHTML = "<p class='hint'>Learn from:</p>";
      Object.keys(bySender).sort(function (a, b) { return bySender[b] - bySender[a]; }).forEach(function (s) {
        var label = document.createElement("label");
        var cb = document.createElement("input"); cb.type = "checkbox"; cb.checked = true; cb.value = s;
        label.appendChild(cb); label.appendChild(document.createTextNode(" " + s + " (" + bySender[s] + ")"));
        box.appendChild(label);
      });
      box.hidden = false;
      $("learnBtn").disabled = false;
      $("learnResult").textContent = messages.length + " messages found.";
    }).catch(function (e) { $("learnResult").textContent = "Could not read the file: " + e.message; });
    this.value = "";
  });

  $("learnBtn").addEventListener("click", function () {
    if (!pendingChat) return;
    var allowed = {};
    $("senders").querySelectorAll("input:checked").forEach(function (cb) { allowed[cb.value] = true; });
    var words = {}, bigrams = {}, used = 0;
    pendingChat.messages.forEach(function (m) {
      if (!allowed[m.sender] || SKIP_RE.test(m.text)) return;
      var toks = (m.text.toLowerCase().match(/[a-z']+/g) || [])
        .map(function (t) { return t.replace(/'/g, ""); })
        .filter(function (t) { return /^[a-z]+$/.test(t) && t.length <= 24; });
      if (!toks.length) return;
      used++;
      for (var i = 0; i < toks.length; i++) {
        words[toks[i]] = (words[toks[i]] || 0) + 1;
        if (i) { var k = toks[i - 1] + " " + toks[i]; bigrams[k] = (bigrams[k] || 0) + 1; }
      }
    });
    var t = performance.now();
    engine.loadPersonal({ words: words, bigrams: bigrams });
    personal.sources.push({ name: pendingChat.name, date: new Date().toISOString().slice(0, 10), messages: used });
    savePersonal(); render();
    $("learnResult").textContent = "Learned " + Object.keys(words).length + " words and " +
      Object.keys(bigrams).length + " pairs from " + used + " messages (" + Math.round(performance.now() - t) + " ms).";
    pendingChat = null; $("senders").hidden = true; $("learnBtn").disabled = true;
  });

  // ---------- service worker ----------
  if ("serviceWorker" in navigator) {
    navigator.serviceWorker.register("sw.js").then(function (reg) {
      // A real update sits in "waiting" behind the active worker. A
      // first install goes straight to activating, so checking for
      // reg.waiting keeps the banner off a fresh load.
      function watch(worker) {
        worker.addEventListener("statechange", function () {
          if (worker.state === "installed" && reg.waiting === worker && navigator.serviceWorker.controller) $("banner").hidden = false;
        });
      }
      if (reg.waiting && navigator.serviceWorker.controller) $("banner").hidden = false;
      reg.addEventListener("updatefound", function () { if (reg.installing) watch(reg.installing); });
      $("reload").addEventListener("click", function () {
        var w = reg.waiting;
        if (w) w.postMessage("skipWaiting");
        setTimeout(function () { location.reload(); }, 300);
      });
    }).catch(function () {});
  }

  render();
})();
