package main

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	proton "github.com/ProtonMail/go-proton-api"
	"github.com/ProtonMail/gopenpgp/v2/crypto"
)

func TestVerificationURLRequiresProtonOriginAndChallenge(t *testing.T) {
	for _, raw := range []string{
		"", "http://verify.proton.me/?methods=captcha&token=test-challenge",
		"https://verify.proton.me.evil.test/?methods=captcha&token=test-challenge",
		"https://user@verify.proton.me/?methods=captcha&token=test-challenge",
		"https://verify.proton.me:443/?methods=captcha&token=test-challenge",
		"https://verify.proton.me/?methods=captcha&token=other",
		"https://verify.proton.me/?methods=captcha&token=test-challenge&token=other",
		"https://verify.proton.me/?methods=payment&token=test-challenge",
		"https://verify.proton.me/other?methods=captcha&token=test-challenge",
		"https://verify.proton.me/?methods=captcha&token=test-challenge#fragment",
	} {
		if _, err := captchaPageURL(raw, "test-challenge"); err == nil {
			t.Fatal("accepted untrusted verification URL")
		}
	}
	value, err := captchaPageURL("https://verify.proton.me/?methods=captcha,email&token=test-challenge", "test-challenge")
	if err != nil {
		t.Fatal(err)
	}
	u, _ := url.Parse(value)
	if u.Query().Get("embed") != "1" || u.Query().Get("methods") != "captcha" || u.Query().Get("token") != "test-challenge" {
		t.Fatal("lost embedded flow or challenge binding")
	}
}

func TestCaptchaDiagnosticsRedactsUntrustedOutput(t *testing.T) {
	var output bytes.Buffer
	report := evidence{}
	sink := captchaDiagnostics{report: &report, output: &output}
	for _, part := range []string{"private-token-and-url\nPROTON_SPIKE:page_", "loaded\nPROTON_SPIKE:http_status:200\n", "PROTON_SPIKE:http_status:secret\nPROTON_SPIKE:callback_received\n", "PROTON_SPIKE:navigation_failed\nPROTON_SPIKE:timeout\nPROTON_SPIKE:widget_loaded\nPROTON_SPIKE:widget_error\n"} {
		_, _ = sink.Write([]byte(part))
	}
	if !report.CaptchaLoaded || report.CaptchaHTTP != 200 || !report.CaptchaCallback || !report.CaptchaFailed || !report.CaptchaTimeout || !report.CaptchaWidgetLoaded || !report.CaptchaWidgetError {
		t.Fatal("lost diagnostic state")
	}
	if strings.Contains(output.String(), "private-token") || strings.Contains(output.String(), "secret") {
		t.Fatal("untrusted child output was exposed")
	}
}

func TestCaptchaChallengeBinding(t *testing.T) {
	for _, response := range []string{"", "challenge:", "unrelated:solution"} {
		if _, err := captchaResponse("challenge", []byte(response)); err == nil {
			t.Fatal("accepted an unbound or empty challenge response")
		}
	}
	value, err := captchaResponse("challenge", []byte("challenge:human-solved-response"))
	if err != nil || value.Token != "challenge:human-solved-response" || len(value.Methods) != 1 || value.Methods[0] != "captcha" {
		t.Fatal("lost the original challenge binding")
	}
}

func TestThirdPartyClientIdentity(t *testing.T) {
	service := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("x-pm-appversion") != "Other" || r.Header.Get("User-Agent") != "pigi-proton-spike/0.1.0" {
			t.Error("missing third-party category or actual client identity")
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"Code":1000}`))
	}))
	defer service.Close()
	m := proton.New(proton.WithHostURL(service.URL), proton.WithAppVersion("Other"),
		proton.WithTransport(identifiedTransport{http.DefaultTransport}), proton.WithRetryCount(0))
	defer m.Close()
	if _, err := m.AuthInfo(context.Background(), proton.AuthInfoReq{Username: "fixture"}); err != nil {
		t.Fatal(err)
	}
}

// Real OpenPGP ciphertext, generated in memory. Only the HTTP service is fake.
func TestReadOne(t *testing.T) {
	key, err := crypto.GenerateKey("fixture", "fixture@example.test", "x25519", 0)
	if err != nil {
		t.Fatal(err)
	}
	ring, err := crypto.NewKeyRing(key)
	if err != nil {
		t.Fatal(err)
	}
	defer ring.ClearPrivateParams()
	expected := "ACM-769 本机测试正文"
	encrypted, err := ring.Encrypt(crypto.NewPlainMessageFromString(expected), nil)
	if err != nil {
		t.Fatal(err)
	}
	armored, err := encrypted.GetArmored()
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name, body, address, wantError string
		empty                          bool
	}{
		{name: "decrypt", body: armored, address: "address"},
		{name: "wrong_address", body: armored, address: "other", wantError: "missing_address_key"},
		{name: "server_plaintext_rejected", body: expected, address: "address", wantError: "body_not_armored_ciphertext"},
		{name: "corrupt_ciphertext", body: "-----BEGIN PGP MESSAGE-----\ninvalid", address: "address", wantError: "decryption_failed"},
		{name: "empty_inbox", empty: true, wantError: "empty_inbox"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			service := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "application/json")
				switch {
				case r.URL.Path == "/mail/v4/messages" && r.Method == "POST":
					if r.Header.Get("X-HTTP-Method-Override") != "GET" {
						t.Error("missing read-only override")
					}
					var filter map[string]interface{}
					if err := json.NewDecoder(r.Body).Decode(&filter); err != nil {
						t.Error(err)
					}
					if filter["LabelID"] != "0" || filter["PageSize"] != float64(5) {
						t.Error("unbounded or wrong mailbox filter")
					}
					rows := []map[string]interface{}{}
					if !tc.empty {
						rows = append(rows, map[string]interface{}{"ID": "message", "AddressID": tc.address})
					}
					_ = json.NewEncoder(w).Encode(map[string]interface{}{"Code": 1000, "Stale": 0, "Messages": rows})
				case r.URL.Path == "/mail/v4/messages/message" && r.Method == "GET":
					_ = json.NewEncoder(w).Encode(map[string]interface{}{"Code": 1000, "Message": map[string]interface{}{"ID": "message", "AddressID": tc.address, "Body": tc.body}})
				default:
					t.Errorf("unexpected request %s %s", r.Method, r.URL.Path)
					w.WriteHeader(http.StatusBadRequest)
				}
			}))
			defer service.Close()
			m := proton.New(proton.WithHostURL(service.URL), proton.WithRetryCount(0), proton.WithLogger(quietLogger{}))
			defer m.Close()
			c := m.NewClient("fixture", "fixture", "fixture")
			defer c.Close()
			report := evidence{}
			plaintext, err := readOne(context.Background(), c, map[string]*crypto.KeyRing{"address": ring}, &report)
			if tc.wantError != "" {
				if err == nil || err.Error() != tc.wantError {
					t.Fatalf("expected %s, got %v", tc.wantError, err)
				}
				if len(plaintext) != 0 {
					t.Fatal("failure returned plaintext")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if string(plaintext) != expected || report.PlainBytes != len(expected) || !report.UTF8 || !report.Ciphertext {
				t.Fatal("incorrect decryption evidence")
			}
			encoded, err := json.Marshal(report)
			if err != nil {
				t.Fatal(err)
			}
			for _, private := range []string{expected, armored, "example.test"} {
				if strings.Contains(string(encoded), private) {
					t.Fatal("private content leaked into evidence")
				}
			}
		})
	}
}
