package proxy

import (
	"context"
	"encoding/base64"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"github.com/surfmore/v6/internal/config"
)

func TestPHPProxyPreservesMethodHeadersQueryAndBody(t *testing.T) {
	var gotMethod, gotHeader, gotQuery, gotBody string
	handler := newPHPProxyHandlerWithTransport(true, config.AuthConfig{AllowAnonymous: true}, func() (net.IP, error) { return net.ParseIP("127.0.0.1"), nil }, func(net.IP) http.RoundTripper { return roundTripperFunc(func(r *http.Request) (*http.Response, error) {
		body, _ := io.ReadAll(r.Body)
		gotMethod, gotHeader, gotQuery, gotBody = r.Method, r.Header.Get("X-Request-Test"), r.URL.RawQuery, string(body)
		return &http.Response{StatusCode: http.StatusCreated, Header: make(http.Header), Body: io.NopCloser(strings.NewReader("origin-response")), Request: r}, nil
	}) })
	req := httptest.NewRequest(http.MethodPost, "/Proxy.php?url=https%3A%2F%2Fexample.com%2Fpath%3Fexisting%3Dyes", strings.NewReader("raw=body&x=1"))
	req.Header.Set("X-Request-Test", "preserve-me")
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusCreated || rec.Body.String() != "origin-response" {
		t.Fatalf("unexpected response: status=%d body=%q", rec.Code, rec.Body.String())
	}
	if gotMethod != http.MethodPost || gotHeader != "preserve-me" || gotQuery != "existing=yes" || gotBody != "raw=body&x=1" {
		t.Fatalf("request changed: method=%q header=%q query=%q body=%q", gotMethod, gotHeader, gotQuery, gotBody)
	}
}

type roundTripperFunc func(*http.Request) (*http.Response, error)

func (f roundTripperFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestPHPProxyCanBeDisabled(t *testing.T) {
	handler := newPHPProxyHandler(false, config.AuthConfig{}, nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/Proxy.php?url=https://example.com", nil))
	if rec.Code != http.StatusNotFound {
		t.Fatalf("disabled endpoint returned %d, want 404", rec.Code)
	}
}

func TestPHPProxyRejectsInvalidTarget(t *testing.T) {
	handler := newPHPProxyHandler(true, config.AuthConfig{AllowAnonymous: true}, func() (net.IP, error) { return net.ParseIP("127.0.0.1"), nil })
	for _, target := range []string{"", "file:///etc/passwd", "https://user:pass@example.com/path"} {
		rec := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodGet, "/Proxy.php?url="+url.QueryEscape(target), nil)
		handler.ServeHTTP(rec, req)
		if rec.Code != http.StatusBadRequest {
			t.Errorf("target %q returned %d, want 400", target, rec.Code)
		}
	}
}

func TestNetworkForSourceMatchesAddressFamily(t *testing.T) {
	if got := networkForSource(net.ParseIP("2001:db8::2")); got != "tcp6" {
		t.Fatalf("IPv6 source selected %q, want tcp6", got)
	}
	if got := networkForSource(net.ParseIP("192.0.2.20")); got != "tcp4" {
		t.Fatalf("IPv4 source selected %q, want tcp4", got)
	}
}

func TestDialWithSourceCanReachMatchingListener(t *testing.T) {
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Skipf("IPv4 loopback unavailable: %v", err)
	}
	defer listener.Close()
	go func() {
		conn, err := listener.Accept()
		if err == nil {
			_ = conn.Close()
		}
	}()
	conn, err := dialWithSource(context.Background(), listener.Addr().String(), net.ParseIP("127.0.0.1"))
	if err != nil {
		t.Fatalf("matching-family dial failed: %v", err)
	}
	conn.Close()
}

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
	cfg := &config.Config{CIDR: "2001:db8::/64", RealIPv4: "192.0.2.10", RandomIPv6Port: 100, RealIPv4Port: 101, MaxConcurrent: 256}
	cfg.AuthConfig.AllowAnonymous = true
	if err := cfg.Validate(); err != nil {
		t.Fatal(err)
	}
	cfg.RealIPv4 = "2001:db8::1"
	if err := cfg.Validate(); err == nil {
		t.Fatal("IPv6 accepted as real IPv4")
	}
}

func TestCheckAuthConfigRequiresExplicitAnonymousOptIn(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "http://example.com", nil)
	if checkAuthConfig(config.AuthConfig{}, req) {
		t.Fatal("anonymous access accepted without explicit opt-in")
	}
	if !checkAuthConfig(config.AuthConfig{AllowAnonymous: true}, req) {
		t.Fatal("explicit anonymous opt-in rejected")
	}
}

func TestValidatePHPProxyTargetRejectsPrivateLiterals(t *testing.T) {
	for _, target := range []string{"http://127.0.0.1/", "http://169.254.169.254/", "http://[::1]/"} {
		if _, err := validatePHPProxyTarget(target); err == nil {
			t.Errorf("target %q was accepted", target)
		}
	}
}
