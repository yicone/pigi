package helper

import (
	"encoding/json"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"golang.org/x/net/proxy"
)

// configure_network carries only scheme, host and port. Credentials, PAC
// scripts and proxy environment variables are not accepted. A failed proxy
// dial stays on that proxy; Transport.Proxy is never restored to direct.
type networkParams struct {
	Scheme string `json:"scheme"`
	Host   string `json:"host"`
	Port   int    `json:"port"`
}

func (b *ProtonBackend) configureNetwork(raw json.RawMessage) (any, *Fault) {
	if b.client != nil || b.pending != nil {
		return nil, fail("already_authenticated")
	}
	if b.transport == nil || b.directDial == nil {
		return nil, fail("network")
	}
	var params networkParams
	if !Decode(raw, &params) {
		return nil, fail("invalid_params")
	}
	if fault := b.applyProxy(params); fault != nil {
		return nil, fault
	}
	return map[string]bool{"configured": true}, nil
}

func (b *ProtonBackend) applyProxy(params networkParams) *Fault {
	switch params.Scheme {
	case "direct":
		if params.Host != "" || params.Port != 0 {
			return fail("invalid_params")
		}
		b.transport.Proxy = nil
		b.transport.DialContext = b.directDial
		return nil
	case "http", "socks5":
		if params.Port < 1 || params.Port > 65535 || !validProxyHost(params.Host) {
			return fail("invalid_params")
		}
		address := net.JoinHostPort(params.Host, strconv.Itoa(params.Port))
		if params.Scheme == "http" {
			proxyURL := &url.URL{Scheme: "http", Host: address}
			if proxyURL.User != nil {
				return fail("invalid_params")
			}
			b.transport.DialContext = b.directDial
			b.transport.Proxy = http.ProxyURL(proxyURL)
			return nil
		}
		dialer, err := proxy.SOCKS5("tcp", address, nil, &net.Dialer{Timeout: 15 * time.Second})
		if err != nil {
			return fail("invalid_params")
		}
		contextDial, ok := dialer.(proxy.ContextDialer)
		if !ok {
			return fail("invalid_params")
		}
		b.transport.Proxy = nil
		b.transport.DialContext = contextDial.DialContext
		return nil
	default:
		return fail("invalid_params")
	}
}

func validProxyHost(host string) bool {
	if host == "" || len(host) > 253 || strings.ContainsAny(host, "@/\\?# \t\r\n") {
		return false
	}
	if ip := net.ParseIP(host); ip != nil {
		return true
	}
	if strings.Contains(host, ":") {
		return false
	}
	for _, label := range strings.Split(host, ".") {
		if label == "" || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' {
			return false
		}
		for _, r := range label {
			if (r < 'a' || r > 'z') && (r < 'A' || r > 'Z') && (r < '0' || r > '9') && r != '-' {
				return false
			}
		}
	}
	return true
}
