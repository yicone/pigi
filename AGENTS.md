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
- 本机登录钥匙串里有一张自签代码签名证书 “Pigi Local Signing”，仅用于让本机多次重编译保持同一签名身份，这样钥匙串对 `one.yic.pigi` 的“始终允许”只需点一次。`tools/build-debug.sh` 与 `release.sh`（未设置 `PIGI_SIGNING_IDENTITY` 时）会自动使用它。
- 首次授权：换成新签名后第一次运行，系统会弹窗询问 pigi 能否访问钥匙串条目，由用户本人点“始终允许”（需要时输入登录密码）。代理不得代点、不得索要或记录密码。
- 换机器需要重新创建该证书（openssl 生成后 `security import` 到登录钥匙串，允许 `/usr/bin/codesign` 使用私钥；私钥与 p12 临时文件用后删除，不进仓库）。
- 没有该证书时自动退回 ad-hoc，每次重编译后钥匙串都会重新要求授权。

## 凭据
邮箱账号、令牌、密码等一律不进仓库、提交信息、PR/Issue 评论与聊天记录。
