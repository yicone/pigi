package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/ProtonMail/gluon/async"
	proton "github.com/ProtonMail/go-proton-api"
	"github.com/ProtonMail/gopenpgp/v2/crypto"
	"github.com/sirupsen/logrus"
)

type credentials struct {
	Username string `json:"username"`
	Password string `json:"password"`
	Mailbox  string `json:"mailbox"`
	Free     bool   `json:"free_confirmed"`
}
type quietLogger struct{}

func (quietLogger) Errorf(string, ...interface{}) {}
func (quietLogger) Warnf(string, ...interface{})  {}
func (quietLogger) Debugf(string, ...interface{}) {}

// Proton accepts "Other" as the third-party client category. Identify this
// actual client separately instead of claiming an official Proton product.
type identifiedTransport struct{ http.RoundTripper }

func (t identifiedTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	request = request.Clone(request.Context())
	request.Header.Set("User-Agent", "pigi-proton-spike/0.1.0")
	return t.RoundTripper.RoundTrip(request)
}

// Public evidence contains no identifiers, subjects, addresses, tokens or bodies.
type evidence struct {
	Time                string `json:"time_utc"`
	Stage               string `json:"stage"`
	Free                bool   `json:"free_plan_user_confirmed"`
	Listed              int    `json:"inbox_metadata_count"`
	Ciphertext          bool   `json:"armored_ciphertext_received"`
	PlainBytes          int    `json:"plaintext_bytes"`
	UTF8                bool   `json:"plaintext_utf8"`
	UserVerified        bool   `json:"user_verified_plaintext"`
	SessionRevoked      bool   `json:"session_revoked"`
	KeychainCleared     bool   `json:"temporary_keychain_item_removed"`
	HTTPStatus          int    `json:"http_status,omitempty"`
	APICode             int    `json:"api_code,omitempty"`
	ErrorKind           string `json:"error_kind,omitempty"`
	HVRequired          bool   `json:"human_verification_required"`
	HVSolved            bool   `json:"human_verification_completed"`
	CaptchaLoaded       bool   `json:"captcha_page_loaded"`
	CaptchaHTTP         int    `json:"captcha_page_http_status,omitempty"`
	CaptchaFailed       bool   `json:"captcha_navigation_failed"`
	CaptchaCallback     bool   `json:"captcha_callback_received"`
	CaptchaTimeout      bool   `json:"captcha_timed_out"`
	CaptchaWidgetLoaded bool   `json:"captcha_widget_loaded"`
	CaptchaWidgetError  bool   `json:"captcha_widget_error"`
}

func captchaPageURL(raw, challenge string) (string, error) {
	u, err := url.Parse(raw)
	if err != nil || challenge == "" || u.Scheme != "https" || u.Host != "verify.proton.me" || u.User != nil || u.Fragment != "" || (u.Path != "" && u.Path != "/") {
		return "", errors.New("invalid_verification_url")
	}
	q := u.Query()
	if len(q["token"]) != 1 || q.Get("token") != challenge || !slices.Contains(strings.Split(q.Get("methods"), ","), "captcha") {
		return "", errors.New("invalid_verification_url")
	}
	// Supported parameters of the official Verify app; no CSP modification.
	q.Set("methods", "captcha")
	q.Set("embed", "1")
	u.RawQuery = q.Encode()
	return u.String(), nil
}

// WebKit stderr may contain URLs or tokens. Forward only fixed diagnostic
// events and a validated numeric HTTP status, never arbitrary child output.
type captchaDiagnostics struct {
	report  *evidence
	output  io.Writer
	pending string
}

func (d *captchaDiagnostics) Write(data []byte) (int, error) {
	d.pending += string(data)
	for {
		line, rest, found := strings.Cut(d.pending, "\n")
		if !found {
			break
		}
		d.pending = rest
		message := ""
		switch line {
		case "PROTON_SPIKE:page_loaded":
			d.report.CaptchaLoaded = true
			message = "CAPTCHA page loaded."
		case "PROTON_SPIKE:callback_received":
			d.report.CaptchaCallback = true
			message = "CAPTCHA callback received."
		case "PROTON_SPIKE:widget_loaded":
			d.report.CaptchaWidgetLoaded = true
			message = "CAPTCHA widget loaded."
		case "PROTON_SPIKE:widget_error":
			d.report.CaptchaWidgetError = true
			message = "CAPTCHA widget reported an error."
		case "PROTON_SPIKE:navigation_failed", "PROTON_SPIKE:navigation_blocked":
			d.report.CaptchaFailed = true
			message = "CAPTCHA navigation failed."
		case "PROTON_SPIKE:timeout":
			d.report.CaptchaTimeout = true
			message = "CAPTCHA timed out."
		default:
			if value, ok := strings.CutPrefix(line, "PROTON_SPIKE:http_status:"); ok {
				if status, err := strconv.Atoi(value); err == nil && status >= 100 && status <= 599 {
					d.report.CaptchaHTTP = status
					message = fmt.Sprintf("CAPTCHA page HTTP=%d.", status)
				}
			}
		}
		if message != "" {
			_, _ = fmt.Fprintln(d.output, message)
		}
	}
	if len(d.pending) > 4096 {
		d.pending = ""
	}
	return len(data), nil
}

func captchaResponse(challenge string, response []byte) (*proton.APIHVDetails, error) {
	if challenge == "" || !strings.HasPrefix(string(response), challenge+":") || len(response) <= len(challenge)+1 {
		return nil, errors.New("invalid_captcha_response")
	}
	return &proton.APIHVDetails{Methods: []string{"captcha"}, Token: string(response)}, nil
}

func helper(path, mode, item string, input []byte, report ...*evidence) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 250*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, path, mode, item)
	cmd.Stdin = bytes.NewReader(input)
	if mode == "captcha" && len(report) == 1 {
		cmd.Stderr = &captchaDiagnostics{report: report[0], output: os.Stdout}
	}
	// Never forward stderr or raw subprocess errors.
	return cmd.Output()
}
func unlock(ctx context.Context, c *proton.Client, keyPass []byte) (map[string]*crypto.KeyRing, error) {
	user, err := c.GetUser(ctx)
	if err != nil {
		return nil, err
	}
	addresses, err := c.GetAddresses(ctx)
	if err != nil {
		return nil, err
	}
	salts, err := c.GetSalts(ctx)
	if err != nil {
		return nil, err
	}
	var primary string
	for _, key := range user.Keys {
		if key.Primary {
			primary = key.ID
			break
		}
	}
	if primary == "" {
		return nil, errors.New("missing_primary_key")
	}
	salted, err := salts.SaltForKey(keyPass, primary)
	if err != nil || len(salted) == 0 {
		return nil, errors.New("key_derivation_failed")
	}
	defer clear(salted)
	userKR, addressKRs, err := proton.Unlock(user, addresses, salted, async.NoopPanicHandler{})
	if userKR != nil {
		defer userKR.ClearPrivateParams()
	}
	return addressKRs, err
}
func readOne(ctx context.Context, c *proton.Client, rings map[string]*crypto.KeyRing, report *evidence) ([]byte, error) {
	report.Stage = "list"
	rows, err := c.GetMessageMetadataPage(ctx, 0, 5, proton.MessageFilter{LabelID: proton.InboxLabel, Desc: true})
	if err != nil {
		return nil, err
	}
	report.Listed = len(rows)
	if len(rows) == 0 {
		return nil, errors.New("empty_inbox")
	}
	report.Stage = "fetch_ciphertext"
	message, err := c.GetMessage(ctx, rows[0].ID)
	if err != nil {
		return nil, err
	}
	report.Ciphertext = bytes.HasPrefix([]byte(message.Body), []byte("-----BEGIN PGP MESSAGE-----"))
	if !report.Ciphertext {
		return nil, errors.New("body_not_armored_ciphertext")
	}
	report.Stage = "decrypt"
	ring := rings[message.AddressID]
	if ring == nil {
		return nil, errors.New("missing_address_key")
	}
	plaintext, err := message.Decrypt(ring)
	if err != nil {
		return nil, errors.New("decryption_failed")
	}
	report.PlainBytes = len(plaintext)
	report.UTF8 = utf8.Valid(plaintext)
	if len(plaintext) == 0 || !report.UTF8 {
		clear(plaintext)
		return nil, errors.New("empty_or_non_utf8_body")
	}
	return plaintext, nil
}
func run(report *evidence) (runErr error) {
	executable, err := os.Executable()
	if err != nil {
		return errors.New("executable_path")
	}
	prompt := filepath.Join(filepath.Dir(executable), "proton-prompt")
	nonce := make([]byte, 16)
	if _, err := rand.Read(nonce); err != nil {
		return errors.New("random_failed")
	}
	item := "proton-spike-" + hex.EncodeToString(nonce)
	defer func() {
		_, err := helper(prompt, "delete", item, nil)
		report.KeychainCleared = err == nil
		if err != nil && runErr == nil {
			runErr = errors.New("keychain_cleanup_failed")
		}
	}()
	report.Stage = "local_credential_prompt"
	fmt.Println("ACM-769: enter credentials only in the native secure prompt.")
	if _, err := helper(prompt, "collect", item, nil); err != nil {
		return errors.New("credential_prompt_cancelled_or_unavailable")
	}
	data, err := helper(prompt, "read", item, nil)
	if err != nil {
		return errors.New("keychain_read_failed")
	}
	var creds credentials
	if err := json.Unmarshal(data, &creds); err != nil {
		clear(data)
		return errors.New("credential_decode_failed")
	}
	clear(data)
	report.Free = creds.Free
	if !creds.Free {
		return errors.New("free_plan_not_confirmed")
	}
	// Context covers network operations; UI prompts have their own bounded waits.
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Minute)
	defer cancel()
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.DialContext = (&net.Dialer{Timeout: 15 * time.Second}).DialContext
	transport.ResponseHeaderTimeout = 30 * time.Second
	manager := proton.New(proton.WithAppVersion("Other"), proton.WithRetryCount(0),
		proton.WithDebug(false), proton.WithLogger(quietLogger{}), proton.WithTransport(identifiedTransport{transport}))
	defer manager.Close()
	report.Stage = "srp_login"
	client, auth, err := manager.NewClientWithLogin(ctx, creds.Username, []byte(creds.Password))
	var apiErr *proton.APIError
	if errors.As(err, &apiErr) && apiErr.IsHVError() {
		report.HVRequired = true
		report.Stage = "human_verification"
		details, detailsErr := apiErr.GetHVDetails()
		if detailsErr != nil || details == nil || !slices.Contains(details.Methods, "captcha") || details.Token == "" {
			return errors.New("unsupported_human_verification")
		}
		fmt.Println("ACM-769: complete the official Proton CAPTCHA manually in the native window.")
		var page struct {
			WebURL string `json:"WebUrl"`
		}
		if json.Unmarshal(apiErr.Details, &page) != nil {
			return errors.New("invalid_verification_url")
		}
		pageURL, pageErr := captchaPageURL(page.WebURL, details.Token)
		if pageErr != nil {
			return pageErr
		}
		response, captchaErr := helper(prompt, "captcha", item, []byte(pageURL), report)
		if captchaErr != nil {
			return errors.New("human_verification_cancelled_or_unavailable")
		}
		verified, captchaErr := captchaResponse(details.Token, response)
		clear(response)
		if captchaErr != nil {
			return captchaErr
		}
		report.HVSolved = true
		report.Stage = "srp_login_after_human_verification"
		// Exactly one retry after the user completes the server-required challenge.
		client, auth, err = manager.NewClientWithLoginWithHVToken(ctx, creds.Username, []byte(creds.Password), verified)
	}
	if err != nil {
		return err
	}
	defer client.Close()
	defer func() {
		revokeCtx, revokeCancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer revokeCancel()
		report.SessionRevoked = client.AuthDelete(revokeCtx) == nil
		if !report.SessionRevoked && runErr == nil {
			runErr = errors.New("session_cleanup_failed")
		}
	}()
	if auth.TwoFA.Enabled&proton.HasTOTP != 0 {
		report.Stage = "totp"
		otp, err := helper(prompt, "otp", item, nil)
		if err != nil {
			return errors.New("totp_cancelled")
		}
		err = client.Auth2FA(ctx, proton.Auth2FAReq{TwoFactorCode: string(otp)})
		clear(otp)
		if err != nil {
			return err
		}
	} else if auth.TwoFA.Enabled != 0 {
		return errors.New("interactive_fido_required")
	}
	keyPass := []byte(creds.Password)
	if auth.PasswordMode == proton.TwoPasswordMode {
		if creds.Mailbox == "" {
			return errors.New("mailbox_password_required")
		}
		keyPass = []byte(creds.Mailbox)
	}
	creds = credentials{}
	defer clear(keyPass)
	report.Stage = "unlock_keys"
	rings, err := unlock(ctx, client, keyPass)
	if err != nil {
		return err
	}
	defer func() {
		for _, ring := range rings {
			ring.ClearPrivateParams()
		}
	}()
	plaintext, err := readOne(ctx, client, rings, report)
	if err != nil {
		return err
	}
	defer clear(plaintext)
	report.Stage = "local_plaintext_confirmation"
	if _, err := helper(prompt, "show", item, plaintext); err != nil {
		return errors.New("plaintext_not_confirmed")
	}
	report.UserVerified = true
	report.Stage = "complete"
	return nil
}
func main() {
	logrus.SetOutput(io.Discard)
	report := evidence{Time: time.Now().UTC().Format(time.RFC3339)}
	err := run(&report)
	if err != nil {
		report.ErrorKind = "operation_failed"
		var apiErr *proton.APIError
		if errors.As(err, &apiErr) {
			report.HTTPStatus = apiErr.Status
			report.APICode = int(apiErr.Code)
		}
		// Only our own fixed error messages may be emitted; never API error text.
		for _, safe := range []string{"invalid_verification_url", "unsupported_human_verification", "human_verification_cancelled_or_unavailable", "invalid_captcha_response", "credential_prompt_cancelled_or_unavailable", "keychain_read_failed", "credential_decode_failed", "free_plan_not_confirmed", "totp_cancelled", "interactive_fido_required", "mailbox_password_required", "empty_inbox", "body_not_armored_ciphertext", "missing_address_key", "decryption_failed", "empty_or_non_utf8_body", "plaintext_not_confirmed", "session_cleanup_failed", "keychain_cleanup_failed"} {
			if err.Error() == safe {
				report.ErrorKind = safe
				break
			}
		}
	}
	_ = json.NewEncoder(os.Stdout).Encode(report)
	if err != nil {
		os.Exit(1)
	}
}
