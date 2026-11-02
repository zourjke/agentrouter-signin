# AgentRouter 签到面板

`agentrouter.org` 每日签到助手 —— 单文件 bash 面板，SSH 进去就能用。
支持多账号、GitHub 账号密码登录、自动检测两步验证、Telegram 推送、systemd 定时。

> 站点特性：没有签到按钮，**登录事件本身就是签到**（登录响应里 `checked_in:true` 即奖励到账）。
> 所以脚本做的事就是「每天重新登录一次 GitHub → 走 OAuth → 触发签到」。

---

## 特性

- **单文件** `agentrouter.sh`，依赖只有 `curl + jq + python3`（python3 仅用于算 TOTP）
- **新手向导**：6 步配完（环境自检 → 站点 → 网络 → 账号 → TG → 定时）
- **多账号**：任意数量，各自独立的 cookie jar
- **自动检测两步验证**：提交密码后看 GitHub 跳转，自动区分「无 2FA / TOTP / 邮箱设备验证」
- **TOTP 自动算码**：填了 base32 密钥后完全免人工
- **Telegram 推送**：贴 bot token 自动查 chat_id，签到结果推成卡片
- **定时容错**：每天 08:00–11:40 每 20 分钟重试，成功即停，次日 00:05 自动重新武装
- **断线自愈**：GitHub 线路被 SNI 阻断时不会瞎撞，直接跳过等下次

---

## 一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/<你的用户名>/agentrouter-signin/main/install.sh | bash
```

装完直接敲：

```bash
ck
```

就会进入新手向导。

### 手动安装

```bash
curl -fsSL https://raw.githubusercontent.com/<你的用户名>/agentrouter-signin/main/agentrouter.sh -o /root/agentrouter.sh
chmod +x /root/agentrouter.sh
ln -sf /root/agentrouter.sh /usr/local/bin/ck
ck
```

---

## 首次配置（向导 6 步）

```
[1/6] 环境自检      检查 curl / jq / python3
[2/6] 站点地址      默认 https://agentrouter.org
[3/6] 网络与代理    自动探测直连 / 常见代理端口
[4/6] 添加账号      GitHub 用户名 + 密码 → 自动检测两步验证
[5/6] Telegram      贴 bot token → 自动列会话 → 选一个 → 发测试消息
[6/6] 定时任务      装 systemd timer，每天 08:00 起重试
```

### 关于两步验证

| 检测结果 | 面板行为 |
|---|---|
| 未开启 2FA | 直接登录成功 |
| 已开启（TOTP） | 提示输入 6 位码；**填了 base32 密钥就自动算码** |
| 邮箱设备验证 | 提示输入 GitHub 邮件里的验证码 |

想完全免人工，把 Authenticator 的 base32 密钥填进去（面板里叫「TOTP 密钥」）。
拿密钥的办法：GitHub → Settings → Password and authentication → Authenticator app → 重新配置 → 二维码用任意扫码工具解出 `otpauth://totp/...?secret=XXXX`。

---

## 主菜单

```
 1) 添加账号（GitHub 账号密码，自动检测两步验证）
 2) 账号列表 / 状态检测
 3) 立即签到（全部账号）
 4) 单个账号签到
 5) Telegram 推送设置
 6) 定时任务
 7) 站点与网络设置
 8) 新手向导（重走一遍配置流程）
 T) 环境体检（站点/GitHub/节点）
 L) 查看日志        D) 删除账号
 0) 退出
```

---

## 命令行

| 命令 | 作用 |
|---|---|
| `ck` / `./agentrouter.sh` | 进面板（首次自动向导） |
| `./agentrouter.sh --cron` | 无交互跑一轮（定时任务用） |
| `./agentrouter.sh --otp 123456` | 带验证码免交互跑一轮 |
| `./agentrouter.sh --wizard` | 重跑向导 |
| `./agentrouter.sh --doctor` | 体检（依赖 / 站点 / GitHub / 出口） |
| `./agentrouter.sh --fix-node` | 逐个切换 Clash 节点，找能通 GitHub 的 |
| `./agentrouter.sh --debug` | 逐步调试日志 |
| `./agentrouter.sh --shortcut kk` | 装一个自定义快捷命令 |
| `./agentrouter.sh --list` / `--detect` | 列账号 / 检测会话 |

---

## 数据目录

```
~/.agentrouter/
├── config.json     站点/代理/额度换算/TG        (600)
├── accounts.json   账号凭据（密码明文存本机）    (600)
├── state.json      每日余额基线（算「较昨日」）
├── jars/           运行期 cookie jar
├── logs/           每日日志 + debug.log
└── .done_YYYY-MM-DD  当日成功标记
```

**建议**：把 `~/.agentrouter` 放在只给自己可读的位置，别提交到任何仓库。

---

## 常见问题

**Q：登录报 `error:http000` / `GitHub 线路不通`？**
A：`github.com` 被 SNI 定向阻断（`api.github.com` 却正常）。换出口节点，或等窗口：
```bash
./agentrouter.sh --fix-node    # 逐个试 Clash 节点
```

**Q：`GitHub 授权未拿到 code`？**
A：多半是线路在授权那一步断了，重跑即可；持续出现就 `--fix-node`。

**Q：`两步验证码校验失败`？**
A：码过期（30 秒）或线路超时。填 TOTP 密钥后由脚本自己算码，不会再出现。

**Q：`较昨日 —`？**
A：`state.json` 里还没有前一天基线，跑第二天起就有值。

**Q：cookie 会不会过期？**
A：会。失效时脚本用保存的账号密码自动重登（有 TOTP 密钥则全自动）。

---

## 安全说明

- 脚本不内置任何凭据，所有账号信息只存在本机 `~/.agentrouter/`（权限 600）
- 只对 `agentrouter.org` 与 `github.com` 发请求；Telegram 只调 `sendMessage`（不读消息）
- 请自行保管好服务器与配置目录权限

## License

MIT
