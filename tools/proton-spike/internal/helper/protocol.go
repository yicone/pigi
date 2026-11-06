// Package helper implements the private Pigi child-process protocol.
package helper

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"io"
	"time"
)

const Version = 1
const MaxFrame = 8 * 1024 * 1024

type Request struct {
	Version int             `json:"version"`
	ID      uint64          `json:"id"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params"`
}

// Fault is deliberately just a code. Never serialize an underlying error.
type Fault struct {
	Code string `json:"code"`
}

func (f *Fault) Error() string { return f.Code }
func fail(code string) *Fault  { return &Fault{Code: code} }

type Response struct {
	Version int    `json:"version"`
	ID      uint64 `json:"id"`
	Result  any    `json:"result,omitempty"`
	Error   *Fault `json:"error,omitempty"`
}

type Backend interface {
	Call(context.Context, string, json.RawMessage) (any, *Fault)
	Close() *Fault
}

func Decode(data []byte, out any) bool {
	trimmed := bytes.TrimSpace(data)
	if len(trimmed) == 0 || trimmed[0] != '{' {
		return false
	}
	d := json.NewDecoder(bytes.NewReader(data))
	d.DisallowUnknownFields()
	return d.Decode(out) == nil && d.Decode(new(any)) == io.EOF
}

// Serve is sequential: one in-memory account per process. EOF revokes the
// session. Malformed/oversized input is fatal so framing cannot desynchronize.
func Serve(in io.Reader, out io.Writer, backend Backend) error {
	defer backend.Close()
	scanner := bufio.NewScanner(in)
	scanner.Buffer(make([]byte, 4096), MaxFrame+1)
	negotiated := false
	write := func(r Response) error {
		data, err := json.Marshal(r)
		if err != nil || len(data) > MaxFrame {
			data, _ = json.Marshal(Response{Version: Version, ID: r.ID, Error: fail("frame_too_large")})
		}
		_, err = out.Write(append(data, '\n'))
		clear(data)
		return err
	}
	for scanner.Scan() {
		var req Request
		frame := scanner.Bytes()
		valid := len(frame) <= MaxFrame && Decode(frame, &req) && req.ID > 0 && req.Method != "" && len(req.Method) <= 64 && len(req.Params) > 0
		clear(frame)
		resp := Response{Version: Version, ID: req.ID}
		if !valid {
			resp.ID = 0
			resp.Error = fail("invalid_request")
			_ = write(resp)
			return nil
		}
		switch {
		case req.Version != Version:
			resp.Error = fail("unsupported_version")
		case req.Method == "hello":
			if !Decode(req.Params, new(struct{})) {
				resp.Error = fail("invalid_params")
			} else {
				negotiated = true
				resp.Result = map[string]any{"protocol": Version, "helper_version": "0.4.0", "max_frame_bytes": MaxFrame, "methods": []string{"configure_network", "begin_login", "continue_login", "login", "list", "decrypt", "logout", "snapshot", "metadata", "labels", "latest", "events", "session", "resume"}}
			}
		case !negotiated:
			resp.Error = fail("handshake_required")
		default:
			ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
			resp.Result, resp.Error = backend.Call(ctx, req.Method, req.Params)
			cancel()
		}
		clear(req.Params)
		if err := write(resp); err != nil {
			return err
		}
	}
	if scanner.Err() != nil {
		_ = write(Response{Version: Version, Error: fail("frame_too_large")})
	}
	return scanner.Err()
}
