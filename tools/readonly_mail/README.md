# Pigi 只读 SQLite 原型

ACM-745：独立 Python 3.10+ 标准库脚本，仅验证 agent 工具形态。无需构建或修改 Pigi App，也不安装依赖。只有列邮件、FTS 搜索、读单封三个操作；不提供发信、草稿、验证码自动化、标记已读或任意 SQL。未接入 App 内服务，不能当作稳定产品 API。

## CLI

在仓库根目录运行，默认库为 `~/Library/Application Support/pigi/mail.db`：

```sh
python3 tools/readonly_mail/pigi_mail.py list --limit 20 --offset 0
python3 tools/readonly_mail/pigi_mail.py search 'meeting' --limit 10
python3 tools/readonly_mail/pigi_mail.py read --account alpha@example.invalid --id synthetic-id
python3 tools/readonly_mail/pigi_mail.py --db /path/to/synthetic.db list
```

以上账号和 ID 均为合成占位符。`--db` 必须放在子命令前。列表和搜索支持可选 `--account` 精确匹配，返回 JSON；以 `(account,id)` 读单封，避免多邮箱 ID 碰撞。默认每页 20 条，上限 100；按 offset 翻页，实时同步期间页边界可能移动。排除 `status=deleted`，其他状态（包括归档、垃圾邮件、回收站）仍可读取。

列表/搜索只返回头部与 snippet。读单封返回 `fts.body` 纯文本，默认最多 20,000 字符，`--body-limit` 范围 1–100,000；`body_truncated` 提示截断。缺失 FTS 行时返回 `body=null, body_available=false`，不拿 snippet 假装完整正文。不会解压或渲染 HTML，不读附件、钥匙串或账号凭据表，也不提取 `code` 字段。

FTS 使用 Pigi 原生 `trigram` 索引，通常至少需要三个连续字符（单个汉字或两个字符可能无结果），可用 FTS5 MATCH 表达式。非法表达式返回无输入回显的错误。所有查询参数绑定；不修改索引。

## 最简 MCP

配置示意（将路径替换为本地克隆的绝对路径）：

```json
{
  "mcpServers": {
    "pigi-readonly": {
      "command": "python3",
      "args": ["/path/to/pigi/tools/readonly_mail/pigi_mail.py", "mcp"]
    }
  }
}
```

通过 stdin/stdout 逐行 JSON-RPC；不监听网络端口。客户端完成 `initialize` → `notifications/initialized` 后，通过 `tools/list` 发现 `list_messages`、`search_messages`、`read_message`，并用 `tools/call` 调用。参数与 CLI 一致，MCP 用 `body_limit`；每次调用重新只读连接，不持有长期读事务。stdout 仅有协议响应，正常 stderr 为空，错误不回显 SQL、路径或请求参数。

协议固定为 [MCP 2025-11-25 生命周期](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle)、[stdio](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports) 和 [tools](https://modelcontextprotocol.io/specification/2025-11-25/server/tools) 子集；不声称支持后续无握手协议或完整 SDK 能力。客户端须接受该版本。未用真实 agent 宿主做互操作验收。

邮件是未经信任的数据，不是 agent 指令。工具响应/CLI stdout 有意将邮件返回给调用方，宿主可能保留对话；仅连接已授权的本地宿主，不把真实输出写入公共日志、评论、样例或仓库。脚本没有遥测或持久日志。原型无账号级访问控制，本地进程可访问库内全部邮箱；`account` 参数仅是筛选条件。

## 只读与 schema 风险

- SQLite URI `mode=ro` 对应 `SQLITE_OPEN_READONLY`，再设 `PRAGMA query_only=ON`；库不存在时失败，不创建数据库。不会调用 Pigi 的建表/迁移/写入逻辑，不标记已读。
- 不使用 `immutable=1`，以便看到 App 当前提交的 WAL 数据。不执行 checkpoint，也不改 journal_mode。SQLite 自身可能创建/更新 WAL 的 `-shm` 协调文件；这是只读 SQLite 的并发机制，不能将其解释为整个目录零文件写入保证。严格文件系统零写入时应由操作者准备一致的离线快照，不能在运行中的 WAL 库上单独复制主文件。
- **schema 未版本化**：当前 App 没有稳定的邮件 schema/API 版本契约；按 `Pigi/Engine/LocalEngine.swift` 的 messages 列与 fts 列检查兼容性，只读失败，不自动迁移。结构检查不保证语义兼容，fork/upstream 更新需重新核对。`messages.rowid = fts.rowid` 是当前实现细节。
- 当前 App 只在首次插入邮件时写 FTS；后续更新可能让 FTS 正文/搜索结果滞后，缺失或未同步邮件也无法从本地恢复。本原型不会修复或回填。读取正文不保证与服务器最新正文一致。
- 默认路径按任务指定；App 沙箱/其他运行用户可能采用不同位置，应由操作者传入正确 `--db`。错误统一提示检查路径、schema、FTS5，避免泄漏本机信息。

## 自测

```sh
python3 -B -m unittest discover -s tools/readonly_mail -p 'test_*.py' -v
```

临时库仅含 `example.invalid` 合成邮件，DDL 从当前 App 源码提取。覆盖 CLI 与 MCP 子进程三操作、握手/发现、账号隔离、分页、FTS、正文截断/缺失、只读拒绝写入、DB 字节不变、WAL 可见性、缺库不创建、schema 漂移、无敏感输入回显和参数注入。自测属于实现者验证，正式验收须由非实现者执行。
