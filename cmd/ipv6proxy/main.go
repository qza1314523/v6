package main

import (
	"fmt"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/surfmore/v6/internal/config"
	"github.com/surfmore/v6/internal/proxy"
	"github.com/surfmore/v6/internal/sysutils"
)

func main() {
	log.SetOutput(os.Stdout)
	cfg := config.ParseFlags()
	if err := cfg.Validate(); err != nil {
		log.Fatal(err)
	}

	if cfg.AutoForwarding {
		sysutils.SetV6Forwarding()
	}

	if cfg.AutoRoute {
		sysutils.AddV6Route(cfg.CIDR)
	}

	if cfg.AutoIpNoLocalBind {
		sysutils.SetIpNonLocalBind()
	}

	randomIPv6Proxy := proxy.NewProxyServer(cfg, true)
	realIPv4Proxy := proxy.NewProxyServer(cfg, false)

	server := &http.Server{Addr: fmt.Sprintf("%s:%d", cfg.Bind, cfg.RealIPv4Port), Handler: realIPv4Proxy, ReadHeaderTimeout: 15 * time.Second}
	go func() {
		log.Printf("Starting random IPv6 proxy server on %s:%d", cfg.Bind, cfg.RandomIPv6Port)
		err := http.ListenAndServe(fmt.Sprintf("%s:%d", cfg.Bind, cfg.RandomIPv6Port), randomIPv6Proxy)
		if err != nil {
			log.Fatal(err)
		}
	}()

	log.Printf("Starting real IPv4 proxy server on %s:%d", cfg.Bind, cfg.RealIPv4Port)
	err := server.ListenAndServe()
	if err != nil {
		log.Fatal(err)
	}
}
