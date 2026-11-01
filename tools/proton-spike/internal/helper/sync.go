package helper

import (
	"context"
	"encoding/json"
	"errors"
	"strings"

	"github.com/ProtonMail/gluon/async"
	proton "github.com/ProtonMail/go-proton-api"
)

// All fields are secrets except Email. Never log or write this outside Keychain.
type savedSession struct {
	UID     string `json:"uid"`
	Access  string `json:"access"`
	Refresh string `json:"refresh"`
	Salted  []byte `json:"salted"`
	Email   string `json:"email"`
}

func (b *ProtonBackend) trackAuth() {
	b.client.AddAuthHandler(func(a proton.Auth) {
		if a.UID != "" {
			b.session.UID = a.UID
		}
		b.session.Access, b.session.Refresh = a.AccessToken, a.RefreshToken
	})
}

func (b *ProtonBackend) reloadKeys(ctx context.Context) error {
	user, err := b.client.GetUser(ctx)
	if err != nil {
		return err
	}
	if !strings.EqualFold(user.Email, b.session.Email) {
		return errors.New("account_mismatch")
	}
	addresses, err := b.client.GetAddresses(ctx)
	if err != nil {
		return err
	}
	userKR, rings, err := proton.Unlock(user, addresses, b.session.Salted, async.NoopPanicHandler{})
	if userKR != nil {
		userKR.ClearPrivateParams()
	}
	if err != nil {
		for _, ring := range rings {
			ring.ClearPrivateParams()
		}
		return err
	}
	for _, ring := range b.rings {
		ring.ClearPrivateParams()
	}
	b.rings = rings
	return nil
}

type syncMetadata struct {
	ID          string   `json:"id"`
	Subject     string   `json:"subject"`
	Time        int64    `json:"time"`
	Unread      bool     `json:"unread"`
	SenderName  string   `json:"sender_name"`
	SenderEmail string   `json:"sender_email"`
	Labels      []string `json:"labels"`
	Size        int      `json:"size"`
}

func metadata(r proton.MessageMetadata) syncMetadata {
	m := syncMetadata{ID: r.ID, Subject: r.Subject, Time: r.Time, Unread: bool(r.Unread), Labels: r.LabelIDs, Size: r.Size}
	if m.Labels == nil {
		m.Labels = []string{}
	}
	if r.Sender != nil {
		m.SenderName, m.SenderEmail = r.Sender.Name, r.Sender.Address
	}
	return m
}

type syncLabel struct {
	ID     string `json:"id"`
	Name   string `json:"name"`
	Parent string `json:"parent"`
	Type   int    `json:"type"`
}

type syncChange struct {
	ID      string `json:"id"`
	Deleted bool   `json:"deleted"`
}

func validID(id string) bool {
	return id != "" && len(id) <= 1024 && !strings.ContainsAny(id, "/?#\\\r\n") && id != "." && id != ".."
}

func (b *ProtonBackend) syncCall(ctx context.Context, method string, raw json.RawMessage) (any, *Fault) {
	if method == "resume" {
		if b.client != nil {
			return nil, fail("already_authenticated")
		}
		var s savedSession
		if !Decode(raw, &s) || s.UID == "" || s.Access == "" || s.Refresh == "" || len(s.Salted) == 0 || !strings.Contains(s.Email, "@") {
			return nil, fail("invalid_params")
		}
		b.session = s
		// Reuse access first: an automatic refresh is captured and exported even if
		// subsequent key loading fails. This avoids consuming refresh tokens twice.
		b.client = b.manager.NewClient(s.UID, s.Access, s.Refresh)
		b.trackAuth()
		b.persistent = true
		if err := b.reloadKeys(ctx); err != nil {
			return nil, classify(err, "key")
		}
		return map[string]bool{"authenticated": true}, nil
	}
	if b.client == nil {
		return nil, fail("not_authenticated")
	}
	if method == "session" {
		if !Decode(raw, new(struct{})) {
			return nil, fail("invalid_params")
		}
		if b.session.Email == "" {
			user, err := b.client.GetUser(ctx)
			if err != nil {
				return nil, classify(err, "upstream")
			}
			b.session.Email = strings.ToLower(user.Email)
		}
		b.persistent = true
		return b.session, nil
	}
	if b.rings == nil {
		return nil, fail("not_authenticated")
	}
	switch method {
	case "latest":
		if !Decode(raw, new(struct{})) {
			return nil, fail("invalid_params")
		}
		id, err := b.client.GetLatestEventID(ctx)
		if err != nil {
			return nil, classify(err, "upstream")
		}
		return map[string]string{"cursor": id}, nil
	case "labels":
		if !Decode(raw, new(struct{})) {
			return nil, fail("invalid_params")
		}
		labels, err := b.client.GetLabels(ctx, proton.LabelTypeLabel, proton.LabelTypeFolder)
		if err != nil {
			return nil, classify(err, "upstream")
		}
		result := make([]syncLabel, 0, len(labels))
		for _, l := range labels {
			result = append(result, syncLabel{l.ID, l.Name, l.ParentID, int(l.Type)})
		}
		return result, nil
	case "snapshot":
		var p struct {
			After string `json:"after"`
			Limit int    `json:"limit"`
		}
		if !Decode(raw, &p) || (p.After != "" && !validID(p.After)) || p.Limit < 1 || p.Limit > 100 {
			return nil, fail("invalid_params")
		}
		ids, err := b.client.GetMessageIDs(ctx, p.After, p.Limit)
		if err != nil {
			return nil, classify(err, "upstream")
		}
		if ids == nil {
			ids = []string{}
		}
		return ids, nil
	case "metadata":
		var p struct {
			ID string `json:"id"`
		}
		if !Decode(raw, &p) || !validID(p.ID) {
			return nil, fail("invalid_params")
		}
		msg, err := b.client.GetMessage(ctx, p.ID)
		if err != nil {
			return nil, classify(err, "upstream")
		}
		return metadata(msg.MessageMetadata), nil
	case "events":
		var p struct {
			Cursor string `json:"cursor"`
		}
		if !Decode(raw, &p) || !validID(p.Cursor) {
			return nil, fail("invalid_params")
		}
		events, more, err := b.client.GetEvent(ctx, p.Cursor)
		if err != nil {
			var api *proton.APIError
			if errors.As(err, &api) && (api.Status == 400 || api.Status == 422) {
				return nil, fail("cursor_expired")
			}
			return nil, classify(err, "upstream")
		}
		changes := []syncChange{}
		newest := p.Cursor
		reset := false
		keysChanged := false
		for _, e := range events {
			if e.EventID != "" {
				newest = e.EventID
			}
			if e.Refresh&proton.RefreshMail != 0 {
				reset = true
			}
			if len(e.Addresses) > 0 || e.User != nil {
				keysChanged = true
			}
			for _, m := range e.Messages {
				changes = append(changes, syncChange{m.ID, m.Action == proton.EventDelete})
			}
		}
		if keysChanged {
			if err := b.reloadKeys(ctx); err != nil {
				return nil, classify(err, "key")
			}
		}
		return struct {
			Cursor  string       `json:"cursor"`
			More    bool         `json:"more"`
			Reset   bool         `json:"reset"`
			Changes []syncChange `json:"changes"`
		}{newest, more, reset, changes}, nil
	}
	return nil, fail("unknown_method")
}
