// Massage Buddy shared code (customer, therapist and admin apps)
(function () {
  "use strict";
  const C = self.MB_CONFIG || {};
  const MB = (window.MB = {});
  MB.version = C.appVersion || "1.04";
  MB.configured = !!(C.supabaseUrl && !/YOUR-PROJECT/.test(C.supabaseUrl) && C.supabaseAnonKey && !/YOUR-ANON/.test(C.supabaseAnonKey));
  MB.sb = MB.configured ? window.supabase.createClient(C.supabaseUrl, C.supabaseAnonKey, {
    auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true }
  }) : null;

  MB.AREAS = ["Caloocan", "Las Piñas", "Makati", "Malabon", "Mandaluyong", "Manila", "Marikina", "Muntinlupa", "Navotas",
    "Parañaque", "Pasay", "Pasig", "Pateros", "Quezon City", "San Juan", "Taguig", "Valenzuela"];
  MB.DAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
  MB.STATUS = {
    pending: "Waiting for therapist", confirmed: "Confirmed", on_the_way: "Therapist on the way",
    in_progress: "In progress", completed: "Completed", cancelled: "Cancelled", declined: "Not accepted"
  };
  MB.ACTIVE = ["pending", "confirmed", "on_the_way", "in_progress"];
  MB.PLACEHOLDER = "data:image/svg+xml;utf8," + encodeURIComponent(
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><rect width="100" height="100" fill="#E3F2F1"/><circle cx="50" cy="38" r="18" fill="#9CCFCB"/><path d="M18 92c4-20 18-30 32-30s28 10 32 30" fill="#9CCFCB"/></svg>');

  // ---------- app mode: one app, two modes (customer / therapist) ----------
  MB.getMode = () => { try { return localStorage.getItem("mb_mode") || ""; } catch (e) { return ""; } };
  MB.setMode = (m) => { try { localStorage.setItem("mb_mode", m); } catch (e) {} };
  MB.switchTo = (m, hash) => {
    MB.setMode(m);
    location.href = (m === "therapist" ? "therapist.html" : "./") + (hash ? "#" + hash : "");
  };

  // ---------- small helpers ----------
  MB.$ = (s, el) => (el || document).querySelector(s);
  MB.$$ = (s, el) => Array.from((el || document).querySelectorAll(s));
  MB.esc = (v) => String(v == null ? "" : v).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  MB.peso = (n) => "₱" + Number(n || 0).toLocaleString("en-PH", { maximumFractionDigits: 0 });
  const TZ = "Asia/Manila";
  MB.fmtWhen = (iso) => new Date(iso).toLocaleString("en-PH", { timeZone: TZ, weekday: "short", day: "numeric", month: "short", hour: "numeric", minute: "2-digit" });
  MB.fmtTime = (iso) => new Date(iso).toLocaleTimeString("en-PH", { timeZone: TZ, hour: "numeric", minute: "2-digit" });
  MB.fmtDate = (iso) => new Date(iso).toLocaleDateString("en-PH", { timeZone: TZ, day: "numeric", month: "short", year: "numeric" });
  MB.ago = (iso) => {
    const s = (Date.now() - new Date(iso).getTime()) / 1000;
    if (s < 60) return "just now"; if (s < 3600) return Math.floor(s / 60) + " min ago";
    if (s < 86400) return Math.floor(s / 3600) + " h ago"; return MB.fmtDate(iso);
  };
  // "YYYY-MM-DD" for today + n days, in Manila time
  MB.manilaDate = (n) => {
    const d = new Date(Date.now() + (n || 0) * 86400000);
    return d.toLocaleDateString("en-CA", { timeZone: TZ });
  };
  MB.dateParts = (ymd) => {
    const d = new Date(ymd + "T12:00:00+08:00");
    return { dow: d.toLocaleDateString("en-PH", { timeZone: TZ, weekday: "short" }), day: d.getUTCDate(),
      mon: d.toLocaleDateString("en-PH", { timeZone: TZ, month: "short" }) };
  };
  MB.stars = (r) => { const n = Math.round(Number(r || 0)); return "★★★★★".slice(0, n) + "☆☆☆☆☆".slice(0, 5 - n); };
  MB.badge = (st, label) => `<span class="badge ${MB.esc(st)}">${MB.esc(label || MB.STATUS[st] || st)}</span>`;
  MB.time12 = (hhmm) => { const [h, m] = hhmm.split(":").map(Number); return ((h % 12) || 12) + (m ? ":" + String(m).padStart(2, "0") : "") + (h < 12 ? " AM" : " PM"); };
  MB.phPhone = (v) => { // to +63XXXXXXXXXX
    let d = String(v || "").replace(/\D/g, "");
    if (d.startsWith("0")) d = "63" + d.slice(1);
    else if (d.length === 10 && d.startsWith("9")) d = "63" + d;
    return d ? "+" + d : "";
  };
  MB.errMsg = (e) => {
    const m = (e && (e.message || e.error_description || e.msg)) || String(e || "Something went wrong.");
    if (/Failed to fetch|NetworkError|Load failed/i.test(m)) return "No internet connection. Please try again.";
    if (/Invalid login credentials/i.test(m)) return "Wrong email or password.";
    if (/Email not confirmed/i.test(m)) return "Please confirm your email first (check your inbox).";
    if (/User already registered/i.test(m)) return "This email already has an account. Please log in.";
    return m;
  };

  // Password box with a show/hide eye button
  MB.eyeOpen = '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/></svg>';
  MB.eyeShut = '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 3l18 18"/><path d="M10.6 5.1A10.4 10.4 0 0 1 12 5c6.5 0 10 7 10 7a17 17 0 0 1-3.2 4.2M6.6 6.6C3.8 8.4 2 12 2 12s3.5 7 10 7c1.9 0 3.6-.6 5-1.4"/><path d="M9.9 9.9a3 3 0 0 0 4.2 4.2"/></svg>';
  MB.pwInput = (attrs) => `<div class="pw-wrap"><input type="password" ${attrs}><button type="button" class="pw-eye" aria-label="Show password">${MB.eyeOpen}</button></div>`;
  document.addEventListener("click", (e) => {
    const b = e.target.closest && e.target.closest(".pw-eye"); if (!b) return;
    e.preventDefault();
    const i = b.parentNode.querySelector("input"), show = i.type === "password";
    i.type = show ? "text" : "password";
    b.innerHTML = show ? MB.eyeShut : MB.eyeOpen;
    b.setAttribute("aria-label", show ? "Hide password" : "Show password");
  });

  let toastTimer;
  MB.toast = (msg, isErr) => {
    let t = MB.$("#mb-toast");
    if (!t) { t = document.createElement("div"); t.id = "mb-toast"; document.body.appendChild(t); }
    t.className = "toast" + (isErr ? " err" : ""); t.textContent = msg; t.style.display = "block";
    clearTimeout(toastTimer); toastTimer = setTimeout(() => (t.style.display = "none"), isErr ? 5000 : 2800);
  };

  // Call a database function. Shows the error and rethrows.
  MB.rpc = async (fn, args, opts) => {
    if (!MB.sb) throw new Error("App is not connected to the database yet (see config.js).");
    const { data, error } = await MB.sb.rpc(fn, args || {});
    if (error) { if (!(opts && opts.quiet)) MB.toast(MB.errMsg(error), true); throw error; }
    return data;
  };

  // Disable a button while an async job runs
  MB.busy = async (btn, job) => {
    if (btn) { if (btn.disabled) return; btn.disabled = true; btn.dataset.t = btn.innerHTML; btn.innerHTML = "Please wait…"; }
    try { return await job(); }
    finally { if (btn) { btn.disabled = false; btn.innerHTML = btn.dataset.t; } }
  };

  // ---------- modal ----------
  MB.modal = (title, html, onClose) => {
    MB.closeModal();
    const bg = document.createElement("div");
    bg.className = "modal-bg"; bg.id = "mb-modal";
    bg.innerHTML = `<div class="modal" role="dialog" aria-modal="true"><div class="modal-head"><h2>${MB.esc(title)}</h2><button class="x" aria-label="Close">×</button></div><div class="modal-body">${html}</div></div>`;
    bg.addEventListener("click", (e) => { if (e.target === bg || e.target.classList.contains("x")) { MB.closeModal(); onClose && onClose(); } });
    document.body.appendChild(bg);
    return MB.$(".modal-body", bg);
  };
  MB.closeModal = () => { const m = MB.$("#mb-modal"); if (m) m.remove(); };
  MB.confirm = (title, text, okLabel, danger) => new Promise((res) => {
    const body = MB.modal(title, `<p>${MB.esc(text)}</p><div class="btn-row"><button class="btn ghost" data-a="no">Back</button><button class="btn ${danger ? "danger" : ""}" data-a="yes">${MB.esc(okLabel || "Yes")}</button></div>`, () => res(false));
    body.addEventListener("click", (e) => { const a = e.target.dataset.a; if (a) { MB.closeModal(); res(a === "yes"); } });
  });
  MB.prompt = (title, text, placeholder, okLabel) => new Promise((res) => {
    const body = MB.modal(title, `<p>${MB.esc(text)}</p><textarea id="mb-pr" placeholder="${MB.esc(placeholder || "")}"></textarea><div class="btn-row" style="margin-top:12px"><button class="btn ghost" data-a="no">Back</button><button class="btn" data-a="yes">${MB.esc(okLabel || "OK")}</button></div>`, () => res(null));
    body.addEventListener("click", (e) => { const a = e.target.dataset.a; if (a) { const v = MB.$("#mb-pr").value.trim(); MB.closeModal(); res(a === "yes" ? v : null); } });
  });

  // ---------- auth ----------
  MB.session = null;
  MB.getSession = async () => {
    if (!MB.sb) return null;
    const { data } = await MB.sb.auth.getSession();
    MB.session = data.session; return MB.session;
  };
  MB.logout = async () => {
    try { if (MB._pushToken) await MB.rpc("mb_delete_push_token", { p_token: MB._pushToken }, { quiet: true }); } catch (e) {}
    await MB.sb.auth.signOut(); location.hash = ""; location.reload();
  };

  // Renders the login / sign-up box into `el`. onDone() runs after a successful login.
  MB.renderAuth = (el, opts) => {
    opts = opts || {};
    const redirect = location.href.split("#")[0];
    let mode = "login"; // login | signup | phone | forgot
    const draw = () => {
      el.innerHTML = `
        ${opts.title ? `<h2 class="center">${MB.esc(opts.title)}</h2>` : ""}
        ${opts.subtitle ? `<p class="center muted small">${MB.esc(opts.subtitle)}</p>` : ""}
        <button class="btn block google-btn" id="a-google" type="button">
          <svg width="18" height="18" viewBox="0 0 48 48"><path fill="#FFC107" d="M43.6 20.5H42V20H24v8h11.3C33.7 32.7 29.2 36 24 36c-6.6 0-12-5.4-12-12s5.4-12 12-12c3.1 0 5.8 1.2 7.9 3l5.7-5.7C34 6.1 29.3 4 24 4 12.9 4 4 12.9 4 24s8.9 20 20 20 20-8.9 20-20c0-1.3-.1-2.4-.4-3.5z"/><path fill="#FF3D00" d="m6.3 14.7 6.6 4.8C14.7 15.1 19 12 24 12c3.1 0 5.8 1.2 7.9 3l5.7-5.7C34 6.1 29.3 4 24 4 16.3 4 9.7 8.3 6.3 14.7z"/><path fill="#4CAF50" d="M24 44c5.2 0 9.9-2 13.4-5.2l-6.2-5.2C29.2 35.1 26.7 36 24 36c-5.2 0-9.6-3.3-11.3-8l-6.5 5C9.5 39.6 16.2 44 24 44z"/><path fill="#1976D2" d="M43.6 20.5H42V20H24v8h11.3c-.8 2.2-2.2 4.2-4.1 5.6l6.2 5.2C37 39.2 44 34 44 24c0-1.3-.1-2.4-.4-3.5z"/></svg>
          Continue with Google</button>
        <div class="tabs" style="margin-top:14px">
          <button type="button" data-m="login" class="${mode !== "phone" ? "on" : ""}">Email</button>
          <button type="button" data-m="phone" class="${mode === "phone" ? "on" : ""}">Phone</button>
        </div>
        <form id="a-form" autocomplete="on"></form>`;
      const f = MB.$("#a-form", el);
      if (mode === "login" || mode === "signup") {
        f.innerHTML = `
          ${mode === "signup" ? `<label>Full name</label><input name="name" autocomplete="name" required minlength="2" placeholder="Juan Dela Cruz">
          <label>Mobile number</label><input name="phone" type="tel" autocomplete="tel" required placeholder="0917 123 4567">` : ""}
          <label>Email</label><input name="email" type="email" autocomplete="email" required placeholder="you@email.com">
          <label>Password</label>${MB.pwInput(`name="password" autocomplete="${mode === "signup" ? "new-password" : "current-password"}" required minlength="6" placeholder="At least 6 characters"`)}
          ${mode === "signup" ? `<p class="small muted" style="margin:10px 0 0">By creating an account you agree to our <a href="terms.html" target="_blank">Terms</a>, <a href="privacy.html" target="_blank">Privacy Policy</a> and <a href="refund.html" target="_blank">Refund &amp; Cancellation Policy</a>.</p>` : ""}
          <button class="btn block" style="margin-top:16px">${mode === "signup" ? "Create account" : "Log in"}</button>
          <p class="center small">${mode === "signup"
            ? `Already have an account? <a href="#" data-m="login">Log in</a>`
            : `New here? <a href="#" data-m="signup">Create an account</a> · <a href="#" data-m="forgot">Forgot password?</a>`}</p>`;
      } else if (mode === "forgot") {
        f.innerHTML = `<label>Email</label><input name="email" type="email" required placeholder="you@email.com">
          <button class="btn block" style="margin-top:16px">Send reset link</button>
          <p class="center small"><a href="#" data-m="login">Back to log in</a></p>`;
      } else {
        f.innerHTML = `<label>Mobile number</label><input name="phone" type="tel" required placeholder="0917 123 4567">
          <div id="a-otp" class="hide"><label>6-digit code sent by SMS</label><input name="code" inputmode="numeric" maxlength="6" placeholder="123456"></div>
          <button class="btn block" style="margin-top:16px" id="a-phone-btn">Send code</button>`;
      }
    };
    draw();
    el.addEventListener("click", async (e) => {
      const m = e.target.dataset && e.target.dataset.m;
      if (m) { e.preventDefault(); mode = m; draw(); return; }
      if (e.target.closest("#a-google")) {
        const { error } = await MB.sb.auth.signInWithOAuth({ provider: "google", options: { redirectTo: redirect } });
        if (error) MB.toast(MB.errMsg(error), true);
      }
    });
    let otpSent = false;
    el.addEventListener("submit", async (e) => {
      e.preventDefault();
      const f = e.target, btn = MB.$("button", f) && f.querySelector("button.btn");
      const v = (n) => (f.elements[n] ? f.elements[n].value.trim() : "");
      await MB.busy(btn, async () => {
        try {
          if (mode === "login") {
            const { error } = await MB.sb.auth.signInWithPassword({ email: v("email"), password: f.elements.password.value });
            if (error) throw error;
          } else if (mode === "signup") {
            if (v("phone").replace(/\D/g, "").length < 10) throw new Error("Please enter a valid mobile number.");
            const { data, error } = await MB.sb.auth.signUp({ email: v("email"), password: f.elements.password.value,
              options: { data: { full_name: v("name"), phone: v("phone") }, emailRedirectTo: redirect } });
            if (error) throw error;
            if (!data.session) { el.innerHTML = `<div class="empty"><div class="big">📧</div><h2>Check your email</h2><p>We sent a confirmation link to <b>${MB.esc(v("email"))}</b>. Tap it, then come back here and log in.</p></div>`; return; }
          } else if (mode === "forgot") {
            const { error } = await MB.sb.auth.resetPasswordForEmail(v("email"), { redirectTo: redirect });
            if (error) throw error;
            MB.toast("Reset link sent. Please check your email."); mode = "login"; draw(); return;
          } else if (mode === "phone") {
            const phone = MB.phPhone(v("phone"));
            if (phone.length < 12) throw new Error("Please enter a valid mobile number.");
            if (!otpSent) {
              const { error } = await MB.sb.auth.signInWithOtp({ phone });
              if (error) throw error;
              otpSent = true; MB.$("#a-otp", el).classList.remove("hide"); btn.dataset.t = "Verify code"; MB.toast("Code sent by SMS.");
              return;
            }
            const { error } = await MB.sb.auth.verifyOtp({ phone, token: v("code"), type: "sms" });
            if (error) throw error;
          }
          await MB.getSession();
          opts.onDone && opts.onDone();
        } catch (err) { MB.toast(MB.errMsg(err), true); }
      });
    });
  };

  MB.loginModal = (title, subtitle) => new Promise((res) => {
    const body = MB.modal("Log in", "", () => res(false));
    MB.renderAuth(body, { title, subtitle, onDone: () => { MB.closeModal(); res(true); } });
  });

  // Show "set a new password" after the reset link is opened
  if (MB.sb) MB.sb.auth.onAuthStateChange((ev, session) => {
    MB.session = session;
    if (ev === "PASSWORD_RECOVERY") {
      setTimeout(() => {
        const body = MB.modal("New password", `<label>New password</label>${MB.pwInput('id="np" minlength="6" autocomplete="new-password"')}<button class="btn block" id="np-b" style="margin-top:14px">Save password</button>`);
        MB.$("#np-b", body).onclick = (e) => MB.busy(e.target, async () => {
          const { error } = await MB.sb.auth.updateUser({ password: MB.$("#np").value });
          if (error) return MB.toast(MB.errMsg(error), true);
          MB.closeModal(); MB.toast("Password saved.");
        });
      }, 300);
    }
  });

  // ---------- photos ----------
  // Shrinks a photo on the phone before upload (saves data), returns a Blob
  MB.shrinkImage = (file, maxSide) => new Promise((res, rej) => {
    if (!file || !/^image\//.test(file.type)) return rej(new Error("Please choose a photo."));
    const img = new Image(), url = URL.createObjectURL(file);
    img.onload = () => {
      const s = Math.min(1, (maxSide || 1280) / Math.max(img.width, img.height));
      const c = document.createElement("canvas"); c.width = Math.round(img.width * s); c.height = Math.round(img.height * s);
      c.getContext("2d").drawImage(img, 0, 0, c.width, c.height); URL.revokeObjectURL(url);
      c.toBlob((b) => (b ? res(b) : rej(new Error("Could not read photo."))), "image/jpeg", 0.85);
    };
    img.onerror = () => rej(new Error("Could not read photo."));
    img.src = url;
  });
  // bucket "mb-photos" -> returns public URL; bucket "mb-docs" -> returns storage path
  MB.upload = async (bucket, file, name) => {
    const blob = await MB.shrinkImage(file, bucket === "mb-docs" ? 1600 : 1080);
    const uid = MB.session.user.id;
    const path = `${uid}/${name}-${Date.now()}.jpg`;
    const { error } = await MB.sb.storage.from(bucket).upload(path, blob, { contentType: "image/jpeg", upsert: true });
    if (error) throw error;
    if (bucket === "mb-photos") return MB.sb.storage.from(bucket).getPublicUrl(path).data.publicUrl;
    return path;
  };

  // ---------- notifications (in-app bell + phone push via Firebase) ----------
  MB.openNotifications = async (onChange) => {
    const body = MB.modal("Notifications", `<div class="spinner"></div>`);
    try {
      const d = await MB.rpc("mb_my_notifications");
      body.innerHTML = (MB.pushSupported() && Notification.permission !== "granted"
        ? `<div class="banner info"><b>Get alerts on your phone</b><br>Know right away about bookings.<div style="margin-top:8px"><button class="btn sm" id="n-push">Turn on notifications</button></div></div>` : "")
        + (d.items.length ? d.items.map((n) => `
          <div class="card" style="padding:12px;${n.read ? "" : "border-left:4px solid var(--brand)"}" data-link="${MB.esc(n.link)}">
            <div class="row"><b class="grow">${MB.esc(n.title)}</b><span class="small muted">${MB.ago(n.created_at)}</span></div>
            <div class="small">${MB.esc(n.body)}</div></div>`).join("")
          : `<div class="empty"><div class="big">🔔</div>No notifications yet.</div>`);
      const pb = MB.$("#n-push", body); if (pb) pb.onclick = (e) => MB.busy(e.target, () => MB.enablePush(true));
      body.addEventListener("click", (e) => {
        const c = e.target.closest("[data-link]"); if (!c || !c.dataset.link) return;
        MB.closeModal();
        const [pg, h] = c.dataset.link.split("#");
        const here = location.pathname.split("/").pop() || "index.html";
        const target = pg || here;
        if (target !== here && !(target === "index.html" && here === "")) {
          if (target === "therapist.html") MB.switchTo("therapist", h); else if (target === "index.html") MB.switchTo("customer", h); else location.href = c.dataset.link;
        } else if (h != null) location.hash = h;
      });
      if (d.unread) { await MB.rpc("mb_mark_notifications_read", {}, { quiet: true }); onChange && onChange(0); }
    } catch (e) { body.innerHTML = `<div class="empty">Could not load notifications.</div>`; }
  };

  MB.pushSupported = () => !!(C.firebase && "Notification" in window && "serviceWorker" in navigator && "PushManager" in window);
  MB._swReg = null;
  MB.registerSW = async () => {
    if (!("serviceWorker" in navigator)) return null;
    try { MB._swReg = await navigator.serviceWorker.register("sw.js", { scope: "./" }); } catch (e) { MB._swReg = null; }
    return MB._swReg;
  };
  const loadScript = (src) => new Promise((res, rej) => { const s = document.createElement("script"); s.src = src; s.onload = res; s.onerror = rej; document.head.appendChild(s); });
  // ask=true: show the phone's permission popup. ask=false: only refresh the token if already allowed.
  MB.enablePush = async (ask) => {
    if (!MB.pushSupported() || !MB.session) return false;
    try {
      if (Notification.permission === "denied") { if (ask) MB.toast("Notifications are blocked. Allow them in your browser settings.", true); return false; }
      if (Notification.permission !== "granted") {
        if (!ask) return false;
        if ((await Notification.requestPermission()) !== "granted") return false;
      }
      const reg = MB._swReg || (await MB.registerSW()) || (await navigator.serviceWorker.ready);
      if (!window.firebase || !window.firebase.messaging) {
        await loadScript("https://www.gstatic.com/firebasejs/10.14.1/firebase-app-compat.js");
        await loadScript("https://www.gstatic.com/firebasejs/10.14.1/firebase-messaging-compat.js");
      }
      if (!firebase.apps.length) firebase.initializeApp(C.firebase);
      const messaging = firebase.messaging();
      const token = await messaging.getToken({ vapidKey: C.firebase.vapidKey, serviceWorkerRegistration: reg });
      if (!token) return false;
      MB._pushToken = token;
      await MB.rpc("mb_save_push_token", { p_token: token, p_platform: /Android/i.test(navigator.userAgent) ? "android" : /iPhone|iPad/i.test(navigator.userAgent) ? "ios" : "web" }, { quiet: true });
      // when the app is open, show the alert as a toast instead
      messaging.onMessage((p) => { const n = p.notification || p.data || {}; MB.toast((n.title || "") + (n.body ? ": " + n.body : "")); MB.onPushWhileOpen && MB.onPushWhileOpen(); });
      if (ask) MB.toast("Notifications are on ✅");
      return true;
    } catch (e) { if (ask) MB.toast("Could not turn on notifications: " + MB.errMsg(e), true); return false; }
  };

  MB.setupBanner = () => MB.configured ? "" :
    `<div class="banner bad"><b>Not connected yet.</b> Open <code>massage/config.js</code> and paste your Supabase Project URL and anon key.</div>`;

  // refresh data when the app comes back on screen (no background polling = no battery drain)
  MB.onResume = (fn) => {
    let last = Date.now();
    document.addEventListener("visibilitychange", () => { if (document.visibilityState === "visible" && Date.now() - last > 15000) { last = Date.now(); fn(); } });
  };

  MB.icons = {
    home: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 10.5 12 3l9 7.5V20a1 1 0 0 1-1 1h-5v-6H9v6H4a1 1 0 0 1-1-1z"/></svg>',
    cal: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="5" width="18" height="16" rx="2"/><path d="M16 3v4M8 3v4M3 10h18"/></svg>',
    user: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="8" r="4"/><path d="M4 21c1.5-4 4.5-6 8-6s6.5 2 8 6"/></svg>',
    bell: '<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M6 8a6 6 0 1 1 12 0c0 7 3 9 3 9H3s3-2 3-9"/><path d="M10.3 21a1.9 1.9 0 0 0 3.4 0"/></svg>',
    clock: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/></svg>',
    list: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M8 6h13M8 12h13M8 18h13M3 6h.01M3 12h.01M3 18h.01"/></svg>',
    peso: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M7 21V3h6a5 5 0 0 1 0 10H7M4 7h16M4 10h16"/></svg>',
    leaf: '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="#0E7C7B" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M11 20A7 7 0 0 1 4 13c0-5 4-9 16-9 0 12-4 16-9 16z"/><path d="M4 20c4-4 7-6 11-8"/></svg>',
    gear: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"/></svg>'
  };
})();
