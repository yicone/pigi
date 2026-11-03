# Proton 异常、缓存与依赖审计

审计日期：2026-11-03。基线：fork main `6d3ad26`。仅针对 Pigi 的只读
Proton helper 及其本地缓存路径，不代表 Proton 服务或整个操作系统的安全认证。
测试均使用回环服务、临时生成密钥、内存 SQLite、替代钥匙串和合成邮件；不访问用户邮箱。

## 异常与签名

- 地址密钥缺失：`key_missing`；私钥响应或密文装甲格式不能识别：`key_format`；
  密文不能由当前地址密钥解密：`key_decryption`。解锁密码错误仍为 `key`。
  用户界面分别提示加载最新密钥、更新应用、重新登录或检查邮箱密码。
- key/address 事件重新加载密钥；加载开始即清除旧 keyring，失败后禁止继续用旧密钥解密。
  成功轮换用新密钥验证。私钥始终留在 Go；失败不返回原始错误。
- 解密结果显式返回 `signature_status: unverified`。当前调用没有可信发送者公钥及信任链，
  因而无论邮件是否带签名都只显示“签名未验证 · 无法确认发件人身份”。
  未实现 verified/invalid/unsigned 判定，不把解密成功或发件地址当成真实性证明。
- 断网、超时、429、407、版本头拒绝、验证码要求各有固定错误码与提示。
  helper 关闭自动网络重试；同步失败后等 120 秒再试，游标不跨过失败消息。
  events 与其他接口使用相同的具体错误分类，HTTP 400/422/404 本身不证明游标过期；
  `InvalidValue`（2001）也是通用错误，不能单独触发重建。固定 SDK 没有专用游标失效错误码，
  因而不把任何 HTTP 错误猜测为 `cursor_expired`；服务器明确返回 `RefreshMail` 时才经
  `reset:true` 重建快照。相关依据为固定 SDK `event_types.go` 的 `RefreshMail` 位和
  `event.go` 的事件响应结构；不依赖可变/本地化的 Error 文本。
  `Retry-After` 暂未透传；服务要求更长冷却时间时可能继续返回 429，不会忙循环。
- 子进程环境为空，**不会导入 HTTP_PROXY/HTTPS_PROXY/ALL_PROXY 或凭据**。
  Go 默认 transport 不读取 macOS PAC/系统代理；当前 app 没有显式代理配置入口。
  回归中的代理成功路径通过注入 transport 验证 HTTP 转发，407 用 API 格式响应验证。
  这不证明真实系统代理、HTTPS CONNECT 认证代理或 VPN 已通过实机验收；此类失败显示网络错误。
  网络提示中的“系统代理”用于指导排查，不表示已经支持读取系统代理配置。

## 缓存与清理

- `~/Library/Application Support/pigi/mail.db` 保存明文元数据、摘要、FTS 正文和压缩 HTML；
  `mail.db-wal`/`mail.db-shm` 属 SQLite 的工作文件。压缩不是加密，数据库没有 SQLCipher。
- `mail-headers.json` 是第二份元数据缓存，含主题、发件人、摘要和标签，不保存 body。
  app 支持目录设为 0700，主数据库及邮件头 JSON 设为 0600；父目录限制其他本地用户访问侧文件。
  这不防同用户进程、管理员、恶意软件、备份或已取得权限的工具。
- 删除账号按 account 清除 messages、attachments、FTS、muted、labels、snapshot 和账号行；
  UI 立即重写邮件头缓存，不再依赖延迟保存。其他账号保持可读，旧同步不能复活账号。
  SQLite 开启 `secure_delete=ON`，减少普通表删除页残留。
- 这是**逻辑清除**：不承诺 FTS 历史影子页、旧 WAL、已打开 WebView、内存副本、系统交换区、
  SSD、Time Machine 和其他备份的物理抹除。远端删除仅打 tombstone，缓存正文仍可存在，
  完整移除本地数据使用“删除账号”。设备丢失保护依赖系统磁盘加密与账号权限。
- 凭据和派生解锁秘密放应用钥匙串；密码/OTP 不持久化。删除账号会请求移除钥匙串项，
  远端会话撤销仍为尽力执行（离线时不能保证撤销）。不将其描述为远端凭据已确认失效。
- helper stdout 是私有协议，stderr 丢弃，logrus 丢弃输出，SDK debug 关闭，quietLogger 不输出。
  同步只保存固定提示，不保存 SDK/SQL/JSON 错误。源码扫描未发现正文/凭据日志调用。
  不能保证运行时字符串完全归零或阻止操作系统级进程转储。
- 本报告的“无遥测”不覆盖邮件 HTML 的远程图片/链接或官方 CAPTCHA 页面；其网络行为由
  现有远程内容开关与官方页面控制。截图和日志只能使用合成数据。

## 依赖许可

依 `go list -mod=readonly -deps -json ./cmd/pigi-proton-helper` 对 Darwin arm64/amd64
取并集；25 个外部运行时模块。完整模块图里的 gin、gRPC、MongoDB、x/telemetry 等
测试/未链接依赖不等于打包进 app。本清单仅对实际 helper 闭包下结论。

| 模块 | 实际版本/来源 | 检查到的许可 |
| --- | --- | --- |
| `github.com/ProtonMail/bcrypt` | `v0.0.0-20211005172633-e235017c1baf` | BSD-3-Clause |
| `github.com/ProtonMail/gluon` | `v0.0.0-20260910132611-39e5c6ac84fe` | MIT |
| `github.com/ProtonMail/go-crypto` | `v1.5.2-proton` | BSD-3-Clause |
| `github.com/ProtonMail/go-mime` | `v0.0.0-20230322103455-7d82a3887f2f` | MIT |
| `github.com/ProtonMail/go-proton-api` | `3f8fbebac58d144861efb8c41a04562389498125` | MIT |
| `github.com/ProtonMail/go-srp` | `v0.0.7` | MIT |
| `github.com/ProtonMail/gopenpgp/v2` | `v2.11.1-proton` | MIT |
| `github.com/PuerkitoBio/goquery` | `v1.12.0` | BSD-3-Clause |
| `github.com/andybalholm/cascadia` | `v1.3.3` | BSD-3-Clause |
| `github.com/bradenaw/juniper` | `v0.15.3` | MIT |
| `github.com/cloudflare/circl` | `v1.6.3` | BSD-3-Clause + bundled BSD notice |
| `github.com/cronokirby/saferith` | `v0.33.0` | MIT + BSD-3-Clause (LICENSE_go) |
| `github.com/emersion/go-message` | `v0.16.0` | MIT |
| `github.com/emersion/go-textwrapper` | `v0.0.0-20200911093747-65d896831594` | MIT |
| `github.com/emersion/go-vcard` | `v0.0.0-20230331202150-f3d26859ccd3` | MIT |
| `github.com/go-resty/resty/v2` | `v2.0.0-20250929142426-e3dc6308c80b` | MIT |
| `github.com/google/uuid` | `v1.6.0` | BSD-3-Clause |
| `github.com/pkg/errors` | `v0.9.1` | BSD-3-Clause |
| `github.com/sirupsen/logrus` | `v1.9.4` | MIT |
| `gitlab.com/c0b/go-ordered-json` | `v0.0.0-20201030195603-febf46534d5a` | MIT |
| `golang.org/x/crypto` | `v0.56.0` | BSD-3-Clause |
| `golang.org/x/net` | `v0.58.0` | BSD-3-Clause |
| `golang.org/x/sync` | `v0.22.0` | BSD-3-Clause |
| `golang.org/x/sys` | `v0.47.0` | BSD-3-Clause |
| `golang.org/x/text` | `v0.41.0` | BSD-3-Clause |

主依赖 `go-proton-api` 固定 SHA `3f8fbebac58d144861efb8c41a04562389498125`；
`prepare.sh` 拒绝脏或错版缓存。resty 实际使用 ProtonMail fork，不能按原模块名遗漏。
上述源许可为 MIT/BSD 类；需保留版权、许可、免责条款及相应非背书限制。
本次未在该运行时闭包发现 GPL/AGPL 或专有许可。此结论来自固定版本源码 LICENSE，
不是未来版本或整个模块图的法律意见。

构建自动运行 `audit-dependencies.py`，找不到模块许可即失败，生成：

- `proton-dependencies.json`：两个架构的包闭包、模块版本及各许可文件 SHA-256；无机器路径。
- `proton-third-party-notices.txt`：模块全部 LICENSE/COPYING/NOTICE 文件与 Go 标准库许可。

两者嵌入 `Contents/Resources/`，包含 circl 子目录及 saferith 的额外 BSD 许可。
审计工具使用本地已解析源码，不访问用户数据库/钥匙串；依赖下载仅发生在构建时。
Go 构建工具自身的 telemetry 配置是开发机设置，不由 app 开启或修改。

## 遥测结论及证据边界

实际包闭包没有 telemetry/analytics/sentry 命名的导入。对编译源文件搜索这些词、
HTTP URL、`init`，并核对网络与初始化路径：go-proton-api 默认主机为
`https://mail.proton.me/api`；resty/Go transport 按调用请求，不建立独立收集器；
密码学依赖初始化只注册算法/硬件特性，不发送网络请求。`core_settings.go` 有
`SetUserSettingsTelemetry`，但 helper 从未调用，也没有启用 SDK 遥测/崩溃上报 hook。
`x/sys` 的 `SYS_TELEMETRY` 是系统调用常量，不是上报调用。

据当前源码与实际调用路径，未发现 helper 自动遥测、第三方统计端点或内容上报。
该结论为有边界的静态审计，不能用关键词扫描证明任意未来代码都不联网；
本次未做真实账号抓包或系统级全流量监控。API 请求本身必然向 Proton 发送操作所需数据。

原始许可可对照固定源码，例如
[go-proton-api LICENSE](https://github.com/ProtonMail/go-proton-api/blob/3f8fbebac58d144861efb8c41a04562389498125/LICENSE)、
[go-crypto LICENSE](https://github.com/ProtonMail/go-crypto/blob/v1.5.2-proton/LICENSE)。
审计以本地解析到的实际文件和生成的 SHA-256 为准。

## 重复回归

```sh
bash tools/proton-spike/run.sh test
bash Tests/proton-helper-regression.sh
bash Tests/proton-sync-regression.sh .build/proton-evidence
python3 tools/proton-spike/audit-dependencies.py .build/proton-audit
bash release.sh
```

Go 用例覆盖：新密钥替换旧密钥、轮换失败禁止旧密钥使用、缺失/格式变化、错误地址密钥、
错误密文、解密成功但签名未验证、断网、超时、HTTP 代理转发、407、429、5001/5003、
验证码错误与挑战绑定。合成服务断言固定客户端头、不自动重试、错误不含原始诊断。
Swift 覆盖不同错误提示、失败游标重放、账号隔离、删除/搜索清理、只读操作和签名提示渲染。
这些用例不替代真实账号、真实私钥轮换、实际限流或系统代理验收。

## 2026-11-03 后续返工：隔离磁盘验证与剩余门禁

来源：ACM-797 评论 `01a19fe8-e957-748f-8d64-83329a08c741`、ACM-798 评论
`01a1a006-3129-7164-a2d9-2f73c079cade`。events 的独立通过不代表整单通过。

新增 `bash Tests/cache-disk-regression.sh` 使用临时 `CFFIXED_USER_HOME`，启动后断言
Application Support 位于隔离目录，再执行真实 `AppState.removeAccount → ArchiveClient →
LocalEngine.shared → Store/MailCache`。钥匙串和 MainWindow 被替代，真实产品磁盘路径代码
未替代；不使用用户数据库、账号、安装版或进程。覆盖：

- 现存 0755 目录及 0666 的 DB/WAL/SHM 收紧为 0700/0600；通过第二个打开的 SQLite
  连接保留现存 WAL/SHM，验证实际权限迁移。Store 在打开 SQLite 前后处理侧文件，权限
  迁移失败直接抛错，初始化失败会关闭 SQLite 句柄。
- SQLite `max_page_count` 导致真实 SQLITE_FULL 写入失败并回滚；`query_only=ON`
  导致实际 App 删除路径写失败，错误向上传播，数据库事务未部分删除。
- 删除账号后实时核对磁盘数据库、FTS 和真实邮件头 JSON，另一个账号保持可读；JSON
  不含 body。邮件头目标替换为目录时触发真实文件写入错误：删除操作显式报错，清除失败
  写入的旧目标，并可恢复写入空缓存。不是把模拟 save 函数返回失败当成磁盘验证。

上述是源代码集成路径测试，不是鼠标点击安装版的 UI 自动化，也不覆盖真实钥匙串/远端
撤销、磁盘掉电、文件系统损坏、ACL/所有者错误、磁盘硬件故障或所有 I/O 组合。
普通延迟保存仍为尽力执行；账号移除使用 throwing `saveChecked`，写入失败不再静默成功。
如果目录访问/权限预检或旧文件删除本身失败，仍须人工处理，不能承诺数据已经清除。
缓存继续为明文；历史 WAL/FTS、SSD、快照及备份的物理抹除边界不变。

Swift：布局尺寸常量明确 nonisolated；IMAP 回调使用 `Mutex` 保护一次性 completion，
在锁外恢复 continuation。已知未使用返回值改为明确丢弃，不改变既有尽力执行语义。
IMAP 文件及实际 SidebarMetrics 源码片段结合 LayoutState 的 Swift 6 / warnings-as-errors
定向 typecheck 通过。完整 `swift build -Xswiftc -swift-version -Xswiftc 6` 仍失败：
ProtonHelper 泛型 Sendable、Store/IMAP 调用的隔离传递、Gmail JSON `[String: Any]`
及 ArchiveModels 返回值跨 actor 等仍需进一步迁移。因此**整项目 Swift 6 尚未就绪**，
不通过 unchecked 声明、关闭检查或改写旧验收掩盖该阻断。

远程内容静态复核：`MailHTMLView` 禁止 JavaScript，但远程内容开启时允许 HTTP/HTTPS
图片及 HTTPS 样式、字体；`MailDetailView` 与设置页的 `loadRemoteImages` 默认值为 true。
所以有远程跟踪请求风险，静态“helper 无遥测”不能覆盖这部分。验证码使用 nonPersistent
WebKit 存储，主框架限制官方 HTTPS 来源及挑战绑定，但子资源网络未逐包验证。
本轮不修改这些产品行为；需用户决定远程内容策略并授权隔离网络/隐私验收。

## 用户自用范围修订（2026-11-03）

用户评论 `01a1a017-2c51-7c15-9228-6908bbe10c5e` 明确：pigi 当前仅限用户自用，
不打算分发。该说明覆盖本报告此前将签名/真实环境缺口列为门禁的处置建议；历史测试
结果和原独立 BLOCKED 结论不改写为通过。

- **第 4 项取消**：Developer ID、公证、spctl 不再是本单要求。自用可接受 ad-hoc；
  已测 spctl 拒绝为已知现象，不需要修，不申请证书或公证。未来分发需求另开单。
- **第 2/3/6 项需要真实环境的部分**：真实账号/轮换/服务限流、认证代理/CONNECT、
  PAC/系统代理/VPN、远程邮件/官方验证页流量、系统抓包及运行时全流量审计，统一记为
  **未验证，需用户决定；不作为本单未完成阻断**。没有新授权，不操作真实环境。
  静态许可/源码结论、合成回归和远程内容风险说明继续保留，不等于用户接受风险。
- **第 1 项继续有效**：已补隔离磁盘权限迁移、SQLite 写失败及实际 AppState 删除到
  磁盘缓存链路测试，范围和未覆盖组合如上；WAL/FTS、SSD、备份物理抹除限制不变。
- **第 5 项继续有效**：已知布局常量和 IMAP 回调并发警告已修，定向 Swift 6 检查
  通过；完整 Swift 6 构建仍退出 1，上述跨 actor/Sendable 问题未修，明确保留开放项。
- **ACM-797 events 阻断继续有效且已有修正**：`e437e89` 保留 5001/5003/9001
  分类；ACM-798 独立复验已确认该局部修复。旧整单 BLOCKED 不因此升级为整单通过。

本轮不 push、合并、部署；不修改远程内容默认值或声称验证了发件人身份。
