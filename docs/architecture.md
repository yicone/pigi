# 架构

pigi 没有服务器。同步在 SwiftPM library `PigiCore` 的 `LocalEngine`(Swift actor)里完成,App 通过本地包依赖使用它。界面通过 `ArchiveClient` 门面与引擎交互。Gmail 的系统浏览器登录留在 App 里;令牌刷新在 library。

```
SwiftUI 界面 ── AppState ── ArchiveClient ── LocalEngine ─┬─ GmailSession (REST, OAuth PKCE, history 增量)
                                                          ├─ ImapConnection (Network.framework TLS)
                                                          └─ Store (系统 SQLite3, WAL, FTS5 trigram)
```

## 数据

- 数据库:`~/Library/Application Support/pigi/mail.db`;列表头缓存:`.../pigi/mail-headers.json`。
- 表:`accounts`、`messages`(含 `seq` 变更序号)、`attachments`、`muted`、FTS5 虚表。
- 变更流:每次写入递增 `seq`;界面用 `changes(after:)` 增量拉取,`events()` 推送唤醒。
- 状态:`inbox / archived / trash / spam / deleted`;标签沿用 Gmail 词汇 `INBOX / UNREAD / STARRED / TRASH / SPAM`。

## Gmail

- 用户自备 OAuth 客户端(iOS 类型,无 secret),PKCE,scope `gmail.modify`。客户端 ID 存 UserDefaults `gmailClientID`。
- 首次回填默认 30 天;之后用 `history.list` 增量。请求限速 8/s,遇 401/配额/5xx 重试。
- 刷新令牌存钥匙串。

## IMAP

- 自实现的 TLS IMAP 客户端:LOGIN、LIST、SELECT、UID SEARCH/FETCH/STORE/MOVE/COPY、EXPUNGE。
- 每 60 秒轮询;UIDVALIDITY 变化时旧行标记删除。归档移到 `\Archive`(缺失则创建),删除移到 `\Trash`。
- 密码存钥匙串(`imap-<email>`)。

## 解析

`MIME` 解析 RFC 2047 编码词、quoted-printable、base64、multipart、字符集与 RFC 2231 文件名。`Detect` 提取验证码、退订信息(one-click / link / mailto,仅公网 URL)与地址。

## 测试

调试构建设置环境变量 `PIGI_INSECURE_TLS=1` 可连接自签名证书的本地 IMAP 测试服务器(仅 DEBUG)。

## 目录

```
Package.swift        PigiCore SwiftPM library
Sources/PigiCore/    同步引擎、钥匙串、Gmail token refresh
Pigi/                App 源码(界面、AppState、更新、AppKit 交互登录)
landing/             官网(Cloudflare Workers Static Assets)
docs/                文档
```

## 界面与刷新（0.1.1）

外观选择保存在 appearanceMode，原生窗口与 WebKit 正文共用深浅色。面板邮箱菜单提供刷新，标题右上角图标打开主窗口；批量已读保存当前列表未读 ID。验证码通知通过 category/action 复制已提取的验证码。

手动刷新调用本地引擎 poke，观察账号 last_sync/错误，期间读取本地变更；同一刷新期间防重入，错误和超时不会误报成功。邮箱同步中收到触发会合并为后续一轮；不改变 Gmail 增量同步和 IMAP 后端。Gmail 现有 8 请求/秒不是按配额单位加权的预算，大量历史回填仍可能限流。

回归命令：`bash Tests/workflow-regression.sh`（7 项外观、刷新及通知）；`bash Tests/panel-layout-regression.sh`（8 项未读计数/范围布局，内存数据库）；`bash Tests/mail-appearance-regression.sh`（12 项真实 WebKit 深浅色渲染）。测试不读取真实邮件或凭据。
