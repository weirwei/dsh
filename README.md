# dsh 自托管栈

把 [DeepSeek Harness](https://github.com/deepseek-ai)（dsh，一个能执行任意命令的
coding agent）和 [Hindsight](https://github.com/vectorize-io/hindsight)（给 agent
提供长期记忆的服务）跑在自己的服务器上，用域名 + HTTPS 访问。

仓库里是两套独立的编排，互不干扰：

| | 文件 | compose 项目名 | 用途 |
|---|---|---|---|
| 本地 | `docker-compose.yml` + `.env` | `dsh` | 在自己机器上试配置，端口只绑回环 |
| 远程 | `docker-compose.prod.yml` + `.env.prod` | `dsh-prod` | 真正对外提供服务 |

远程那套和本地的差异都是必需的，不是优化：镜像换 slim（2GB 内存的机器上，完整
镜像的 hindsight 实测占 895MB 内存，slim 占 517MB）、embedding 和 reranker 改用
外部 provider（slim 不带本地模型）、开 dsh 自带的 Basic Auth、挂载代码目录、
多一个一次性服务预装插件、多一个 Caddy 终止 TLS。每一条在
`docker-compose.prod.yml` 顶部都有说明。

## 架构

对外入口有两种选法，取决于宿主的 80/443 是否已经被占用：

```
                 ┌─ A. 宿主已有 Nginx ─> nginx ──┐
公网 ──80/443──> │                                ├─> 127.0.0.1:3080 ─> dsh:3079
                 └─ B. 80/443 空着 ──> caddy ────┘        （容器内回环）
                                                     │
                                     dsh ──> hindsight:8888（仅容器网络内可达）
                                                     │
                                                     └─> pg0（嵌入式 Postgres）
```

A 用 `docker-compose.prod.yml` + `config/nginx-dsh.conf.example`，证书用 certbot 管。
B 额外叠加 `docker-compose.caddy.yml`，证书由 Caddy 自动签发续期。

两种方案下 dsh 都只绑宿主回环（`127.0.0.1:3080`），hindsight 的 9999 也一样，
要访问得走 SSH 隧道。hindsight 的 8888 连宿主都不发布。

方案 A 三个容器：`dsh-prod`、`dsh-prod-init`（一次性，跑完退出）、`hindsight-prod`。
方案 B 多一个 `caddy-prod`。

---

## 远程部署

### 1. 前置条件

```bash
dig +short <你的域名>          # 结果要等于下一行
curl -s ifconfig.me
systemctl is-active firewalld  # 是 active 就放通 80/443
sudo ss -lntp | grep -E ':(80|443)\b'   # 看这两个端口有没有被占
```

最后一条决定走哪个方案 —— 不加 `sudo` 看不到进程名，容易误判：

- **有输出** → 宿主上已经有 Web 服务（`sudo nginx -T | grep server_name` 看它在
  服务什么）。走方案 A：Nginx 反代，不要启动 Caddy，两者会抢同一个端口。
- **无输出** → 走方案 B：叠加 `docker-compose.caddy.yml`，证书自动管。

还要在云控制台安全组放通 **TCP 80 和 443**。80 不能省，ACME HTTP-01 挑战和
HTTP→HTTPS 跳转都走它。

**国内 region 的机器，域名必须先完成 ICP 备案。** 未备案时运营商会在链路上拦掉
80/443，现象和安全组没开一模一样，很难区分。香港和海外节点不受此限。

### 2. 传文件

服务器上只需要这几个文件：

```
docker-compose.prod.yml
Caddyfile                              ← 方案 B
config/nginx-dsh.conf.example          ← 方案 A
config/nginx-dsh-gate.conf.example     ← 方案 A
config/init-plugins.sh
.env.prod            ← 在服务器上从 .env.prod.example 复制后填写，不要从本地传
```

`.env.prod` 含密钥，不入库也不要 scp。

### 3. 准备数据目录

所有持久化数据放在 `DATA_DIR` 下，方便整体备份和换盘：

| 子目录 | 内容 | 重要性 |
|---|---|---|
| `hindsight-data/` | pg0 数据库，记忆本体 | 最该备份 |
| `dsh-home/` | 会话历史、已装插件、profile、`.credentials.yaml` | 高 |
| `hindsight-agent/` | coding-agents 插件运行时状态 | 中 |
| `session-workdir/` | 历史会话的工作目录，只为保住工作区分组 | 低 |
| `caddy-data/` | TLS 证书与 ACME 账号私钥 | 中 |
| `caddy-config/` | Caddy 自动保存的运行配置 | 低 |

```bash
export D=/data/dsh     # 换成你的路径，有独立数据盘就指到盘上
sudo mkdir -p $D/{hindsight-data,hindsight-agent,dsh-home,session-workdir,caddy-data,caddy-config}
sudo chown -R 1000:1000 $D/hindsight-data
sudo chown -R 0:0 $D/dsh-home $D/hindsight-agent $D/session-workdir $D/caddy-data $D/caddy-config
sudo chmod 700 $D/dsh-home $D/caddy-data
```

**chown 这步不能省。** hindsight 容器以 uid 1000 运行（镜像里的 `hindsight`
用户），而 Docker 自动创建的 bind mount 目录属主是 `root:root` —— 拿不到写权限，
pg0 会在启动期失败，报的是权限错误、看起来却像配置问题。dsh 和 caddy 都以 root
运行，所以那几个目录归 root。

SELinux（RHEL 系默认可能是 Enforcing，用 `getenforce` 查）下所有挂载点都已带
`:z` 标签，不需要额外处理。用 `:z` 而非 `:Z` 是因为 `dsh-home` 和
`hindsight-agent` 被 `dsh` 和 `dsh-init` 两个容器共享，`:Z` 的独占标签会让后挂的
那个读不到。

### 4. 填 .env.prod

```bash
cp .env.prod.example .env.prod
chmod 600 .env.prod
```

必填八项（方案 B 再加 `DSH_DOMAIN` 和 `ACME_EMAIL`），漏任何一项 compose 会直接
报错拒绝启动，错误信息里带中文提示，不会静默跑起来：

| 变量 | 说明 | 去哪拿 |
|---|---|---|
| `DATA_DIR` | 上一步那个目录的绝对路径 | — |
| `WORKSPACE_DIR` | 要让 dsh 操作的代码目录，宿主绝对路径 | — |
| `PROXY_USERNAME` | dsh 的 Basic Auth 用户名 | `openssl rand -base64 24` |
| `PROXY_PASSWORD` | dsh 的 Basic Auth 口令，和上一项都设才启用，任一缺失代理层完全放行 | 同上 |
| `HINDSIGHT_API_TOKEN` | Hindsight 服务端 token，dsh 和控制台共用 | `openssl rand -hex 32` |
| `HINDSIGHT_API_LLM_API_KEY` | Hindsight 做记忆抽取和反思要调 LLM | platform.deepseek.com |
| `HINDSIGHT_API_EMBEDDINGS_OPENAI_API_KEY` | slim 镜像不带本地 embedding 模型，必须用外部 provider | cloud.siliconflow.cn |
| `HINDSIGHT_API_RERANKER_SILICONFLOW_API_KEY` | 重排模型，和上一项填同一个 key | 同上 |

后两项当前在硅基流动是免费的（`BAAI/bge-m3` 和 `BAAI/bge-reranker-v2-m3`），
注册就能用。三个 key 缺任何一个，Hindsight 会在启动期直接崩溃退出而不是降级运行。

`DSH_DOMAIN`（域名，不带 `https://`、路径或端口）和 `ACME_EMAIL`（证书到期通知
邮箱）只有方案 B 需要，方案 A 保持注释状态。

生成随机值：`openssl rand -base64 24`（口令）、`openssl rand -hex 32`（token）。

有一条贯穿整个文件的规则：**不需要的项保持注释状态，不要写成 `KEY=` 留空。**
留空会往容器里注入空字符串，而 Hindsight 各处读环境变量的写法不统一，后果不同
且都不好查 —— 比如数值类键拿到空串会在 `float()` 解析时直接崩溃退出，
`PROVIDER` 拿到空串会覆盖掉默认值变成非法的空 provider。

### 5. 启动

```bash
docker compose -f docker-compose.prod.yml --env-file .env.prod up -d
```

启动顺序由 `depends_on` 保证：`hindsight` 和 `dsh-init` 并行起（装插件不需要
hindsight，没必要串行），两者都就绪后才起 `dsh`（等 hindsight 健康 + dsh-init
成功退出）。首次启动 `hindsight` 要做 LLM 连通性校验，
`healthcheck.start_period` 给了 330s，慢是正常的。

此时 dsh 只监听 `127.0.0.1:3080`，公网还进不来。接下来按方案二选一。

#### 方案 A：宿主已有 Nginx

```bash
# 门禁密钥（说明见文件顶部）：一个随机 cookie 值 + 发给 dsh 的 Basic 头
sudo cp config/nginx-dsh-gate.conf.example /etc/nginx/dsh-gate.conf
sudo chmod 600 /etc/nginx/dsh-gate.conf
sudo vi /etc/nginx/dsh-gate.conf

sudo cp config/nginx-dsh.conf.example /etc/nginx/conf.d/dsh.conf
sudo vi /etc/nginx/conf.d/dsh.conf        # 换成你的域名
sudo nginx -t && sudo systemctl reload nginx
sudo certbot --nginx -d <你的域名>         # 签证书并自动改写上面那个文件
```

方案 A 的 Nginx 带一层 cookie 门禁：浏览器登录一次拿到 30 天的 `dsh_gate`
cookie，之后由 Nginx 替它向 dsh 容器补 Basic 头。不加这层的话，iOS Safari
每次打开都要重新输口令（而且常常弹两次）—— 它不持久保存 Basic 凭据，地址栏
预载又会并发两个请求，各拿一个 401。门禁 cookie 带 `Secure`，所以 certbot
签完证书之前走 http 会一直跳登录页，这是正常的。`/__dsh_logout` 退出登录；
改 `dsh-gate.conf` 里的随机值能让所有设备立刻失效。

`.env.prod` 的 `PROXY_USERNAME` / `PROXY_PASSWORD` 改了，`dsh-gate.conf` 里的
Basic 头要同步改，否则门禁过了、dsh 那层拒绝，页面表现为一个裸的 401。

**已经在跑旧版配置的机器**（certbot 改写过 `dsh.conf`，里面有 80 和 443 两个
server 块）不要整份覆盖，否则证书配置会丢。按下面改：

1. 生成 `/etc/nginx/dsh-gate.conf`，同上。
2. 把新示例里 `server {` 之前的 `include` 和三个 `map` 复制到 `dsh.conf` 顶部。
3. 在 **443 那个** server 块里，用新示例 server 块里 `absolute_redirect` 起到
   末尾的全部内容（两个 `/__dsh_*`、manifest 那个、新的 `location /`）替换掉
   原来的 `location / { ... }`。80 块是 certbot 写的跳转，不动。
4. `sudo nginx -t && sudo systemctl reload nginx`，手机上重新登录一次。

`nginx -t` 报 `unknown "connection_upgrade" variable` 是正常的第一次失败 ——
WebSocket 需要的那段 `map` 必须放在 `nginx.conf` 的 `http` 块里，不能放在
`server` 块。配置文件顶部注释里有原文，照抄进去（别的站点已经加过就不要重复加，
会报 duplicate）。

#### 方案 B：80/443 空着

```bash
docker compose -f docker-compose.prod.yml -f docker-compose.caddy.yml \
  --env-file .env.prod up -d
```

两个 `-f` 都要传，顺序不能反。这时 `DSH_DOMAIN` 和 `ACME_EMAIL` 变成必填。

### 6. 验证

```bash
docker compose -f docker-compose.prod.yml --env-file .env.prod ps
docker logs dsh-prod-init          # 看插件装了没
docker logs hindsight-prod         # 确认没有 permission denied
docker logs -f caddy-prod          # 方案 B：等 certificate obtained successfully
curl -I https://<你的域名>          # 方案 A 期望 302 → /__dsh_login；方案 B 期望 401
```

浏览器打开会弹 Basic Auth 登录框，用 `PROXY_USERNAME` / `PROXY_PASSWORD` 登录。
方案 B 的认证只由 dsh 容器内的代理层做，Caddy 不叠第二层，也没有 cookie 门禁
（iOS 上会遇到上面说的反复登录）。方案 A 的登录框由 Nginx 门禁弹出，校验的是同
一对口令。

---

## 日常运维

### 装插件

默认预装两个：`dshmarket`（插件市场）和
`@vectorize-io/hindsight-coding-agents`（接 hindsight 长期记忆）。装完市场之后，
其余 3000+ 插件在 Web UI 的「设置 → 插件市场」里点一下就行，不用回命令行。

要改预装列表就在 `.env.prod` 里设 `DSH_PLUGINS`（空格分隔，pnpm spec 语法），
然后：

```bash
docker compose -f docker-compose.prod.yml --env-file .env.prod up -d dsh-init
docker restart dsh-prod
```

已装的会被跳过，不会白等一轮网络请求。安装失败不阻塞 dsh 启动，只是插件没装上。

在 Web UI 的插件市场里装插件时，提示「重启后生效」也一样用 `docker restart dsh-prod`
—— UI 上那个「立即重启」按钮经反代访问会被拒，原因见下面排查一节。

镜像本身不带 pnpm，只带 corepack，`init-plugins.sh` 会在需要时自动
`corepack enable pnpm`。所以不要手工 `docker exec dsh-prod dsh plugin add ...`，
那样会遇到 `pnpm not found on PATH`。

国内机器拉 npm 慢的话，在 `.env.prod` 里解开这两行换镜像源（两个都要设，前者管
corepack 下载 pnpm 二进制，后者管 pnpm 装插件）：

```
COREPACK_NPM_REGISTRY=https://registry.npmmirror.com
npm_config_registry=https://registry.npmmirror.com
```

### 访问 Hindsight 控制台

控制台只绑宿主回环，服务器上不需要有浏览器 —— 在**你自己机器上**开隧道，用本地
浏览器访问：

```bash
ssh -N -L 19999:127.0.0.1:9999 -L 13080:127.0.0.1:3080 <user>@<服务器IP>
```

然后开 http://127.0.0.1:19999 。`-L` 右边的 `127.0.0.1:9999` 是从服务器视角解析
的地址，所以指的是服务器自己的回环。本地端口用 19999 而不是 9999，是为了避开本地
测试栈可能已经占用的端口。

`13080` 那条是绕过 Caddy 直连 dsh，排查故障出在哪一层时用。日常访问 dsh 走
`https://<域名>` 就行。

控制台的登录口令是 `HINDSIGHT_CP_ACCESS_KEY`。

### 备份

```bash
export D=/data/dsh     # 你的 DATA_DIR
docker compose -f docker-compose.prod.yml --env-file .env.prod stop hindsight
sudo tar czf dsh-backup-$(date +%F).tar.gz -C $D .
docker compose -f docker-compose.prod.yml --env-file .env.prod start hindsight
```

pg0 关机时需要最多 30s 落盘 WAL（compose 里 `stop_grace_period` 已设 30s），
热备份可能拿到不一致的数据库，所以先 stop。

备份包含 `caddy-data/` 里的 ACME 账号私钥，别放到公开的地方。

### 升级

镜像版本由 `.env.prod` 里的 `DSH_IMAGE` 控制（不填就用 compose 里钉住的那个），
`dsh` 和 `dsh-init` 共用同一个值。**升级不是 pull 一下就完了** —— 宿主升级后，
profile 里的插件仍钉在第一次安装时解析出的版本上，`init-plugins.sh` 只按包名判重、
不看版本，所以它永远不会自己刷新。

```bash
# 1. 挑版本：https://hub.docker.com/r/smanx/deepseek-harness/tags
vi .env.prod                       # 改 DSH_IMAGE

# 2. 换镜像。必须写服务名：裸 pull 会连 hindsight 一起拉，而
#    ghcr.io/vectorize-io/hindsight:latest-slim 是移动 tag，等于顺带升级了
#    记忆服务。那个镜像 450MB，国内小带宽机器实测跑到 79 分钟还没完，
#    SSH 一断整个 pull 就废了 —— 所以也建议在 tmux 里跑。
docker compose -f docker-compose.prod.yml --env-file .env.prod pull dsh dsh-init
docker compose -f docker-compose.prod.yml --env-file .env.prod up -d dsh-init dsh

# 3. 按新宿主重装插件（绕开判重，直接重新解析版本）
docker compose -f docker-compose.prod.yml --env-file .env.prod run --rm \
  --entrypoint sh dsh-init -c \
  'corepack enable pnpm && dsh plugin --profile web add dshmarket@latest @vectorize-io/hindsight-coding-agents@latest'
docker restart dsh-prod

# 4. 确认镜像内那层代理认得新版的 token 认证
docker exec dsh-prod ls /app/proxy | grep upstream-token.js
docker logs dsh-prod | grep upstream-token
```

数据在 `DATA_DIR` 里，容器重建不受影响。

第 4 步在查什么：dsh 0.1.2 起 `dsh web` 加了浏览器会话认证 —— 启动时打印一个
一次性 launch token，浏览器必须先访问 `/?token=...` 换一个签名 cookie（绑定
请求的 Host、HttpOnly、SameSite=Strict、默认 30 天，签名密钥在
`dsh-home/.credentials.yaml` 里，所以 cookie 能跨容器重启存活）。这一步没法关掉。
镜像内的 `/app/proxy/upstream-token.js` 替你做了：根目录 GET 撞上 401 时，它从
`/app/.dsh-web.log` 尾部捞出 token，剥掉浏览器的旧 cookie 带 token 重发一次，
再把上游的 `Set-Cookie` 透传回去。所以正常情况下你什么都不用做。

`ls /app/proxy` 里没有这个文件，说明镜像太旧（该修复 2026-09-19 才发布，而
携带 token 认证的 dsh 0.1.2 在 09-09 就进了 `latest`，中间十天拉到的镜像是
新 dsh + 旧代理的组合），换新版即可。真要手工兜底，代理还留了
`DSH_TOKEN` / `DSH_TOKEN_FILE` 两个环境变量可以直接把 token 喂给它。

---

## 排查

**hindsight 一直 unhealthy** — 最常见的卡点不是模型下载，而是 LLM 连通性校验
（端点不可达、`BASE_URL` 写错、被限流）。看 `docker logs hindsight-prod`。正确
做法是修 `BASE_URL`，不是把 `HINDSIGHT_API_MODEL_INIT_TIMEOUT` 调大。真要调大，
必须同步把 compose 里 `healthcheck.start_period` 改成「该值 + 30s」以上，
否则 healthcheck 会早于容器自身的超时判定 unhealthy。

**hindsight 报 permission denied** — `$DATA_DIR/hindsight-data` 的属主不是
`1000:1000`。回到第 3 步。

**证书签不下来** — 方案 B 下 Caddy 会反复重试并打日志。按第 1 步逐条查，尤其是
备案和 80 端口。注意 Let's Encrypt 对同一组域名有每周 5 张的重复签发限制，反复
重建撞上了要等一周，所以 `caddy-data/` 千万别删。

**页面能开但对话中途卡住 / 反复重连（方案 A）** — Nginx 把 WebSocket 掐了。
三个原因按可能性排序：`map $http_upgrade $connection_upgrade` 没加到 `http` 块、
`proxy_read_timeout` 还是默认 60s、`proxy_buffering` 没关（流式输出会攒着一次性
吐出来）。三项在 `config/nginx-dsh.conf.example` 里都有。

**Caddy 起不来报 address already in use** — 宿主 80/443 被 Nginx 之类占着。
你要的是方案 A，不要传 `-f docker-compose.caddy.yml`。

**dsh 连不上 hindsight（401）** — 检查 `$DATA_DIR/hindsight-agent/` 下有没有
残留的 `coding-agent.json`。插件的配置加载顺序是「先铺环境变量层，再让文件层
覆盖它」，文件里的 `apiToken` 会静默压掉 `HINDSIGHT_API_TOKEN`，而报错只说 token
被拒、不会告诉你它读的是文件那份。这套编排不需要那个文件，删掉即可。

**Web UI 里点「立即重启」报 `restart is limited to same-origin loopback requests`**
— 不是故障，是 dshmarket 的安全设计。它的 `lib/restart.js` 里 `trustedRestartRequest`
要求三条同时成立：socket 远端是回环地址、**请求里不带任何转发头**
（`Forwarded` / `X-Forwarded-For` / `X-Real-IP` 出现任一个就拒绝）、`Origin` 与
`Host` 同源。经 Nginx 或 Caddy 访问必然踩中第二条 —— 那几个头是反代该加的，
恰好也是这个接口用来识别「请求经过了代理」的信号。

直接重启容器即可，效果完全等价（插件的「重启」就是重新 spawn dsh 进程，
容器重启时 entrypoint 做的是同一件事）：

```bash
docker restart dsh-prod
```

装插件后提示「重启后生效」时都这么做。**不要为了让那个按钮能用去删 Nginx 里的
`X-Real-IP` / `X-Forwarded-For`** —— 那会让 dsh 拿不到真实客户端 IP，也削弱了这个
接口本来要防的东西（外部请求触发进程重启）。真想在 UI 里点，走 SSH 隧道从
`http://127.0.0.1:3080` 访问，绕开反代就没有转发头了。

**升级后工作区变空、会话全跑到「未分组」** — 会话一条没丢，是分组失效了。
工作区分组不是存死的映射：`dsh-workspace` 在读取时按「会话 cwd 逐字等于工作区
path」重新校验（`get sessionIds()` 里那个 filter），路径对不上就当没归属，前端
把无归属会话统统塞进「未分组」。换镜像必然重建容器，而容器可写层里的目录会一起
消失 —— 工作目录只要不在 `/root/.dsh`、`/root/.hindsight`、`/workspace` 这几个
挂载点下就会踩到。

```bash
sudo grep -oE '"(path|title)": *"[^"]*"' $D/dsh-home/storages/workspace.json
docker exec dsh-prod sh -c 'ls -ld <上面那个 path>'      # 不存在就是这个原因
```

把 `.env.prod` 里的 `SESSION_WORKDIR` 设成那个 path（逐字一致），重建 dsh 即可；
`sessionIds` 记录没被删，路径一回来分组自动恢复。注意它只恢复分组，不恢复那个
目录里原有的文件。以后在 `/workspace` 下开会话就不会再遇到。

**改了配置没生效** — `dsh` 的端口从公网收回之后，`http://<IP>:3080` 不再可用，
这是有意的（Basic Auth 密码明文过网）。要临时恢复，把 compose 里 dsh 的
`127.0.0.1:3080:3080` 左边的 `127.0.0.1:` 去掉。

---

## 本地测试栈

只用来试配置，不对外服务：

```bash
cp .env.example .env
# 填 HINDSIGHT_API_TOKEN 和 LLM 相关项
docker compose up -d
```

dsh 在 http://127.0.0.1:3080 ，Hindsight 控制台在 http://127.0.0.1:9999 。
两个端口都只绑回环，且默认都没有登录口令，所以同一台机器上的任何进程都能访问 ——
`HINDSIGHT_CP_ACCESS_KEY` 建议还是设一个。

本地这套用完整镜像（自带本地 embedding / reranker 模型，不需要外部 provider），
数据放在 Docker 命名卷里而不是 bind mount。
