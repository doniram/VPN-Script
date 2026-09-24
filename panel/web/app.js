const SERVICES = [
  ["ssh", "SSH"], ["ovpn", "OpenVPN"], ["wg", "WireGuard"], ["xray", "Xray"],
  ["ss", "Shadowsocks"], ["sstp", "SSTP"], ["l2tp", "L2TP"], ["pptp", "PPTP"],
];
let current = "ssh";

const $ = (id) => document.getElementById(id);

async function api(method, path, body) {
  const res = await fetch(path, {
    method,
    headers: { "Content-Type": "application/json", "X-Requested-With": "scriptvps-panel" },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  try { return JSON.parse(text); } catch { return { ok: false, output: text }; }
}

function show(id, on) { $(id).classList.toggle("hidden", !on); }

async function boot() {
  const s = await api("GET", "/api/session");
  if (s.authenticated) { enter(s.user); } else { show("login", true); show("app", false); }
}

function enter(user) {
  show("login", false);
  show("app", true);
  $("hostinfo").textContent = "login: " + user;
  renderTabs();
  loadAll();
}

function renderTabs() {
  const nav = $("tabs");
  nav.innerHTML = "";
  SERVICES.forEach(([svc, label]) => {
    const b = document.createElement("button");
    b.textContent = label;
    b.className = svc === current ? "tab active" : "tab";
    b.onclick = () => { current = svc; renderTabs(); loadUsers(); toggleXray(); };
    nav.appendChild(b);
  });
}

function toggleXray() {
  const isX = current === "xray";
  $("uproto").style.display = isX ? "" : "none";
  $("utrans").style.display = isX ? "" : "none";
}

async function loadUsers() {
  const rows = await api("GET", `/api/services/${current}/users`);
  const tb = document.querySelector("#users tbody");
  tb.innerHTML = "";
  if (!Array.isArray(rows)) { $("output").textContent = rows.output || "gagal memuat"; return; }
  rows.forEach((u) => {
    const tr = document.createElement("tr");
    tr.innerHTML = `<td>${esc(u.name)}</td><td>${esc(u.created)}</td><td>${esc(u.expires)}</td>` +
      `<td>${u.iplimit}</td><td>${u.quota_gb}</td><td class="muted">${esc(u.meta)}</td>`;
    const td = document.createElement("td");
    const rn = document.createElement("button");
    rn.textContent = "Renew"; rn.className = "ghost";
    rn.onclick = async () => { const r = await api("POST", `/api/services/${current}/users/${u.name}/renew`, { days: 30 }); out(r); loadUsers(); };
    const dl = document.createElement("button");
    dl.textContent = "Hapus"; dl.className = "danger";
    dl.onclick = async () => { if (!confirm("Hapus " + u.name + "?")) return; const r = await api("DELETE", `/api/services/${current}/users/${u.name}`); out(r); loadUsers(); };
    td.appendChild(rn); td.appendChild(dl);
    tr.appendChild(td);
    tb.appendChild(tr);
  });
}

function out(r) { $("output").textContent = r.output || r.error || JSON.stringify(r); }

async function addUser() {
  const body = {
    name: $("uname").value.trim(),
    days: parseInt($("udays").value || "30", 10),
    iplimit: parseInt($("uiplimit").value || "0", 10),
    quota: parseInt($("uquota").value || "0", 10),
  };
  if (current === "xray") { body.protocol = $("uproto").value; body.transport = $("utrans").value; }
  if (!body.name) { $("output").textContent = "nama wajib diisi"; return; }
  const r = await api("POST", `/api/services/${current}/users`, body);
  out(r);
  $("uname").value = "";
  loadUsers();
}

async function loadAll() {
  const st = await api("GET", "/api/status");
  $("status").textContent = typeof st === "object" && st.services
    ? st.services.map((s) => `${s.service}: ${s.state} (${s.accounts})`).join("\n")
    : (st.output || "");
  const lic = await api("GET", "/api/license");
  $("license").textContent = lic.output || "";
  const q = await api("GET", "/api/quota");
  $("quota").textContent = q.output || "";
  loadUsers();
}

function esc(s) { return String(s == null ? "" : s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c])); }

// events
$("loginBtn").onclick = async () => {
  const r = await api("POST", "/api/login", { username: $("u").value.trim(), password: $("p").value });
  if (r.ok) { enter(r.user); } else { $("loginMsg").textContent = r.error || "gagal login"; }
};
$("logoutBtn").onclick = async () => { await api("POST", "/api/logout"); location.reload(); };
$("addBtn").onclick = addUser;
$("limitBtn").onclick = async () => { const r = await api("POST", "/api/limit-speed", { kbps: $("kbps").value.trim() }); out(r); };
$("bannerBtn").onclick = async () => { const r = await api("POST", "/api/banner", { text: $("banner").value }); out(r); };
$("p").addEventListener("keydown", (e) => { if (e.key === "Enter") $("loginBtn").click(); });

boot();
toggleXray();
