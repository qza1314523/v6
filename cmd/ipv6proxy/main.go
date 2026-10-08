package main

import (
	"context"
	"crypto/tls"
	"fmt"
	"log"
	"net"
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

	randomAddr := net.JoinHostPort(cfg.Bind, fmt.Sprint(cfg.RandomIPv6Port))
	realAddr := net.JoinHostPort(cfg.Bind, fmt.Sprint(cfg.RealIPv4Port))
	randomMux := http.NewServeMux()
	randomMux.Handle("/", randomIPv6Proxy)
	randomMux.Handle("/Proxy.php", proxy.NewPHPProxyHandler(cfg, true))
	realMux := http.NewServeMux()
	realMux.Handle("/", realIPv4Proxy)
	realMux.Handle("/Proxy.php", proxy.NewPHPProxyHandler(cfg, false))
	randomServer := &http.Server{Addr: randomAddr, Handler: randomMux, ReadHeaderTimeout: 15 * time.Second}
	realServer := &http.Server{Addr: realAddr, Handler: realMux, ReadHeaderTimeout: 15 * time.Second}
	useTLS := cfg.TLSCertFile != ""

	serverErrors := make(chan error, 2)
	go serve(randomServer, "random IPv6", useTLS, cfg.TLSCertFile, cfg.TLSKeyFile, serverErrors)
	go serve(realServer, "real IPv4", useTLS, cfg.TLSCertFile, cfg.TLSKeyFile, serverErrors)

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

func serve(server *http.Server, name string, useTLS bool, certFile, keyFile string, errors chan<- error) {
	log.Printf("Starting %s %s server on %s", name, map[bool]string{true: "HTTPS", false: "HTTP"}[useTLS], server.Addr)
	var err error
	if useTLS {
		cert, loadErr := tls.LoadX509KeyPair(certFile, keyFile)
		if loadErr != nil {
			errors <- loadErr
			return
		}
		listener, listenErr := net.Listen("tcp", server.Addr)
		if listenErr != nil {
			errors <- listenErr
			return
		}
		tlsListener := tls.NewListener(listener, &tls.Config{Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS12})
		err = server.Serve(tlsListener)
	} else {
		err = server.ListenAndServe()
	}
	if err != nil && err != http.ErrServerClosed {
		errors <- err
	}
}
