package helper

import (
	"bufio"
	"context"
	"crypto/tls"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestConfigureNetworkValidation(t *testing.T) {
	b := NewBackend()
	defer b.Close()
	for _, params := range []string{
		`{"scheme":"http","host":"user@secret.example","port":8080}`,
		`{"scheme":"http","host":"proxy.example","port":0}`,
		`{"scheme":"http","host":"proxy.example","port":65536}`,
		`{"scheme":"http","host":"proxy.example","port":-1}`,
		`{"scheme":"ftp","host":"proxy.example","port":8080}`,
		`{"scheme":"https","host":"proxy.example","port":8080}`,
		`{"scheme":"HTTP","host":"proxy.example","port":8080}`,
		`{"scheme":"direct","host":"proxy.example","port":1}`,
		`{"scheme":"direct","host":"","port":1}`,
		`{"scheme":"http","host":"proxy.example","port":8080,"password":"secret"}`,
		`{"scheme":"http","host":"proxy.example","port":"8080"}`,
		`{"scheme":"http","host":"","port":8080}`,
		`{}`,
	} {
		_, fault := b.Call(context.Background(), "configure_network", json.RawMessage(params))
		if fault == nil || fault.Code != "invalid_params" {
			t.Fatalf("%s got %v", params, fault)
		}
	}
	if b.transport.Proxy != nil {
		t.Fatal("rejected configure installed a proxy")
	}

	_, fault := b.Call(context.Background(), "configure_network", json.RawMessage(`{"scheme":"direct","host":"","port":0}`))
	if fault != nil || b.transport.Proxy != nil {
		t.Fatalf("direct: fault=%v hasProxy=%t", fault, b.transport.Proxy != nil)
	}

	b.pending = &pendingLogin{}
	_, fault = b.Call(context.Background(), "configure_network", json.RawMessage(`{"scheme":"http","host":"127.0.0.1","port":9}`))
	if fault == nil || fault.Code != "already_authenticated" || b.transport.Proxy != nil {
		t.Fatalf("pending login configure: %v", fault)
	}
	b.pending = nil

	b.client = b.manager.NewClient("fixture", "fixture", "fixture")
	_, fault = b.Call(context.Background(), "configure_network", json.RawMessage(`{"scheme":"http","host":"127.0.0.1","port":9}`))
	b.client = nil
	if fault == nil || fault.Code != "already_authenticated" || b.transport.Proxy != nil {
		t.Fatalf("authenticated configure: %v", fault)
	}
}

func TestHelloAdvertisesConfigureNetwork(t *testing.T) {
	input := `{"version":1,"id":1,"method":"hello","params":{}}
{"version":1,"id":2,"method":"configure_network","params":{"scheme":"http","host":"user@secret.example","port":8080}}
`
	var out strings.Builder
	if err := Serve(strings.NewReader(input), &out, NewBackend()); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(out.String(), "secret") || strings.Contains(out.String(), "@") {
		t.Fatal("proxy host leaked into the response")
	}
	lines := strings.Split(strings.TrimSpace(out.String()), "\n")
	if len(lines) != 2 {
		t.Fatalf("responses: %s", out.String())
	}
	var hello struct {
		Result struct {
			HelperVersion string   `json:"helper_version"`
			Methods       []string `json:"methods"`
		} `json:"result"`
	}
	if err := json.Unmarshal([]byte(lines[0]), &hello); err != nil {
		t.Fatal(err)
	}
	if hello.Result.HelperVersion != "0.4.0" || !contains(hello.Result.Methods, "configure_network") {
		t.Fatalf("hello: %+v", hello.Result)
	}
	var rejected Response
	if err := json.Unmarshal([]byte(lines[1]), &rejected); err != nil {
		t.Fatal(err)
	}
	if rejected.Error == nil || rejected.Error.Code != "invalid_params" {
		t.Fatalf("userinfo host: %s", lines[1])
	}
}

func TestDirectIgnoresEnvironmentAndProxy(t *testing.T) {
	t.Setenv("HTTP_PROXY", "http://127.0.0.1:9")
	t.Setenv("http_proxy", "http://127.0.0.1:9")
	t.Setenv("HTTPS_PROXY", "http://127.0.0.1:9")
	t.Setenv("ALL_PROXY", "socks5://127.0.0.1:9")
	originHits := 0
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		originHits++
		w.WriteHeader(http.StatusNoContent)
	}))
	defer origin.Close()
	b := NewBackend()
	defer b.Close()
	if b.transport.Proxy != nil {
		t.Fatal("default transport still consults the environment")
	}
	_, fault := b.Call(context.Background(), "configure_network", json.RawMessage(`{"scheme":"direct","host":"","port":0}`))
	if fault != nil {
		t.Fatal(fault)
	}
	client := &http.Client{Transport: b.transport, Timeout: 3 * time.Second}
	response, err := client.Get(origin.URL)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != http.StatusNoContent || originHits != 1 {
		t.Fatalf("direct request status=%d hits=%d", response.StatusCode, originHits)
	}
}

func TestHTTPProxyUsesCONNECTAndDoesNotFallBack(t *testing.T) {
	target := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/proton" {
			t.Errorf("path %s", r.URL.Path)
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	defer target.Close()
	connects := int32(0)
	proxyAddr := serveCONNECTProxy(t, &connects)
	host, portText, err := net.SplitHostPort(proxyAddr)
	if err != nil {
		t.Fatal(err)
	}
	port, err := strconv.Atoi(portText)
	if err != nil {
		t.Fatal(err)
	}
	b := NewBackend()
	defer b.Close()
	params, err := json.Marshal(map[string]any{"scheme": "http", "host": host, "port": port})
	if err != nil {
		t.Fatal(err)
	}
	_, fault := b.Call(context.Background(), "configure_network", params)
	if fault != nil || b.transport.Proxy == nil {
		t.Fatalf("configure http proxy: %v", fault)
	}
	b.transport.TLSClientConfig = &tls.Config{InsecureSkipVerify: true}
	client := &http.Client{Transport: b.transport, Timeout: 3 * time.Second}
	response, err := client.Get(target.URL + "/proton")
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != http.StatusNoContent || atomic.LoadInt32(&connects) != 1 {
		t.Fatalf("CONNECT status=%d connects=%d", response.StatusCode, connects)
	}

	closed, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	closedAddr := closed.Addr().String()
	closed.Close()
	closedHost, closedPortText, err := net.SplitHostPort(closedAddr)
	if err != nil {
		t.Fatal(err)
	}
	closedPort, err := strconv.Atoi(closedPortText)
	if err != nil {
		t.Fatal(err)
	}
	originHits := int32(0)
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&originHits, 1)
	}))
	defer origin.Close()
	refused := NewBackend()
	defer refused.Close()
	refusedParams, err := json.Marshal(map[string]any{"scheme": "http", "host": closedHost, "port": closedPort})
	if err != nil {
		t.Fatal(err)
	}
	if _, fault := refused.Call(context.Background(), "configure_network", refusedParams); fault != nil {
		t.Fatal(fault)
	}
	refusedClient := &http.Client{Transport: refused.transport, Timeout: 3 * time.Second}
	if _, err := refusedClient.Get(origin.URL); err == nil || atomic.LoadInt32(&originHits) != 0 {
		t.Fatalf("proxy failure fell back to the origin: err=%v hits=%d", err, originHits)
	}
}

func TestSOCKS5ProxyIsUsed(t *testing.T) {
	originHits := int32(0)
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&originHits, 1)
		w.WriteHeader(http.StatusNoContent)
	}))
	defer origin.Close()
	handshakes := int32(0)
	proxyAddr := serveSOCKS5(t, &handshakes)
	host, portText, err := net.SplitHostPort(proxyAddr)
	if err != nil {
		t.Fatal(err)
	}
	port, err := strconv.Atoi(portText)
	if err != nil {
		t.Fatal(err)
	}
	b := NewBackend()
	defer b.Close()
	params, err := json.Marshal(map[string]any{"scheme": "socks5", "host": host, "port": port})
	if err != nil {
		t.Fatal(err)
	}
	_, fault := b.Call(context.Background(), "configure_network", params)
	if fault != nil || b.transport.Proxy != nil {
		t.Fatalf("configure socks5: fault=%v hasProxy=%t", fault, b.transport.Proxy != nil)
	}
	client := &http.Client{Transport: b.transport, Timeout: 3 * time.Second}
	response, err := client.Get(origin.URL)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != http.StatusNoContent || atomic.LoadInt32(&handshakes) != 1 || atomic.LoadInt32(&originHits) != 1 {
		t.Fatalf("socks status=%d handshakes=%d hits=%d", response.StatusCode, handshakes, originHits)
	}
}

func serveCONNECTProxy(t *testing.T, connects *int32) string {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go func(conn net.Conn) {
				defer conn.Close()
				reader := bufio.NewReader(conn)
				request, err := http.ReadRequest(reader)
				if err != nil || request.Method != http.MethodConnect {
					return
				}
				atomic.AddInt32(connects, 1)
				dest, err := net.Dial("tcp", request.Host)
				if err != nil {
					_, _ = conn.Write([]byte("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n"))
					return
				}
				defer dest.Close()
				if _, err := conn.Write([]byte("HTTP/1.1 200 Connection Established\r\n\r\n")); err != nil {
					return
				}
				done := make(chan struct{}, 2)
				go func() { _, _ = io.Copy(dest, reader); done <- struct{}{} }()
				go func() { _, _ = io.Copy(conn, dest); done <- struct{}{} }()
				<-done
			}(conn)
		}
	}()
	return listener.Addr().String()
}

func serveSOCKS5(t *testing.T, handshakes *int32) string {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go func(conn net.Conn) {
				defer conn.Close()
				target, err := acceptSOCKS5(conn)
				if err != nil {
					return
				}
				atomic.AddInt32(handshakes, 1)
				dest, err := net.Dial("tcp", target)
				if err != nil {
					return
				}
				defer dest.Close()
				done := make(chan struct{}, 2)
				go func() { _, _ = io.Copy(dest, conn); done <- struct{}{} }()
				go func() { _, _ = io.Copy(conn, dest); done <- struct{}{} }()
				<-done
			}(conn)
		}
	}()
	return listener.Addr().String()
}

func acceptSOCKS5(conn net.Conn) (string, error) {
	header := make([]byte, 2)
	if _, err := io.ReadFull(conn, header); err != nil {
		return "", err
	}
	if header[0] != 5 {
		return "", io.ErrUnexpectedEOF
	}
	if _, err := io.ReadFull(conn, make([]byte, int(header[1]))); err != nil {
		return "", err
	}
	if _, err := conn.Write([]byte{5, 0}); err != nil {
		return "", err
	}
	request := make([]byte, 4)
	if _, err := io.ReadFull(conn, request); err != nil {
		return "", err
	}
	if request[0] != 5 || request[1] != 1 {
		return "", io.ErrUnexpectedEOF
	}
	var host string
	switch request[3] {
	case 1:
		ip := make([]byte, 4)
		if _, err := io.ReadFull(conn, ip); err != nil {
			return "", err
		}
		host = net.IP(ip).String()
	case 3:
		length := make([]byte, 1)
		if _, err := io.ReadFull(conn, length); err != nil {
			return "", err
		}
		name := make([]byte, int(length[0]))
		if _, err := io.ReadFull(conn, name); err != nil {
			return "", err
		}
		host = string(name)
	case 4:
		ip := make([]byte, 16)
		if _, err := io.ReadFull(conn, ip); err != nil {
			return "", err
		}
		host = net.IP(ip).String()
	default:
		return "", io.ErrUnexpectedEOF
	}
	portBytes := make([]byte, 2)
	if _, err := io.ReadFull(conn, portBytes); err != nil {
		return "", err
	}
	if _, err := conn.Write([]byte{5, 0, 0, 1, 0, 0, 0, 0, 0, 0}); err != nil {
		return "", err
	}
	port := int(portBytes[0])<<8 | int(portBytes[1])
	return net.JoinHostPort(host, strconv.Itoa(port)), nil
}

func contains(values []string, want string) bool {
	for _, value := range values {
		if value == want {
			return true
		}
	}
	return false
}
