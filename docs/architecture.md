# 架构

pigi 没有服务器。同步在 SwiftPM library `PigiCore` 的 `LocalEngine`(Swift actor)里完成,App 通过本地包依赖使用它。界面通过 `ArchiveClient` 门面与引擎交互。Gmail 的系统浏览器登录留在 App 里;令牌刷新在 library。

```
SwiftUI 界面 ── AppState ── ArchiveClient ── LocalEngine ─┬─ GmailSession (REST, OAuth PKCE, history 增量)
                                                          ├─ ImapConnection (Network.framework TLS)
                                                          ├─ ProtonSession (只读 helper IPC, 事件游标)
                                                          └─ Store (系统 SQLite3, WAL, FTS5 trigram)
```

## 数据

- 数据库:`~/Library/Application Support/pigi/mail.db`;列表头缓存:`.../pigi/mail-headers.json`。
- 表:`accounts`、`messages`(含 `seq` 变更序号)、`attachments`、`account_labels`、`proton_snapshot`、`muted`、FTS5 虚表。
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

CI 与本地测试不得依赖、也不得写入真实 `~/Library/Application Support/pigi`（`mail.db`、`translations.db`、`mail-headers.json`、`agent.sock`）或 `~/Library/Containers`。会走到产品磁盘路径的回归二进制用 `-D PIGI_REGRESSION` 编译：进程若仍解析到真实用户目录，在创建文件前直接失败。`swift test` 同样拒绝这条默认路径。需要真的打开该目录时，用临时 `CFFIXED_USER_HOME` 与 `HOME`（见 `Tests/isolate-support.sh`）。快照比较整个真实 `pigi` 目录（含父目录自己的 mtime）。正在运行的 pigi 会改 `mail.db-wal`，并用原子替换改 `mail-headers.json` 和父目录 mtime；自托管 runner 上的旧回归还会打开默认 `translations.db`。有这些写入者时，快照变化不能算测试污染已经排除。核对前先退出 pigi、停掉 runner，并用 `lsof` 确认该目录没有打开者。

应用内「清空译文缓存」只删除库里的译文行，不删除文件。不要用 `mode=ro&immutable=1` 判断 `translations.db` 是否为空：`immutable=1` 不读 WAL，已提交在 WAL 里的译文会显示成 0 行。测试脚本不代删。仅在用户确认后，按下面的顺序清理；非空或查询失败都保留原文件。绝不删除 `mail.db`，绝不删除整个 `pigi` 目录。

1. 退出 pigi，并确认没有进程打开 `translations.db`、`translations.db-wal`、`translations.db-shm`。
2. 把这三个文件成组复制到一个空的临时目录。缺少的侧文件不要另造，也不要单独复制主库。
3. 在副本上查询，让 SQLite 读同目录的 WAL。不要加 `immutable=1`，也不要执行 checkpoint：

```sh
sqlite3 "file:$COPY/translations.db?mode=ro" "PRAGMA query_only=ON; SELECT count(*) FROM translations;"
```

`mode=ro` 可能更新副本自己的 `-shm`。那只发生在副本目录里。
4. 结果不是单独一个 `0`，或查询失败：停止，保留原文件。
5. 结果是 `0` 且用户确认后，只删除原来的这三个文件。

## 目录

```
Package.swift        PigiCore SwiftPM library
Sources/PigiCore/    同步引擎、钥匙串、Gmail token refresh
Pigi/                App 源码(界面、AppState、更新、AppKit 交互登录)
docs/                文档
```

## 界面与刷新（0.1.1）

外观选择保存在 appearanceMode，原生窗口与 WebKit 正文共用深浅色。面板邮箱菜单提供刷新，标题右上角图标打开主窗口；批量已读保存当前列表未读 ID。验证码通知通过 category/action 复制已提取的验证码。

手动刷新调用本地引擎 poke，观察账号 last_sync/错误，期间读取本地变更；同一刷新期间防重入，错误和超时不会误报成功。邮箱同步中收到触发会合并为后续一轮；不改变 Gmail 增量同步和 IMAP 后端。Gmail 现有 8 请求/秒不是按配额单位加权的预算，大量历史回填仍可能限流。

回归命令：`bash Tests/workflow-regression.sh`（7 项外观、刷新及通知）；`bash Tests/panel-layout-regression.sh`（8 项未读计数/范围布局，内存数据库）；`bash Tests/mail-appearance-regression.sh`（12 项真实 WebKit 深浅色渲染）。测试不读取真实邮件或凭据。
