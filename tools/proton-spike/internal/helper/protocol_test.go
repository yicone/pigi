package helper

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"strings"
	"testing"

	proton "github.com/ProtonMail/go-proton-api"
)

type fakeBackend struct {
	calls  int
	closed bool
}

func (b *fakeBackend) Call(context.Context, string, json.RawMessage) (any, *Fault) {
	b.calls++
	return nil, fail("credentials")
}
func (b *fakeBackend) Close() *Fault { b.closed = true; return nil }

func TestHandshakeAndRedaction(t *testing.T) {
	input := `{"version":1,"id":1,"method":"login","params":{}}
{"version":2,"id":2,"method":"hello","params":{}}
{"version":1,"id":3,"method":"hello","params":{}}
{"version":1,"id":4,"method":"login","params":{"password":"SENSITIVE-SENTINEL"}}
`
	b := new(fakeBackend)
	var out bytes.Buffer
	if err := Serve(strings.NewReader(input), &out, b); err != nil {
		t.Fatal(err)
	}
	if !b.closed || b.calls != 1 {
		t.Fatalf("state: %+v", b)
	}
	if strings.Contains(out.String(), "SENSITIVE") {
		t.Fatal("request leaked")
	}
	lines := strings.Split(strings.TrimSpace(out.String()), "\n")
	for i, code := range []string{"handshake_required", "unsupported_version", "", "credentials"} {
		var r Response
		if err := json.Unmarshal([]byte(lines[i]), &r); err != nil {
			t.Fatal(err)
		}
		if r.ID != uint64(i+1) || r.Version != 1 {
			t.Fatal("correlation")
		}
		if code != "" && (r.Error == nil || r.Error.Code != code) {
			t.Fatalf("wrong code %s", lines[i])
		}
		if code == "" && (r.Error != nil || r.Result == nil) {
			t.Fatal("missing hello")
		}
	}
}

func TestInvalidFramesFailClosed(t *testing.T) {
	for _, input := range []string{`{"version":1,"id":1,"method":"hello","extra":"secret"}` + "\n", "secret\n", strings.Repeat("x", MaxFrame+2) + "\n", `{"version":1,"id":0,"method":"hello"}` + "\n", `{} {}` + "\n"} {
		b := new(fakeBackend)
		var out bytes.Buffer
		_ = Serve(strings.NewReader(input), &out, b)
		if !b.closed || b.calls != 0 {
			t.Fatal("malformed input reached backend")
		}
		if strings.Contains(out.String(), "secret") || out.Len() > 150 {
			t.Fatal("unbounded or sensitive diagnostic")
		}
	}
}

type hugeBackend struct{ fakeBackend }

func (*hugeBackend) Call(context.Context, string, json.RawMessage) (any, *Fault) {
	return strings.Repeat("x", MaxFrame), nil
}
func TestOversizedResponse(t *testing.T) {
	var out bytes.Buffer
	_ = Serve(strings.NewReader("{\"version\":1,\"id\":1,\"method\":\"hello\",\"params\":{}}\n{\"version\":1,\"id\":2,\"method\":\"list\",\"params\":{}}\n"), &out, new(hugeBackend))
	if !strings.Contains(out.String(), "frame_too_large") || out.Len() > 1024 {
		t.Fatal("response limit failed")
	}
}

func TestErrorTaxonomy(t *testing.T) {
	cases := []struct {
		err            error
		fallback, code string
	}{
		{&proton.APIError{Code: proton.PasswordWrong, Message: "secret"}, "upstream", "credentials"},
		{&proton.APIError{Code: proton.HumanVerificationRequired, Details: []byte(`{"token":"secret"}`)}, "upstream", "human_verification_required"},
		{&proton.APIError{Status: 429}, "upstream", "rate_limited"},
		{&proton.APIError{Status: 503}, "key", "network"},
		{&net.DNSError{Err: "secret"}, "upstream", "network"},
		{context.DeadlineExceeded, "upstream", "timeout"},
		{errors.New("secret private key"), "key", "key"},
		{errors.New("secret"), "upstream", "upstream"},
	}
	for _, c := range cases {
		if f := classify(c.err, c.fallback); f.Code != c.code {
			t.Errorf("got %s want %s", f.Code, c.code)
		}
	}
}

func TestUnauthenticatedBackendAndValidation(t *testing.T) {
	b := NewBackend()
	defer b.Close()
	for _, c := range []struct{ method, params, code string }{
		{"login", `{"username":"","password":""}`, "invalid_params"},
		{"list", `{"page":0,"limit":101}`, "invalid_params"},
		{"list", `{"page":0,"limit":5}`, "not_authenticated"},
		{"decrypt", `{"id":"synthetic"}`, "not_authenticated"},
		{"decrypt", `{"id":""}`, "invalid_params"},
		{"send", `{}`, "unknown_method"},
		{"logout", `{"extra":1}`, "invalid_params"},
	} {
		_, f := b.Call(context.Background(), c.method, json.RawMessage(c.params))
		if f == nil || f.Code != c.code {
			t.Errorf("%s got %v", c.method, f)
		}
	}
	if _, f := b.Call(context.Background(), "logout", json.RawMessage(`{}`)); f != nil {
		t.Fatal(f)
	}
	if err := Serve(strings.NewReader(""), io.Discard, new(fakeBackend)); err != nil {
		t.Fatal(err)
	}
}
