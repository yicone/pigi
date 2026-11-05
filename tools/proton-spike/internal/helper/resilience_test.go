package helper

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	proton "github.com/ProtonMail/go-proton-api"
	"github.com/ProtonMail/gopenpgp/v2/crypto"
)

// Exercise the actual HTTP stack, rather than only classifying fabricated errors.
func TestServiceFailuresAreBoundedAndRedacted(t *testing.T) {
	for _, tc := range []struct {
		name         string
		status, code int
		want         string
	}{
		{"rate", 429, 429, "rate_limited"}, {"offline-service", 503, 5000, "network"},
		{"proxy-auth", 407, 407, "proxy"}, {"old-version", 422, 5003, "api_version"},
		{"missing-version", 422, 5001, "api_version"}, {"captcha-change", 422, 9001, "human_verification_required"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			calls := 0
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls++
				if r.Header.Get("X-Pm-Appversion") != "Other" || r.Header.Get("User-Agent") != "pigi-proton-helper/0.1.0" {
					t.Error("client identity changed")
				}
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(tc.status)
				json.NewEncoder(w).Encode(map[string]any{"Code": tc.code, "Error": "PRIVATE_DIAGNOSTIC", "Details": map[string]any{"credential": "PRIVATE_TOKEN"}})
			}))
			defer server.Close()
			transport := http.DefaultTransport.(*http.Transport).Clone()
			transport.Proxy = nil
			manager := proton.New(proton.WithHostURL(server.URL), proton.WithAppVersion("Other"), proton.WithRetryCount(0), proton.WithLogger(quietLogger{}), proton.WithTransport(identifiedTransport{transport}))
			b := &ProtonBackend{manager: manager, client: manager.NewClient("fixture", "fixture", "fixture"), rings: map[string]*crypto.KeyRing{}, persistent: true}
			defer b.Close()
			_, fault := b.Call(context.Background(), "latest", json.RawMessage(`{}`))
			data, _ := json.Marshal(fault)
			if fault == nil || fault.Code != tc.want || strings.Contains(string(data), "PRIVATE") {
				t.Fatalf("unsafe/wrong fault: %s", data)
			}
			if calls != 1 {
				t.Fatalf("request retried %d times", calls)
			}
		})
	}
}

func TestOfflineTimeoutAndExplicitProxy(t *testing.T) {
	// Closed local port gives a deterministic disconnect without external traffic.
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	target := "http://" + listener.Addr().String()
	listener.Close()
	manager := proton.New(proton.WithHostURL(target), proton.WithRetryCount(0), proton.WithLogger(quietLogger{}))
	b := &ProtonBackend{manager: manager, client: manager.NewClient("f", "f", "f"), rings: map[string]*crypto.KeyRing{}, persistent: true}
	defer b.Close()
	_, fault := b.Call(context.Background(), "latest", json.RawMessage(`{}`))
	if fault == nil || fault.Code != "network" {
		t.Fatal("disconnect not classified")
	}
	ctx, cancel := context.WithDeadline(context.Background(), time.Now().Add(-time.Second))
	defer cancel()
	_, fault = b.Call(ctx, "latest", json.RawMessage(`{}`))
	if fault == nil || fault.Code != "timeout" {
		t.Fatal("deadline not classified")
	}
	calls := 0
	proxy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"Code":1000,"EventID":"proxy-fixture"}`))
	}))
	defer proxy.Close()
	proxyURL, _ := url.Parse(proxy.URL)
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.Proxy = http.ProxyURL(proxyURL)
	pm := proton.New(proton.WithHostURL("http://fixture.invalid"), proton.WithRetryCount(0), proton.WithLogger(quietLogger{}), proton.WithTransport(identifiedTransport{transport}))
	pb := &ProtonBackend{manager: pm, client: pm.NewClient("f", "f", "f"), rings: map[string]*crypto.KeyRing{}, persistent: true}
	defer pb.Close()
	result, fault := pb.Call(context.Background(), "latest", json.RawMessage(`{}`))
	if fault != nil || result.(map[string]string)["cursor"] != "proxy-fixture" || calls != 1 {
		t.Fatal("proxy route failed")
	}
}

// A timeout fault is a bounded call result: backend state (client, rings,
// session) survives it, so the parent must be able to keep using the same
// helper process instead of restarting it.
func TestTimeoutLeavesSessionCallable(t *testing.T) {
	manager := proton.New(proton.WithHostURL("http://127.0.0.1:1"), proton.WithRetryCount(0), proton.WithLogger(quietLogger{}))
	b := &ProtonBackend{manager: manager, client: manager.NewClient("f", "f", "f"), rings: map[string]*crypto.KeyRing{},
		session: savedSession{UID: "u", Access: "a", Refresh: "r", Salted: []byte("s"), Email: "fixture@example.test"}, persistent: true}
	defer b.Close()
	ctx, cancel := context.WithDeadline(context.Background(), time.Now().Add(-time.Second))
	defer cancel()
	if _, fault := b.Call(ctx, "latest", json.RawMessage(`{}`)); fault == nil || fault.Code != "timeout" {
		t.Fatalf("expected timeout, got %v", fault)
	}
	result, fault := b.Call(context.Background(), "session", json.RawMessage(`{}`))
	if fault != nil {
		t.Fatalf("session unusable after timeout: %v", fault)
	}
	if s, ok := result.(savedSession); !ok || s.Email != "fixture@example.test" {
		t.Fatalf("session lost after timeout: %v", result)
	}
	if _, fault := b.Call(context.Background(), "latest", json.RawMessage(`{}`)); fault == nil || fault.Code != "network" {
		t.Fatalf("call routing broken after timeout: %v", fault)
	}
}

// A resume that times out inside reloadKeys keeps the API client but has no
// keyrings: session stays answerable while key-dependent calls refuse. This
// documents current semantics; do not change them silently.
func TestResumeTimeoutKeepsClientWithoutKeys(t *testing.T) {
	manager := proton.New(proton.WithHostURL("http://127.0.0.1:1"), proton.WithRetryCount(0), proton.WithLogger(quietLogger{}))
	b := &ProtonBackend{manager: manager}
	defer b.Close()
	ctx, cancel := context.WithDeadline(context.Background(), time.Now().Add(-time.Second))
	defer cancel()
	params := json.RawMessage(`{"uid":"u","access":"a","refresh":"r","salted":"c2FsdGVk","email":"fixture@example.test"}`)
	if _, fault := b.Call(ctx, "resume", params); fault == nil || fault.Code != "timeout" {
		t.Fatalf("expected timeout, got %v", fault)
	}
	if b.client == nil || b.rings != nil {
		t.Fatal("resume timeout changed client/ring state unexpectedly")
	}
	if _, fault := b.Call(context.Background(), "session", json.RawMessage(`{}`)); fault != nil {
		t.Fatalf("session unusable after resume timeout: %v", fault)
	}
	if _, fault := b.Call(context.Background(), "labels", json.RawMessage(`{}`)); fault == nil || fault.Code != "not_authenticated" {
		t.Fatalf("labels should refuse without keyrings, got %v", fault)
	}
}

func TestFailedKeyRotationDisablesStaleKeys(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if strings.Contains(r.URL.Path, "events") {
			w.Write([]byte(`{"Code":1000,"EventID":"next","User":{"Email":"fixture@example.test"}}`))
			return
		}
		w.WriteHeader(503)
		w.Write([]byte(`{"Code":5000,"Error":"PRIVATE"}`))
	}))
	defer server.Close()
	manager := proton.New(proton.WithHostURL(server.URL), proton.WithRetryCount(0), proton.WithLogger(quietLogger{}))
	key, err := crypto.GenerateKey("fixture", "fixture@example.test", "x25519", 0)
	if err != nil {
		t.Fatal(err)
	}
	ring, err := crypto.NewKeyRing(key)
	if err != nil {
		t.Fatal(err)
	}
	b := &ProtonBackend{manager: manager, client: manager.NewClient("f", "f", "f"), rings: map[string]*crypto.KeyRing{"old": ring}, persistent: true}
	defer b.Close()
	_, fault := b.Call(context.Background(), "events", json.RawMessage(`{"cursor":"old"}`))
	if fault == nil || b.rings != nil {
		t.Fatal("failed rotation retained stale keys")
	}
	_, fault = b.Call(context.Background(), "decrypt", json.RawMessage(`{"id":"fixture"}`))
	if fault == nil || fault.Code != "not_authenticated" {
		t.Fatal("decrypt used stale keys")
	}
}

func TestRotatedAddressKeyReplacesPreviousKey(t *testing.T) {
	pass := []byte("synthetic-unlock-secret")
	makeKey := func(id string) (proton.Key, *crypto.KeyRing) {
		t.Helper()
		key, err := crypto.GenerateKey("fixture", "fixture@example.test", "x25519", 0)
		if err != nil {
			t.Fatal(err)
		}
		ring, err := crypto.NewKeyRing(key)
		if err != nil {
			t.Fatal(err)
		}
		locked, err := key.Lock(pass)
		if err != nil {
			t.Fatal(err)
		}
		data, err := locked.Serialize()
		if err != nil {
			t.Fatal(err)
		}
		return proton.Key{ID: id, PrivateKey: data, Primary: true, Active: true}, ring
	}
	oldKey, oldRing := makeKey("old")
	newKey, newRing := makeKey("new")
	defer newRing.ClearPrivateParams()
	current := oldKey
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/core/v4/users":
			json.NewEncoder(w).Encode(map[string]any{"Code": 1000, "User": proton.User{Email: "fixture@example.test", Keys: proton.Keys{current}}})
		case "/core/v4/addresses":
			json.NewEncoder(w).Encode(map[string]any{"Code": 1000, "Addresses": []proton.Address{{ID: "address", Keys: proton.Keys{current}}}})
		default:
			t.Error("unexpected key endpoint")
			w.WriteHeader(404)
		}
	}))
	defer server.Close()
	manager := proton.New(proton.WithHostURL(server.URL), proton.WithRetryCount(0), proton.WithLogger(quietLogger{}))
	b := &ProtonBackend{manager: manager, client: manager.NewClient("f", "f", "f"), rings: map[string]*crypto.KeyRing{"address": oldRing}, session: savedSession{Email: "fixture@example.test", Salted: pass}, persistent: true}
	defer b.Close()
	current = newKey
	if err := b.reloadKeys(context.Background()); err != nil {
		t.Fatal("rotation reload failed")
	}
	encrypted, err := newRing.Encrypt(crypto.NewPlainMessageFromString("synthetic rotated body"), nil)
	if err != nil {
		t.Fatal(err)
	}
	plain, err := b.rings["address"].Decrypt(encrypted, nil, crypto.GetUnixTime())
	if err != nil || plain.GetString() != "synthetic rotated body" {
		t.Fatal("rotated key not installed")
	}
	if b.rings["address"] == oldRing {
		t.Fatal("stale key retained")
	}
}

func TestKeySchemaFailures(t *testing.T) {
	for _, tc := range []struct{ name, body, want string }{
		{"missing", `{"Code":1000,"User":{"Email":"fixture@example.test","Keys":[]}}`, "key_missing"},
		{"format", `{"Code":1000,"User":{"Email":"fixture@example.test","Keys":[{"ID":"f","Primary":1,"Active":1,"PrivateKey":"unrecognized private key format"}]}}`, "key_format"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "application/json")
				if r.URL.Path == "/core/v4/users" {
					w.Write([]byte(tc.body))
				} else {
					w.Write([]byte(`{"Code":1000,"Addresses":[]}`))
				}
			}))
			defer server.Close()
			manager := proton.New(proton.WithHostURL(server.URL), proton.WithRetryCount(0), proton.WithLogger(quietLogger{}))
			b := &ProtonBackend{manager: manager, client: manager.NewClient("f", "f", "f"), session: savedSession{Email: "fixture@example.test"}, persistent: true}
			defer b.Close()
			fault := classify(b.reloadKeys(context.Background()), "key")
			if fault == nil || fault.Code != tc.want || b.rings != nil {
				t.Fatal("key schema failed open or wrong error")
			}
		})
	}
}

// Generic HTTP/InvalidValue errors are deliberately NOT cursor-expiry evidence.
// Use the actual events endpoint so endpoint-specific handling cannot bypass classify.
func TestEventFailuresPreserveSpecificCodes(t *testing.T) {
	for _, status := range []int{400, 422} {
		for _, tc := range []struct {
			code int
			want string
		}{
			{5001, "api_version"}, {5003, "api_version"}, {9001, "human_verification_required"},
			{12087, "human_verification_required"}, {2001, "upstream"}, {2999, "upstream"},
		} {
			t.Run(fmt.Sprintf("http-%d-code-%d", status, tc.code), func(t *testing.T) {
				calls := 0
				server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					calls++
					if r.Method != "GET" || r.URL.Path != "/core/v4/events/old" {
						t.Error("wrong event endpoint")
					}
					w.Header().Set("Content-Type", "application/json")
					w.WriteHeader(status)
					json.NewEncoder(w).Encode(map[string]any{"Code": tc.code, "Error": "PRIVATE_DIAGNOSTIC", "Details": map[string]any{"EventID": "PRIVATE_CURSOR"}})
				}))
				defer server.Close()
				manager := proton.New(proton.WithHostURL(server.URL), proton.WithRetryCount(0), proton.WithLogger(quietLogger{}))
				b := &ProtonBackend{manager: manager, client: manager.NewClient("f", "f", "f"), rings: map[string]*crypto.KeyRing{}, persistent: true}
				defer b.Close()
				result, fault := b.Call(context.Background(), "events", json.RawMessage(`{"cursor":"old"}`))
				data, _ := json.Marshal(fault)
				if result != nil || fault == nil || fault.Code != tc.want || strings.Contains(string(data), "PRIVATE") || calls != 1 {
					t.Fatalf("incorrect events response: %s, calls=%d", data, calls)
				}
			})
		}
	}
}

func TestEventExplicitRefreshRequiresSnapshot(t *testing.T) {
	for _, refresh := range []int{0, 1, 2, 255} {
		t.Run(fmt.Sprintf("refresh-%d", refresh), func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path != "/core/v4/events/old" {
					t.Error("wrong event endpoint")
				}
				w.Header().Set("Content-Type", "application/json")
				json.NewEncoder(w).Encode(map[string]any{"Code": 1000, "EventID": "new", "Refresh": refresh})
			}))
			defer server.Close()
			manager := proton.New(proton.WithHostURL(server.URL), proton.WithRetryCount(0), proton.WithLogger(quietLogger{}))
			b := &ProtonBackend{manager: manager, client: manager.NewClient("f", "f", "f"), rings: map[string]*crypto.KeyRing{}, persistent: true}
			defer b.Close()
			result, fault := b.Call(context.Background(), "events", json.RawMessage(`{"cursor":"old"}`))
			if fault != nil {
				t.Fatal(fault)
			}
			data, _ := json.Marshal(result)
			var page struct {
				Cursor string
				Reset  bool
			}
			if json.Unmarshal(data, &page) != nil || page.Cursor != "new" || page.Reset != (refresh&1 != 0) {
				t.Fatalf("incorrect explicit refresh: %s", data)
			}
		})
	}
}
