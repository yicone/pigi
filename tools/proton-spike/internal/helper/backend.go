package helper

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/ProtonMail/gluon/async"
	proton "github.com/ProtonMail/go-proton-api"
	"github.com/ProtonMail/gopenpgp/v2/constants"
	"github.com/ProtonMail/gopenpgp/v2/crypto"
	"github.com/sirupsen/logrus"
)

type quietLogger struct{}

func (quietLogger) Errorf(string, ...interface{}) {}
func (quietLogger) Warnf(string, ...interface{})  {}
func (quietLogger) Debugf(string, ...interface{}) {}

type identifiedTransport struct{ http.RoundTripper }

func (t identifiedTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	r = r.Clone(r.Context())
	r.Header.Set("User-Agent", "pigi-proton-helper/0.1.0")
	return t.RoundTripper.RoundTrip(r)
}

type ProtonBackend struct {
	manager      *proton.Manager
	client       *proton.Client
	rings        map[string]*crypto.KeyRing
	session      savedSession
	persistent   bool
	pending      *pendingLogin
	loginAttempt func(context.Context, string, []byte, *proton.APIHVDetails) (*proton.Client, proton.Auth, error)
	transport    *http.Transport
	directDial   func(context.Context, string, string) (net.Conn, error)
}

func NewBackend() *ProtonBackend {
	logrus.SetOutput(io.Discard)
	t := http.DefaultTransport.(*http.Transport).Clone()
	// Swift sends configure_network. Never read HTTP(S)_PROXY / ALL_PROXY, and
	// never fall back to a direct dial after a proxy has been installed.
	dialer := &net.Dialer{Timeout: 15 * time.Second}
	t.Proxy = nil
	t.DialContext = dialer.DialContext
	t.ResponseHeaderTimeout = 30 * time.Second
	return &ProtonBackend{
		transport:  t,
		directDial: dialer.DialContext,
		manager:    proton.New(proton.WithAppVersion("Other"), proton.WithRetryCount(0), proton.WithDebug(false), proton.WithLogger(quietLogger{}), proton.WithTransport(identifiedTransport{t})),
	}
}

func classify(err error, fallback string) *Fault {
	if err == nil {
		return nil
	}
	var fault *Fault
	if errors.As(err, &fault) {
		return fault
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return fail("timeout")
	}
	var api *proton.APIError
	if errors.As(err, &api) {
		switch {
		case api.Code == proton.AppVersionMissingCode, api.Code == proton.AppVersionBadCode:
			return fail("api_version")
		case api.Status == http.StatusProxyAuthRequired:
			return fail("proxy")
		case api.IsHVError(), api.Code == proton.HumanValidationInvalidToken:
			return fail("human_verification_required")
		case api.Code == proton.PasswordWrong, api.Code == proton.UsernameInvalid, api.Status == 401:
			return fail("credentials")
		case api.Status == 404:
			return fail("not_found")
		case api.Status == 429:
			return fail("rate_limited")
		case api.Status >= 500:
			return fail("network")
		default:
			// A service error is not evidence of an unrecognized private-key schema.
			if fallback == "key_format" {
				return fail("upstream")
			}
			return fail(fallback)
		}
	}
	var network *proton.NetError
	var netErr net.Error
	if errors.As(err, &network) || errors.As(err, &netErr) {
		return fail("network")
	}
	return fail(fallback)
}

type loginParams struct {
	Username string `json:"username"`
	Password string `json:"password"`
	Mailbox  string `json:"mailbox_password,omitempty"`
	OTP      string `json:"otp,omitempty"`
}

func (b *ProtonBackend) Call(ctx context.Context, method string, raw json.RawMessage) (any, *Fault) {
	switch method {
	case "configure_network":
		return b.configureNetwork(raw)
	case "begin_login", "continue_login":
		return b.loginCall(ctx, method, raw)
	case "login":
		if b.client != nil || b.pending != nil {
			return nil, fail("already_authenticated")
		}
		var p loginParams
		if !Decode(raw, &p) || p.Username == "" || p.Password == "" {
			return nil, fail("invalid_params")
		}
		defer func() { p = loginParams{} }()
		pass := []byte(p.Password)
		defer clear(pass)
		client, auth, err := b.manager.NewClientWithLogin(ctx, p.Username, pass)
		if err != nil {
			return nil, classify(err, "credentials")
		}
		// Keep the client even when cleanup fails, so logout/EOF can retry.
		b.client = client
		ok := false
		defer func() {
			if !ok {
				_ = b.logout()
			}
		}()
		if auth.TwoFA.Enabled&proton.HasTOTP != 0 {
			if p.OTP == "" {
				return nil, fail("second_factor_required")
			}
			if err := client.Auth2FA(ctx, proton.Auth2FAReq{TwoFactorCode: p.OTP}); err != nil {
				return nil, classify(err, "credentials")
			}
		} else if auth.TwoFA.Enabled != 0 {
			return nil, fail("second_factor_required")
		}
		if auth.PasswordMode == proton.TwoPasswordMode {
			if p.Mailbox == "" {
				return nil, fail("key")
			}
			clear(pass)
			pass = []byte(p.Mailbox)
			defer clear(pass)
		}
		rings, salted, err := unlockSession(ctx, client, pass)
		if err != nil {
			return nil, classify(err, "key")
		}
		b.rings = rings
		b.session = savedSession{UID: auth.UID, Access: auth.AccessToken, Refresh: auth.RefreshToken, Salted: salted}
		b.trackAuth()
		ok = true
		return map[string]bool{"authenticated": true}, nil
	case "list":
		var p struct {
			Page  int `json:"page"`
			Limit int `json:"limit"`
		}
		if !Decode(raw, &p) || p.Page < 0 || p.Limit < 1 || p.Limit > 100 {
			return nil, fail("invalid_params")
		}
		if b.client == nil || b.rings == nil {
			return nil, fail("not_authenticated")
		}
		rows, err := b.client.GetMessageMetadataPage(ctx, p.Page, p.Limit, proton.MessageFilter{LabelID: proton.InboxLabel, Desc: true})
		if err != nil {
			return nil, classify(err, "upstream")
		}
		type row struct {
			ID      string `json:"id"`
			Subject string `json:"subject"`
			Time    int64  `json:"time"`
			Unread  bool   `json:"unread"`
		}
		result := make([]row, 0, len(rows))
		for _, r := range rows {
			result = append(result, row{r.ID, r.Subject, r.Time, bool(r.Unread)})
		}
		return result, nil
	case "decrypt":
		var p struct {
			ID string `json:"id"`
		}
		if !Decode(raw, &p) || !validID(p.ID) {
			return nil, fail("invalid_params")
		}
		if b.client == nil || b.rings == nil {
			return nil, fail("not_authenticated")
		}
		msg, err := b.client.GetMessage(ctx, p.ID)
		if err != nil {
			return nil, classify(err, "upstream")
		}
		if !strings.HasPrefix(msg.Body, "-----BEGIN PGP MESSAGE-----") {
			return nil, fail("key_format")
		}
		ring := b.rings[msg.AddressID]
		if ring == nil {
			return nil, fail("key_missing")
		}
		encrypted, err := crypto.NewPGPMessageFromArmored(msg.Body)
		if err != nil {
			return nil, fail("key_format")
		}
		// Only trust keys the service marks uncompromised; obsolete keys may
		// still verify historical mail. Lookup failures never imply a bad signature.
		var verifier *crypto.KeyRing
		if msg.Sender != nil && msg.Sender.Address != "" {
			keys, _, lookupErr := b.client.GetPublicKeys(ctx, msg.Sender.Address)
			if lookupErr == nil {
				trusted := proton.PublicKeys{}
				for _, key := range keys {
					if key.Flags&proton.KeyStateTrusted != 0 {
						trusted = append(trusted, key)
					}
				}
				if len(trusted) > 0 {
					verifier, _ = trusted.GetKeyRing()
				}
			}
		}
		decrypted, status, err := decryptVerified(ring, encrypted, verifier, int64(msg.Time))
		if err != nil {
			return nil, fail("key_decryption")
		}
		plain := decrypted.GetBinary()
		defer clear(plain)
		if !utf8.Valid(plain) {
			return nil, fail("key")
		}
		return map[string]string{"body": string(plain), "mime_type": string(msg.MIMEType), "signature_status": status}, nil
	case "snapshot", "events", "labels", "latest", "metadata", "session", "resume":
		return b.syncCall(ctx, method, raw)
	case "logout":
		var p struct{}
		if !Decode(raw, &p) {
			return nil, fail("invalid_params")
		}
		if fault := b.logout(); fault != nil {
			return nil, fault
		}
		return map[string]bool{"logged_out": true}, nil
	default:
		return nil, fail("unknown_method")
	}
}

func (b *ProtonBackend) logout() *Fault {
	b.clearPending()
	clear(b.session.Salted)
	b.session = savedSession{}
	b.persistent = false
	for _, ring := range b.rings {
		ring.ClearPrivateParams()
	}
	b.rings = nil
	if b.client == nil {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := b.client.AuthDelete(ctx); err != nil {
		return fail("cleanup_failed")
	}
	b.client.Close()
	b.client = nil
	return nil
}

func (b *ProtonBackend) Close() *Fault {
	var fault *Fault
	if !b.persistent {
		fault = b.logout()
	} else {
		for _, ring := range b.rings {
			ring.ClearPrivateParams()
		}
		b.rings = nil
		clear(b.session.Salted)
		b.session = savedSession{}
	}
	if b.client != nil {
		b.client.Close()
		b.client = nil
	}
	b.manager.Close()
	return fault
}

func unlockSession(ctx context.Context, c *proton.Client, pass []byte) (map[string]*crypto.KeyRing, []byte, error) {
	user, err := c.GetUser(ctx)
	if err != nil {
		return nil, nil, classify(err, "key_format")
	}
	addresses, err := c.GetAddresses(ctx)
	if err != nil {
		return nil, nil, classify(err, "key_format")
	}
	salts, err := c.GetSalts(ctx)
	if err != nil {
		return nil, nil, err
	}
	var primary string
	for _, key := range user.Keys {
		if key.Primary {
			primary = key.ID
			break
		}
	}
	if primary == "" {
		return nil, nil, fail("key_missing")
	}
	salted, err := salts.SaltForKey(pass, primary)
	if err != nil || len(salted) == 0 {
		return nil, nil, errors.New("key_derivation_failed")
	}
	// The derived unlock secret is exported only over the private pipe for Keychain storage.
	userKR, rings, err := proton.Unlock(user, addresses, salted, async.NoopPanicHandler{})
	if userKR != nil {
		userKR.ClearPrivateParams()
	}
	if err != nil {
		for _, ring := range rings {
			ring.ClearPrivateParams()
		}
		clear(salted)
		return nil, nil, err
	}
	return rings, salted, nil
}

// Signature errors preserve the decrypted body; integrity/decryption errors do not.
func decryptVerified(ring *crypto.KeyRing, encrypted *crypto.PGPMessage, verifier *crypto.KeyRing, sentAt int64) (*crypto.PlainMessage, string, error) {
	if sentAt <= 0 {
		sentAt = crypto.GetUnixTime()
	}
	plain, err := ring.Decrypt(encrypted, verifier, sentAt)
	status := "unverified"
	if verifier != nil && err == nil {
		status = "verified"
	}
	var sigErr crypto.SignatureVerificationError
	if errors.As(err, &sigErr) {
		if sigErr.Status != constants.SIGNATURE_NOT_SIGNED {
			status = "failed"
		}
		err = nil
	}
	return plain, status, err
}
