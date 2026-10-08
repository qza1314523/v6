package proxy

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"io"
	"log"

	"math/big"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/elazarl/goproxy"
	"github.com/surfmore/v6/internal/config"
)

func generateRandomIPv6(cidr string) (net.IP, error) {
	_, network, err := net.ParseCIDR(cidr)
	if err != nil || network.IP.To4() != nil {
		if err == nil {
			err = fmt.Errorf("CIDR is not IPv6")
		}
		return nil, err
	}
	ip := append(net.IP(nil), network.IP.To16()...)
	for i := range ip {
		for bit := byte(0); bit < 8; bit++ {
			if network.Mask[i]&(1<<(7-bit)) == 0 {
				if randomBit, err := rand.Int(rand.Reader, big.NewInt(2)); err != nil {
					return nil, err
				} else if randomBit.Int64() == 1 {
					ip[i] |= 1 << (7 - bit)
				} else {
					ip[i] &^= 1 << (7 - bit)
				}
			}
		}
	}
	return ip, nil
}

func NewProxyServer(cfg *config.Config, useRandomIPv6 bool) *goproxy.ProxyHttpServer {
	proxy := goproxy.NewProxyHttpServer()
	proxy.Verbose = cfg.Verbose
	proxy.ConnectDial = func(network, addr string) (net.Conn, error) {
		ip, err := selectOutgoingIP(cfg, useRandomIPv6)
		if err != nil {
			return nil, err
		}
		return dialWithSource(context.Background(), addr, ip)
	}

	proxy.OnRequest().DoFunc(func(req *http.Request, ctx *goproxy.ProxyCtx) (*http.Request, *http.Response) {
		if !checkAuth(cfg.AuthConfig.Username, cfg.AuthConfig.Password, req) {
			return req, goproxy.NewResponse(req, goproxy.ContentTypeText, http.StatusProxyAuthRequired, "Proxy Authentication Required")
		}
		outgoingIP, err := selectOutgoingIP(cfg, useRandomIPv6)
		if err != nil {
			return req, goproxy.NewResponse(req, goproxy.ContentTypeText, http.StatusBadGateway, err.Error())
		}
		transport := newTransport(outgoingIP)
		ctx.RoundTripper = goproxy.RoundTripperFunc(func(request *http.Request, _ *goproxy.ProxyCtx) (*http.Response, error) {
			return transport.RoundTrip(request)
		})
		return req, nil
	})
	proxy.OnRequest().HijackConnect(func(req *http.Request, client net.Conn, _ *goproxy.ProxyCtx) {
		if !checkAuth(cfg.AuthConfig.Username, cfg.AuthConfig.Password, req) {
			_, _ = io.WriteString(client, "HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"Proxy\"\r\n\r\n")
			_ = client.Close()
			return
		}
		outgoingIP, err := selectOutgoingIP(cfg, useRandomIPv6)
		if err != nil {
			writeProxyError(client, req, err)
			return
		}
		server, err := dialWithSource(req.Context(), req.URL.Host, outgoingIP)
		if err != nil {
			log.Printf("CONNECT %s from %s failed: %v", req.URL.Host, outgoingIP, err)
			writeProxyError(client, req, err)
			return
		}
		_, _ = io.WriteString(client, fmt.Sprintf("%s 200 Connection established\r\n\r\n", req.Proto))
		go copyData(client, server)
		go copyData(server, client)
	})
	return proxy
}

func NewPHPProxyHandler(cfg *config.Config, useRandomIPv6 bool) http.Handler {
	return newPHPProxyHandler(cfg.PHPProxyEnabled, cfg.AuthConfig, func() (net.IP, error) {
		return selectOutgoingIP(cfg, useRandomIPv6)
	})
}

func newTransport(localIP net.IP) *http.Transport {
	dialer := &net.Dialer{Timeout: 30 * time.Second, KeepAlive: 30 * time.Second, LocalAddr: &net.TCPAddr{IP: localIP}}
	return &http.Transport{Proxy: nil, DialContext: func(ctx context.Context, _, address string) (net.Conn, error) {
		return dialer.DialContext(ctx, networkForSource(localIP), address)
	}, MaxIdleConns: 64, IdleConnTimeout: 90 * time.Second, TLSHandshakeTimeout: 10 * time.Second, ResponseHeaderTimeout: 30 * time.Second, ExpectContinueTimeout: 1 * time.Second}
}

func newPHPProxyHandler(enabled bool, auth config.AuthConfig, selectIP func() (net.IP, error)) http.Handler {
	return newPHPProxyHandlerWithTransport(enabled, auth, selectIP, newTransport)
}

func newPHPProxyHandlerWithTransport(enabled bool, auth config.AuthConfig, selectIP func() (net.IP, error), transportFor func(net.IP) *http.Transport) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !enabled {
			http.NotFound(w, r)
			return
		}
		if !checkAuth(auth.Username, auth.Password, r) {
			w.Header().Set("Proxy-Authenticate", `Basic realm="Proxy.php"`)
			http.Error(w, "Proxy Authentication Required", http.StatusProxyAuthRequired)
			return
		}
		target, err := validatePHPProxyTarget(r.URL.Query().Get("url"))
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		ip, err := selectIP()
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}
		outgoing := r.Clone(r.Context())
		outgoing.URL = target
		outgoing.RequestURI = ""
		outgoing.Host = target.Host
		outgoing.Header = outgoing.Header.Clone()
		for _, header := range []string{"Connection", "Proxy-Authorization", "Proxy-Connection", "Keep-Alive", "TE", "Trailer", "Transfer-Encoding", "Upgrade"} {
			outgoing.Header.Del(header)
		}
		resp, err := transportFor(ip).RoundTrip(outgoing)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}
		defer resp.Body.Close()
		for key, values := range resp.Header {
			for _, value := range values {
				w.Header().Add(key, value)
			}
		}
		w.WriteHeader(resp.StatusCode)
		_, _ = io.Copy(w, resp.Body)
	})
}

func validatePHPProxyTarget(raw string) (*url.URL, error) {
	target, err := url.Parse(raw)
	if err != nil || (target.Scheme != "http" && target.Scheme != "https") || target.Host == "" || target.User != nil {
		return nil, fmt.Errorf("url must be an absolute http or https URL without userinfo")
	}
	host := target.Hostname()
	if ip := net.ParseIP(host); ip != nil && (ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() || ip.IsUnspecified()) {
		return nil, fmt.Errorf("private or local targets are not allowed")
	}
	if strings.EqualFold(host, "localhost") || strings.HasSuffix(strings.ToLower(host), ".localhost") || strings.HasSuffix(strings.ToLower(host), ".local") {
		return nil, fmt.Errorf("private or local targets are not allowed")
	}
	if port := target.Port(); port != "" {
		if _, err := strconv.Atoi(port); err != nil {
			return nil, fmt.Errorf("invalid target port")
		}
	}
	return target, nil
}

func networkForSource(source net.IP) string {
	if source.To4() != nil {
		return "tcp4"
	}
	return "tcp6"
}

func dialWithSource(ctx context.Context, address string, source net.IP) (net.Conn, error) {
	dialer := &net.Dialer{Timeout: 30 * time.Second, KeepAlive: 30 * time.Second, LocalAddr: &net.TCPAddr{IP: source}}
	return dialer.DialContext(ctx, networkForSource(source), address)
}

func selectOutgoingIP(cfg *config.Config, random bool) (net.IP, error) {
	if random {
		return generateRandomIPv6(cfg.CIDR)
	}
	ip := net.ParseIP(cfg.RealIPv4).To4()
	if ip == nil {
		return nil, fmt.Errorf("invalid configured IPv4 address")
	}
	return ip, nil
}

func writeProxyError(client net.Conn, req *http.Request, err error) {
	_, _ = io.WriteString(client, fmt.Sprintf("%s 502 Bad Gateway\r\n\r\n%s", req.Proto, err))
	_ = client.Close()
}

func checkAuth(username, password string, req *http.Request) bool {
	if username == "" && password == "" {
		return true
	}
	value := req.Header.Get("Proxy-Authorization")
	if !strings.HasPrefix(value, "Basic ") {
		return false
	}
	decoded, err := base64.StdEncoding.DecodeString(strings.TrimSpace(strings.TrimPrefix(value, "Basic ")))
	if err != nil {
		return false
	}
	credentials := strings.SplitN(string(decoded), ":", 2)
	return len(credentials) == 2 && credentials[0] == username && credentials[1] == password
}

func copyData(dst, src net.Conn) { defer dst.Close(); defer src.Close(); _, _ = io.Copy(dst, src) }
