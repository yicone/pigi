package helper

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	proton "github.com/ProtonMail/go-proton-api"
	"github.com/ProtonMail/gopenpgp/v2/crypto"
)

func TestSyncReadOnlyMappingAndSessionRefresh(t *testing.T) {
	var revoked, refreshed bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/mail/v4/messages/ids":
			if r.Method != "GET" || r.URL.Query().Get("AfterID") != "previous" || r.URL.Query().Get("Limit") != "25" {
				t.Error("unstable snapshot paging")
			}
			_, _ = w.Write([]byte(`{"Code":1000,"IDs":["one","two"]}`))
		case "/mail/v4/messages/one":
			if r.Method != "GET" {
				t.Error("message fetch mutated state")
			}
			_, _ = w.Write([]byte(`{"Code":1000,"Message":{"ID":"one","AddressID":"address","Subject":"Fixture","Time":123,"Unread":1,"Sender":{"Name":"Sender","Address":"sender@example.test"},"LabelIDs":["0","5","custom"],"Size":42}}`))
		case "/core/v4/labels":
			if r.Method != "GET" {
				t.Error("labels mutated state")
			}
			id := "custom"
			if r.URL.Query().Get("Type") == "3" {
				id = "folder"
			}
			_ = json.NewEncoder(w).Encode(map[string]any{"Code": 1000, "Labels": []map[string]any{{"ID": id, "Name": id, "Type": 3, "ParentID": "parent"}}})
		case "/core/v4/events/latest":
			_, _ = w.Write([]byte(`{"Code":1000,"EventID":"c0"}`))
		case "/core/v4/events/c0":
			if !refreshed {
				w.WriteHeader(401)
				_, _ = w.Write([]byte(`{"Code":401,"Error":"private diagnostic"}`))
				return
			}
			_, _ = w.Write([]byte(`{"Code":1000,"EventID":"c1","More":1,"Messages":[{"ID":"one","Action":2},{"ID":"two","Action":0}]}`))
		case "/core/v4/events/c1":
			_, _ = w.Write([]byte(`{"Code":1000,"EventID":"c2","More":0,"Refresh":1,"Messages":[{"ID":"two","Action":1}]}`))
		case "/core/v4/events/expired":
			w.WriteHeader(400)
			_, _ = w.Write([]byte(`{"Code":2001,"Error":"private cursor diagnostic"}`))
		case "/auth/v4/refresh":
			if r.Method != "POST" {
				t.Error("wrong refresh method")
			}
			refreshed = true
			_, _ = w.Write([]byte(`{"Code":1000,"UID":"uid","AccessToken":"new-access","RefreshToken":"new-refresh"}`))
		case "/auth/v4":
			if r.Method != "DELETE" {
				t.Error("unexpected auth mutation")
			}
			revoked = true
			_, _ = w.Write([]byte(`{"Code":1000}`))
		default:
			t.Errorf("unexpected network mutation/path %s %s", r.Method, r.URL.Path)
			w.WriteHeader(400)
		}
	}))
	defer server.Close()
	m := proton.New(proton.WithHostURL(server.URL), proton.WithRetryCount(0), proton.WithLogger(quietLogger{}))
	b := &ProtonBackend{manager: m, client: m.NewClient("uid", "old-access", "old-refresh"), rings: map[string]*crypto.KeyRing{}, session: savedSession{UID: "uid", Access: "old-access", Refresh: "old-refresh", Salted: []byte("derived-fixture"), Email: "fixture@example.test"}}
	b.trackAuth()
	ctx := context.Background()
	call := func(method, params string) any {
		t.Helper()
		result, f := b.Call(ctx, method, json.RawMessage(params))
		if f != nil {
			t.Fatal(f)
		}
		return result
	}
	if got, _ := json.Marshal(call("snapshot", `{"after":"previous","limit":25}`)); string(got) != `["one","two"]` {
		t.Fatal(string(got))
	}
	meta := call("metadata", `{"id":"one"}`).(syncMetadata)
	if !meta.Unread || meta.SenderEmail != "sender@example.test" || len(meta.Labels) != 3 || meta.Time != 123 {
		t.Fatal("metadata mapping")
	}
	labels := call("labels", `{}`).([]syncLabel)
	if len(labels) != 2 || labels[0].ID != "custom" || labels[1].ID != "folder" || labels[1].Parent != "parent" {
		t.Fatal("label mapping")
	}
	call("latest", `{}`)
	events := call("events", `{"cursor":"c0"}`)
	data, _ := json.Marshal(events)
	if !strings.Contains(string(data), `"cursor":"c2"`) || !strings.Contains(string(data), `"reset":true`) || !strings.Contains(string(data), `"deleted":true`) {
		t.Fatal(string(data))
	}
	_, f := b.Call(ctx, "events", json.RawMessage(`{"cursor":"expired"}`))
	if f == nil || f.Code != "cursor_expired" {
		t.Fatal("expired cursor did not trigger resnapshot")
	}
	secret := call("session", `{}`).(savedSession)
	if secret.Access != "new-access" || secret.Refresh != "new-refresh" || !b.persistent {
		t.Fatal("refreshed session not exported")
	}
	if f := b.Close(); f != nil {
		t.Fatal(f)
	}
	if revoked || b.rings != nil || b.client != nil || len(b.session.Salted) != 0 {
		t.Fatal("persistent close must clear memory without revoking")
	}
}

func TestSyncValidation(t *testing.T) {
	b := NewBackend()
	defer b.Close()
	for _, c := range []struct{ method, params, code string }{
		{"resume", `{"uid":"uid","access":"secret","refresh":"secret","salted":"eA==","email":"invalid"}`, "invalid_params"},
		{"events", `{"cursor":"x"}`, "not_authenticated"},
		{"snapshot", `{"after":"x","limit":5}`, "not_authenticated"},
		{"session", `{}`, "not_authenticated"},
	} {
		_, f := b.Call(context.Background(), c.method, json.RawMessage(c.params))
		if f == nil || f.Code != c.code {
			t.Fatalf("%s: %v", c.method, f)
		}
	}
	for _, id := range []string{"", "../auth", "a?x=y", "a/b", "a#b", ".."} {
		if validID(id) {
			t.Fatalf("unsafe id %q", id)
		}
	}
}
