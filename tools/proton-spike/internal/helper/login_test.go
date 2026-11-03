package helper

import (
	"context"
	"encoding/json"
	proton "github.com/ProtonMail/go-proton-api"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestInteractiveHVContinuationAndCancellation(t *testing.T) {
	b := NewBackend()
	defer b.Close()
	attempts := 0
	b.loginAttempt = func(ctx context.Context, user string, pass []byte, hv *proton.APIHVDetails) (*proton.Client, proton.Auth, error) {
		attempts++
		if user != "synthetic" || string(pass) != "synthetic-password" {
			t.Fatal("lost login context")
		}
		if hv != nil && hv.Token != "bound:answer" {
			t.Fatal("unbound response")
		}
		return nil, proton.Auth{}, &proton.APIError{Code: proton.HumanVerificationRequired, Details: proton.ErrDetails(`{"HumanVerificationToken":"bound","HumanVerificationMethods":["captcha"],"WebUrl":"https://verify.proton.me/?token=bound&methods=email,captcha"}`)}
	}
	step, f := b.Call(context.Background(), "begin_login", json.RawMessage(`{"username":"synthetic","password":"synthetic-password"}`))
	if f != nil || step.(loginStep).Stage != "captcha" {
		t.Fatalf("verification flattened to error: %v", f)
	}
	for _, answer := range []string{"foreign:answer", "bound:", ""} {
		p, _ := json.Marshal(map[string]string{"response": answer})
		if _, f = b.Call(context.Background(), "continue_login", p); f == nil || f.Code != "invalid_params" {
			t.Fatal("invalid binding accepted")
		}
	}
	if attempts != 1 {
		t.Fatal("invalid response contacted server")
	}
	if _, f = b.Call(context.Background(), "continue_login", json.RawMessage(`{"response":"bound:answer"}`)); f != nil || attempts != 2 {
		t.Fatal("continuation missing")
	}
	secret := b.pending.password
	if _, f = b.Call(context.Background(), "logout", json.RawMessage(`{}`)); f != nil || b.pending != nil {
		t.Fatal("cancel did not clear login")
	}
	for _, v := range secret {
		if v != 0 {
			t.Fatal("password not cleared")
		}
	}
	if _, f = b.Call(context.Background(), "begin_login", json.RawMessage(`{"username":"synthetic","password":"synthetic-password"}`)); f != nil {
		t.Fatal("cancel prevents restart")
	}
	b.pending.deadline = time.Now().Add(-time.Second)
	if _, f = b.Call(context.Background(), "continue_login", json.RawMessage(`{"response":"bound:answer"}`)); f == nil || f.Code != "login_expired" || b.pending != nil {
		t.Fatal("expired login continued")
	}
}
func TestVerificationURLRejectsUntrustedAndPreservesServerURL(t *testing.T) {
	good := "https://verify.proton.me/?token=bound&methods=email,captcha"
	if got, ok := verificationURL(good, "bound"); !ok || got != good {
		t.Fatal("official URL changed")
	}
	for _, raw := range []string{"http://verify.proton.me/?token=bound&methods=captcha", "https://verify.proton.me.evil.test/?token=bound&methods=captcha", "https://verify.proton.me:443/?token=bound&methods=captcha", "https://x@verify.proton.me/?token=bound&methods=captcha", "https://verify.proton.me/?token=foreign&methods=captcha", "https://verify.proton.me/?token=bound&token=bound&methods=captcha", "https://verify.proton.me/?token=bound&methods=captcha&methods=captcha", "https://verify.proton.me/?token=bound&methods=captcha#fragment"} {
		if _, ok := verificationURL(raw, "bound"); ok {
			t.Fatal("unsafe URL accepted")
		}
	}
}
func TestInteractiveTOTPAndMailboxRetry(t *testing.T) {
	calls := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.Method == "DELETE" {
			w.Write([]byte(`{"Code":1000}`))
			return
		}
		calls++
		if calls == 1 {
			w.WriteHeader(422)
			w.Write([]byte(`{"Code":8002}`))
			return
		}
		w.Write([]byte(`{"Code":1000}`))
	}))
	defer server.Close()
	m := proton.New(proton.WithHostURL(server.URL), proton.WithRetryCount(0), proton.WithLogger(quietLogger{}))
	b := &ProtonBackend{manager: m, client: m.NewClient("synthetic", "synthetic", "synthetic"), pending: &pendingLogin{stage: "totp", password: []byte("synthetic"), deadline: time.Now().Add(time.Minute)}}
	defer b.Close()
	b.pending.auth.PasswordMode = proton.TwoPasswordMode
	if _, f := b.Call(context.Background(), "continue_login", json.RawMessage(`{"response":"123456"}`)); f == nil || b.pending.stage != "totp" {
		t.Fatal("wrong TOTP lost session")
	}
	step, f := b.Call(context.Background(), "continue_login", json.RawMessage(`{"response":"654321"}`))
	if f != nil || step.(loginStep).Stage != "mailbox" {
		t.Fatal("TOTP retry missing mailbox stage")
	}
	for _, v := range b.pending.password {
		if v != 0 {
			t.Fatal("login password retained")
		}
	}
	if _, f = b.Call(context.Background(), "continue_login", json.RawMessage(`{"response":""}`)); f == nil || b.pending.stage != "mailbox" {
		t.Fatal("invalid mailbox consumed session")
	}
}
