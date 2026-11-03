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

func TestDecryptSignatureStatus(t *testing.T) {
	makeRing := func() *crypto.KeyRing {
		t.Helper()
		key, err := crypto.GenerateKey("fixture", "sender@example.test", "x25519", 0)
		if err != nil {
			t.Fatal(err)
		}
		ring, err := crypto.NewKeyRing(key)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(ring.ClearPrivateParams)
		return ring
	}
	recipient, sender, other := makeRing(), makeRing(), makeRing()
	for _, tc := range []struct {
		name, want    string
		signer, key   *crypto.KeyRing
		flags         proton.KeyState
		lookupFailure bool
	}{
		{"valid", "verified", sender, sender, proton.KeyStateTrusted, false},
		{"wrong-signer", "failed", other, sender, proton.KeyStateTrusted, false},
		{"unsigned", "unverified", nil, sender, proton.KeyStateTrusted, false},
		{"missing-key", "unverified", sender, nil, 0, false},
		{"compromised-key", "unverified", sender, sender, 0, false},
		{"lookup-error", "unverified", sender, sender, proton.KeyStateTrusted, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			encrypted, err := recipient.Encrypt(crypto.NewPlainMessageFromString("synthetic body"), tc.signer)
			if err != nil {
				t.Fatal(err)
			}
			armor, err := encrypted.GetArmored()
			if err != nil {
				t.Fatal(err)
			}
			keyCalls := 0
			service := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "application/json")
				if r.Method != "GET" {
					t.Errorf("write request: %s", r.Method)
				}
				switch r.URL.Path {
				case "/mail/v4/messages/synthetic-id":
					json.NewEncoder(w).Encode(map[string]any{"Code": 1000, "Message": map[string]any{"ID": "synthetic-id", "AddressID": "address", "Sender": map[string]string{"Address": "sender@example.test"}, "Body": armor, "MIMEType": "text/plain"}})
				case "/core/v4/keys":
					keyCalls++
					if r.URL.Query().Get("Email") != "sender@example.test" {
						t.Error("wrong sender lookup")
					}
					if tc.lookupFailure {
						w.WriteHeader(503)
						w.Write([]byte(`{"Code":5000}`))
						return
					}
					keys := proton.PublicKeys{}
					if tc.key != nil {
						public, err := tc.key.GetKey(0)
						if err != nil {
							t.Fatal(err)
						}
						armored, err := public.GetArmoredPublicKey()
						if err != nil {
							t.Fatal(err)
						}
						keys = append(keys, proton.PublicKey{Flags: tc.flags, PublicKey: armored})
					}
					json.NewEncoder(w).Encode(map[string]any{"Code": 1000, "Keys": keys})
				default:
					t.Errorf("unexpected endpoint %s", r.URL.Path)
					w.WriteHeader(404)
				}
			}))
			defer service.Close()
			manager := proton.New(proton.WithHostURL(service.URL), proton.WithRetryCount(0), proton.WithLogger(quietLogger{}))
			b := &ProtonBackend{manager: manager, client: manager.NewClient("f", "f", "f"), rings: map[string]*crypto.KeyRing{"address": recipient}, persistent: true}
			// Avoid clearing the shared fixture's recipient between cases.
			defer func() { b.rings = nil; b.Close() }()
			result, fault := b.Call(context.Background(), "decrypt", json.RawMessage(`{"id":"synthetic-id"}`))
			if fault != nil {
				t.Fatal(fault)
			}
			got := result.(map[string]string)
			if got["signature_status"] != tc.want || got["body"] != "synthetic body" || keyCalls != 1 {
				t.Fatalf("status=%s want=%s calls=%d", got["signature_status"], tc.want, keyCalls)
			}
		})
	}
}
