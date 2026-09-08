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

```
公网 ──443──> caddy ──> dsh:3080 ──> dsh:3079（容器内回环）
                          │
                          └──> hindsight:8888（仅容器网络内可达）
                                    │
                                    └──> pg0（嵌入式 Postgres）
```

只有 Caddy 对公网开放。dsh 的 3080 和 hindsight 的 9999 都只绑宿主回环，
要访问得走 SSH 隧道。hindsight 的 8888 连宿主都不发布。

四个容器：`caddy-prod`、`dsh-prod`、`dsh-prod-init`（一次性，跑完退出）、
`hindsight-prod`。

---

## 远程部署

### 1. 前置条件

四条全部满足再往下走，缺任何一条证书都签不下来：

```bash
dig +short <你的域名>          # 结果要等于下一行
curl -s ifconfig.me
systemctl is-active firewalld  # 是 active 就放通 80/443
ss -lntp | grep -E ':(80|443)\b'   # 确认没有别的进程占着
```

还要在云控制台安全组放通 **TCP 80 和 443**。80 不能省，ACME HTTP-01 挑战和
HTTP→HTTPS 跳转都走它。

**国内 region 的机器，域名必须先完成 ICP 备案。** 未备案时运营商会在链路上拦掉
80/443，现象和安全组没开一模一样，很难区分。香港和海外节点不受此限。

### 2. 传文件

服务器上只需要四个文件：

```
docker-compose.prod.yml
Caddyfile
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
| `caddy-data/` | TLS 证书与 ACME 账号私钥 | 中 |
| `caddy-config/` | Caddy 自动保存的运行配置 | 低 |

```bash
export D=/data/dsh     # 换成你的路径，有独立数据盘就指到盘上
sudo mkdir -p $D/{hindsight-data,hindsight-agent,dsh-home,caddy-data,caddy-config}
sudo chown -R 1000:1000 $D/hindsight-data
sudo chown -R 0:0 $D/dsh-home $D/hindsight-agent $D/caddy-data $D/caddy-config
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

必填七项，漏任何一项 compose 会直接报错拒绝启动（而不是静默跑起来）：

| 变量 | 说明 |
|---|---|
| `DSH_DOMAIN` | 域名，不带 `https://`、路径或端口 |
| `ACME_EMAIL` | 证书到期通知邮箱 |
| `DATA_DIR` | 上一步那个目录的绝对路径 |
| `WORKSPACE_DIR` | 要让 dsh 操作的代码目录，宿主绝对路径 |
| `PROXY_USERNAME` / `PROXY_PASSWORD` | dsh 的 Basic Auth，两个都设才启用，任一缺失代理层完全放行 |
| `HINDSIGHT_API_TOKEN` | Hindsight 服务端 token，dsh 和控制台共用 |

生成随机值：`openssl rand -base64 24`（口令）、`openssl rand -hex 32`（token）。

还有 LLM 和 embedding 的 key 要填，见 `.env.prod.example` 里的说明。

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
成功退出），最后 `caddy`。首次启动 `hindsight` 要做 LLM 连通性校验，
`healthcheck.start_period` 给了 330s，慢是正常的。

### 6. 验证

```bash
docker compose -f docker-compose.prod.yml --env-file .env.prod ps
docker logs dsh-prod-init          # 看插件装了没
docker logs hindsight-prod         # 确认没有 permission denied
docker logs -f caddy-prod          # 等 certificate obtained successfully
curl -I https://<你的域名>          # 期望 401
```

`401` 就是通的 —— 认证由 dsh 容器内的代理层做，Caddy 不叠第二层。浏览器打开会弹
Basic Auth 登录框，用 `PROXY_USERNAME` / `PROXY_PASSWORD` 登录。

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

### 更新镜像

```bash
docker compose -f docker-compose.prod.yml --env-file .env.prod pull
docker compose -f docker-compose.prod.yml --env-file .env.prod up -d
```

数据在 `DATA_DIR` 里，容器重建不受影响。

---

## 排查

**hindsight 一直 unhealthy** — 最常见的卡点不是模型下载，而是 LLM 连通性校验
（端点不可达、`BASE_URL` 写错、被限流）。看 `docker logs hindsight-prod`。正确
做法是修 `BASE_URL`，不是把 `HINDSIGHT_API_MODEL_INIT_TIMEOUT` 调大。真要调大，
必须同步把 compose 里 `healthcheck.start_period` 改成「该值 + 30s」以上，
否则 healthcheck 会早于容器自身的超时判定 unhealthy。

**hindsight 报 permission denied** — `$DATA_DIR/hindsight-data` 的属主不是
`1000:1000`。回到第 3 步。

**证书签不下来** — Caddy 会反复重试并打日志。按第 1 步逐条查，尤其是备案和 80
端口。注意 Let's Encrypt 对同一组域名有每周 5 张的重复签发限制，反复重建撞上了
要等一周，所以 `caddy-data/` 千万别删。

**dsh 连不上 hindsight（401）** — 检查 `$DATA_DIR/hindsight-agent/` 下有没有
残留的 `coding-agent.json`。插件的配置加载顺序是「先铺环境变量层，再让文件层
覆盖它」，文件里的 `apiToken` 会静默压掉 `HINDSIGHT_API_TOKEN`，而报错只说 token
被拒、不会告诉你它读的是文件那份。这套编排不需要那个文件，删掉即可。

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
