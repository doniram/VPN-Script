const SERVICES = [
  ["ssh", "SSH"], ["ovpn", "OpenVPN"], ["wg", "WireGuard"], ["xray", "Xray"],
  ["ss", "Shadowsocks"], ["sstp", "SSTP"], ["l2tp", "L2TP"], ["pptp", "PPTP"],
];
const $ = (id) => document.getElementById(id);
let users = [], filter = "all", view = "users";

async function api(method, path, body) {
  const res = await fetch(path, {
    method,
    headers: { "Content-Type": "application/json", "X-Requested-With": "scriptvps-panel" },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  try { return JSON.parse(text); } catch { return { ok: false, output: text }; }
}

let toastTimer;
function toast(msg, kind) {
  const t = $("toast");
  t.textContent = msg;
  t.className = "toast " + (kind || "");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => t.classList.add("hidden"), 5000);
}
function esc(s) {
  return String(s == null ? "" : s).replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

// ---------------- auth ----------------
async function boot() {
  const s = await api("GET", "/api/session");
  if (s.authenticated) enter(s.user);
  else { $("login").classList.remove("hidden"); $("app").classList.add("hidden"); }
}
function enter(user) {
  $("login").classList.add("hidden");
  $("app").classList.remove("hidden");
  $("who").textContent = user;
  buildServiceSelect();
  switchView("users");
  refreshAll();
}
$("loginForm").addEventListener("submit", async (e) => {
  e.preventDefault();
  const r = await api("POST", "/api/login", { username: $("u").value.trim(), password: $("p").value });
  if (r.ok) { $("loginMsg").textContent = ""; enter(r.user); }
  else toast(r.error || "gagal login", "err");
});
$("logout").onclick = async () => { await api("POST", "/api/logout"); location.reload(); };

// ---------------- views ----------------
document.querySelectorAll(".nav-btn").forEach((b) => {
  b.onclick = () => switchView(b.dataset.view);
});
function switchView(v) {
  view = v;
  document.querySelectorAll(".nav-btn").forEach((b) => b.classList.toggle("active", b.dataset.view === v));
  $("view-users").classList.toggle("hidden", v !== "users");
  $("view-ports").classList.toggle("hidden", v !== "ports");
  $("view-system").classList.toggle("hidden", v !== "system");
  $("viewTitle").textContent = { users: "Akun", ports: "Port", system: "Sistem" }[v];
  if (v === "ports") loadPorts();
  if (v === "system") loadSystem();
  if (v === "users") renderUsers();
}

async function refreshAll() {
  const st = await api("GET", "/api/status");
  if (st && st.hostname) $("hostline").textContent = `${st.hostname} · ${st.ip || ""} · v${st.version || ""}`;
  const u = await api("GET", "/api/users");
  users = Array.isArray(u) ? u : [];
  renderStats();
  renderChips();
  renderUsers();
}

function renderStats() {
  const online = users.filter((u) => u.status === "online").length;
  const soon = users.filter((u) => u.status === "soon").length;
  const expired = users.filter((u) => u.status === "expired").length;
  const svcs = new Set(users.map((u) => u.service)).size;
  const cards = [
    ["Total akun", users.length],
    ["Online", online],
    ["Segera habis", soon],
    ["Expired", expired],
  ];
  $("stats").innerHTML = cards.map(([k, v]) =>
    `<div class="stat"><div class="k">${k}</div><div class="v">${v}</div></div>`).join("");
  // keep service count in title area
  $("hostline").dataset.svcs = svcs;
}

function renderChips() {
  const present = ["all", ...SERVICES.map((s) => s[0]).filter((s) => users.some((u) => u.service === s))];
  $("chips").innerHTML = present.map((s) => {
    const label = s === "all" ? "Semua" : (SERVICES.find((x) => x[0] === s) || [s, s])[1];
    return `<button class="chip ${filter === s ? "active" : ""}" data-f="${s}">${label}</button>`;
  }).join("");
  $("chips").querySelectorAll(".chip").forEach((c) => c.onclick = () => { filter = c.dataset.f; renderChips(); renderUsers(); });
}

function statusPill(s) {
  const label = { online: "online", active: "aktif", soon: "segera", expired: "expired" }[s] || s;
  return `<span class="pill ${esc(s)}">${esc(label)}</span>`;
}

function renderUsers() {
  const q = ($("search").value || "").toLowerCase();
  const rows = users.filter((u) =>
    (filter === "all" || u.service === filter) &&
    (!q || u.name.toLowerCase().includes(q)));
  const tb = $("table").querySelector("tbody");
  tb.innerHTML = "";
  rows.forEach((u) => {
    const tr = document.createElement("tr");
    tr.innerHTML = `<td>${esc(u.service)}</td><td><b>${esc(u.name)}</b></td>` +
      `<td>${esc(u.expires)}</td><td>${esc(u.days_left)}</td>` +
      `<td>${esc(u.quota_gb) === "0" ? "-" : esc(u.used_gb) + "/" + esc(u.quota_gb) + " GB"}</td>` +
      `<td>${statusPill(u.status)}</td><td class="muted">${esc(u.ip) || "-"}</td>`;
    const td = document.createElement("td");
    const rn = document.createElement("button");
    rn.textContent = "+30h"; rn.className = "ghost mini";
    rn.onclick = () => renew(u);
    const dl = document.createElement("button");
    dl.textContent = "Hapus"; dl.className = "danger mini";
    dl.onclick = () => delUser(u);
    td.append(rn, " ", dl);
    tr.appendChild(td);
    tb.appendChild(tr);
  });
  $("emptyUsers").classList.toggle("hidden", rows.length > 0);
}

async function renew(u) {
  const r = await api("POST", `/api/services/${u.service}/users/${u.name}/renew`, { days: 30 });
  toast(r.output || r.error || "ok", r.ok ? "ok" : "err");
  refreshAll();
}
async function delUser(u) {
  if (!confirm(`Hapus akun ${u.name} (${u.service})?`)) return;
  const r = await api("DELETE", `/api/services/${u.service}/users/${u.name}`);
  toast(r.output || r.error || "ok", r.ok ? "ok" : "err");
  refreshAll();
}

// ---------------- modal: add user ----------------
function buildServiceSelect() {
  $("m_svc").innerHTML = SERVICES.map(([v, l]) => `<option value="${v}">${l}</option>`).join("");
}
$("addOpen").onclick = () => { $("modal").classList.remove("hidden"); $("m_out").classList.add("hidden"); $("m_name").value = ""; };
$("m_cancel").onclick = () => $("modal").classList.add("hidden");
$("m_svc").onchange = () => $("xrayOpts").classList.toggle("hidden", $("m_svc").value !== "xray");
$("m_save").onclick = async () => {
  const body = {
    name: $("m_name").value.trim(),
    days: parseInt($("m_days").value || "30", 10),
    iplimit: parseInt($("m_ipl").value || "0", 10),
    quota: parseInt($("m_quota").value || "0", 10),
  };
  if ($("m_svc").value === "xray") { body.protocol = $("m_proto").value; body.transport = $("m_trans").value; }
  if (!body.name) { toast("nama wajib", "err"); return; }
  const r = await api("POST", `/api/services/${$("m_svc").value}/users`, body);
  $("m_out").textContent = r.output || r.error || "";
  $("m_out").classList.remove("hidden");
  toast(r.ok ? "akun dibuat" : (r.error || "gagal"), r.ok ? "ok" : "err");
  if (r.ok) { refreshAll(); }
};

// ---------------- ports ----------------
async function loadPorts() {
  const list = await api("GET", "/api/ports");
  const tb = $("portTable").querySelector("tbody");
  tb.innerHTML = "";
  if (!Array.isArray(list)) return;
  list.forEach((p) => {
    const tr = document.createElement("tr");
    tr.innerHTML = `<td>${esc(p.service)}</td><td class="muted">${esc(p.key)}</td>`;
    const td = document.createElement("td");
    const inp = document.createElement("input");
    inp.value = p.value; inp.style.width = "90px";
    inp.disabled = !/^[0-9]+$/.test(p.value);
    const btn = document.createElement("button");
    btn.textContent = "Simpan"; btn.className = "primary mini";
    btn.disabled = inp.disabled;
    btn.onclick = async () => {
      const r = await api("POST", "/api/ports", { service: p.service, key: p.key, value: inp.value });
      toast(r.output || r.error || "ok", r.ok ? "ok" : "err");
      loadPorts();
    };
    td.append(inp, " ", btn);
    const td2 = document.createElement("td");
    td2.appendChild(td);
    tr.appendChild(td);
    tb.appendChild(tr);
  });
}

// ---------------- system ----------------
async function loadSystem() {
  const st = await api("GET", "/api/status");
  $("status").textContent = (st.services || []).map((s) => `${s.service}: ${s.state} (${s.accounts})`).join("\n");
  const lic = await api("GET", "/api/license");
  $("license").textContent = lic.output || "";
  const q = await api("GET", "/api/quota");
  $("quota").textContent = q.output || "";
}
$("limitBtn").onclick = async () => {
  const r = await api("POST", "/api/limit-speed", { kbps: $("kbps").value.trim() });
  toast(r.output || r.error || "ok", r.ok ? "ok" : "err");
};
$("bannerBtn").onclick = async () => {
  const r = await api("POST", "/api/banner", { text: $("banner").value });
  toast(r.output || r.error || "ok", r.ok ? "ok" : "err");
};
$("refresh").onclick = () => { refreshAll(); if (view === "ports") loadPorts(); if (view === "system") loadSystem(); };
$("search").oninput = renderUsers;

boot();
$("xrayOpts").classList.add("hidden");
