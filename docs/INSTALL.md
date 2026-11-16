# 安装与部署

服务端只有一个可执行文件 `yhmatrix`（`yhprobe` 是调试用的探针，可选）。任选一种方式：

| 方式 | 适用场景 | 前提 |
| --- | --- | --- |
| [1. Release 预编译二进制](#1-下载预编译二进制release) | 物理机 / VPS / systemd 常驻 | 无 |
| [2. Docker 镜像](#2-docker-直接拉取预构建镜像) | 想一条命令跑起来 | Docker |
| [3. Docker Compose](#3-docker-compose) | 长期部署、方便改配置 | Docker Compose v2 |
| [4. 本地 Dockerfile 构建](#4-本地构建镜像) | 改过代码、不想用 GHCR | Docker + 源码 |
| [5. 源码编译](#5-源码编译) | 开发 / 二次开发 | Go ≥ 1.23 |

> 首次启动建议先跑 `-mock` 确认链路（演示账号 `demo@yunhu.dev` / `demo1234`），不需要真实云湖账号。

## 1. 下载预编译二进制（Release）

打开 [Releases](https://github.com/Kauid323/YunhuUser2Matrix/releases)，下载对应平台的包：

| 平台 | 文件名后缀 |
| --- | --- |
| Linux x86_64 | `linux_amd64.tar.gz` |
| Linux ARM64（树莓派 4/5、ARM 云主机） | `linux_arm64.tar.gz` |
| Linux ARMv7（32 位 ARM 设备） | `linux_armv7.tar.gz` |
| macOS Intel | `darwin_amd64.tar.gz` |
| macOS Apple Silicon | `darwin_arm64.tar.gz` |
| Windows x86_64 | `windows_amd64.zip` |
| Windows ARM64 | `windows_arm64.zip` |
| FreeBSD x86_64 | `freebsd_amd64.tar.gz` |

文件名格式：`yhmatrix_<版本>_<平台>.<后缀>`。每个包内含 `yhmatrix`（Windows 为 `.exe`）、`yhprobe`、`config.example.yaml`、`README.md`、`LICENSE`。

Linux x86_64 示例：

```bash
VERSION=v1.0.0
BASE=https://github.com/Kauid323/YunhuUser2Matrix/releases/download/${VERSION}
curl -fLO "${BASE}/yhmatrix_${VERSION}_linux_amd64.tar.gz"
curl -fLO "${BASE}/SHA256SUMS"
sha256sum -c SHA256SUMS --ignore-missing   # 校验完整性

tar -xzf "yhmatrix_${VERSION}_linux_amd64.tar.gz"
cd "yhmatrix_${VERSION}_linux_amd64"
cp config.example.yaml config.yaml         # 改 server.name，见下方「配置」
./yhmatrix -version                        # 打印构建时注入的版本号
./yhmatrix
```

> `config.yaml` 必须和可执行文件放在同一目录，或者用 `-config <路径>` / `$YHMATRIX_CONFIG` 明确指定；相对路径（`./data`、`./element-web`、`./certs/*`）也一律相对**可执行文件目录**解析。

### 用 systemd 常驻

把解压后的目录放到 `/opt/yhmatrix`，建一个专用用户，然后写入 `/etc/systemd/system/yhmatrix.service`：

```ini
[Unit]
Description=yhmatrix - Yunhu to Matrix homeserver
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=yhmatrix
Group=yhmatrix
WorkingDirectory=/opt/yhmatrix
Environment=YHMATRIX_SERVER_NAME=matrix.example.com
Environment=YHMATRIX_SERVER_PUBLIC_URL=https://matrix.example.com
Environment=YHMATRIX_LOG_LEVEL=info
ExecStart=/opt/yhmatrix/yhmatrix
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=/opt/yhmatrix/data

[Install]
WantedBy=multi-user.target
```

```bash
useradd -r -s /sbin/nologin yhmatrix
chown -R yhmatrix:yhmatrix /opt/yhmatrix
systemctl daemon-reload && systemctl enable --now yhmatrix
journalctl -u yhmatrix -f
```

## 2. Docker：直接拉取预构建镜像

```bash
docker run -d --name yhmatrix \
  --restart unless-stopped \
  -p 8008:8008 \
  -e YHMATRIX_SERVER_NAME=192.168.1.12 \
  -v yhmatrix-data:/app/data \
  ghcr.io/kauid323/yunhuuser2matrix:latest
```

- `YHMATRIX_SERVER_NAME` 改成客户端实际访问的域名/IP（决定用户 ID 后缀，如 `@yh_10001:192.168.1.12`）。
- 建议把 `:latest` 换成具体版本（如 `:v1.0.0`）以便回滚。
- 想跑探针工具：`docker run --rm <镜像> yhprobe info`。
- 传参给服务端：`docker run ... -mock`（直接追加在镜像名后即可）。

验证：

```bash
curl -s http://127.0.0.1:8008/_matrix/client/versions
docker logs -f yhmatrix
```

## 3. Docker Compose

```bash
curl -fLO https://raw.githubusercontent.com/Kauid323/YunhuUser2Matrix/main/compose.yaml
# 编辑 environment 里的 YHMATRIX_SERVER_NAME
docker compose up -d
docker compose logs -f
```

也可以直接在仓库根目录执行 `docker compose up -d`。`compose.yaml` 默认用具名卷保存 `/app/data`、设置了健康检查、`restart: unless-stopped`。

想用自己改过的代码构建：注释掉 `image:` 一行，取消 `build: .` 的注释，再 `docker compose up -d --build`。

## 4. 本地构建镜像

```bash
git clone https://github.com/Kauid323/YunhuUser2Matrix.git
cd YunhuUser2Matrix
docker build -t yhmatrix:local .
docker run -d --name yhmatrix --restart unless-stopped -p 8008:8008 \
  -e YHMATRIX_SERVER_NAME=localhost \
  -v yhmatrix-data:/app/data \
  yhmatrix:local
```

构建时会注入版本号：`docker build --build-arg VERSION=v1.0.0 -t yhmatrix:local .`。
国内网络拉 `proxy.golang.org` 超时时，追加 `--build-arg GOPROXY=https://goproxy.cn,direct`。

### 自定义配置

三种写法任选其一：

```bash
# a) 挂载完整配置文件（优先级最高，镜像内自动生成的那份会被跳过）
-v $PWD/config.yaml:/app/config.yaml:ro

# b) 把配置放在别处并指过去
-e YHMATRIX_CONFIG=/config/yhmatrix.yaml -v $PWD/yhmatrix.yaml:/config/yhmatrix.yaml:ro

# c) 完全不挂文件，只用环境变量（见下表）
```

容器首次启动且没有挂载 `config.yaml` 时，会把 `config.example.yaml` 复制成 `/app/config.yaml`；环境变量的优先级高于配置文件，所以可以不挂文件直接跑。

| 环境变量 | 作用 | 示例 |
| --- | --- | --- |
| `YHMATRIX_CONFIG` | 指定配置文件路径 | `/app/config.yaml` |
| `YHMATRIX_SERVER_NAME` | Matrix 域名 / 用户 ID 后缀 | `matrix.example.com` |
| `YHMATRIX_SERVER_BIND` | 监听地址 | `:8008` |
| `YHMATRIX_SERVER_PUBLIC_URL` | 反向代理后的对外地址 | `https://matrix.example.com` |
| `YHMATRIX_DATA_DIR` | 数据目录 | `/app/data` |
| `YHMATRIX_LOG_LEVEL` | `info` / `debug` | `info` |
| `YHMATRIX_YUNHU_BASE_URL` / `YHMATRIX_YUNHU_WS_URL` | 云湖上游地址 | — |

> `allow_relogin`、`allow_register`、`support` 等没有环境变量覆盖，需要改请挂载 `config.yaml`。**暴露到公网时务必把 `allow_relogin` 设为 `false`**，否则任何能访问端口的人都能拿到已有账号的 access token。

### 数据与权限

所有状态都在数据目录里：`accounts/*.json`（账号、设备、房间、事件）、`media/`、`cache/`，备份这个目录即可。容器内以 UID/GID `10001` 运行，用绑定挂载时先授权：

```bash
mkdir -p data && sudo chown 10001:10001 data
# 然后改成 -v $PWD/data:/app/data
```

用 `compose.yaml` 里的具名卷则不需要这一步。

## 5. 源码编译

需要 Go ≥ 1.23（与 `go.mod` 一致）。

```bash
git clone https://github.com/Kauid323/YunhuUser2Matrix.git
cd YunhuUser2Matrix
make build          # 产出 bin/yhmatrix、bin/yhprobe
cp config.example.yaml bin/config.yaml   # 注意：要放在 bin/ 里，因为路径相对可执行文件解析
./bin/yhmatrix -mock -bind 127.0.0.1:8008 -data ./tmpdata
make test
```

或者直接 `go build -o yhmatrix ./cmd/yhmatrix && ./yhmatrix`。

## 反向代理与 HTTPS

Caddy 最省事（客户端填 `https://matrix.example.com`）：

```
matrix.example.com {
    reverse_proxy 127.0.0.1:8008
}
```

只有客户端看到的域名和 `server.name` 不一致时才需要 `public_url`；留空时地址从请求的 `Host` 推导，局域网 IP、localhost 都能自动正确。

浏览器里用 `https://app.element.io` 连 `http://` 局域网地址会被混合内容拦截，可用 Element Desktop、服务端同源托管 Element Web（`-fetch-web ./element-web` + `-web ./element-web`），或套一层 HTTPS 反向代理。详见 README 第 3 节。

## 升级

- 二进制：下载新版本，替换可执行文件，保留 `config.yaml` 与 `data/`。
- Docker：`docker pull ghcr.io/kauid323/yunhuuser2matrix:latest && docker compose up -d`（具名卷数据不会丢）。

## 维护者：发布新版本

打一个 `v*` tag 即可，两条 workflow 会自动跑：

```bash
git tag v1.0.0
git push origin v1.0.0
```

- `release.yml`：先跑 `go test ./...`，然后交叉编译 8 个平台的 `yhmatrix` + `yhprobe`，打包（Linux/macOS/FreeBSD 为 `.tar.gz`，Windows 为 `.zip`，内含 `config.example.yaml`、`README.md`、`LICENSE`），生成 `SHA256SUMS`，最后自动创建 GitHub Release 并附上全部产物与自动生成的 changelog。`-X main.version=<tag>` 会注入版本号，`yhmatrix -version` 可查。
- `docker.yml`：构建 `linux/amd64`、`linux/arm64`、`linux/arm/v7` 三种架构镜像，推送到 GHCR，同时打上 `:v1.0.0`、`:1.0.0`、`:1.0`、`:latest` 标签。

补发某个版本：Actions → 对应 workflow → Run workflow，填入**已存在**的 tag 名。

首次使用前的仓库设置：

1. Settings → Actions → General → Workflow permissions 选 **Read and write**（Release 需要 `contents: write`，GHCR 需要 `packages: write`，workflow 里已声明）。
2. 镜像推送成功后默认是私有的，到仓库的 Packages 页面把 `yunhuuser2matrix` 的可见性改为 **Public**，其他人才能直接 `docker pull`。
3. fork 之后镜像名会自动变成 `ghcr.io/<你的用户名>/<仓库名>`，`docs/INSTALL.md` 与 `compose.yaml` 里的镜像地址需同步修改。
