package helper

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	proton "github.com/ProtonMail/go-proton-api"
	"github.com/ProtonMail/gopenpgp/v2/crypto"
)

func TestReadDecryptAndCleanup(t *testing.T) {
	key, err := crypto.GenerateKey("fixture", "fixture@example.test", "x25519", 0)
	if err != nil {
		t.Fatal(err)
	}
	ring, err := crypto.NewKeyRing(key)
	if err != nil {
		t.Fatal(err)
	}
	encrypted, err := ring.Encrypt(crypto.NewPlainMessageFromString("synthetic plaintext"), nil)
	if err != nil {
		t.Fatal(err)
	}
	armor, err := encrypted.GetArmored()
	if err != nil {
		t.Fatal(err)
	}
	otherKey, err := crypto.GenerateKey("other", "other@example.test", "x25519", 0)
	if err != nil {
		t.Fatal(err)
	}
	otherRing, err := crypto.NewKeyRing(otherKey)
	if err != nil {
		t.Fatal(err)
	}
	otherEncrypted, err := otherRing.Encrypt(crypto.NewPlainMessageFromString("synthetic other key"), nil)
	if err != nil {
		t.Fatal(err)
	}
	otherArmor, err := otherEncrypted.GetArmored()
	if err != nil {
		t.Fatal(err)
	}
	defer otherRing.ClearPrivateParams()
	body, address := "", "address"
	revokeFails := true
	service := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch {
		case r.URL.Path == "/mail/v4/messages" && r.Method == "POST":
			if r.Header.Get("X-HTTP-Method-Override") != "GET" {
				t.Error("not a readonly list")
			}
			_ = json.NewEncoder(w).Encode(map[string]any{"Code": 1000, "Stale": 0, "Messages": []map[string]any{{"ID": "synthetic-id", "Subject": "synthetic subject", "Time": 123, "Unread": 1}}})
		case r.URL.Path == "/mail/v4/messages/synthetic-id" && r.Method == "GET":
			_ = json.NewEncoder(w).Encode(map[string]any{"Code": 1000, "Message": map[string]any{"ID": "synthetic-id", "AddressID": address, "Body": body, "MIMEType": "text/plain"}})
		case r.URL.Path == "/auth/v4" && r.Method == "DELETE":
			if revokeFails {
				w.WriteHeader(503)
				_, _ = w.Write([]byte(`{"Code":5000,"Error":"synthetic sensitive diagnostic"}`))
				return
			}
			_, _ = w.Write([]byte(`{"Code":1000}`))
		default:
			t.Errorf("unexpected request %s %s", r.Method, r.URL.Path)
			w.WriteHeader(400)
		}
	}))
	defer service.Close()
	m := proton.New(proton.WithHostURL(service.URL), proton.WithRetryCount(0), proton.WithLogger(quietLogger{}))
	b := &ProtonBackend{manager: m, client: m.NewClient("synthetic", "synthetic", "synthetic"), rings: map[string]*crypto.KeyRing{"address": ring}}
	defer b.Close()
	ctx := context.Background()
	rows, f := b.Call(ctx, "list", json.RawMessage(`{"page":0,"limit":5}`))
	if f != nil {
		t.Fatal(f)
	}
	encoded, _ := json.Marshal(rows)
	if string(encoded) != `[{"id":"synthetic-id","subject":"synthetic subject","time":123,"unread":true}]` {
		t.Fatalf("unstable metadata schema: %s", encoded)
	}
	for _, c := range []struct{ body, address, code string }{
		{armor, "address", ""},
		{armor, "missing", "key_missing"},
		{otherArmor, "address", "key_decryption"},
		{"server plaintext", "address", "key_format"},
		{"-----BEGIN PGP MESSAGE-----\ncorrupt", "address", "key_format"},
	} {
		body, address = c.body, c.address
		result, f := b.Call(ctx, "decrypt", json.RawMessage(`{"id":"synthetic-id"}`))
		if c.code != "" {
			if f == nil || f.Code != c.code {
				t.Fatalf("expected key error, got %v", f)
			}
			continue
		}
		if f != nil {
			t.Fatal(f)
		}
		decoded := result.(map[string]string)
		if decoded["body"] != "synthetic plaintext" || decoded["mime_type"] != "text/plain" || decoded["signature_status"] != "unverified" {
			t.Fatal("wrong plaintext")
		}
	}
	_, f = b.Call(ctx, "logout", json.RawMessage(`{}`))
	if f == nil || f.Code != "cleanup_failed" || b.client == nil || b.rings != nil {
		t.Fatal("failed revoke must retain retryable client and clear keys")
	}
	_, f = b.Call(ctx, "list", json.RawMessage(`{"page":0,"limit":5}`))
	if f == nil || f.Code != "not_authenticated" {
		t.Fatal("use after failed cleanup")
	}
	revokeFails = false
	if _, f = b.Call(ctx, "logout", json.RawMessage(`{}`)); f != nil || b.client != nil {
		t.Fatal("cleanup retry failed")
	}
}
