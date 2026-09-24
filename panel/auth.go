package main

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"golang.org/x/crypto/bcrypt"
)

type creds struct {
	User string
	Hash string
}

func panelConfPath() string {
	if p := os.Getenv("SVPS_PANEL_CONF"); p != "" {
		return p
	}
	return "/etc/scriptvps/panel.conf"
}

func loadCreds() (creds, error) {
	// Environment override (useful for tests / containers).
	if u, h := os.Getenv("SVPS_PANEL_USER"), os.Getenv("SVPS_PANEL_HASH"); u != "" && h != "" {
		return creds{User: u, Hash: h}, nil
	}
	b, err := os.ReadFile(panelConfPath())
	if err != nil {
		return creds{}, err
	}
	c := creds{}
	for _, line := range strings.Split(string(b), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "username=") {
			c.User = strings.TrimPrefix(line, "username=")
		}
		if strings.HasPrefix(line, "password_hash=") {
			c.Hash = strings.TrimPrefix(line, "password_hash=")
		}
	}
	if c.User == "" || c.Hash == "" {
		return creds{}, errors.New("panel.conf tidak lengkap")
	}
	return c, nil
}

func verifyLogin(user, pass string) bool {
	c, err := loadCreds()
	if err != nil || user != c.User {
		return false
	}
	return bcrypt.CompareHashAndPassword([]byte(c.Hash), []byte(pass)) == nil
}

func hashPassword(pass string) (string, error) {
	b, err := bcrypt.GenerateFromPassword([]byte(pass), bcrypt.DefaultCost)
	return string(b), err
}

func panelSecret() []byte {
	if s := os.Getenv("SVPS_PANEL_SECRET"); s != "" {
		return []byte(s)
	}
	if b, err := os.ReadFile("/etc/scriptvps/panel.secret"); err == nil && len(b) >= 16 {
		return b
	}
	nb := make([]byte, 32)
	_, _ = rand.Read(nb)
	_ = os.MkdirAll("/etc/scriptvps", 0o700)
	_ = os.WriteFile("/etc/scriptvps/panel.secret", nb, 0o600)
	return nb
}

func signSession(user string) string {
	exp := time.Now().Add(12 * time.Hour).Unix()
	payload := fmt.Sprintf("%s|%d", user, exp)
	mac := hmac.New(sha256.New, panelSecret())
	mac.Write([]byte(payload))
	sig := hex.EncodeToString(mac.Sum(nil))
	return base64.RawURLEncoding.EncodeToString([]byte(payload + "|" + sig))
}

func verifySession(tok string) (string, bool) {
	raw, err := base64.RawURLEncoding.DecodeString(tok)
	if err != nil {
		return "", false
	}
	parts := strings.Split(string(raw), "|")
	if len(parts) != 3 {
		return "", false
	}
	payload := parts[0] + "|" + parts[1]
	mac := hmac.New(sha256.New, panelSecret())
	mac.Write([]byte(payload))
	if !hmac.Equal([]byte(hex.EncodeToString(mac.Sum(nil))), []byte(parts[2])) {
		return "", false
	}
	exp, err := strconv.ParseInt(parts[1], 10, 64)
	if err != nil || time.Now().Unix() > exp {
		return "", false
	}
	return parts[0], true
}
