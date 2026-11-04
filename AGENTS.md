# AGENTS.md

## 项目
pigi 的个人 fork（macOS 原生邮件客户端），仅供仓库主人自用，不分发、不公证、不上架。

## 仓库边界
- 只在 `yicone/pigi` 工作；上游 `xiezhaoye/pigi` 只读，绝不推送、绝不提 PR。
- push、开 PR、合并都必须先得到用户批准。

## 日常运行形态
- 只运行由 `~/Workspace/pigi` 编出来的 Debug 版（`build/Build/Products/Debug/pigi.app`）。
- 不要在 `/Applications` 并存安装版：同一 bundle ID `one.yic.pigi` 与同一钥匙串条目会互相干扰。旧安装版备份在 `~/.local/state/backups/pigi/`。
- “部署”默认指重编译 Debug 版；“更新安装版”只有用户明确说时才做。
- 部署前先请用户确认，再退出旧进程；不要自动退出、重启或杀 pigi 进程。
- 工作区保持干净：本地调试改动放分支或 `git stash`，不要留在 main 上。

## 构建
- Debug：`tools/build-debug.sh`（含 `xcodegen generate`、编译与签名校验，不启动 app）。
- Release 打包：`./release.sh`（不公证；`--publish` 已禁用）。
- `Pigi.xcodeproj` 不入库，由 `xcodegen` 生成；需要 PATH 含 `/opt/homebrew/bin:/usr/local/go/bin`。
- Proton helper 自检：`build/Build/Products/Debug/pigi.app/Contents/MacOS/pigi --proton-helper-selftest`。

## 签名
- `project.yml` 默认 ad-hoc 签名，保持不改，方便其他环境编译。
- Debug（`tools/build-debug.sh`）优先用登录钥匙串里有效的 Apple Development 证书（`security find-identity -v -p codesigning`），并确认证书 OU 里有 Team ID。身份名括号中的 10 位字符不一定等于这个 Team ID；以 `codesign -dvv` 的 `TeamIdentifier` 为准。app 与 Proton helper 使用同一身份。同一张证书下重编译时，系统按团队身份记住钥匙串授权，通常不必再点“始终允许”。
- 找不到这类证书时，脚本会明确提示并退回自签 “Pigi Local Signing”。该证书没有 Team ID，macOS 按 cdhash 记授权，重编译后仍会弹窗。连这张自签证书也没有时，再退回 ad-hoc，并说明每次重编译都要重新授权。
- `release.sh` 在未设置 `PIGI_SIGNING_IDENTITY` 时仍默认 “Pigi Local Signing”（仅自用，不可公证）。Release 要用别的身份时，显式设置 `PIGI_SIGNING_IDENTITY`（以及需要时的 `PIGI_DEVELOPMENT_TEAM`）。
- 证书续期、更换签名身份，或第一次改用 Apple Development 之后，要由用户本人再点一轮“始终允许”（需要时输入登录密码）。代理不得代点、不得索要或记录密码。续期在 Apple Developer 更新 Apple Development 证书并装入登录钥匙串，允许 `/usr/bin/codesign` 使用对应私钥；私钥与 p12 不进仓库。
- 换机器：安装同一 Team 的 Apple Development 证书。若只能自签，再创建 “Pigi Local Signing”（openssl 生成后 `security import` 到登录钥匙串，允许 `/usr/bin/codesign` 使用私钥；临时私钥与 p12 用后删除，不进仓库）。
- 钥匙串条目合并为单条 `vault-v1` 由 ACM-813 负责。本脚本只选择签名身份，不创建、不修改、不删除钥匙串条目。签名切换后的首次“始终允许”可以和 ACM-813 迁移弹窗放在同一次用户操作里：若迁移还没跑过，先换好 Debug 签名，再让用户点授权，避免按旧 cdhash 授权后又因换证再弹一轮。

## 凭据
邮箱账号、令牌、密码等一律不进仓库、提交信息、PR/Issue 评论与聊天记录。
