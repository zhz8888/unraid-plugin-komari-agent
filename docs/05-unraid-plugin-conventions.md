# Unraid 官方插件规范对照

本文记录本插件与 Unraid 官方插件规范的逐条对照关系：每一条规范是什么、官方依据在哪里、
本项目怎么落地、以及哪些点仍然无法验证。

对照对象是 Limetech 官方维护的插件与官方安装器源码：

| 参考对象 | 地址 |
|---|---|
| 官方安装器源码 | `unraid/webgui` → `emhttp/plugins/dynamix.plugin.manager/scripts/plugin`（990 行 PHP CLI） |
| 官方插件示例 | [`unraid/unraid-tailscale`](https://github.com/unraid/unraid-tailscale) |
| 官方插件示例 | [`unraid/apprise-plugin`](https://github.com/unraid/apprise-plugin) |
| 官方插件示例 | [`unraid/unraid-nvidia-driver`](https://github.com/unraid/unraid-nvidia-driver) |
| 第三方插件示例 | [`johnpwhite/unraid-plg-zram`](https://github.com/johnpwhite/unraid-plg-zram) |
| CA 收录指南 | <https://ca.unraid.net/submit/help> |

> 安装器在运行时位于 `/usr/local/sbin/plugin`，它是指向
> `/usr/local/emhttp/plugins/dynamix.plugin.manager/scripts/plugin` 的软链。

---

## 一、硬性要求（违反即失效）

### 1.1 版本号必须能用 `strcmp()` 正确排序

官方安装器比较插件版本用的是 **字节序字符串比较**，不是语义化比较：

```php
if (strcmp($version, $installed_version) < 0) {
    write("plugin: not installing older version\n");
```

这意味着语义化版本会出事：`strcmp("1.5.10", "1.5.9") < 0`，也就是
**1.5.10 会被 Unraid 判定成比 1.5.9 更旧而拒绝安装**。

> 本项目如果跟随上游版本号（`version="1.5.11"`），正好会踩在这个坑里：上游一旦发布
> 1.5.12，用户就收不到更新。

**本项目的做法**：插件版本用**发布日期** `YYYYMMDD`；同一天发布多次时，第二个版本起
追加字母后缀（`.a`、`.b`、`.c`……）。这套格式在字节序下正好等于时间序：

```
20261106 < 20261106.a < 20261106.b < 20261107
```

（`20261106` 是前缀，短的在前；`.` 的字节值 0x2E 小于数字，所以 `20261106.z` 仍小于
`20261107`。）

上游版本另存为 `upstream` 实体：

```xml
<!ENTITY version  "20261106">
<!ENTITY upstream "1.5.11">
```

`lint-plg.sh` 强制检查版本格式，并额外拒绝 `version == upstream`——两者相等意味着
重新打包同一个上游版本时无法推送给已安装用户。

### 1.2 安装脚本绝不能返回非零

安装器把 `<FILE Run=...>` 的退出码透传；非零会中止整次安装：

```php
if ($retval != 0) {
    $error = "run failed: '$command' returned $retval";
    return false;
}
```

而 `plugin install` 失败时：

```php
if (plugin('install', $plugin_file, $error) === false) {
    write("plugin: $error\n");
    if (dirname($plugin_file) == "$boot") {
        move($plugin_file, "$boot-error");     // -> /boot/config/plugins-error/
    }
    post_hooks($error);
    done(1);
}
```

后果链：`/var/log/plugins/<name>.plg` 软链**不会建立** → WebGUI 的
`glob("/var/log/plugins/*.plg")` 扫不到 → 插件不出现在「Plugins」页 →
**用户连卸载按钮都没有**；同时 `.plg` 被移走，下次开机也不会再被处理。

**本项目的做法**：

- `plugin/install.sh` 开头 `trap 'exit 0' EXIT`，所有失败分支打印明确错误后 `exit 0`；
- 不启用 `set -e` / `set -u`——它们会把「一个变量没设」变成非零退出，效果等同于
  `exit 1`，而且更难发现；
- `lint-plg.sh` 用正则检查 `exit [^0]` 与 `set -[A-Za-z]*[eu]`；
- `verify-release.sh` 对包内每个脚本再查一遍。

### 1.3 安装脚本必须幂等

开机时 `/etc/rc.d/rc.local` 会对 `/boot/config/plugins/*.plg` 逐个执行
`/usr/local/sbin/plugin install`：

```sh
for PLUGIN in $CONFIG/plugins/*.plg; do
    PLUGIN_NAME=$(basename "$PLUGIN")
    /usr/local/sbin/plugin install "$PLUGIN" | log
done
```

「已安装」登记表在 `/var/log/plugins/`，而 `/var/log` 是 tmpfs
（`rc.S`：`mount -t tmpfs -o size=128m tmpfs /var/log`），开机即清空；
`/usr` 本身是 squashfs + RAM overlay，同样不跨重启。
所以**每次开机都是全新安装，安装脚本每次都会执行**。

**本项目的做法**：

- 用 `upgradepkg --install-new` 装包（已装同版本是 no-op）；
- 二进制用 `cp -f` 覆盖，随后 `chmod 0755`；
- 所有清理用 `rm -f`（对不存在的文件是 no-op）；
- logrotate 配置每次重写（`cat >`）；
- 启动用 `scripts/restart.sh`，它自身幂等（先 stop 再 start）。

### 1.4 `<FILE Name=...>` 指向的文件不会被覆盖

安装器只在「文件不存在」或「校验和不匹配」时重新下载。**版本号必须写进缓存文件名**，
否则新版本不会生效。

**本项目的做法**：包名 `unraid-plugin-komari-agent-<插件版本>-x86_64-1.txz`，文件名带
版本，每次发布都是新路径。上游二进制缓存文件名固定（`komari-agent-linux-amd64`），
但它**不是靠文件名区分版本**的——靠的是 `<SHA256>`：上游一发新版，哈希就变，安装器
会重新下载并覆盖。这也是为什么缓存文件名里不写版本：`.plg` 里两个 `<FILE>` 的顺序和
名字必须稳定，否则旧缓存会一直留在 flash 上。

### 1.5 `<FILE>` 下载必须带 `<SHA256>`

官方插件仍在用 `<MD5>`，现代第三方插件都用 `<SHA256>`。安装器两者都认，且
`<SHA256>` 优先。

**本项目的做法**：

- `<SHA256>` 固定 txz 哈希（`&txzSHA256;`）；
- `<!ENTITY binSHA256 ...>` 额外固定二进制本身的哈希，安装脚本装完后会再校验一次；
- 上游二进制与 txz 的 SHA256 都从 `plugin/upstream.lock` 读取，下载后逐字节校验；
  `.plg` 里再钉一层——所以 `.plg` 里那个哈希是**上游声明的值**（GitHub API 的 `digest`
  字段），不是"这次下载算出来的值"。

### 1.6 必须提供卸载路径

安装器自身只删 `/var/log/plugins` 软链、把 `.plg` 移到
`/boot/config/plugins-removed/`，其余要插件自己清理。

**本项目的做法**：`<FILE Run="/bin/bash" Method="remove">` 先停服务（supervisor +
agent），再 `removepkg`，再清二进制、rc 脚本、logrotate 配置、WebGUI 目录、pidfile 和
flash 上的包缓存。**刻意保留** `komari-agent.cfg` 与 `net_static.json`——那是用户数据
（配置与流量统计），重装后应当还在。

### 1.7 WebGUI 页面放在 `/usr/local/emhttp/plugins/<name>/`

插件 `name` 属性对应的目录约定：
`/usr/local/emhttp/plugins/<name>/` 放页面与图标，
`/boot/config/plugins/<name>/` 放持久化配置。

**本项目的做法**：目录名与插件名一致（`unraid-plugin-komari-agent`），WebGUI 页面在
包里，随 txz 一起安装；持久化配置（cfg、二进制缓存、`net_static.json`）全在 flash 目录。

### 1.8 守护进程类插件：进程必须被托管

这一条不是安装器强制的，但对 daemon 类插件是硬要求——官方 tailscale 插件是样板：

| 官方做法（tailscale） | 本项目落地 |
|---|---|
| `/etc/rc.d/rc.<name>` 提供 start/stop/restart/status | `/etc/rc.d/rc.komari-agent`，四个子命令齐全 |
| 用 `pgrep` 判断进程是否在跑 | `lib.sh` 先探测本机 `pgrep` 是否支持 `--ns`，支持时加 `--ns $$` 限定同一 PID 命名空间（Unraid 上跑着 Docker，容器内同名进程会误判），不支持时自动退化 |
| 开机由 `rc.local` 拉起（经安装脚本） | 安装脚本读 `ENABLED` 后调 `scripts/restart.sh` |
| 关机由 `rc.6` 停止 | `rc.komari-agent stop` 由 Unraid 关机流程调用；`stop.sh` 先 `TERM`（agent 会 flush `net_static.json`）再 `KILL` |
| 日志落到 `/var/log` | `/var/log/komari-agent.log` + `/etc/logrotate.d/komari-agent` |

**Unraid 没有 systemd**，所以没有 `Restart=always`。本项目用 `scripts/supervise.sh`
实现等价的崩溃重启：一个 `while :; do run_agent; sleep "$RESTART_DELAY"; done` 循环，
`RESTART_DELAY` 默认 10 秒。pidfile 记录的是 **supervisor** 的 pid，`status` 同时报告
supervisor 与 agent 两个 pid。

### 1.9 CA 收录的硬性要求

| 要求 | 本项目状态 |
|---|---|
| 仓库公开且未归档 | ✅ |
| 仓库根目录有 OSI 认可的 `LICENSE` | ✅ MIT |
| 仓库根目录有 `ca_profile.xml`，且 `<Profile>` 非空 | ✅ 见 `ca_profile.xml` |
| 每个插件一个 wrapper XML，含 `<Name>` 与 `<PluginURL>` | ✅ 见 `ca/unraid-plugin-komari-agent.xml` |
| wrapper 的 `<PluginURL>` 与 `.plg` 的 `pluginURL` **完全一致** | ✅ 两者都是 `releases/latest/download/unraid-plugin-komari-agent.plg` |
| `.plg` 已带 `support` 时，wrapper 的 `<Support>` 可选 | ✅ 两者都有 |
| 兼容性窗口写在 `.plg` 的 `min`/`max` 里 | ✅ `min="7.0.0"` |

---

## 二、最佳实践（官方惯例）

| # | 惯例 | 官方依据 | 本项目落地 |
|---|---|---|---|
| 1 | 一个插件只发布一个 `.plg` | 安装器按 `.plg` **文件名**建软链；两个同名 `.plg` 会在「Plugins」页显示两条 | 发布一个主 `.plg`；代理版仅供无法直连 GitHub 的网络使用，主版安装时自动删除代理版（与官方 tailscale 处理 main/preview 分支的做法一致） |
| 2 | 用 XML 实体避免重复字面量 | `unraid/apprise-plugin` | `.plg` 用 `<!ENTITY>` 定义 name/version/upstream/URL/哈希 |
| 3 | `<CHANGES>` 以 `##<name>` 开头、每版一个 `###<version>` | `unraid/apprise-plugin` 的自检脚本 | 已对齐；正文由构建脚本从 `CHANGELOG.md` 抽取当前版本段落 |
| 4 | 提供 `author` / `support` / `icon` / `launch` | 安装器 usage 文本 | 全部提供；`launch="Settings/KomariAgent"` 指向本插件的 `.page` 文件，`icon` 解析到插件目录下的 PNG |
| 5 | 插件目录放 `README.md`，Plugins 页会渲染成说明 | `ShowPlugins.php` | 包内含 `README.md`（含 `@@PLUGIN_VERSION@@` / `@@UPSTREAM_VERSION@@` 占位符，构建时替换） |
| 6 | 用 Slackware 包路线（`upgradepkg` / `removepkg`），不要手拷二进制 | 三个官方插件都这么做 | `src/` 是包源码树，构建时打进 txz；只有**上游二进制**走 flash 缓存 + 安装脚本拷贝，因为它在 vfat 上无法执行 |
| 7 | 提供 `plugin.info` 作为页面可读的构建元数据 | 官方插件页面读取版本信息的惯例 | 构建期生成，值一律双引号包裹（PHP INI 扫描器会把裸值里的运算符求值，导致整个文件解析失败） |
| 8 | 提供 `<Name>.page` 页面文件 | Dynamix 页面机制 | `KomariAgent.page`（落地 tab）+ `KomariAgent-1-Settings.page`（配置）+ `KomariAgent-2-Status.page`（详情），`Tabs="true"` 把它们串成一个带页签的页面 |
| 9 | PHP 用 `$docroot` 解析路径 | `unraid/plugin`、`PluginHelpers.php` | `.page` 文件统一走 `$docroot` |
| 10 | 安装脚本不能有交互提示 | 安装器用 `popen()` 非交互执行 | 全程无 `read`、无 `pause` |
| 11 | `donate` / `webUI` 属性**不被安装器识别** | 全仓库检索无对应处理 | 不使用这两个属性 |
| 12 | `Type="hook"` **不是合法的 `<FILE>` 属性** | 安装器只认 `Type="base64"` | 不使用；真正的钩子是 `dynamix.plugin.manager` 的 pre/post-hooks 或插件目录下的 `event/` 脚本 |
| 13 | **CDATA 里的实体引用不会被展开** | XML 规范：CDATA 段是字面文本 | `.plg` 里 CDATA（`<CHANGES>`、`<INLINE>`）一律用构建期占位符 `@@...@@`；实体只用在属性值和元素文本里。`lint-plg.sh` 会检查这一点 |
| 14 | **token / 凭据不得进入命令行** | `ps` 与 `/proc/<pid>/cmdline` 对本机所有用户可读 | agent 的 `AGENT_TOKEN` 只走环境变量；`lint-plg.sh` 检查 `.plg` 里没有 `--token "$..."` 形式 |

### 两种占位机制的分工（容易踩坑）

| 位置 | 机制 | 例子 |
|---|---|---|
| `<PLUGIN>` 属性 | XML 实体（解析器展开） | `name="&name;"` |
| `<FILE Name=...>` 属性 | XML 实体 | `Name="/boot/config/plugins/&name;/&binName;"` |
| `<URL>`、`<SHA256>` 元素文本 | XML 实体 | `<URL>&txzURL;</URL>` |
| `<CHANGES>` 里的 CDATA | **构建期占位符** | `##@@PLUGIN_NAME@@` |
| `<INLINE>` 里的 CDATA | **构建期占位符** | `PLUGIN_NAME="@@PLUGIN_NAME@@"` |

CDATA 里的 `&name;` 不会被 XML 解析器展开，会原样写进安装脚本里，脚本就废了。
官方 `unraid/apprise-plugin` 的 `<INLINE>` 故意**不**用 CDATA（它靠实体展开），
官方 `unraid/unraid-tailscale` 的 `<INLINE>` 用 CDATA（它里面是字面量路径）。
本项目两者混用：属性用实体，CDATA 用占位符，并用 `lint-plg.sh` 把这条规则固定下来。

---

## 三、daemon 类插件特有的坑

这一节是参考项目没有的——它分发一次性 CLI，本项目分发常驻进程。

| # | 坑 | 后果 | 本项目处理 |
|---|---|---|---|
| 1 | 把 agent 当"跑一次就完"的进程 | 安装脚本正常返回，但服务根本没在跑，面板永远离线 | 安装脚本最后显式调 `restart.sh`；`ENABLED=0` 时打印说明而非静默跳过 |
| 2 | pidfile 记错对象 | `stop.sh` 杀掉 agent 后 supervisor 立刻把它拉起来，`stop` 永远"不成功" | pidfile 记 **supervisor** 的 pid；`stop.sh` 先杀 supervisor 再杀 agent 子进程 |
| 3 | 不加 PID 命名空间限定 | Unraid 上跑着 Docker，`pgrep komari-agent` 可能命中容器内同名进程，误杀/误判 | `lib.sh` 探测本机 `pgrep` 是否支持 `--ns`，支持时加 `--ns $$`（官方 tailscale 同款做法），不支持时自动退化 |
| 4 | 用 `kill -9` 收尾 | agent 来不及 flush `net_static.json`，流量统计丢失 | `stop.sh` 先 `TERM`，最多等 10 秒，仍在才 `KILL` |
| 5 | 工作目录是当前 shell 目录 | `net_static.json` 落到 overlay，重启即丢，面板流量归零 | `supervise.sh` 在每轮拉起 agent 前 `cd` 到 flash 插件目录（不可进入时退回 `/var/tmp`）；所有入口都走 `start.sh`，不要手工直接运行二进制 |
| 6 | 同步跑状态探测 | 面板不可达时 Settings 标签页卡几十秒 | 状态数据全部走 `$.post` 异步拉取；动作端点后台执行后立即返回 |
| 7 | 动作名直接拼进 shell | 命令注入 | 固定白名单 + 服务端定义命令 + 同源校验 + 仅 POST |
| 8 | 日志无限增长 | `/var/log` 是 128MB tmpfs，写满会连带影响其它服务 | `/etc/logrotate.d/komari-agent` 轮转 |
| 9 | 启用 `set -e` | 一个未设变量让安装脚本非零退出，插件从 Plugins 页消失 | 全部插件脚本禁用 `set -e` / `set -u`；lint 与 verify 双重检查 |
| 10 | 页面渲染期抛异常 | 异常栈和绝对路径直接打进页面，泄漏主机路径 | `.page` 内 try/catch 兜底，异常写 `/var/log/unraid-plugin-komari-agent-page-error.log` |

---

## 四、本次落地时确定的设计取舍

| # | 取舍 | 原因 |
|---|---|---|
| 1 | 插件版本用发布日期，不跟随上游 | `strcmp` 比较；且同一上游版本的重新打包也要能推送 |
| 2 | 默认关闭上游自更新（`DISABLE_AUTO_UPDATE=1`） | overlay 会把自更新成果回滚；且绕过插件钉死的 SHA256。详见 `02-technical-design.md` 第六节 |
| 3 | 默认关闭远程控制（`DISABLE_WEB_SSH=1`） | 面板下发 RCE 对 NAS 是糟糕的默认值；安全优先 |
| 4 | token 只走环境变量 | 命令行对本机所有用户可读 |
| 5 | 工作目录设为 flash 目录 | `net_static.json` 必须跨重启 |
| 6 | 二进制走「flash 缓存 + 安装时拷贝」 | vfat 不能执行；`/usr` 不跨重启 |
| 7 | 卸载保留 cfg 与 `net_static.json` | 用户数据，不是打包状态 |
| 8 | 状态数据异步加载 | 同步探测会阻塞页面渲染 |
| 9 | 动作端点白名单 + 同源校验 | 请求值永不进入 shell |
| 10 | cfg 只写配置表里列出的键 | 避免"声明了没人读"的死配置 |

---

## 五、仍未验证的点

以下内容无法在本地环境确认，需要在真实 Unraid 主机上验证：

1. **`.plg` 安装器全流程尚未在真机跑通。** 构建产物通过了 `lint-plg.sh` 与
   `verify-release.sh` 的静态检查，但没有在 Unraid 上实际执行 `plugin install`。
2. **WebGUI 页面未在真机验证。** 页面按官方 `.page` 约定编写，但没有在 Dynamix 里实际
   渲染过。
3. **守护循环的重启行为未在真机观察。** `supervise.sh` 的逻辑是直白的，但
   「杀掉 agent → 10 秒后自动恢复」以及「杀掉 supervisor 后 agent 是否也被清理」
   需要在真机上确认。
4. **开机重装行为**依赖官方安装器源码（已逐行核对）与 `rc.local`（已核对），
   但没有在本机上观察到实际的开机日志。
5. **`pgrep --ns` 的探测逻辑未在真机验证。** `lib.sh` 用探针进程的退出码区分"选项被
   接受但没有匹配"（1）与"选项不被理解"（其它），判据依赖 procps-ng 的具体行为，
   需要在 Unraid 7 上确认；若探测误判，最坏结果是退化为不带 `--ns`，只影响精度不影响
   功能。
6. **CA 的分类名** `Tools:System` 取自已收录的 `unraid-plg-zram`，但提交前应以
   CA 的字段参考为准。
7. **`launch` 的取值**取自官方示例的 `Settings/<页面文件名>` 形式
   （`Settings/Tailscale`、`Settings/UnraidZramCard`），但没有文档明确写出
   Dynamix 的路由规则。
8. **代理版 `.plg` 与主版共存**时的清理顺序依赖文件名字典序
   （`unraid-plugin-komari-agent-proxy.plg` 排在 `unraid-plugin-komari-agent.plg`
   之前），未经真机验证。
9. **flash 上每 10 分钟一次小文件写入**的长期影响（U 盘磨损）没有实测数据。写入量约
   100–200 KB/10min，即约 25 MB/天，理论上是可接受的，但没有跑过长期观察。

---

## 六、参考资料

- 安装器源码：<https://github.com/unraid/webgui/blob/master/emhttp/plugins/dynamix.plugin.manager/scripts/plugin>
- 开机流程：<https://github.com/unraid/webgui/blob/master/etc/rc.d/rc.local>
- 关机流程：<https://github.com/unraid/webgui/blob/master/etc/rc.d/rc.6>
- `/update.php`：<https://github.com/unraid/webgui/blob/master/emhttp/update.php>
- 插件列表页：<https://github.com/unraid/webgui/blob/master/emhttp/plugins/dynamix.plugin.manager/include/ShowPlugins.php>
- CA 收录指南：<https://ca.unraid.net/submit/help>
- CA 仓库说明：<https://ca.unraid.net/submit/help/repository-info-xml>
- CA 字段参考：<https://ca.unraid.net/submit/help/xml-field-reference>
- 官方插件示例：<https://github.com/unraid/unraid-tailscale>、
  <https://github.com/unraid/apprise-plugin>、
  <https://github.com/unraid/unraid-nvidia-driver>
- 上游源码：<https://github.com/komari-monitor/komari-agent>
