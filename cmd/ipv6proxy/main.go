package main

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
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

	randomAddr := fmt.Sprintf("%s:%d", cfg.Bind, cfg.RandomIPv6Port)
	realAddr := fmt.Sprintf("%s:%d", cfg.Bind, cfg.RealIPv4Port)
	randomServer := &http.Server{Addr: randomAddr, Handler: randomIPv6Proxy, ReadHeaderTimeout: 15 * time.Second}
	realServer := &http.Server{Addr: realAddr, Handler: realIPv4Proxy, ReadHeaderTimeout: 15 * time.Second}

	serverErrors := make(chan error, 2)
	go serve(randomServer, "random IPv6", serverErrors)
	go serve(realServer, "real IPv4", serverErrors)

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	select {
	case sig := <-stop:
		log.Printf("Received %s, shutting down", sig)
	case err := <-serverErrors:
		if err != nil {
			log.Printf("Proxy server stopped: %v", err)
		}
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_ = randomServer.Shutdown(ctx)
	_ = realServer.Shutdown(ctx)
}

func serve(server *http.Server, name string, errors chan<- error) {
	log.Printf("Starting %s proxy server on %s", name, server.Addr)
	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		errors <- err
	}
}
