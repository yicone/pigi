import Foundation
import JavaScriptCore

extension ProtonHelperRegression {
    @MainActor static func loginCases(root: URL) async throws {
        let url = root.appendingPathComponent("interactive-login")
        let source = #"""
#!/usr/bin/python3
import sys,json
n=0
for line in sys.stdin:
 r=json.loads(line); m=r['method']; result=None; error=None
 if m=='hello': result={'protocol':1,'helper_version':'fixture','max_frame_bytes':8388608,'methods':['configure_network','login','list','decrypt','logout','begin_login','continue_login']}
 elif m=='configure_network':
  assert r['params']=={'scheme':'direct','host':'','port':0} and 'password' not in r['params']
  result={'configured':True}
 elif m=='begin_login':
  assert r['params']['username']=='fixture' and r['params']['password']=='synthetic'
  result={'stage':'captcha','web_url':'https://verify.proton.me/?methods=email,captcha&token=bound','challenge':'bound'}
 elif m=='continue_login':
  value=r['params']['response']; n+=1
  if n==1:
   assert value=='bound:response'
   result={'stage':'totp'}
  elif n==2:
   assert value=='111111'
   error={'code':'credentials'}
  elif n==3:
   assert value=='222222'
   result={'stage':'mailbox'}
  elif n==4:
   assert value=='wrong-synthetic'
   error={'code':'key'}
  elif n==5:
   assert value=='correct-synthetic'
   result={'stage':'ready'}
  else: raise Exception('unexpected extra retry')
 elif m=='logout': result={'logged_out':True}
 else: error={'code':'unknown_method'}
 reply={'version':1,'id':r['id']}
 reply['error' if error else 'result']=error if error else result
 print(json.dumps(reply),flush=True)
 if m=='logout': break
"""#
        try source.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        let client = ProtonHelperClient(executable: url)
        var stages: [String] = []
        try await client.loginInteractively(username: "fixture", password: "synthetic", mailboxPassword: "", otp: "") { step in
            stages.append(step.stage)
            switch stages.count {
            case 1: return "bound:response"
            case 2: return "111111"
            case 3: try expect(step.failure == .credentials, "wrong TOTP surfaced"); return "222222"
            case 4: return "wrong-synthetic"
            case 5: try expect(step.failure == .key, "wrong mailbox password surfaced"); return "correct-synthetic"
            default: throw TestFailure(name: "unexpected challenge")
            }
        }
        try expect(stages == ["captcha", "totp", "totp", "mailbox", "mailbox"], "interactive login continuation")
        try await client.logout()
        do {
            try await client.loginInteractively(username: "fixture", password: "synthetic", mailboxPassword: "", otp: "") { _ in throw CancellationError() }
            throw TestFailure(name: "cancelled login succeeded")
        } catch is CancellationError {}
        try await client.logout()

        let good = "https://verify.proton.me/?methods=email,captcha&token=bound"
        try expect(ProtonVerificationPolicy.url(good, challenge: "bound")?.absoluteString == good, "server URL retained")
        for raw in [good.replacingOccurrences(of: "https:", with: "http:"),good+"&token=bound",good+"#x",good.replacingOccurrences(of:"verify.proton.me",with:"verify.proton.me.evil.test"),good.replacingOccurrences(of:"token=bound",with:"token=foreign")] {
            try expect(ProtonVerificationPolicy.url(raw, challenge: "bound") == nil, "unsafe URL rejected")
        }
        try expect(!ProtonVerificationPolicy.result("foreign:answer", challenge: "bound"), "foreign callback rejected")
        let js = JSContext()!
        js.evaluateScript("var window={posts:[],addEventListener:function(n,h){this.h=h},webkit:{messageHandlers:{protonVerification:{postMessage:function(v){window.posts.push(v)}}}}};")
        js.evaluateScript(ProtonVerificationPolicy.script)
        let result = js.evaluateScript(#"""
        (function(){
          const valid={type:'HUMAN_VERIFICATION_SUCCESS',payload:{type:'captcha',token:'bound:answer'}};
          window.h({origin:'https://evil.test',data:valid});
          window.h({origin:'https://verify.proton.me',data:'invalid json'});
          window.h({origin:'https://verify.proton.me',data:{type:'HUMAN_VERIFICATION_SUCCESS',payload:{type:'other',token:'bound:answer'}}});
          if(window.posts.length) return false;
          window.h({origin:'https://verify.proton.me',data:JSON.stringify(valid)});
          window.h({origin:'https://verify.proton.me',data:{type:'ERROR',payload:{secret:'never forward'}}});
          return window.posts.length===2 && window.posts[0].token==='bound:answer' && Object.keys(window.posts[1]).length===1;
        })()
        """#)
        try expect(result?.toBool() == true && js.exception == nil, "official event parser, origin and redaction")
        let prompt = ProtonLoginPrompt()
        let pending = Task { try await prompt.request(ProtonLoginChallenge(stage: "totp")) }
        while prompt.pending == nil { await Task.yield() }
        prompt.answer = "123456"; prompt.submit()
        let answer = try await pending.value
        try expect(answer == "123456" && prompt.pending == nil && prompt.answer.isEmpty, "prompt submission clears input")
        let cancelled = Task { try await prompt.request(ProtonLoginChallenge(stage: "mailbox")) }
        while prompt.pending == nil { await Task.yield() }
        cancelled.cancel()
        do { _ = try await cancelled.value; throw TestFailure(name: "prompt cancellation ignored") }
        catch is CancellationError {}
        try expect(prompt.pending == nil, "cancelled prompt dismissed")
        print("PASS: CAPTCHA/TOTP/mailbox continuation, wrong-factor retry, cancellation, URL/challenge binding and official message parsing")
    }
}
