package config

import (
	"flag"
	"fmt"
	"net"
	"net/url"
	"strings"
)

type Config struct {
	RandomIPv6Port    int
	RealIPv4Port      int
	CIDR              string
	Bind              string
	AutoRoute         bool
	AutoForwarding    bool
	AutoIpNoLocalBind bool
	UseDOH            bool
	Verbose           bool
	AuthConfig        AuthConfig
	RealIPv4          string
	PHPProxyEnabled   bool
	TLSCertFile       string
	TLSKeyFile        string
	MaxConcurrent     int
	EndpointMode      string
	Domain            string
	CertName          string
}

func ValidateEndpointMode(mode, domain string) error {
	switch mode {
	case "ipv4-http", "ipv4-https":
		if domain != "" {
			return fmt.Errorf("domain is only valid in domain-https mode")
		}
	case "domain-https":
		if domain == "" {
			return fmt.Errorf("domain is required in domain-https mode")
		}
		u, err := url.Parse("https://" + domain)
		if err != nil || u.Hostname() != domain || strings.ContainsAny(domain, "/:@?#") || net.ParseIP(domain) != nil {
			return fmt.Errorf("invalid DNS domain %q", domain)
		}
	default:
		return fmt.Errorf("endpoint mode must be ipv4-http, ipv4-https, or domain-https")
	}
	return nil
}

type AuthConfig struct {
	Username       string
	Password       string
	AllowAnonymous bool
}

func ParseFlags() *Config {
	cfg := &Config{}
	flag.IntVar(&cfg.RandomIPv6Port, "random-ipv6-port", 100, "Port for random IPv6 proxy")
	flag.IntVar(&cfg.RealIPv4Port, "real-ipv4-port", 101, "Port for real IPv4 proxy")
	flag.StringVar(&cfg.CIDR, "cidr", "", "IPv6 CIDR is required")
	flag.StringVar(&cfg.AuthConfig.Username, "username", "", "Basic auth username")
	flag.StringVar(&cfg.AuthConfig.Password, "password", "", "Basic auth password")
	flag.StringVar(&cfg.Bind, "bind", "0.0.0.0", "Bind address")
	flag.BoolVar(&cfg.AutoRoute, "auto-route", true, "Auto add route to local network")
	flag.BoolVar(&cfg.AutoForwarding, "auto-forwarding", true, "Auto enable IPv6 forwarding")
	flag.BoolVar(&cfg.AutoIpNoLocalBind, "auto-ip-nonlocal-bind", true, "Auto enable IPv6 non local bind")
	flag.BoolVar(&cfg.UseDOH, "use-doh", true, "Use DNS over HTTPS instead of DNS over TLS")
	flag.BoolVar(&cfg.Verbose, "verbose", false, "Enable verbose logging")
	flag.StringVar(&cfg.RealIPv4, "real-ipv4", "", "Server's real IPv4 address")
	flag.BoolVar(&cfg.PHPProxyEnabled, "php-proxy", false, "Enable /Proxy.php forwarding endpoint")
	flag.StringVar(&cfg.TLSCertFile, "tls-cert", "", "TLS certificate PEM file")
	flag.StringVar(&cfg.TLSKeyFile, "tls-key", "", "TLS private key PEM file")
	flag.BoolVar(&cfg.AuthConfig.AllowAnonymous, "allow-anonymous", false, "Allow unauthenticated proxy access (unsafe)")
	flag.IntVar(&cfg.MaxConcurrent, "max-concurrent", 256, "Maximum concurrent proxy connections")
	flag.StringVar(&cfg.EndpointMode, "endpoint-mode", "ipv4-http", "Endpoint mode: ipv4-http, ipv4-https, domain-https")
	flag.StringVar(&cfg.Domain, "domain", "", "DNS hostname for domain-https mode")
	flag.StringVar(&cfg.CertName, "cert-name", "ipv6proxy-ip", "Certbot certificate name")
	flag.Parse()
	return cfg
}

func (c *Config) Validate() error {
	if c.CIDR == "" {
		return fmt.Errorf("-cidr is required")
	}
	if ip, network, err := net.ParseCIDR(c.CIDR); err != nil || ip.To4() != nil || network.IP.To4() != nil {
		return fmt.Errorf("-cidr must be a valid IPv6 network: %q", c.CIDR)
	}
	if c.RealIPv4 == "" {
		return fmt.Errorf("-real-ipv4 is required")
	}
	if ip := net.ParseIP(c.RealIPv4); ip == nil || ip.To4() == nil {
		return fmt.Errorf("-real-ipv4 must be a valid IPv4 address: %q", c.RealIPv4)
	}
	if c.RandomIPv6Port < 1 || c.RandomIPv6Port > 65535 || c.RealIPv4Port < 1 || c.RealIPv4Port > 65535 {
		return fmt.Errorf("proxy ports must be between 1 and 65535")
	}
	if c.RandomIPv6Port == c.RealIPv4Port {
		return fmt.Errorf("proxy ports must be different")
	}
	if c.MaxConcurrent < 1 {
		return fmt.Errorf("-max-concurrent must be positive")
	}
	if c.AuthConfig.Username == "" && c.AuthConfig.Password != "" || c.AuthConfig.Username != "" && c.AuthConfig.Password == "" {
		return fmt.Errorf("-username and -password must be provided together")
	}
	if c.AuthConfig.Username == "" && !c.AuthConfig.AllowAnonymous {
		return fmt.Errorf("authentication is required; provide -username and -password, or explicitly set -allow-anonymous")
	}
	if (c.TLSCertFile == "") != (c.TLSKeyFile == "") {
		return fmt.Errorf("-tls-cert and -tls-key must be provided together")
	}
	if err := ValidateEndpointMode(c.EndpointMode, c.Domain); err != nil {
		return err
	}
	if c.EndpointMode == "ipv4-http" && c.TLSCertFile != "" {
		return fmt.Errorf("TLS certificate supplied while endpoint mode is ipv4-http")
	}
	if c.EndpointMode != "ipv4-http" && c.TLSCertFile == "" {
		return fmt.Errorf("TLS certificate and key are required for HTTPS endpoint mode")
	}
	return nil
}
