# 验证日志

本文记录本插件在**构建机**上能够验证的全部内容，以及**只能在真实 Unraid 主机上验证**的部分。
两类分开写，是因为把前者当作后者会给出虚假的交付信心。

最后更新：2026-11-06（插件版本 20261106，上游 komari-agent 1.5.11）

---

## 一、构建机环境

| 项目 | 值 |
|---|---|
| 宿主 | Windows 11 + MSYS2（GNU bash 5.3.20） |
| 可用命令 | `bash`、`git`、`tar`、`sha256sum` |
| 不可用命令 | `make`、`php`、`shellcheck`、`xz`、`pgrep`、`setsid` |
| Python | 3.12（`D:/Python312/python.exe`）；`python3` 是 WindowsApps 存根，不可用 |
| 网络 | 需要 HTTPS 代理；`curl`（Schannel 后端）TLS 握手失败，改用 Python urllib |

这些限制直接决定了下面"已验证"与"未验证"的边界。

---

## 二、已验证（可复现）

### 2.1 构建全链路

```
build-plugin.sh  →  0
lint-plg.sh      →  0
check-php-syntax.py src/  →  0
verify-release.sh →  0
smoke-test.sh     →  0
```

产物：

| 文件 | 大小 | 说明 |
|---|---|---|
| `dist/unraid-plugin-komari-agent-20261106-x86_64-1.txz` | 46984 字节 | Slackware 包，38 个成员 |
| `dist/unraid-plugin-komari-agent.plg` | ~23 KB | 直连变体 |
| `dist/unraid-plugin-komari-agent-proxy.plg` | ~24 KB | gh-proxy 镜像变体 |

### 2.2 可复现构建

| 校验 | 结果 |
|---|---|
| 同一目录重复构建 | 哈希一致 `606fd689…a53aef` |
| 全新副本构建（不同路径） | 与原地构建**哈希完全一致** |
| tar 成员顺序 | 按路径分量排序，locale 无关 |
| mtime / uid / gid / uname / gname | 全部固定（mtime = 1577836800） |

复现性由 Python `tarfile` + `lzma` 保证，不依赖宿主 `tar` 实现。这一点是必需的：GNU tar 与 bsdtar 在 mode 字段宽度、uname、xattr pax 头、成员顺序上都不同，同一份源码会产出不同字节。

### 2.3 打包正确性（两个真实缺陷，已修）

这两个缺陷都由运行时成员在集成阶段发现，且**都会导致"安装成功但插件什么都不做"**：

**缺陷 1：tar 成员名用了反斜杠**

`os.path.join` 在 Windows 上产出 `etc\rc.d\rc.komari-agent`。tar 成员名按定义是 POSIX 路径，
反斜杠在 Unraid 上是普通字符，GNU tar 会把它解成一个名为 `etc\rc.d\rc.komari-agent` 的扁平文件，
`/etc`、`/usr/local/emhttp`、`/install` 全部为空。

- 实测：38 个成员中 **34 个**路径错误
- 修复：成员名改用 `posixpath.join`，符号链接目标同样归一化
- 回归防护：`verify-release.sh` 断言所有成员名不含 `\`、不是绝对路径、不含 `..`

**缺陷 2：所有脚本权限为 0644**

`st.st_mode & 0o111` 在 git/MSYS 工作区上恒为假，因为该文件系统不报告 POSIX 执行位。
结果是 rc 脚本与全部运行时脚本在 Unraid 上不可执行。

- 修复：构建脚本维护一份**显式清单**（`EXECUTABLE_PATHS`），由归档写入器按路径强制 0755，
  不再从工作区继承权限
- 回归防护：`verify-release.sh` 断言 `rc.komari-agent`、`doinst.sh`、`scripts/*.sh` 为 0755，
  `slack-desc`、`logrotate.d`、`plugin.info` 不是可执行

修复后实测模式：

```
0755  ./etc/rc.d/rc.komari-agent
0755  ./install/doinst.sh
0755  ./usr/local/emhttp/plugins/unraid-plugin-komari-agent/scripts/*.sh   (8 个)
0644  其余
```

### 2.4 PHP / 页面语法

- `check-php-syntax.py`：5 个 PHP 文件 + 3 个 `.page` 文件通过
- 检查器本身做过**负向测试**：故意构造未闭合大括号、未终止字符串、调用未定义助手三种错误，
  三种都被正确报出（避免"永远通过"的假检查）
- 三个 `.page` 均为 LF-only，头部全为 `key="value"` 格式

检查器在开发中自身修掉两个缺陷，记录在此以防回归：

1. `<?php` 不含 `>`，用 `text.find('>', index)` 跳到下一个 `>` 会吞掉真实代码，
   导致每个纯 PHP 文件误报"never closed"。改为按标签长度步进。
2. 纯 PHP 文件**不应**有结尾 `?>`（PHP 官方推荐），原逻辑误报。改为只对混合 HTML/PHP 的文件要求闭合。

### 2.5 运行时脚本静态校验

- 12 个脚本全部 `bash -n` 通过
- 全部 `exit 0`：`grep -E '^\s*exit\s+[^0]'` 为空
- 无 `set -e` / `set -u`
- 无 CRLF
- 打包后仍为 0755（见 2.3）

### 2.6 配置读取与启动逻辑（沙箱模拟）

`smoke-test.sh` 把包解开到临时目录，用 `sed` 把绝对路径重写到沙箱，并用一个只 sleep 的桩程序
替代真实 agent，然后执行真实的 `start.sh` / `stop.sh` / `status.sh`：

| 检查 | 结果 |
|---|---|
| `start.sh` 退出码 | 0 |
| 写出 pidfile | 是 |
| 重复 `start.sh` | 退出 0，且不产生第二个 supervisor |
| `status.sh` 输出 | 合法 JSON，schema 为 `komari-agent-status/1`，六个 section 齐全 |
| token 不出现在 status JSON | 是 |
| `stop.sh` 退出码 | 0，且删除 pidfile |
| 重复 `stop.sh` | 退出 0（幂等） |
| `ENABLED=0` | 不启动，退出 0 |
| `ENDPOINT` 为空 | 不启动，退出 0 |

### 2.7 `.plg` 静态校验

`lint-plg.sh` 对两个 `.plg` 变体逐项通过：

- XML 良构，`PLUGIN` 根属性齐全（`name`/`author`/`version`/`pluginURL`/`support`/`min`/`launch`/`icon`）
- 实体已展开：属性值中无残留 `&entity;`
- CDATA 中无实体引用（CDATA 是字面文本，实体在那里不会被展开）
- 版本号符合 `YYYYMMDD[.a-z]`，且不等于上游版本
- `<CHANGES>` 以 `##<name>` 开头
- 每个 `<FILE>` 的 URL 都有配套 SHA256，且为 https
- 缓存文件位于 `/boot/config/plugins/<name>/`
- install / remove 脚本各一份，`bash -n` 通过
- 使用 `upgradepkg --install-new`、清理用 `rm -f`、卸载调 `removepkg`
- 无 `exit [非零]`、无 `set -e/-u`
- 无残留 `@@PLACEHOLDER@@`
- token 未被放到命令行（`--token $VAR` 形式）
- `launch="Settings/KomariAgent"` 能解析到包内 `.page`
- 镜像变体的 txz 与二进制 URL 确实经过 `gh-proxy.org`

### 2.8 上游二进制来源

| 项目 | 值 |
|---|---|
| 来源 | `komari-monitor/komari-agent` Release `1.5.11` |
| 资产 | `komari-agent-linux-amd64` |
| 大小 | 12,585,218 字节 |
| SHA256 | `78c28d89e523816baea010c0ed0714f245f508ffdaca0540f5c9f230f7053c8c` |
| 校验 | 与 GitHub Releases API 的 `digest` 字段逐字一致 |
| ELF 校验 | `\x7fELF`，e_machine = 62（x86-64） |

SHA256 记录在 `plugin/upstream.lock`，构建时逐字节校验。构建**不查询 API**：锁文件在仓库里，
因此构建可复现、可离线、不吃 API 限流（未认证 60 次/小时），上游升级是一次可评审的 diff。

---

## 三、未验证（必须在真实 Unraid 主机上完成）

以下内容**无法**在构建机上验证，交付时不得声称已验证。

### 3.1 `.plg` 安装器全流程

构建机没有 Unraid 安装器（`/usr/local/sbin/plugin`）。以下路径全部未经实机确认：

- `plugin install` 下载 flash 上的两个 `<FILE>` 并校验 SHA256
- `upgradepkg --install-new` 安装 txz
- `install.sh` 从 flash 缓存把二进制装到 `/usr/local/sbin/komari-agent` 并设 0755
- `/var/log/plugins/<name>.plg` 软链建立
- 卸载路径 `plugin remove` 完整清理

### 3.2 进程守护与信号

这是**最需要实机验证**的部分。MSYS 上：

- `pgrep` 是 niu 包装器的 shim，行为不可信（对不存在的命令也报存在，真实调用返回 127）
- `setsid` 不存在
- 信号不跨 Windows 进程边界，`stop.sh` 无法结束 supervisor

因此以下均**未验证**：

| 项目 | 说明 |
|---|---|
| `pgrep -f '^/usr/local/sbin/komari-agent'` 能否找到 agent 子进程 | `agent_pids` 在沙箱里恒为空 |
| `pgrep --ns $$` 特性探测是否正确降级 | 探测逻辑本身未经真实 procps-ng 验证 |
| supervisor 的 `wait` + 重启循环 | 沙箱里 supervisor 无法被终止，重启路径未跑通 |
| `stop.sh` 的 TERM → 10 秒 → KILL 序列 | 信号未送达 |
| agent 收到 SIGTERM 后 flush `net_static.json` | 同上 |
| 崩溃后 10 秒重启 | 未触发 |

**实机验证步骤**（建议按序执行）：

```bash
# 1. 安装
cp unraid-plugin-komari-agent.plg /boot/config/plugins/
plugin install /boot/config/plugins/unraid-plugin-komari-agent.plg

# 2. 确认二进制与权限
ls -l /usr/local/sbin/komari-agent          # 期望 -rwxr-xr-x
ls -l /etc/rc.d/rc.komari-agent             # 期望 -rwxr-xr-x
ls -l /usr/local/emhttp/plugins/unraid-plugin-komari-agent/scripts/   # 期望全部 -rwxr-xr-x

# 3. 配置后启动
/etc/rc.d/rc.komari-agent start
/etc/rc.d/rc.komari-agent status            # 期望 supervisor_pid 与 agent_pid 均非 0
tail -n 30 /var/log/komari-agent.log

# 4. 面板侧确认主机上线

# 5. 崩溃拉起
kill -9 "$(pgrep -f '^/usr/local/sbin/komari-agent')"
sleep 12 && /etc/rc.d/rc.komari-agent status   # 期望 agent_pid 已变化且非 0

# 6. 停止与 flush
/etc/rc.d/rc.komari-agent stop
ls -l /boot/config/plugins/unraid-plugin-komari-agent/net_static.json   # 期望存在且非空

# 7. 幂等
/etc/rc.d/rc.komari-agent stop              # 期望退出 0
/etc/rc.d/rc.komari-agent start             # 期望只起一个 supervisor
/etc/rc.d/rc.komari-agent start             # 期望提示已在运行

# 8. 开机自愈（最关键）
reboot
# 重启后确认插件仍在 Plugins 页、服务自动起来、二进制已从 flash 恢复

# 9. 卸载
plugin remove unraid-plugin-komari-agent.plg
# 确认 cfg 与 net_static.json 保留，其余清除
```

### 3.3 WebGUI 页面渲染

页面按 Dynamix `.page` 约定编写，`check-php-syntax.py` 通过，但**未在 Unraid 的 Dynamix 里实际渲染过**。
需要确认：

- `Settings → Komari Agent` 出现且三个 tab（summary / Settings / Status）可切换
- 表单保存后 cfg 内容正确，`#command` 的进度输出正常显示
- Status 页的异步状态加载正常，不阻塞首屏
- 图标在 Plugins 页显示

### 3.4 一个已知的上游限制：`/update.php` 不转义

官方 `/update.php` 写 `KEY="value"` 时**不做任何转义**。任何字段含一个 `"` 就会提前终止字符串，
把整份 cfg 写坏（不只那个键）。这是官方实现，插件侧无法修。WebGUI 表单已在提交前做客户端拦截，
但这是缓解，不是根治。

### 3.5 CA 收录前置条件

- `ca/unraid-plugin-komari-agent.xml` 的 `<Support>` 目前指向 GitHub Issues；
  正式提交 CA 前应换成 Unraid 论坛支持帖
- `ca_profile.xml` 的 `<Forum>` 为注释占位
- `<Category>Tools:System</Category>` 需对照 CA 字段参考确认

---

## 四、构建机限制的成因（便于日后复现排查）

| 现象 | 成因 | 规避 |
|---|---|---|
| `python3` 立即失败，退出 9009 | WindowsApps 存根 | 用 `PYTHON=D:/Python312/python.exe` |
| `curl` 报 `SEC_E_NO_CREDENTIALS` | Schannel 后端 TLS 握手失败 | 构建脚本已内置 Python urllib 回退 |
| `make: command not found` | 本机未装 make | 直接调用 `scripts/*.sh`，效果等价 |
| `command -v pgrep` 报存在但调用退出 127 | niu 包装器 shim | 用真实调用 + 退出码判断，不要信 `command -v` |
| `pkill -f <dir>` 杀掉调用者自己 | 同上，shim 匹配到自身命令行 | 不要用 `pkill -f` 清理；改用 stop.sh |
| `rm -rf` 报 `Device or resource busy` | 残留进程占着目录 | 见上；Windows 上属预期 |
| `local rc=$?` 拿不到调用者退出码 | `local` 先执行，`$?` 变成它自己的状态 | 分两行写 |

---

## 五、结论

构建、打包、静态校验、可复现性、配置解析、启动/停止的**控制流**已在构建机上充分验证，
过程中修掉的两个打包缺陷都会导致静默失效，属于必须在发布前发现的类型。

进程守护、信号处理、开机自愈、WebGUI 渲染这四项**只能实机验证**，
第 3.2 节的步骤清单是发布前的验收依据。
