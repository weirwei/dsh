#!/bin/sh
# 由 docker-compose.prod.yml 的 dsh-init 服务执行：在 dsh 启动前把 DSH_PLUGINS
# 里列出的插件装进 profile。
#
# 为什么要单独一个一次性容器，而不是在 dsh 服务里做：
#   dsh 服务的 entrypoint 要起 dsh web 和外层 node 代理，覆盖它就得自己重现那套
#   启动逻辑。而插件安装的全部产物都落在 /root/.dsh/profiles/<profile>/
#   （package.json、pnpm-lock.yaml、node_modules），那个目录在 dsh-home 卷里，
#   两个容器共享同一个卷，所以装的人和用的人可以完全分开。
#
# 装完就持久：卷不删，dsh 容器重建也还在。dsh 加载插件是 node 直接 require
# node_modules，不需要 pnpm，所以 dsh 容器里没有 pnpm 也照样跑。
#
# 失败一律 exit 0：预装是便利功能。npm 抽风、限流、断网都不应该让整个栈起不来。
set -u

PROFILE="${DSH_PROFILE:-web}"
PKG="/root/.dsh/profiles/$PROFILE/package.json"

# 挑出还没装的。已装的跳过，这样每次 docker compose up 不会白等一轮网络请求。
missing=""
for spec in ${DSH_PLUGINS:-}; do
	# 从 pnpm spec 里剥出包名做判重：dshmarket@1.44.0 → dshmarket，
	# @scope/pkg@1.2.3 → @scope/pkg。git+https:// 这类 spec 剥不出来，
	# 判重必然失败，于是每次都重新 add —— pnpm 幂等，只是多花点时间。
	case "$spec" in
		@*) name="@$(printf '%s' "${spec#@}" | cut -d@ -f1)" ;;
		*) name=$(printf '%s' "$spec" | cut -d@ -f1) ;;
	esac
	if [ -f "$PKG" ] && grep -q "\"$name\"" "$PKG"; then
		echo "init-plugins: $name 已在 profile $PROFILE 里，跳过"
	else
		missing="$missing $spec"
	fi
done

if [ -z "$missing" ]; then
	echo "init-plugins: 没有要装的插件"
	exit 0
fi

# 镜像只带 corepack（Node 自带的包管理器代理），不带 pnpm。pnpm 那个 shim 是
# corepack enable 在运行期创建的，落在容器可写层 /usr/local/bin/ 而不是卷里，
# 所以这个一次性容器每跑一次都得重新 enable。
#
# COREPACK_ENABLE_DOWNLOAD_PROMPT=0 由 compose 传入：corepack 首次下载 pnpm
# 二进制前会问一次 y/n，非交互容器里会挂住。
if ! corepack enable pnpm; then
	echo "init-plugins: corepack enable pnpm 失败，跳过预装" >&2
	exit 0
fi

# dsh plugin 是 pnpm 的转发器：首次调用会初始化 profile 目录，跑完 pnpm 之后
# 再把新装的包补进 package.json 的 dsh.profile.bundles —— 不补进去插件不会被
# 加载，所以这里必须走 dsh plugin，不能直接 pnpm add。
echo "init-plugins: 正在安装 —$missing"
if ! dsh plugin --profile "$PROFILE" add $missing; then
	echo "init-plugins: 安装失败，dsh 仍会正常启动；修好网络后重跑本服务即可" >&2
fi
exit 0
