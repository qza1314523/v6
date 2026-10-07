package proxy

import (
	"encoding/base64"
	"net"
	"net/http"
	"testing"

	"github.com/surfmore/v6/internal/config"
)

func TestGenerateRandomIPv6KeepsPrefix(t *testing.T) {
	const cidr = "2001:db8:1234:5678::/56"
	_, network, err := net.ParseCIDR(cidr)
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 100; i++ {
		ip, err := generateRandomIPv6(cidr)
		if err != nil {
			t.Fatal(err)
		}
		if !network.Contains(ip) {
			t.Fatalf("generated %s outside %s", ip, cidr)
		}
	}
}

func TestGenerateRandomIPv6RejectsIPv4(t *testing.T) {
	if _, err := generateRandomIPv6("192.0.2.0/24"); err == nil {
		t.Fatal("expected IPv4 CIDR to be rejected")
	}
}

func TestCheckAuth(t *testing.T) {
	req, _ := http.NewRequest(http.MethodGet, "http://example.com", nil)
	if checkAuth("user", "pass", req) {
		t.Fatal("missing credentials accepted")
	}
	req.Header.Set("Proxy-Authorization", "Basic "+base64.StdEncoding.EncodeToString([]byte("user:pass")))
	if !checkAuth("user", "pass", req) {
		t.Fatal("valid credentials rejected")
	}
	req.Header.Set("Proxy-Authorization", "Basic "+base64.StdEncoding.EncodeToString([]byte("user:wrong")))
	if checkAuth("user", "pass", req) {
		t.Fatal("invalid credentials accepted")
	}
}

func TestValidateConfig(t *testing.T) {
	cfg := &config.Config{CIDR: "2001:db8::/64", RealIPv4: "192.0.2.10", RandomIPv6Port: 100, RealIPv4Port: 101}
	if err := cfg.Validate(); err != nil {
		t.Fatal(err)
	}
	cfg.RealIPv4 = "2001:db8::1"
	if err := cfg.Validate(); err == nil {
		t.Fatal("IPv6 accepted as real IPv4")
	}
}
