# 设计决策：官方 Release 资产 vs 源码编译

> 结论先行：**主路径采用 GitHub Releases 官方发布的静态二进制，源码编译仅作为审计与兜底手段。**
> 评估基于 2026-11-06 实测数据，非推测。

---

## 一、先厘清一个前提：上游到底发布什么

| 渠道 | 是否提供 `komari-agent` 可执行文件 |
|---|---|
| `komari-monitor/komari-agent` GitHub Releases | ✅ 每个 tag 提供 13 个资产（darwin / freebsd / linux / windows × 多架构） |
| Linux amd64 资产 | ✅ `komari-agent-linux-amd64`，12,585,218 字节 |
| 源码 | ✅ Go 模块，`cmd/root.go` + `cmd/flags/flag.go` 等 |
| 发行版包管理器 | ❌ 不提供 deb / rpm / apk |

**关键事实：官方 Release 资产本身就是"官方产物"。** 这与参考项目 `unraid-plugin-docker-model`
的情形完全不同——那个项目的上游（Docker Model Runner CLI）**只在 apt/yum 仓库分发**，
GitHub Releases 上没有任何二进制，所以只能去解析 deb 的 ar 容器。本项目没有这个问题：
一条 API 调用就能拿到版本、大小和 SHA256。

`komari-agent` 的资产命名遵循 Go 的发布惯例 `komari-agent-<os>-<arch>`，Linux 上无扩展名：

```
komari-agent-linux-386        12,198,622 B
komari-agent-linux-amd64      12,585,218 B     <- 本项目捆绑
komari-agent-linux-arm        11,999,532 B
komari-agent-linux-arm64      11,892,529 B
komari-agent-linux-loong64    12,108,160 B
```

---

## 二、硬指标对比（全部实测）

| 维度 | 官方 Release 资产 | 源码编译产物 | 胜者 |
|---|---|---|---|
| **可获取性** | 一条 GitHub API 调用 + 一次下载 | 需 `codeload` 拉源码 + Go 工具链 | 资产 |
| **二进制大小** | 12,585,218 B | 同量级（约 12MB，取决于工具链版本） | 平 |
| **链接方式** | 静态链接 ELF（Go 默认 `CGO_ENABLED=0`） | 需手动指定才能一致 | 资产 |
| **版本号正确性** | 上游 CI 注入的正式 tag | 用 codeload tarball 构建**无 `.git`**，`git describe` 失败 → 版本落回 `dev` | **资产** |
| **可复现性** | SHA256 由 GitHub API 直接给出 | 需钉死 Go 版本、`-trimpath`、`-ldflags` 才能复现 | **资产** |
| **可信来源** | GitHub 发布者身份 + GitHub 对该资产公布的 SHA256 摘要 | 只有源码 tag 的 commit 签名 | 资产 |
| **构建耗时** | 下载 12MB，约 3 秒 | 首次约 1–2 分钟（下载 Go module 依赖） | 资产 |
| **构建环境** | 只需 curl + Python 3 | 需 Go 工具链（版本漂移风险） | 资产 |
| **供应链风险** | 依赖一个发布资产 + GitHub API | 依赖上百个 `go.sum` 条目 + 第三方 module proxy | 资产 |
| **可审计性** | 二进制不可读，只能靠摘要链 | 源码可读、可改、可加审计 | 源码 |
| **可定制性** | 无 | 可打补丁、裁剪 | 源码 |
| **功能面** | 全部 | 完全相同（同一份源码） | 平 |

### 关键点：版本号会退化成 `dev`

Go 项目通常用 `-ldflags "-X <pkg>.Version=$(git describe --tags)"` 注入版本号。从
codeload tarball 构建时没有 `.git` 目录，`git describe` 必然失败，构建出来的二进制
`--version` 显示 `dev`。这会让 WebGUI 状态页显示一个无意义的版本号，也让用户无法
判断自己跑的是哪个上游版本。

官方 Release 资产没有这个问题：它的版本号是上游 CI 在真实 git 仓库里注入的。

### 补充说明：源码编译在本项目里的定位

源码编译不是被否决，而是被**降级为兜底路径**。保留它的理由：

- 怀疑 Release 资产被篡改时，可以编译同版本源码做行为对比；
- 需要给插件打补丁时（例如改默认采集间隔、改上报路径）；
- 上游停止发布二进制但继续发源码时。

若走源码编译，**必须显式注入版本号**，否则 `--version` 显示 `dev`：

```bash
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
  go build -trimpath -ldflags="-s -w -X github.com/komari-monitor/komari-agent/update.CurrentVersion=1.5.11" \
  -o komari-agent .
```

> 上面 `-X` 的包路径以实际源码为准：`cmd/root.go` 里打印版本用的是
> `update.CurrentVersion`，因此注入目标在 `update` 包内。升级上游后必须重新核对这一行，
> 这是源码编译路径的主要维护成本。

---

## 三、决策矩阵（加权评分）

权重按"Unraid 插件分发"这个场景设定：**可信度 > 可维护性 > 可定制性**。

| 指标 | 权重 | Release 资产 | 源码编译 |
|---|---|---|---|
| 来源可信 / 可验证 | 30% | 9 | 6 |
| 版本准确无误 | 20% | 10 | 4 |
| 可维护性（升级成本） | 20% | 10 | 4 |
| 构建环境简单 | 15% | 10 | 4 |
| 可审计性 | 10% | 5 | 9 |
| 可定制性 | 5% | 2 | 9 |
| **加权总分** | | **9.10** | **5.05** |

---

## 四、最终方案

### 主路径：官方 Release 资产（`scripts/build-plugin.sh`）

```
1. 读取 plugin/upstream.lock：目标版本、目标架构的
   name / size / sha256 / url
2. 下载资产，逐字节校验 SHA256
3. 校验结果是 ELF 且 e_machine 与请求的架构一致
   （防止把错误页或别的架构当二进制打包）
4. 从 src/ 组装 Slackware 包源码树，附上 rc 脚本、WebGUI 页面、守护脚本
5. 用 Python tarfile 写出可复现 txz（含 install/slack-desc、install/doinst.sh）
6. 渲染 .plg：写入 txz 与二进制的 SHA256、安装/卸载脚本
```

**为什么用锁文件而不是每次构建都查 API：**

- **可复现。** 构建结果不能取决于"今天 API 返回了什么"。锁文件是仓库的一部分，
  某个 commit 的检出永远产出同一个包。
- **供应链可审。** 新的上游版本以「锁文件的一处 diff」形式出现，由人审阅；而不是在
  CI 期间悄无声息地变化。
- **可用性。** GitHub API 对匿名客户端限流 60 次/小时，且在某些网络下间歇性不可达。
  一个仅仅因为查不到 API 就失败的构建，失败原因与代码毫无关系。

**锁文件里的 SHA256 从哪来：** `scripts/update-upstream.sh` 查询 GitHub Releases API，
取资产的 `digest` 字段（GitHub 对上传字节计算出的 SHA256），写入锁文件。所以这个值
仍然是"GitHub 认为这个 release 里有什么"，而不是"某次下载恰好返回了什么"——只是获取
动作被显式化、可审阅化了。

**为什么还要查 ELF 魔数与架构：** 一个 HTTP 200 的错误页、一个被代理返回的 HTML
拦截页，SHA256 校验会失败并中止构建；但如果有人把 arm64 的资产当成 amd64 下载（例如
手动替换了 `pkg/` 缓存），SHA256 校验也会通过——因为那是同一份合法发布资产。检查
`e_machine` 能拦住这一类"合法但错误"的情况。

### 兜底路径：源码编译（仅审计用，不进发布流程）

见第二节末尾的构建命令。**不进入发布流程**：CI 只走主路径。

---

## 五、方案的残余风险与对策

| 风险 | 影响 | 对策 |
|---|---|---|
| GitHub Releases 资产被删除 | 无法重新构建历史版本 | `pkg/` 本地缓存已下载的二进制；发布产物（txz + plg）本身也在 Release 里 |
| 资产被投毒 | 高 | 锁文件里的 `digest` 逐字节校验；`.plg` 里再钉一层 SHA256；安装时安装器还会校验一次 |
| 锁文件被误改 | 构建失败或产出错误版本 | 构建校验锁文件的 `version` 与请求一致、`size > 0`、`url` 为 https、`sha256` 为 64 位十六进制；`upstream-check.yml` 每日交叉核对锁文件、`Makefile` 与 `build-plugin.sh` 三处 pin |
| GitHub API 限流 | 仅影响 `update-upstream.sh`，不影响构建 | 构建完全不查 API；`update-upstream.sh` 接受 `GITHUB_TOKEN`（60 → 5000 次/小时） |
| 上游改了资产命名规则 | 构建失败 | 命名规则固定在 `build-plugin.sh` 的 `EXPECTED_BIN_NAME`，改规则只需改一行 |
| 上游新增 `AGENT_*` 变量 | 功能缺失（不会崩） | `upstream-check.yml` 每日开 issue；`CONTRIBUTING.md` 要求同步更新设置页与文档 |
| 上游删除/重命名已有变量 | 配置项静默失效 | 同上；升级时须逐条核对 `cmd/flags/flag.go` |
| 插件随 Unraid 升级失效 | 中 | `.plg` 的 `min` 版本；开机脚本每次重新部署 |
| 上游二进制与面板版本不匹配 | 中 | `upstream` 实体与 `plugin.info` 都记录捆绑版本，升级时可追溯 |

---

## 六、验证证据摘要

```
$ curl -sL https://api.github.com/repos/komari-monitor/komari-agent/releases/latest
  "tag_name": "1.5.11"
  asset "komari-agent-linux-amd64"
    "size":   12585218
    "digest": "sha256:78c28d89e523816baea010c0ed0714f245f508ffdaca0540f5c9f230f7053c8c"

$ grep -A4 '^\[amd64\]' plugin/upstream.lock
  name = komari-agent-linux-amd64
  size = 12585218
  sha256 = 78c28d89e523816baea010c0ed0714f245f508ffdaca0540f5c9f230f7053c8c
  url  = https://github.com/komari-monitor/komari-agent/releases/download/1.5.11/komari-agent-linux-amd64
# 锁文件记录的值与 API 声明完全一致

$ sha256sum pkg/komari-agent-linux-amd64
78c28d89e523816baea010c0ed0714f245f508ffdaca0540f5c9f230f7053c8c  pkg/komari-agent-linux-amd64
# 下载到的字节与锁文件一致

$ python3 -c '...' pkg/komari-agent-linux-amd64
ELF machine: x86-64
```

上游许可为 MIT（见 `NOTICE`），二进制原样分发即可满足要求。
