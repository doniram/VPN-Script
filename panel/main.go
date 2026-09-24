package main

import (
	"embed"
	"encoding/json"
	"io/fs"
	"log"
	"net/http"
	"os"
	"regexp"
	"strconv"
	"sync"
	"time"
)

//go:embed web
var webFS embed.FS

var allowedServices = map[string]bool{
	"ssh": true, "ovpn": true, "wg": true, "xray": true,
	"ss": true, "sstp": true, "l2tp": true, "pptp": true,
}

var nameRe = regexp.MustCompile(`^[a-zA-Z0-9_-]{1,32}$`)

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------
func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func apiError(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, map[string]any{"ok": false, "error": msg})
}

// session auth -------------------------------------------------------------
func requireAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		c, err := r.Cookie("svps_session")
		if err != nil {
			apiError(w, http.StatusUnauthorized, "belum login")
			return
		}
		if _, ok := verifySession(c.Value); !ok {
			apiError(w, http.StatusUnauthorized, "sesi tidak valid")
			return
		}
		// CSRF: mutating requests must carry our custom header (cookie is SameSite=Strict).
		if r.Method != http.MethodGet {
			if r.Header.Get("X-Requested-With") != "scriptvps-panel" {
				apiError(w, http.StatusForbidden, "header CSRF tidak ada")
				return
			}
		}
		next(w, r)
	}
}

func validService(s string) bool { return allowedServices[s] }

// ---------------------------------------------------------------------------
// login rate limiting (simple in-memory)
// ---------------------------------------------------------------------------
var (
	loginMu     sync.Mutex
	loginFails  = map[string]int{}
	loginLocked = map[string]time.Time{}
)

func loginBlocked(ip string) bool {
	loginMu.Lock()
	defer loginMu.Unlock()
	if t, ok := loginLocked[ip]; ok {
		if time.Now().Before(t) {
			return true
		}
		delete(loginLocked, ip)
		delete(loginFails, ip)
	}
	return false
}

func loginFail(ip string) {
	loginMu.Lock()
	defer loginMu.Unlock()
	loginFails[ip]++
	if loginFails[ip] >= 5 {
		loginLocked[ip] = time.Now().Add(5 * time.Minute)
		loginFails[ip] = 0
	}
}

func loginOK(ip string) {
	loginMu.Lock()
	defer loginMu.Unlock()
	delete(loginFails, ip)
	delete(loginLocked, ip)
}

// ---------------------------------------------------------------------------
// handlers
// ---------------------------------------------------------------------------
func handleLogin(w http.ResponseWriter, r *http.Request) {
	ip := r.RemoteAddr
	if loginBlocked(ip) {
		apiError(w, http.StatusTooManyRequests, "terlalu banyak percobaan, coba lagi nanti")
		return
	}
	var body struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		apiError(w, http.StatusBadRequest, "body tidak valid")
		return
	}
	if !verifyLogin(body.Username, body.Password) {
		loginFail(ip)
		apiError(w, http.StatusUnauthorized, "username/password salah")
		return
	}
	loginOK(ip)
	c := &http.Cookie{
		Name:     "svps_session",
		Value:    signSession(body.Username),
		Path:     "/",
		HttpOnly: true,
		SameSite: http.SameSiteStrictMode,
		Secure:   r.TLS != nil || r.Header.Get("X-Forwarded-Proto") == "https",
		MaxAge:   int((12 * time.Hour).Seconds()),
	}
	http.SetCookie(w, c)
	writeJSON(w, 200, map[string]any{"ok": true, "user": body.Username})
}

func handleLogout(w http.ResponseWriter, _ *http.Request) {
	http.SetCookie(w, &http.Cookie{Name: "svps_session", Value: "", Path: "/", MaxAge: -1, HttpOnly: true})
	writeJSON(w, 200, map[string]any{"ok": true})
}

func handleSession(w http.ResponseWriter, r *http.Request) {
	c, err := r.Cookie("svps_session")
	if err != nil {
		writeJSON(w, 200, map[string]any{"authenticated": false})
		return
	}
	if u, ok := verifySession(c.Value); ok {
		writeJSON(w, 200, map[string]any{"authenticated": true, "user": u})
		return
	}
	writeJSON(w, 200, map[string]any{"authenticated": false})
}

func runAndRespond(w http.ResponseWriter, args ...string) {
	out, err := runCLI(args...)
	if err != nil {
		writeJSON(w, 200, map[string]any{"ok": false, "output": out, "error": err.Error()})
		return
	}
	writeJSON(w, 200, map[string]any{"ok": true, "output": out})
}

func handleStatus(w http.ResponseWriter, _ *http.Request) {
	out, err := runCLI("status", "--json")
	if err != nil {
		writeJSON(w, 200, map[string]any{"ok": false, "output": out, "error": err.Error()})
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_, _ = w.Write([]byte(out))
}

func handleListUsers(w http.ResponseWriter, r *http.Request) {
	svc := r.PathValue("svc")
	if !validService(svc) {
		apiError(w, http.StatusBadRequest, "service tidak valid")
		return
	}
	out, err := runCLI("list", svc, "--json")
	if err != nil {
		writeJSON(w, 200, map[string]any{"ok": false, "output": out, "error": err.Error()})
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_, _ = w.Write([]byte(out))
}

func handleAddUser(w http.ResponseWriter, r *http.Request) {
	svc := r.PathValue("svc")
	if !validService(svc) {
		apiError(w, http.StatusBadRequest, "service tidak valid")
		return
	}
	var body struct {
		Name      string `json:"name"`
		Days      int    `json:"days"`
		IPLimit   int    `json:"iplimit"`
		Quota     int    `json:"quota"`
		Protocol  string `json:"protocol"`
		Transport string `json:"transport"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		apiError(w, http.StatusBadRequest, "body tidak valid")
		return
	}
	if !nameRe.MatchString(body.Name) {
		apiError(w, http.StatusBadRequest, "nama tidak valid")
		return
	}
	if body.Days <= 0 {
		body.Days = 30
	}
	args := []string{"add", svc, body.Name, "--days", itoa(body.Days)}
	if body.IPLimit > 0 {
		args = append(args, "--iplimit", itoa(body.IPLimit))
	}
	if body.Quota > 0 {
		args = append(args, "--quota", itoa(body.Quota))
	}
	if body.Protocol != "" {
		args = append(args, "--protocol", body.Protocol)
	}
	if body.Transport != "" {
		args = append(args, "--transport", body.Transport)
	}
	runAndRespond(w, args...)
}

func handleDelUser(w http.ResponseWriter, r *http.Request) {
	svc, name := r.PathValue("svc"), r.PathValue("name")
	if !validService(svc) || !nameRe.MatchString(name) {
		apiError(w, http.StatusBadRequest, "parameter tidak valid")
		return
	}
	runAndRespond(w, "del", svc, name)
}

func handleRenewUser(w http.ResponseWriter, r *http.Request) {
	svc, name := r.PathValue("svc"), r.PathValue("name")
	if !validService(svc) || !nameRe.MatchString(name) {
		apiError(w, http.StatusBadRequest, "parameter tidak valid")
		return
	}
	var body struct {
		Days int `json:"days"`
	}
	_ = json.NewDecoder(r.Body).Decode(&body)
	if body.Days <= 0 {
		body.Days = 30
	}
	runAndRespond(w, "renew", svc, name, "--days", itoa(body.Days))
}

func handleLicense(w http.ResponseWriter, _ *http.Request) {
	out, err := runCLI("license", "info")
	if err != nil {
		writeJSON(w, 200, map[string]any{"ok": false, "output": out, "error": err.Error()})
		return
	}
	writeJSON(w, 200, map[string]any{"ok": true, "output": out})
}

func handleQuota(w http.ResponseWriter, _ *http.Request) {
	out, err := runCLI("quota", "report")
	if err != nil {
		writeJSON(w, 200, map[string]any{"ok": false, "output": out, "error": err.Error()})
		return
	}
	writeJSON(w, 200, map[string]any{"ok": true, "output": out})
}

func handleLimitSpeed(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodGet {
		runAndRespond(w, "limit-speed", "status")
		return
	}
	var body struct {
		Kbps string `json:"kbps"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		apiError(w, http.StatusBadRequest, "body tidak valid")
		return
	}
	if body.Kbps == "" {
		body.Kbps = "0"
	}
	if body.Kbps != "off" && !regexp.MustCompile(`^[0-9]+$`).MatchString(body.Kbps) {
		apiError(w, http.StatusBadRequest, "kbps tidak valid")
		return
	}
	runAndRespond(w, "limit-speed", body.Kbps)
}

func handleBanner(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Text string `json:"text"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		apiError(w, http.StatusBadRequest, "body tidak valid")
		return
	}
	runAndRespond(w, "banner", body.Text)
}

func itoa(n int) string { return strconv.Itoa(n) }

// ---------------------------------------------------------------------------
func newMux() *http.ServeMux {
	mux := http.NewServeMux()

	mux.HandleFunc("POST /api/login", handleLogin)
	mux.HandleFunc("POST /api/logout", handleLogout)
	mux.HandleFunc("GET /api/session", handleSession)

	mux.HandleFunc("GET /api/status", requireAuth(handleStatus))
	mux.HandleFunc("GET /api/services/{svc}/users", requireAuth(handleListUsers))
	mux.HandleFunc("POST /api/services/{svc}/users", requireAuth(handleAddUser))
	mux.HandleFunc("DELETE /api/services/{svc}/users/{name}", requireAuth(handleDelUser))
	mux.HandleFunc("POST /api/services/{svc}/users/{name}/renew", requireAuth(handleRenewUser))
	mux.HandleFunc("GET /api/license", requireAuth(handleLicense))
	mux.HandleFunc("GET /api/quota", requireAuth(handleQuota))
	mux.HandleFunc("GET /api/limit-speed", requireAuth(handleLimitSpeed))
	mux.HandleFunc("POST /api/limit-speed", requireAuth(handleLimitSpeed))
	mux.HandleFunc("POST /api/banner", requireAuth(handleBanner))

	sub, err := fs.Sub(webFS, "web")
	if err != nil {
		log.Fatalf("web assets: %v", err)
	}
	mux.Handle("/", http.FileServerFS(sub))
	return mux
}

func main() {
	if len(os.Args) > 1 && os.Args[1] == "hashpw" {
		if len(os.Args) < 3 {
			log.Fatal("pemakaian: scriptvps-panel hashpw <password>")
		}
		h, err := hashPassword(os.Args[2])
		if err != nil {
			log.Fatal(err)
		}
		os.Stdout.WriteString(h + "\n")
		return
	}

	addr := os.Getenv("SVPS_PANEL_ADDR")
	if addr == "" {
		addr = "127.0.0.1:8080"
	}
	srv := &http.Server{
		Addr:              addr,
		Handler:           newMux(),
		ReadHeaderTimeout: 10 * time.Second,
	}
	log.Printf("scriptvps panel listening on %s", addr)
	if err := srv.ListenAndServe(); err != nil {
		log.Fatal(err)
	}
}
