package helper

import (
	"context"
	"encoding/json"
	"errors"
	"net/url"
	"slices"
	"strings"
	"time"

	proton "github.com/ProtonMail/go-proton-api"
)

type loginStep struct {
	Stage     string `json:"stage"`
	WebURL    string `json:"web_url,omitempty"`
	Challenge string `json:"challenge,omitempty"`
}
type pendingLogin struct {
	username         string
	password         []byte
	auth             proton.Auth
	stage, challenge string
	deadline         time.Time
}

// Validate the server-returned URL; never manufacture a CAPTCHA page or change CSP.
func verificationURL(raw, challenge string) (string, bool) {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" || u.Host != "verify.proton.me" || u.User != nil || u.Fragment != "" || (u.Path != "" && u.Path != "/") {
		return "", false
	}
	q, err := url.ParseQuery(u.RawQuery)
	if err != nil || challenge == "" || len(q["token"]) != 1 || q.Get("token") != challenge || len(q["methods"]) != 1 || !slices.Contains(strings.Split(q.Get("methods"), ","), "captcha") {
		return "", false
	}
	return raw, true
}
func (b *ProtonBackend) clearPending() {
	if b.pending != nil {
		clear(b.pending.password)
		b.pending = nil
	}
}
func (b *ProtonBackend) loginCall(ctx context.Context, method string, raw json.RawMessage) (any, *Fault) {
	if method == "begin_login" {
		var p struct {
			Username string `json:"username"`
			Password string `json:"password"`
		}
		if !Decode(raw, &p) || strings.TrimSpace(p.Username) == "" || p.Password == "" {
			return nil, fail("invalid_params")
		}
		if b.client != nil || b.pending != nil {
			return nil, fail("already_authenticated")
		}
		b.pending = &pendingLogin{username: p.Username, password: []byte(p.Password), deadline: time.Now().Add(5 * time.Minute)}
		return b.loginWithHV(ctx, nil)
	}
	var p struct {
		Response string `json:"response"`
	}
	if !Decode(raw, &p) || len(p.Response) > 16384 {
		return nil, fail("invalid_params")
	}
	if b.pending == nil || time.Now().After(b.pending.deadline) {
		if f := b.logout(); f != nil {
			return nil, f
		}
		return nil, fail("login_expired")
	}
	switch b.pending.stage {
	case "captcha":
		if !strings.HasPrefix(p.Response, b.pending.challenge+":") || len(p.Response) <= len(b.pending.challenge)+1 {
			return nil, fail("invalid_params")
		}
		return b.loginWithHV(ctx, &proton.APIHVDetails{Methods: []string{"captcha"}, Token: p.Response})
	case "totp":
		if len(p.Response) != 6 || strings.Trim(p.Response, "0123456789") != "" {
			return nil, fail("invalid_params")
		}
		if err := b.client.Auth2FA(ctx, proton.Auth2FAReq{TwoFactorCode: p.Response}); err != nil {
			return nil, classify(err, "credentials")
		}
		return b.afterFactor(ctx)
	case "mailbox":
		if p.Response == "" {
			return nil, fail("invalid_params")
		}
		pass := []byte(p.Response)
		defer clear(pass)
		return b.finishInteractiveLogin(ctx, pass)
	default:
		return nil, fail("invalid_params")
	}
}
func (b *ProtonBackend) loginWithHV(ctx context.Context, hv *proton.APIHVDetails) (any, *Fault) {
	login := b.manager.NewClientWithLoginWithHVToken
	if b.loginAttempt != nil {
		login = b.loginAttempt
	}
	c, a, err := login(ctx, b.pending.username, b.pending.password, hv)
	if err != nil {
		var api *proton.APIError
		if errors.As(err, &api) && api.IsHVError() {
			details, e := api.GetHVDetails()
			var page struct {
				WebURL string `json:"WebUrl"`
			}
			if e == nil && details != nil && slices.Contains(details.Methods, "captcha") && json.Unmarshal(api.Details, &page) == nil {
				if u, ok := verificationURL(page.WebURL, details.Token); ok {
					b.pending.stage = "captcha"
					b.pending.challenge = details.Token
					return loginStep{Stage: "captcha", WebURL: u, Challenge: details.Token}, nil
				}
			}
			b.clearPending()
			return nil, fail("human_verification_required")
		}
		b.clearPending()
		return nil, classify(err, "credentials")
	}
	b.client = c
	b.pending.auth = a
	if a.TwoFA.Enabled&proton.HasTOTP != 0 {
		b.pending.stage = "totp"
		return loginStep{Stage: "totp"}, nil
	}
	if a.TwoFA.Enabled != 0 {
		if f := b.logout(); f != nil {
			return nil, f
		}
		return nil, fail("unsupported_factor")
	}
	return b.afterFactor(ctx)
}
func (b *ProtonBackend) afterFactor(ctx context.Context) (any, *Fault) {
	if b.pending.auth.PasswordMode == proton.TwoPasswordMode {
		clear(b.pending.password)
		b.pending.stage = "mailbox"
		return loginStep{Stage: "mailbox"}, nil
	}
	return b.finishInteractiveLogin(ctx, b.pending.password)
}
func (b *ProtonBackend) finishInteractiveLogin(ctx context.Context, pass []byte) (any, *Fault) {
	rings, salted, err := unlockSession(ctx, b.client, pass)
	if err != nil {
		return nil, classify(err, "key")
	}
	b.rings = rings
	a := b.pending.auth
	b.session = savedSession{UID: a.UID, Access: a.AccessToken, Refresh: a.RefreshToken, Salted: salted}
	b.trackAuth()
	b.clearPending()
	return loginStep{Stage: "ready"}, nil
}
