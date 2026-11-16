# Yunhu User API to Matrix

把云湖（Yunhu / chat-go.jwzhd.com）接成一个 **Matrix 服务端**。
用任意 Matrix 客户端（Element、FluffyChat、Cinny、Nheko、SchildiChat…）登录你的云湖账号，
私聊、群聊、图片、文件、语音、Markdown、引用、编辑、撤回都会双向同步。

```
┌──────────────┐   Matrix C-S API    ┌──────────────┐   REST + WSS    ┌──────────────┐
│ Element /    │ ──────────────────► │   yhmatrix   │ ──────────────► │  云湖服务端   │
│ FluffyChat … │ ◄────────────────── │  (this repo) │ ◄────────────── │ chat-go…/ws  │
└──────────────┘   /sync 长轮询      └──────────────┘   实时推送       └──────────────┘
```

---

## 1. 设计：一个"个人 homeserver"

它不是一个完整的联邦 homeserver，而是把云湖账号投影成 Matrix 空间的**个人服务端**：

| 云湖概念 | Matrix 概念 |
| --- | --- |
| 云湖账号 | 用户 `@yh_<云湖ID>:<你的域名>` |
| 私聊 / 群聊 / 机器人会话 | 房间 `!yh-user-<id>` / `!yh-group-<id>` / `!yh-bot-<id>` |
| 消息 | `m.room.message` 事件 |
| 会话列表 | 初始 `sync` 的 `rooms.join` |
| 头像、群名、简介 | `m.room.avatar` / `m.room.name` / `m.room.topic` |
| 已读 | `read_markers` / `receipt` → `dismiss-notification`（见第 8 节"未读与已读位置"） |

事件流用一条账号级单调递增的位置（`s123` 形式的 sync token）串起来，
同一份日志同时服务：WebSocket 实时推送、REST 历史回溯、自己发出消息的本地回显。
本地回显和云湖回推用 `msg_id` 去重，所以不会出现"自己发的消息两条"。

## 2. 快速开始

```bash
# 1) 编译
go build -o yhmatrix ./cmd/yhmatrix
go build -o yhprobe  ./cmd/yhprobe

# 2) 先跑一个假云湖，确认整条链路（不需要任何账号）
./yhmatrix -mock -bind 127.0.0.1:8008 -data ./data
#   演示账号：demo@yunhu.dev / demo1234

# 3) 用真实云湖账号
cp config.example.yaml config.yaml   # 改 server.name 和 public_url
./yhmatrix
```

客户端里把 homeserver 填 `http://127.0.0.1:8008`（或你的 https 域名）即可登录。

> 不想自己编译：[安装与部署](docs/INSTALL.md) 里列了 Release 预编译二进制、
> Docker 镜像、Compose、本地构建等方式，以及 systemd 常驻配置。

### 配置文件从哪读

`config.yaml` 就是**服务端根目录**（`yhmatrix` 可执行文件所在目录）里的那一份，
和你在哪个目录敲命令无关：

1. `-config <路径>`
2. `$YHMATRIX_CONFIG`
3. `<可执行文件所在目录>/config.yaml` ← 默认
4. `<当前工作目录>/config.yaml`（给 `go run` 用）

相对路径（`./data`、`./element-web`、`./certs/*.pem`）也一律相对**可执行文件目录**解析，
所以从 `C:\` 启动也还是用 `yhmatrix.exe` 旁边那个 `data/`。

写错了会直接报错，不会悄悄忽略：`-config` / `$YHMATRIX_CONFIG` 指向不存在的文件是启动失败，
不是回退到默认值。启动时还会把实际读到的文件打印出来：

```
level=INFO msg="config loaded" path=C:\yhmatrix\config.yaml base_dir=C:\yhmatrix
level=INFO msg="data directory" path=C:\yhmatrix\data
```

如果看到的是 `msg="no config.yaml found, using built-in defaults"`，说明那一份没被找到，
服务跑在默认值上——之前"改了配置没反应"就是这个原因。

### 四种登录方式

**已经登录过一次的账号，用 Matrix ID 直接登就行**（`server.allow_relogin`，默认开）：
账号、云湖 token、房间数据都已经在磁盘上，再走一遍手机号流程只是为了开第二台设备。

| 你在"用户名"里填 | 密码 | 结果 |
| --- | --- | --- |
| `@yh_8516939:localhost` | 随便填 | **直接复用本地账号**，发新 device + access token |
| `yh_8516939` / `8516939` | 随便填 | 同上 |
| 账号绑定过的手机号 / 邮箱 | 随便填 | 同上 |

`allow_relogin: false` 时，密码必须等于该账号保存的云湖 token。

> **安全**：`allow_relogin: true` 意味着任何能访问这个端口的人都能拿到已有账号的
> access token。局域网自用没问题，要暴露到公网请改 `false`。

**新账号**走云湖：`m.login.password` 被重载成"看用户名长什么样"来自动选择云湖的登录方式，
这样**所有只支持用户名密码的客户端都能直接用**：

| 你在"用户名"里填 | 在"密码"里填 | 实际走的云湖接口 |
| --- | --- | --- |
| `demo@yunhu.dev`（含 `@`） | 邮箱密码 | `/v1/user/email-login` |
| `13800138000`（纯数字） | 短信验证码 | `/v1/user/verification-login` |
| `yh_10001` 或留空 | 云湖 token | 用 token 调 `/v1/user/info` 校验 |

> **本地账号优先于上面的表格**。以前 `@yh_8516939:localhost` 会被剥成纯数字 `8516939`，
> 再被当成手机号送进 `/v1/user/verification-login`，于是"用 Matrix ID 登录"变成了
> "走云湖手机号登录"并且 403。现在先查本地账号，命中就直接发 token，**不碰云湖**。

另外还注册了三个自定义登录类型，给支持自定义流程的客户端用：
`com.yunhu.token`（`{token}`）、`com.yunhu.sms`（`{phone, captcha}`）、
`com.yunhu.email`（`{email, password}`）。

### 第三方标识（`m.id.thirdparty`）——FluffyChat 的邮箱登录

FluffyChat 选"邮箱登录"时发的不是 `m.id.user`，而是第三方标识：

```json
{"type":"m.login.password",
 "identifier":{"type":"m.id.thirdparty","medium":"email",
               "address":"@241114514@qq.com:localhost"},
 "password":"…","initial_device_display_name":"FluffyChat android"}
```

地址在 **`identifier.address`** 里，而且客户端还把它当成 Matrix 用户 ID 包了一层：
前面加 `@`、后面拼 `:<它以为的域名>`（日志里是 `localhost`，实际 homeserver 是
`192.168.1.12:8008`）。以前只读 `identifier.user`，于是用户名解析成空串，整个登录
请求直接失败。

现在 `identifierString` 按下面的顺序取标识：

| 请求里的位置 | 例子 |
| --- | --- |
| `identifier.user` | `@yh_8516939:localhost`（`m.id.user`，原样保留） |
| `identifier.address` | `241114514@qq.com` / `@241114514@qq.com:localhost` |
| `user` | 老客户端的字段 |
| `email` / `phone` | 自定义登录类型用的字段 |

第三方标识（`medium` 非空或 `type == m.id.thirdparty`，或值来自 `email`/`phone` 字段）
会被**解包**：去掉客户端加的前缀 `@`，再按**第一个冒号**截断掉后缀域名，
`medium == msisdn` 时再去掉 `+`。所以下面四种写法都能登进同一个云湖账号：

```
241114514@qq.com
@241114514@qq.com:localhost
@241114514@qq.com:192.168.1.12:8008
241114514@qq.com（走 com.yunhu.email）
```

`m.id.user` 里的真正 Matrix ID **不解包** —— 它要原样交给 `localAccountFor`，
那里才认识 `@localpart:server`。

> 解包只影响"长什么样"，不影响"是谁"：解出来的邮箱仍然要去 `localAccountFor` 查本地账号，
> 查不到就走云湖 `/v1/user/email-login` 真登录。所以写错邮箱只会失败，**不会**登进别人账号。

回归测试：`internal/matrix/login_test.go`、`internal/matrix/login_thirdparty_test.go`
（后者把日志里那条请求原样重放了一遍）。

手机号登录前需要图形验证码和短信，辅助接口：

```bash
# 取滑块验证码（返回 base64 图片与 id）
curl http://127.0.0.1:8008/_matrix/client/v3/login/yunhu/captcha

# 请求短信验证码
curl -X POST http://127.0.0.1:8008/_matrix/client/v3/login/yunhu/sms \
  -d '{"phone":"13800138000","captcha_id":"...","captcha_code":"...","x":120}'
```

## 3. 排错：网页版 Element 报 "Invalid /versions response"

如果你在 `https://app.element.io` 里填 `http://192.168.1.12:8008`，会看到：

```
Invalid /versions response
Homeserver URL does not appear to be a valid Matrix homeserver
```

**这不是服务端的问题**。用 curl 打同样的地址是 200 + 合法 JSON + 齐全的 CORS 头。
真正的原因是浏览器：`https://` 页面不允许请求 `http://` 资源（混合内容），
Chrome 还会额外拦截"公网页面 → 局域网 IP"（Private Network Access）。
请求根本没发出去，Element 把网络失败统一报成了 "Invalid /versions response"。

三种解法，按省事程度排序：

**① 用 Element Desktop**（最快，没有浏览器限制）

下载桌面版，homeserver 填 `http://192.168.1.12:8008` 即可。

**② 让服务端自己托管 Element（同源，不需要证书）**

```bash
# 一条命令下载并解压官方 Element Web（约 58 MB，解压后直接可用）
./yhmatrix -fetch-web ./element-web

# 启动时把它挂上去
./yhmatrix -config config.yaml -web ./element-web
```

然后浏览器打开 **`http://192.168.1.12:8008/`**。
服务端会动态生成 `/config.json`，`base_url` 自动指向你当前访问的地址，
登录框已经填好，不用再手填 homeserver。

国内网络拉 GitHub 慢或者被限流时，可以换镜像或锁定版本：

```bash
# ghproxy 式前缀镜像
./yhmatrix -fetch-web ./element-web -mirror https://ghproxy.net

# 锁定版本，完全跳过"查最新版"这一步（GitHub 匿名 API 只有 60 次/小时）
./yhmatrix -fetch-web ./element-web -web-version v1.12.35

# 已经下过一份，想覆盖
./yhmatrix -fetch-web ./element-web -force
```

`-fetch-web` 只做下载，不启动服务；它不需要 `config.yaml`，可以离线先备好客户端。

**③ 给它一个 https 地址**

```bash
# 临时隧道，一条命令拿到 https 域名
cloudflared tunnel --url http://localhost:8008
# 然后把 https://xxx.trycloudflare.com 填进 app.element.io

# 或者用 mkcert 自签（浏览器信任本地 CA 后 https 才能被 fetch）
mkcert -install && mkcert 192.168.1.12
./yhmatrix -tls-cert ./192.168.1.12+0.pem -tls-key ./192.168.1.12+0-key.pem
```

> 自签证书必须被系统信任，否则 `fetch()` 会直接失败——点击"继续访问"只对页面导航有效，
> 对 XHR 无效。

**先确认服务端本身没毛病：**

```bash
curl -s http://192.168.1.12:8008/_matrix/client/versions
# {"unstable_features":{},"versions":["v1.1",...,"v1.11"]}

curl -s -o /dev/null -w '%{http_code}
' http://192.168.1.12:8008/_matrix/client/v3/login
# 200
```

启动日志里也会直接提示这一点：

```
WARN plain HTTP homeserver: browsers block https://app.element.io from calling it (mixed content).
```

## 4. 已验证的行为

在 `-mock` 模式下跑通的端到端流程（`go test ./...` 覆盖其中一部分）：

- 邮箱登录 → 首次 `sync` 自动拉会话列表、建房间、回溯 15 条历史
- 发消息：`PUT /rooms/{id}/send/m.room.message/{txn}` → 云湖 `send-message` → 本地回显 → `/sync` 增量可见
- 另一账号发消息 → 云湖 WebSocket 推送 → 长轮询 `/sync` **毫秒级**唤醒（实测约 250ms）
- 滑动同步：首次请求返回房间列表 + `initial` 状态；对端发消息后长轮询 **~230ms** 唤醒，
  只返回变化的那个房间，`name` 等未变字段省略，`pos` 递增
- 两种方言都能跑：MSC4186 的 `range`/对象式 `required_state`，MSC3575 的 `ranges`/`[type,key]` + `ops`
- 图片：`/media/upload` → 传云湖七牛（按 bucket 查上传域名）→ 云湖 `image`/`image_url` → 通过 `mxc://` 代理回读
- 编辑：**双向**，Matrix `m.replace` ⇄ 云湖 `edit-message`，同一条消息原地改、不产生新消息
  （见第 8 节"编辑"）
- 撤回：双向都走真正的 `m.room.redaction`（见第 8 节"撤回"）
- 机器人：`@yhbot_<id>` 是正常 Matrix 用户，有 `m.room.member`、昵称和头像
- 新建聊天：进入已有云湖会话，**不**调用 `create-group`（见第 8 节"新建聊天"）
- 群人数：来自 `group/info` 的 `headcount`，不是"本地见过的成员数"
- 进程重启：账号、设备 token、房间、历史全部恢复，WebSocket 自动重连

## 5. 对着真实云湖做验证

上游文档里有若干字段没有定论（请求到底走 protobuf 还是 JSON、七牛域名、`list-message` 的
分页语义）。`yhprobe` 可以单独验证这些假设，不用起整个服务：

```bash
export YUNHU_TOKEN='你的云湖 token'

./yhprobe info                          # /v1/user/info，确认 token 可用
./yhprobe convs                         # 会话列表
./yhprobe history -chat 10002 -type 1 -limit 5
./yhprobe send    -chat 10002 -type 1 -text "hello from yhprobe"
./yhprobe ws      -user 10001           # 连 60 秒，打印所有实时帧
```

`-wire proto|json|auto` 可以强制请求编码。默认 `auto`：先发 protobuf，
如果服务端返回 4xx 就自动改用 `application/json` + protojson 重发；
响应侧则按内容嗅探（`{` 开头按 JSON 解，否则按 protobuf 解），两边都能吃。

## 6. 滑动同步（Sliding Sync）

现代客户端（Element X、开了 labs 的 Element Web）默认走滑动同步，而不是 `/sync`。
官方方案要单独跑一个 `matrix-org/sliding-sync` 代理 + Postgres，再在 well-known 里
用 `org.matrix.msc3575.proxy` 指过去。**这里不需要**：服务端直接实现了两种方言。

| 方言 | 端点 | 谁在用 |
|---|---|---|
| MSC4186（简化版） | `POST /_matrix/client/unstable/org.matrix.simplified_msc3575/sync` | Element X |
| MSC3575（经典 sync v3） | `POST /_matrix/client/unstable/org.matrix.msc3575/sync` | Element Web labs、原版代理 |
| v4（稳定路径） | `POST /_matrix/client/v4/sync` | 新规范 |

`/_matrix/client/versions` 会同时声明两个开关，客户端据此启用功能：

```json
"unstable_features": {
  "org.matrix.simplified_msc3575": true,
  "org.matrix.msc3575": true
}
```

`/.well-known/matrix/client` 里的 `org.matrix.msc3575.proxy` 指向服务端**自己**，
这样只认 proxy 字段的老客户端也能直接连上来：

```json
{
  "m.homeserver": { "base_url": "http://192.168.1.12:8008" },
  "org.matrix.msc3575.proxy": { "url": "http://192.168.1.12:8008" }
}
```

两种方言的差异（服务端都能吃，自动识别）：

| | MSC3575 | MSC4186 |
|---|---|---|
| 窗口 | `ranges: [[0,19]]` | `range: [0,19]` |
| 状态 | `required_state: [["m.room.name","*"]]` | `required_state: [{"type":"m.room.name"}]` |
| 列表结果 | `count` + `ops`（`SYNC` 带完整 `room_ids`） | 只有 `count` |
| 未读数 | `notification_count` / `highlight_count` | 已从规范移除 |

支持的请求字段：`lists`（`range`/`ranges`、`timeline_limit`、`required_state`、
`filters.is_dm`、`filters.is_invited`）、`room_subscriptions`、`extensions`
（`typing` 返回真实数据，`e2ee`/`to_device`/`account_data`/`receipts`/`presence` 返回空）、
`pos`、`timeout`、`conn_id`、`set_presence`。

增量语义按规范：没变化的房间**整个不返回**，没变化的字段（`name`、`avatar`）**省略**，
只有首次请求带 `initial: true`。长轮询复用 `/sync` 的唤醒通道，实测推送唤醒 **~230ms**。

> `filters` 只实现了这个投影能表达的：房间没有 type、tag、加密，所以
> `room_types`/`tags`/`is_encrypted` 非空时匹配不到任何房间。

## 7. 端到端加密面（Element X 卡在"确认你的数字身份"）

云湖没有 E2EE，本服务端也不会加密任何消息。但 **E2EE 优先的客户端仍然需要这些接口**，
否则它连自己的设备都看不见。Element X 的表现就是：登录后停在"确认你的数字身份"，
一个按钮都没有，只有一个转圈，并且**每 5 秒打一次 `/keys/query`，永不停止**。

原因在客户端源码里写得很清楚：

- `RustEncryptionService.hasDevicesToVerifyAgainst` 是个 `SharingStarted.Eagerly` 的流，
  循环里 `delay(5_000)`，失败还会 `Timber.e("... retrying in 5s")` 再转一圈；
  `isLastDevice` 同理。两者底层都是 `/keys/query`。
- `RustEncryptionService.recoveryStateStateFlow` 在 `syncState != Running` 时被强行改成
  `WAITING_FOR_SYNC`；`ChooseSelfVerificationModePresenter` 把它映射成 `AsyncData.Loading()`。
- `ChooseSelfVerificationModeView` 在 `Loading` 状态下**只渲染一个 `LoadingButtonAtom`**，
  连"I can't confirm"那个出口按钮都不显示。

所以老的桩实现（`device_keys: {}`、account_data 丢弃）会让客户端永久卡死并空转。
现在按 Synapse 的做法真正存取：

| 接口 | 行为 |
| --- | --- |
| `POST /keys/upload` | 存 device_keys / one_time_keys / fallback_keys，返回真实计数 |
| `POST /keys/query` | 返回本用户的 device_keys 与 master/self_signing/user_signing keys |
| `POST /keys/claim` | 取出并**消费**一次性密钥，没有则回退到 fallback key |
| `POST /keys/device_signing/upload` | 存交叉签名密钥（不做 UIA，否则客户端无法重置身份） |
| `POST /keys/signatures/upload` | 把签名**合并**进已存对象，而不是覆盖 |
| `GET /keys/changes` | 按 `DeviceListPos` 判断是否变化 |
| `PUT/GET /user/{id}/account_data/{type}` | 真正持久化（secret storage 就在这儿） |
| `/room_keys/version`、`/room_keys/keys` | 最小可用的备份版本与载荷存储 |

`/sync` 与滑动同步也会带 `account_data`、`device_lists.changed` 和真实的
`device_one_time_keys_count` —— 缺了这些，客户端永远认为"还没同步完"。

**to-device 是验证的唯一通道**：`m.key.verification.request/ready/start/accept/key/mac`
全是 to-device 事件，不走房间。之前 `to_device` 恒为空，所以"用另一台设备验证"点下去
对方永远收不到请求，界面就一直转圈重试。现在实现了：

- `PUT /sendToDevice/{eventType}/{txnId}`：按 `(目标用户, 目标设备)` 入队，支持 `"*"` 广播到所有会话；
- `/sync` 的 `to_device.events` 与滑动同步的 `to_device` 扩展按**设备游标**投递，只送一次；
- 队列上限 500 条，进程重启后仍在（跟着账号 JSON 落盘）。

配套的两个防循环措施：

- **重复上传不推进流**：`/keys/upload` 收到一模一样的 device_keys、`/account_data` 写入相同内容时
  不再 `NextPos()`。否则客户端每次启动都重传一次，`device_lists.changed` 就永远是"有变化"，
  `/sync` 于是永远有内容、永不长轮询 —— 表现就是疯狂刷请求。
- **滑动同步的扩展内容也算 content**：to-device 或 secret storage 有货时必须立刻返回，
  不能继续长轮询（否则游标已推进、消息却被丢掉）。

服务端始终不持有任何私钥：只存客户端上传的公钥、签名和加密后的 secret storage。
每个用户/房间是否加密不受影响，云湖消息依然是明文。

### 两个"整包被丢弃"的坑（2026-11 修）

matrix-rust-sdk 把响应反序列化成 ruma 的类型，**只要有一个必填字段不对，整个响应就被
判定为解析失败**，不是"忽略这一段"。客户端收到解析错误后：

1. `SyncService` 进入 `State::Offline`；
2. `offline_check()` 开始**无退避地轮询 `/_matrix/client/versions`**，通了就重启两个 sync；
3. 重启后再次解析失败 → 又进 Offline → 无限循环。

服务端日志看起来就是"每秒上百个 200、`dur_ms=0`"；客户端则同时表现为
**"无法连接服务器"**、**停在"确认你的数字身份"转圈**（`recoveryState` 在
`syncState != Running` 时被强制成 `WAITING_FOR_SYNC`），而且 `pos` 永远不前进。

踩过的两个字段：

| 字段 | ruma 的要求 | 我们以前发的 | 结果 |
| --- | --- | --- | --- |
| `to_device.next_batch` | `String`，**必填** | 整个字段缺失 | 只要开了 `to_device` 扩展就必错 |
| `to_device.events` | `Vec<_>` + `#[serde(default)]` | 没有待投递事件时是 `null` | `null` 不等于"缺失"，`default` 救不了 |

第二条尤其阴险：`#[serde(default)]` 只处理**键不存在**，`null` 照样解析失败。所以
Go 里 `var s []T` 直接塞进响应是危险的 —— 必须用 `[]T{}`。
`internal/matrix/wire_test.go` 现在专门钉住这些必填字段。

## 8. 支持的 Matrix 接口

登录与账号：`/login`、`/logout`、`/logout/all`、`/account/whoami`、`/capabilities`、`/devices*`、
`/register`（明确拒绝）、`/account/deactivate`

同步：`/sync`（长轮询、`since` 增量、`filter` 的 timeline limit）、
滑动同步 `/unstable/org.matrix.simplified_msc3575/sync` 与 `/unstable/org.matrix.msc3575/sync`（见第 6 节）

房间：`/joined_rooms`、`/rooms/{id}/messages`（双向翻页）、`/rooms/{id}/context/{eventId}`
（事件的上下文，见第 8 节"`/context` 曾经 404"）、`/send/{type}/{txn}`、
`/state[/{type}[/{key}]]`（读写）、`/members`、`/joined_members`、`/event/{id}`、
`/read_markers`、`/receipt`、`/typing`、`/redact`、`/leave`、`/join`、`/forget`、`/relations`、
`/threads`（空列表，云湖没有子线程，但路由必须存在）、`/createRoom`（= 进入已有云湖会话）

**`/threads` 曾经 404**：Element X 点开"子线程"面板时会 `GET /rooms/{id}/threads`，路由没注册
就落到兜底，返回 `M_UNRECOGNIZED`，日志是 `status=404 dur_ms=0`（`dur_ms=0` = 没进 handler）。
云湖没有 thread 概念，正确回答是空列表 + `next_batch: null`（和 Synapse 一致）。

**`/messages` 的翻页令牌有两种**，客户端当成不透明字符串，混着用没问题：

| 令牌 | 含义 |
| --- | --- |
| `s<pos>` | 本地时间线的流位置，和 `/sync` 的 `prev_batch` 同一套 |
| `y<base64url(msg_id)>` | 已经翻到本地窗口之外，继续从云湖这条消息往前要 |

**事件 ID 也能当令牌用**（`dir=f` 时）：客户端"跳到第一条未读"用的是
`m.fully_read` 里那个 `event_id`，不是流位置。`roomPosOf` 会把它解析成对应的流位置，
否则令牌按 0 解析、页面从房间最开头返回 —— 表现就是"点了跳转未读，翻到的是最早的聊天记录"。
（见下面"未读与已读位置"。）

流程：先在内存时间线里倒着扫，一页不满 `limit` 就说明本地到头了，这时拿**最老一条的
`msg_id`** 去调 `POST /v1/msg/list-message`（文档语义：返回该消息**之前**的消息），
把结果按时间戳升序排好接在这一页前面，`end` 换成 `y<...>`。云湖返回空 → 不给 `end`，
客户端就停下。

不落盘是故意的：这些是旧历史，不是新消息，塞进 `room.Events` 会让 `/sync` 把它们当成
新消息重推一遍，还会和 `max_events_per_room` 的保留策略打架。代价是同一段历史重复翻
会重复请求云湖一次。

顺带修了个隐藏 bug：`ListMsgResponse` 的顺序文档没写，而流位置是按遍历顺序发的，
如果上游给的是倒序，整条时间线（和由它派生的所有令牌）就是反的。现在统一按
`send_timestamp_ms`（缺失时退到 `msg_seq`）升序排，不信任响应顺序。

资料：`/profile/{id}`、`displayname`、`avatar_url`（改名/换头像会同步到云湖）

### 引用消息（`quote_msg_id` + `quote_msg_text`）

Matrix 的引用关系带**两份**内容，云湖要**两份都填**，少一份就出问题：

| Matrix 里的位置 | 云湖字段 | 少了会怎样 |
| --- | --- | --- |
| `m.relates_to.m.in_reply_to.event_id` | `quote_msg_id` | 引用关系丢失 |
| body 里 `> …` 引文块 / `formatted_body` 的 `<blockquote>` | `quote_msg_text` | **云湖引用框显示"空气"** |

以前的实现只填了 `quote_msg_id`，于是云湖官方客户端渲染出一个**空的引用框** ——
这就是"引用消息内容显示：空气，不过有引用 msgid"。

现在 `buildSendRequest` 在**处理内容之前**就把 Matrix 的引用块拆开：

```
> <@yh_1659829:localhost> 1
> 
> 6464646455521        ← 这是用户真正输入的新消息
```

- 引文（`>` 开头的连续行）→ `quote_msg_text`；
- 其余 → 真正的新消息文本；
- `<@user:server> ` 这个 Matrix fallback 前缀会被剥掉：真正的作者云湖自己从
  `quote_msg_id` 就能查到，留着是可见的噪音。

拆分在 mentions/媒体处理**之前**做，所以新消息里的 @ 和图片不会被引文块干扰。

回归测试：`internal/matrix/reply_test.go`。

### 会话类型判定（机器人被判成群聊）

症状：**部分机器人会话在 Matrix 里显示成群聊。**

根因是"房间类型来自哪里"不唯一：

- room id 是从 `(chat_id, chat_type)` 派生的；
- 会话列表通常带 `chat_type`，但**可能缺失**；
- 缺失时老代码直接建一个 `chatType=0` 的房间，于是同一个会话在
  `!yh-bot-…` 和 `!yh-user-…` 之外又多出一个 `!yh-user-…`（type 0）的影子房间。

现在两条兜底：

`inferChatTypeLocked` 在会话列表缺 `chat_type` 时，按已知信息推断类型：

1. 账号里已经有这个 `chat_id` 的房间 → 用它已有的类型；
2. 否则看这个 id 是否等于某个已知 bot 的 id（bot 用自己的 id 寻址）→ bot；
3. 都不匹配 → user。

`retypeRoomLocked` 处理"上游纠正了类型"的情况。类型变了 room id 就得跟着变，
所以它把房间从旧 id 搬到新 id，**事件、成员、状态、已读位置全部原样搬过去**，
不清空任何东西。

回归测试：`internal/matrix/reply_test.go`
（缺 `chat_type` 时推断成 bot、retype 后旧 id 消失且历史不丢）。


本地状态里只有"说过话的人"，所以以前打开群成员列表只能看到零星几个名字。现在群聊的
`/members` 会去拉云湖 `POST /v1/group/list-member`（`page` 从 **1** 开始，`size` 100），
翻到不满一页为止，结果缓存在 `Room.GroupMembers` 里 **5 分钟**。

- 缓存**不落盘**：200 个房间的账号文件已经 3.9 MB，再塞几百人 × 150 个群会把它翻几倍，
  而 `MarkDirty` 每次都是整份重写。重启后重新拉一次只影响用户真正点开的房间。
- 已有 `m.room.member` 状态事件优先，花名册里剩下的人再合成事件补上，
  所以既不会重复也不会漏。
- 单聊 / bot 会话没有花名册，直接返回本地状态，**不发上游请求**。

角色映射（云湖 `permission_level` → Matrix power level）：

| 云湖 | permission_level | Matrix power level | Element 中文显示 |
| --- | --- | --- | --- |
| 群主 | 100 | **100** | 管理员 |
| 管理员 | 2 | **50** | 协管员 |
| 普通成员 | 0 / 无 | 0（不写进 users） | 默认 |

角色的**权威来源是 `POST /v1/group/info`**（和群人数同一次请求，见 `GroupData`）：

| 字段 | 含义 | 用途 |
| --- | --- | --- |
| `owner`（23） | 群主 | → power 100（为空时退回 `create_by`(7)） |
| `admin`（20） | 管理员列表 | → power 50 |
| `permisson_level`（9） | **本账号**在该群的等级 | → 本账号自己的 power |

花名册（`list-member` 的 `permission_level`）是第二来源，用来补个人等级；
两边的等级取最大值后重发一次 `m.room.power_levels`（`users` 里只有群主和管理员，
`users_default: 0`）。等级没变化就不重发，避免刷状态事件。

**本账号的等级只写真实值，绝不写死 100。** 早期版本干过两件错事：

1. 本账号固定 100，于是一个普通管理员（云湖 2）显示成"管理员"，和群主一样；
2. 群聊房间创建时把 `users` 直接播种成 `{本账号: 100}`，而 `group/info` 只在打开
   成员列表时才拉——**于是所有会话都显示自己是管理员**，哪怕群是别人建的。

现在的规则：群聊房间初始 `users` 是**空的**（这个 Matrix 房间是本服务端投影出来的，
创建者不等于云湖群的群主）；只有 `group/info` / 花名册明确说你是群主或管理员时才有等级，
查不到就是 0（Element 显示"默认"）。单聊 / bot 会话仍然给 100——那种房间本来就只有你。

两个配套细节：

- `RolesTS` 为 0 的房间（老版本写的、还带着假 100）会在下次刷新时**强制重拉一次**
  `group/info` 修掉，不会被"人数还没过期"跳过。
- 滑动同步里 `m.room.power_levels` **无条件下发**（和 `m.room.pinned_events` 一样）：
  Element X 的 `required_state` 很窄，被过滤掉的话修正后的角色永远到不了客户端。

回归测试：`internal/matrix/members_test.go`、`internal/matrix/roles_test.go`。

### 置顶：云湖群机器人看板（`m.room.pinned_events`）

云湖的 **群机器人看板**（`BotBoardMessage`）是机器人给一个会话维护的公告：一段内容 +
`content_type`（text / markdown / html）+ `last_update_timestamp` + 机器人名。
Matrix 没有对应概念，最接近的是**置顶消息**，所以它被投影成：

- 一个 `m.room.message` 事件，发送者是那个机器人的 Matrix 用户
  （`@yhbot_<bot_id>`，同时补一条 `m.room.member`，带看板里给的机器人名）；
- `m.room.pinned_events` 状态事件的 `pinned` 指向它 —— Element 的"已置顶消息"
  面板读的就是这个。

**一个群可以有多个机器人，每个机器人一块看板。** 这一点上游文档写得容易误解：

| 来源 | 定义 |
| --- | --- |
| `yhchatAPI` 的 `bot.md` | `BotBoardMessage data = 2`（看起来只有一块） |
| 云湖官方 Android 端 `bot.proto` | `repeated Board_data board = 2` |

两者在线格式完全一致（field 2 的 length-delimited 内嵌消息，单块就是长度 1 的
repeated），所以现在 proto 按官方客户端写成 `repeated`，一份响应能解出**所有**机器人的
看板。以前只有一个 `Room.BoardEvent` 槽位，多机器人群里后写入的那块会把前一块**顶掉**，
最终只有一块看板能置顶。

现在的模型：

| 字段 | 含义 |
| --- | --- |
| `Room.BoardEvents map[botID]*Event` | 每个机器人一块看板事件 |
| `Room.BoardTS map[botID]int64` | 每个机器人已投影的 `last_update_timestamp` |
| `Room.BoardFetchedTS` | 整批看板的拉取时间（5 分钟 TTL） |

几个刻意的选择：

- **看板事件不进时间线**（`Room.BoardEvents`，单独存）。看板是公告不是聊天记录，
  塞进 `room.Events` 既污染对话，又会被 `max_events_per_room` 淘汰掉——而置顶正好
  指向那个事件，淘汰了就变成空面板。
- `/rooms/{id}/event/{eventId}` 能解析它（`Room.FindEvent` 也查 `BoardEvents`），
  这是客户端渲染"没在时间线里见过的置顶项"的路径。
- **`/rooms/{id}/context/{eventId}` 也必须能解析它**，见下面那段。
- **一个机器人一个 pin**：`pinned` 里每个机器人一条，按事件 ID 排序，面板不会每次刷新
  就换顺序。
- **同一版本不重复发**：用 `last_update_timestamp` 去重，事件 ID 是
  `board_<chat_id>_<bot_id>_<ts>` 派生的。某个机器人改一版才换它自己那个事件，
  不影响别人的置顶。
- **某个机器人看板清空 → 只取消它自己的置顶**；整批列表里消失的机器人也在这里被
  清掉，否则删了看板群里会永远留一条死 pin。
- 滑动同步**无条件**带 `m.room.pinned_events`：客户端基本不会在 `required_state` 里列它，
  按 required_state 过滤的话置顶面板永远是空的。

数据来源两条：

| 触发 | 路径 |
| --- | --- |
| 实时 | WebSocket `bot_board_message`（protobuf 与 JSON 两种 wire 都接了） |
| 打开房间 | `/messages?dir=b` 时后台拉一次 `POST /v1/bot/board`，5 分钟 TTL |

不在连接时给所有群拉一遍：那会给 150 个群各加一次请求，而大多数群用户根本不会打开。
请求失败会记 `BoardFetchedTS`，避免每次翻页都重试。

> **"点一下应该弹列表"**：客户端的"已置顶消息"面板就是置顶列表，服务端这边已经把
> 每块看板都塞进 `pinned` 了，点开就能看到全部。如果只显示一条，先看是不是这里的老
> 版本（单槽位）写下的房间 —— 那是数据问题不是路由问题，见下面的排查命令。

回归测试：`internal/matrix/board_test.go`（含 `TestMultipleBoardsAreAllPinned`
和 `TestBoardsRemovedUpstreamUnpin`）。

### `/context` 曾经 404（看板点了就报错）

打开"已置顶消息"时 Element 会请求事件的上下文：

```
GET /_matrix/client/v3/rooms/!yh-group-979377289:localhost/context/$yh_board_979377289_1794644246?limit=30
resp: {"errcode":"M_UNRECOGNIZED","error":"Unrecognized request"}
```

`M_UNRECOGNIZED` 是**路由没注册**的信号（和上一节 `/threads` 同一个坑）：请求直接落到
兜底 handler，日志里是 `status=404 dur_ms=0`。看板事件不在时间线里，客户端只能靠
`/context` 拿到它 —— 所以置顶面板一点就报错。

现在实现了 `GET /rooms/{roomId}/context/{eventId}`（`internal/matrix/rooms.go`
的 `eventContext`）：

- `event` 就是目标事件本身，`Room.FindEvent` 会翻 `BoardEvents`，所以看板事件能解析；
- `events_before` 按规范是**倒序**（紧邻的那条在前），`events_after` 正序；
- 只装时间线事件，state 事件走 `state` 字段，混进去客户端会当成消息渲染；
- `start` 必有，`end` 只在后面确实还有内容时给（`s<pos>` 令牌）；
- 三个数组一律 `[]T{}`，**不能是 `null`**：ruma 把 `null` 当解析失败，整个响应被丢弃
  （见第 7 节"两个整包被丢弃的坑"）。

还有一个竞态：看板是打开房间时**懒加载**的，如果客户端先点置顶面板、`/messages` 的
后台刷新还没回来，目标事件就还不存在。所以 `eventContext` 发现"群聊 + 找不到事件 +
TTL 过期"时会**同步**拉一次 `POST /v1/bot/board` 再查一遍，而不是直接 404。

回归测试：`internal/matrix/context_test.go`（路由存在、看板事件可解析、`events_before`
倒序、三个数组不为 `null`、未知事件是 `M_NOT_FOUND` 而不是 `M_UNRECOGNIZED`）。

### 升级后只看到一块看板？那是旧数据

单槽位时代的房间在账号 JSON 里只有一个 `board_event` / `board_ts`，换成多看板后
这两个键**不会被读**（新键是 `board_events` / `board_ts` 映射），所以老房间的置顶在
第一次成功拉取前是空的。刷新一次就回来了：

```bash
# 该房间最近的活动会在日志里显示看板拉取数量
# level=DEBUG msg="bot boards fetched" room='!yh-group-…' count=3
```

如果一直只有 1 条，先确认云湖那边这个群**真的**有多个机器人挂着看板 ——
`/v1/bot/board` 返回几条就置顶几条，服务端不做过滤。可以直接问上游：

```bash
export YUNHU_TOKEN='你的云湖 token'
./yhprobe board -chat 20001 -type 2
```

> 注意 `board` 的 `chat_type`：**2 = 群聊，3 = 单机器人会话**，和 `list-message` 的
> `1 = 用户` 不通用。用错类型拿到的是空列表，不是报错。

### 未读与已读位置（`unread_notifications` / `m.fully_read`）

症状：**满屏未读红点，点进去不清零；清掉了过一会儿又长回来。**

两个独立的原因，都出在"未读是一个计数器"这个设计上：

1. **`/receipt` 是个空函数**——只回 200，不记录任何东西。客户端滚到底部、发出已读回执，
   服务端丢掉，下一次 `/sync` 照样把旧数字发回去。
2. **每次重连都用云湖的数字覆盖**。`refreshAccount` 拉会话列表时无条件写
   `room.Unread = c.GetUnreadMsg()`，而云湖那个数字**永远不会因为你在 Matrix 里读过而降**：
   `dismiss-notification` 只清云湖自己的角标，不改会话列表里的 `unread_msg`。于是清掉的
   红点在下一次 WebSocket 重连后原样回来。

现在未读是**推导出来的**，不是记账：

| 字段 | 含义 |
| --- | --- |
| `Room.ReadMarkerPos` | 已读到的时间线流位置（**唯一真相**） |
| `Room.ReadMarker` | 已读到的 `event_id`，就是 `m.fully_read` 要发的值 |
| `Room.ReadMarkerChangePos` | 已读位置**被更新**的流位置（不是被标记的位置） |
| `Room.Unread` / `Highlight` | 只作为"从没读过"的种子值 |

`Room.UnreadFor(self)` 数的是"`ReadMarkerPos` 之后、别人发的消息"，所以：

- 读过了 → 恒等于 0，任何重连都不可能复活它；
- 没读过 → 用云湖的种子值（首次导入时唯一能拿到的数字）；
- 永远不会无界增长（以前 `ingest` 里 `room.Unread++` 是只增不减的）。

`ReadMarkerChangePos` 单独存在的理由值得记一下：`ReadMarkerPos` 指向的**永远是过去的事件**，
流位置必然 ≤ 客户端的 `since`，所以拿它判断"这次同步有没有已读变化"永远为假 —— 那就是
"标记已读后红点不消失"的最后一块拼图。改 `ReadMarkerChangePos` 之后 `/sync` 才会因为
"你读了它"而重新下发这个房间。

**`m.receipt` 要回显。** `POST /rooms/{id}/receipt/m.read/{event_id}` 返回 `{}` 是**正确的** ——
Matrix 规范就是空对象。但客户端发完回执后还需要在同步里**看到它回来**：

```
{"type":"m.receipt","content":{"<event_id>":{"m.read":{"<user_id>":{"ts":…}}}}}
```

这条 `ephemeral` 事件驱动未读分隔线的位置（以及第二台设备上的角标清零）。以前
`ephemeral` 里**只有 typing，从来不发 `m.receipt`**，于是回执是个黑洞：客户端说"我读到
这里了"，服务端记住了，客户端再也没听到下文。

现在已读位置变化时（和初始同步里）会带上它。`Room.ReadMarkerTS` 就是那个 `ts`。

**`m.fully_read` 必须是一个真事件 id。** 客户端有时发的是裸位置令牌（`s42`），
或者位置正好落在 state 事件上（state 不在时间线里）。以前"精确匹配 pos"在这种情况
下匹配不到，`ReadMarker` 就留空 —— 客户端连锚点都没有。现在 `eventAtOrBefore`
取**不晚于该位置的最新时间线事件**，一个都没有就退到最早的那个消息。

**这也顺带解决了"跳转到未读"。** 客户端要跳到第一条未读，靠的是：

1. `/sync` 房间级 `account_data` 里的 `m.fully_read`（以前恒为空数组）；
2. `/messages?dir=f&from=<那个 event_id>`。

第 2 步以前是坏的：`parseSince("<event id>")` 返回 0，页面从房间最开头返回。现在
`roomPosOf` 会把 event id 解析成流位置。`/messages` 的 `from` 因此接受三种形态：
`s123`、事件 ID、`y<...>`。

滑动同步（Element X）也带房间级 `account_data`，否则它的未读分隔线永远画不出来。

回归测试：`internal/matrix/unread_test.go`
（派生未读、回执清零并被推送、重连不复活、已读位置只前进、已读位置被淘汰后仍有效、
跳到第一条未读、`m.fully_read` 的 id 能当令牌用）。

### 聊天记录有缺口（`Backfilled` 一次性标记）

症状：**房间里中间一段消息永远缺着，除非删掉 `data/` 重来。**

原因是"回填一次就完事"：房间第一次被抓到时拉 `yunhu.backfill` 条历史，然后
`Backfilled = true`，此后再也不看。于是三种情况都会留下永久空洞：

- 进程停机期间有人说话 —— 那些消息只存在于上游；
- 回填请求失败 —— 老代码**即使失败也标记完成**，这个房间就永远空着；
- 首次只回了 15 条，而中间其实漏了一段。

现在每次重连做一次**对账**（`Room.GapSuspected()` 限流，10 分钟内不重复）：

| 判定 | 含义 |
| --- | --- |
| `GapAfter(页最新 ts)` | 上游比本地新（停机期间有人说话） |
| `GapBetween(页最老 ts, 页最新 ts)` | 上游这一页和本地**不相接**，中间断了 |

只看最新时间戳是不够的：一个房间可以"底部是最新的"，中间却缺一大段。所以两个条件都要满足
其一才修。`gapSlackMS = 2s` 是给时间戳抖动留的余量 —— 设成 60 秒过宽，会把几秒间隔的
真实空洞判成"没缺"。

修复（`repairGap`）：从上游最新一页开始**往回翻**，直到某一页出现已知消息（接缝），
把接缝之后的所有未知消息按时间升序插入。要点：

- **接缝取"最后一个已知消息的下标"**，不是第一个。页面是升序的，已知消息后面（更新）的
  仍是缺失的。按"遇到第一个已知就整页丢掉"会把空洞填一半。
- 回填失败**不再**标记完成，下次重试。
- 往回翻有上限（`maxBackfillPages = 6`），避免一次重连变成无边界的爬取。

回归测试：`internal/matrix/backfill_gap_test.go`
（停机空洞被补齐且不重复、失败不标记完成、对账限流、state 事件不参与"最新消息"判断）。

### 编辑（双向）

Matrix 和云湖对"编辑"的建模完全不同，所以这一节值得单独写：

| | 模型 |
| --- | --- |
| 云湖 | 消息**原地被改写**，只留一个 `edit_timestamp`（`list-message` 返回的就是最终内容） |
| Matrix | 编辑是**一条新事件**：`m.relates_to.rel_type = m.replace`，新内容在 `m.new_content` 里，原事件不动 |

以前两边都做错了一半：

- **云湖 → Matrix 方向**：推送的编辑被投影成一条独立的时间线消息（`* 新文本`），
  原消息仍显示旧文本。聊天记录里于是出现两条，一条还是带 `* ` 前缀的重复。
- **Matrix → 云湖 方向**：上游调用是对的（`edit-message`），但**本地回显把整条
  `m.replace` 信封塞进了时间线**，客户端又渲染出一条 `* 新文本`，而且原消息没被标记。
- **历史回填**：`ListMsgResponse.edit_timestamp` 根本没被读，已编辑的历史消息
  在 Matrix 里显示不出"已编辑"。

现在的做法：

**原始事件是唯一载体。** `Event.EditedTS` 记下编辑时刻，内容直接落在原事件上 ——
这样不管客户端拉不拉关系，看到的都是最新文本。`Event.EditEventID()` 派生
`<原 event id>_edit`，重启后仍然稳定。

**`/sync` 用 `unsigned.m.relations` 声明"这条被编辑过"：**

```json
"unsigned": {
  "m.relations": {
    "m.replace": { "event_id": "$yh_…_edit", "origin_server_ts": …, "sender": "@yh_…" }
  }
}
```

这是客户端画"已编辑"标记、以及决定**要不要去查 `/relations`** 的依据。

**`/relations` 不再恒空。** Element X 对每个置顶项都会请求一次（日志里那几条
`GET /rooms/…/relations/$yh_board_…?recurse=true`），旧实现无条件返回 `chunk: []`。
对被编辑过的消息这就错了：聚合说"有替换版本"，客户端来取却什么都拿不到，于是继续
显示旧文本。现在 `relType=m.replace` 会返回一条合成的替换事件：

- `content.m.new_content` 是新内容（云湖只保留最终文本，所以直接取原事件的内容）；
- `content.body` 是 `* 新文本` 兜底串；
- `content.m.relates_to.event_id` 指回原事件；
- `next_batch` 是**空字符串**（不是 `null` —— Element X 按 `String` 解析，`null` 会让
  整个响应解析失败并进入离线重试循环）。

未编辑的消息仍返回空 `chunk`，行为不变。

**Matrix → 云湖：**
- 目标事件在调用上游**之前**就解析好。以前 `$nope` 这种解析不出 Yunhu msg_id 的
  `m.replace` 会被当成普通消息发出去（把 `m.replace` 信封当聊天内容），现在直接 404。
- 判断"这是不是编辑"看 `m.relates_to.rel_type`，不看"目标 id 能不能解析"。
- 本地只更新原事件（内容 + `EditedTS` + `Pos`），**不追加时间线事件**。
- 编辑撞上撤回时撤回优先（`applyEditLocked` 检查 `Recalled()`），内容不会被复活。

#### WebSocket 编辑推送字段缺失（`edit_message`）

这是最容易踩的一处：**云湖的编辑推送是个"残包"**。`PushMessage` 的注释写得很直白：

| 字段 | 编辑推送里 |
| --- | --- |
| `sender`（2） | **没有**（"发送者信息,编辑消息无此项"） |
| `chat_type`（5） | **没有**（"会话类型,编辑消息无此项"） |
| `timestamp`（8） | **没有**（"时间戳(毫秒),编辑消息无此项"） |
| `recv_id`（3） | 有，但**等于 `chat_id`**（"不知道为啥到编辑这里就和 4 一样了"） |
| `edit_time`（14） | 有，这才是编辑时间 |
| `content` | 有，但**可能不完整**（"编辑消息有缺失"） |

老代码按 `(chat_id, chat_type=0)` 找房间，所以**每次都找不到** → `ensureRoomLocked`
给每个编辑推送新建了一个 `chatType=0` 的幽灵房间 → 编辑落在幽灵房间里，用户在看的那条
消息永远不变。这就是"ws 收到编辑但没转成 Matrix 编辑"的真正原因。

现在按三级回退定位会话，和云湖官方客户端（`yhcanary`）一致：

| 顺序 | 依据 | 说明 |
| --- | --- | --- |
| 1 | `(chat_id, chat_type)` | 正常路径 |
| 2 | `chat_id` 单独 | `chat_type` 缺失时（`RoomByChatID`） |
| 3 | 按 `msg_id` 全局搜 | 连 `chat_id` 都没有时（`RoomByEventMsgID`）—— msg_id 在账号内唯一 |

官方客户端 `ChatViewModel.handleEditedMessage` 也是先按 `msgId` 在本地列表里
`indexOfFirst`，找不到才去查 API。

**还有一个官方做法值得抄：编辑推送的 content 不可信，要回查。**
`WebSocketService` 收到 `edit_message` 后，`ChatViewModel` 会立刻调
`getMessageByIdFromApi` → `POST /v1/msg/list-message-by-mid-seq`
（`msgSeq` 填 `uint64` 最大值、`unknown` 填 0、`msgCount` 填 1），拿到的完整内容
**覆盖**掉推送里的内容。

我们也这么做了（`refetchEditedMessage`）：

- 用 `ListMessagesByMidSeq` 拉完整消息（client 里新增的方法）；
- 只替换 `content` 和 `EditedTS`，**不动** `sender`、事件 ID、流位置；
- 在 `safego` 里跑，不阻塞 WebSocket 读取协程；
- 失败静默：推送已经给出内容，这只是升级。

回归测试：`internal/matrix/ws_edit_test.go`
（无 `chat_type` 时更新原消息且不建幽灵房间、群聊同样生效、连 `chat_id` 都没有时按
msg_id 找到、回查 REST 覆盖被截断的内容）。

#### "空气会话"：编辑/撤回不该创建房间

`/sync` 里多出一个空会话，来源是**编辑推送在找到目标之前就把房间建出来了**。

`ingest` 的流程原来是「定位房间 → 没有就建一个 → 再按 cmd 处理」。对
`push_message` 这是对的（新消息可以来自没见过的会话），但对**编辑和撤回**是错的：
它们是对**已存在消息**的修改，本来就不该引入新会话。于是每当云湖推来一条本端没投影过的
消息的编辑（旧消息、或历史窗口之外的消息），就凭空多出一个只有 7 条 state 事件、
一条消息都没有的房间 —— 客户端列表里那个点不开、也永远不会有内容的"空气会话"。

现在两条规则：

1. `edit_message` / `blocked_message` 只在**既有房间**里找目标，找不到就丢掉并记一条
   debug 日志，**绝不 `ensureRoomLocked`**；
2. 启动时 `purgeEmptyRooms` 清掉老版本已经留下的幽灵房间。

清理条件写得很严，免得误删真实会话 —— **同时满足**才删：

| 条件 | 为什么 |
| --- | --- |
| 没有任何非 state 事件 | 真实会话至少有消息，或被撤回的消息 |
| `Name` 为空 | 会话列表一定会给名字 |
| `ReadMarkerPos == 0` | 有已读位置说明用户打开过，那是真会话 |
| 没有看板事件 | 看板也是内容 |


回归测试：`internal/matrix/edit_test.go`（云湖编辑不进时间线、`/relations` 返回替换事件、
未编辑的消息仍为空、`/sync` 带聚合）、
`internal/matrix/edit_roundtrip_test.go`（Matrix 编辑真的打到 `edit-message`、本地原地改、
未知目标 404 且不泄漏信封、撤回优先于编辑）。

#### "已编辑"标识要一条链走通，四处都得对

Matrix 的"已编辑"标记不是原事件上的一个布尔值，它依赖**一整套机制**，缺任何一环客户端都不显示：

| 环节 | 作用 | 以前的问题 |
| --- | --- | --- |
| `unsigned.m.relations.m.replace` | 告诉客户端"有新版本" | 有 |
| 被编辑事件**重新出现在 `/sync`** | 客户端本来就在看这个房间，只收增量 | 有（`Pos` 推进了） |
| `GET /rooms/{id}/event/{edit_id}` | 客户端拿替换事件确认 | **404 —— 编辑事件从未存储** |
| `/relations?relType=m.replace` | Element X 用这个而不是上面那个 | 有（后来补的） |

第三行是本轮修掉的：`m.replace` 事件是**按需合成**的（它是原事件的纯函数），
`FindEvent` 以前只扫 timeline，所以那个 id 查不到。现在 `getEvent` 会先试
`EventByEditID`，命中就现场渲染。

**还有一个更隐蔽的问题**：编辑推送的 `content` 可能是空的（proto 明确写了
"编辑消息的会话内容和发送消息可以共用但是编辑消息有缺失"）。而 `buildContent` 对空
content 会生成 `{"msgtype":"m.text","body":""}` —— 直接盖上去就把用户还能看的消息**清空**了，
然后标记指向一个空气泡。现在 `isEmptyContent` 挡住这种情况：保留旧内容，只打标记。
回查 REST 的那条路径（`refetchEditedMessage`）同样加了守卫。

回归测试：`internal/matrix/edit_marker_test.go`
（编辑出现在增量 sync、编辑事件 id 可解析、滑动同步也带聚合、
回查不清标记、空 content 不清正文）。


云湖推的 `blocked_message` 只有 1/3/4 字段（`msg_id` / `recv_id` / `chat_id`，见
`full.proto` 的注释），没有发送者也没有内容，所以它不可能变成一条消息。投影方式：

- 追加一条 `m.room.redaction`，`redacts` 指向原事件的 `event_id`（房间版本 10 放在
  **顶层**，和 `capabilities` 里公布的默认版本一致）；
- 原事件**保留自己的 `event_id`、时间戳和流位置**，只把 `content` 清空并记下
  `recalled_by`。以前是原地清空 + `pos = NextPos()`，等于把这条消息当成**新消息**又推
  一遍，客户端就在时间线底部渲染一个空白气泡。
- 输出时给被撤回的事件补 `unsigned.redacted_because`。这样即使用户是几天后才加入、
  或者翻历史翻到这条，客户端也会渲染标准的"消息已删除"，而不是空行。

历史里带 `delete_timestamp > 0` 的消息（在别处撤回的）走同一条路：`content` 为空 +
合成的 `redacted_because`。`/redact` 和客户端发起的 `m.room.redaction` 也复用同一个
`recallEventLocked`，然后才去调云湖 `recall-msg`。

**机器人是正常的 Matrix 用户。** 云湖的 bot 推送经常**不带** `sender.chat_type`，
以前发送者和成员记录是两处独立推导的，结果消息来自 `@yhbot_<id>`、成员却是
`@yh_<id>` —— 机器人就成了"没有资料、点不开头像"的陌生人。现在两处都走
`senderUserID`：显式的 user/bot 保留；只有 `chat_type=group` 且 id 等于房间自身
chat id 时才是群；缺失时私聊沿用房间类型、群里一律当普通用户。
`senderUserID` 保证 bot 一定会拿到 `m.room.member`（带昵称和头像）。

**新建聊天：私聊进入已有会话，群聊真的建群。** `/createRoom` 的解析顺序：

1. `invite` 里有可解析的 **user/bot** id（`@yh_` / `@yhbot_`）→ 直接进入那个 1:1 会话。
   私聊和 bot 会话用对方 id 就能寻址，所以本地可以凭空把房间建出来，**一次上游请求都不发**。
2. `invite` 里是 **群** id（`@yhgrp_`）→ 只有该群已在会话列表里才进入；不在就 `403`
   并说明"请先在云湖客户端加入它"。点群名进来的意思是"进入某个群"，不是"新建群"，
   给一个不存在的群凭空投影房间只会让用户看到一个自己其实不在的空房间。
3. 否则拿 `name` / `room_alias_name` 去匹配已导入的房间名（先精确、再前缀），最后试 `topic`
   —— 命中就进已有会话。
4. 都不匹配 → **调 `/v1/group/create-group` 真的建一个群**。

历史教训两头都踩过：

- 最早每次"新建聊天"都调 `create-group`，在云湖上堆出一堆用户没要过的空群；
- 后来干脆一律不建，于是"新建群聊"这个功能直接不可达。

现在按请求的**语义**分流：给了邀请对象 = 进入某个会话；只给了名字 = 新建一个群。

创建时能对接的都对接了：

| Matrix | 云湖 |
| --- | --- |
| `name` | `name` |
| `topic` | `introduction` |
| `initial_state` 里的 `m.room.avatar.url` | `avatar_url` |

头像是唯一需要搬运的：Matrix 给的是 `mxc://`，云湖存的是 URL，所以先把字节上传到云湖的
七牛桶（`ResolveForYunhu`），再拼成 URL。上传失败**不影响建群** —— 没头像比建不出群好得多。

没名字的请求直接 `400` 并说明原因，而不是让上游报一个看不懂的错。

**群简介双向同步（`m.room.topic` ⇄ `introduction`）。**

Matrix 叫 `topic`（客户端显示成"简介/描述"），云湖叫 `introduction`，语义一一对应：

| 方向 | 路径 |
| --- | --- |
| 云湖 → Matrix | `group/info` 的 `introduction` → `m.room.topic` 状态事件 |
| Matrix → 云湖 | `PUT /state/m.room.topic` → `EditGroupRequest.Introduction` |

以前**只有 Matrix → 云湖**这一半：改简介能同步上去，但云湖那边本来就有的简介从来不会
出现在 Matrix 里，于是每个群的"简介"都是空的。现在 `refreshMemberCounts` 顺势把
`introduction` 也读回来（和人数、角色同一次请求，不多花一个往返）。

**这里有个容易漏的缓存坑。** `refreshMemberCounts` 靠 TTL 跳过"已经新鲜"的房间，而
新鲜度的判据原本只有人数和角色 —— 于是**已经有人数和角色的老房间永远不会被再问一次**，
它的简介就一直是空。现在加了 `Room.TopicTS`：

| 字段 | 含义 |
| --- | --- |
| `TopicTS` | 简介最后一次向上游确认的时间 |

跳过条件是三个人都新鲜，缺一个就重拉一次。而 `TopicTS` 记录的是**"问过了"**，不是
"拿到非空简介" —— 因为"这个群没有简介"是一个正当的答案，靠"简介为空就重拉"会让没有简介
的群每次重连都打一次 `group/info`。

发送时只填变化的那个字段：改简介就只发 `introduction`、改名字就只发 `name` ——
两个都填会把另一个清空。

群头像的 Matrix → 云湖 方向也补上了（`m.room.avatar` → `EditGroupRequest.AvatarUrl`），
同样需要先上传。

**群人数来自 `group/info` 的 `headcount`。** 本地只认识"说过话的人"，一个 500 人的群
可能只有 6 个成员记录，直接 `len(room.Members)` 会报"6 人"。现在
`refreshMemberCounts` 用 8 个并发去拉 `/v1/group/info`，写进 `Room.MemberCount`
（30 分钟内不重复拉），`/sync` 的 `m.joined_member_count` 和滑动同步的
`joined_count` 都读它；拿不到才退回本地计数。人数变化会推进 `MemberCountPos`，
`/sync` 因此会把"只有人数变了"的房间也带上，否则客户端会一直显示旧数字。

媒体：`/media/v3/upload`、`download`、`thumbnail`、`preview_url`、`config`

**两套媒体路由都注册了**，同一批 handler：

| 路由 | 谁在用 | 说明 |
| --- | --- | --- |
| `/_matrix/media/{ver}/download/...` | 老客户端、Element Web 的 `<img>` | MSC3916 之前的免鉴权形式，保留兼容 |
| `/_matrix/client/{ver}/media/download/...` | Element X、matrix-rust-sdk | MSC3916 的鉴权形式，**新客户端只认这个** |

`{ver}` 是任意单段，所以 `/v1`、`/v3`、`/r0`、`unstable` 都能命中。
**曾经踩过的坑**：只注册了 `/_matrix/media/...` 一族，Element X 请求
`/_matrix/client/v1/media/thumbnail/...` 时落到兜底路由，日志里是
`status=404 dur_ms=0`（`dur_ms=0` 就说明压根没进 handler），所有头像和图片全裂。
`internal/matrix/media_route_test.go` 盯着这两族路由和 `M_UNRECOGNIZED` 的区别。

媒体元数据（`info`）也有两个必须守住的点，否则客户端会显示 **0 B**：

- **绝不输出 `"size": 0`**。云湖对图片、语音、视频都不给大小（只有文件消息有
  `file_size`），客户端把 `size: 0` 渲染成"0 B"空文件。拿不到就**不写这个 key**；
  已经反代过的（磁盘缓存里有）会补上真实大小。
- **补 `mimetype`**。云湖也不给，客户端靠它决定怎么渲染/能不能播。从 URL 后缀推导。
- 下载走 `http.ServeContent`，支持 `Range`。手写 `Content-Length` 时客户端发
  `Range: bytes=N-` 会拿到从 0 开始的整份数据，音视频播放器seek 不了就显示 0 B。

**所有媒体都走本地反代**：云湖的头像、房间头像、成员头像、消息里的图片/视频/语音/文件，
一律转成 `mxc://<本机>/yh_<base64url(原始引用)>`，由本服务端的 download 路由
**代理字节流**（不是 302 跳转），首次取回后落盘缓存。
客户端因此只跟一个 origin 说话，不会直连七牛 CDN，也不会有混合内容/跨域问题。

**反代必须带 Referer，否则云湖 CDN 一律 403。** 这条写在云湖 API 文档
`src/api/README.md` 里：

> 云湖数据床地址需要请求头加上 `Referer: http://myapp.jwznb.com` 才可正常获取内容，否则会403.

细节（踩过的坑）：

- 是 **`http`**，不是 `https`；**没有结尾斜杠**。写成 `https://...` 或 `https://www.yunhu.chat/`
  都还是 403。
- 所有 `*.jwznb.com` 主机都要（`chat-img` / `chat-img2` / `chat-img3` / `chat-video1` /
  `chat-audio1` / `chat-file` / `chat-storage1` / `chat-file-oss`），按父域匹配。
- 403 的响应头里有 `X-Error-Detail`：`RHIE` = Referer 防盗链没过，`WTR` = 签名/时间戳缺失。
  本服务端会把它带进错误信息，日志里能直接看出是防盗链还是文件没了。
- `chat-storage1.jwznb.com` 走签名校验（无 Referer 限制），`chat-file-oss` 无限制，
  但统一加 Referer 不影响它们。

代码在 `internal/yunhu/client.go` 的 `Fetch`：`YunhuMediaReferer` 常量 +
`isYunhuStorageHost`，回归测试 `internal/yunhu/fetch_test.go`。

**裸 key 还要按文档分流到不同的 CDN 主机。** 云湖并不是所有媒体都给绝对 URL：表情消息
（`ContentType_sticker`）和 `/v1/sticker/*` 返回的是 `sticker/<md5>.gif` 这种裸 key，
文档原话是"表情包 URL, 需要前面加上 `https://chat-img.jwznb.com/`"。分流表
（`internal/yunhu/media.go` 的 `MediaURL`）：

| key 前缀 | 主机 |
| --- | --- |
| `sticker/` `expression/` `defalut-avatars/` `image/` `avatar/`，以及无前缀的（`background9.webp`） | `https://chat-img.jwznb.com/` |
| `audio/` `voice/` | `https://chat-audio1.jwznb.com/` |
| `video/` | `https://chat-video1.jwznb.com/` |
| `file/` `knowledge/` | `https://chat-file.jwznb.com/` |

绝对 URL 一律原样透传，只有裸 key 才分流。`yunhu.media_base` 现在**默认留空**，
填了才会把所有裸 key 强推到一个前缀（只有进程内 mock 上游需要）。

**曾经踩过的坑**：这里原本只有一个 `media_base`，默认值是 `https://qiniu.jwzhd.com/`
（七牛源站）。该域名后来停止解析，于是所有表情都 502：

```
msg="remote media fetch failed" ref=sticker/85ade3342b00c98361d3322347758104.gif
err="Get \"https://qiniu.jwzhd.com/sticker/...gif\": dial tcp: lookup qiniu.jwzhd.com: no such host"
GET /_matrix/client/v1/media/download/localhost/yh_c3RpY2tlci84... status=502
```

同一个 `sticker/…gif` 换成 `https://chat-img.jwznb.com/sticker/…gif` 并带上 Referer 就是
`200 image/gif`。回归测试 `internal/yunhu/media_test.go`（分流 + Referer）和
`internal/matrix/media_route_test.go`（`TestRemoteStickerKeyServedFromImageCDN`，含
`remoteURL` / 缓存 / 下载路由三者一致）。

### 上传：bucket 决定上传域名

Matrix 客户端发的图片/文件必须先落到云湖的七牛空间，消息里只带**对象 key**。云湖分四个 bucket，
各自在七牛的不同区域，**上传域名要按 bucket 查**（文档里的 `misc.md`）：

```
GET https://api.qiniu.com/v4/query?ak=<token 的第一段>&bucket=<bucket>
→ {"hosts":[{"up":{"domains":["upload-z2.qiniup.com"]}}]}
```

| 媒体 | bucket | key 形态 |
| --- | --- | --- |
| 图片 / 表情 | `chat68` | `<md5>.<ext>` |
| 文件 | `chat68-file` | `disk/<md5>.<ext>` |
| 视频 | `chat68-video` | `<md5>.<ext>` |
| 语音 | `chat68-audio` | `<md5>.<ext>` |

`<ext>` 必须有：接收端靠后缀选渲染器，没后缀的 key 会显示成一个没有名字的附件。

**曾经踩过的坑**：代码写死 `https://upload.qiniup.com`（七牛的通用入口），对别的区域的 bucket
七牛边缘**直接断连**，日志只有一句：

```
level=WARN msg="qiniu upload failed, falling back to public url" err="Post \"https://upload.qiniup.com\": EOF"
PUT /_matrix/client/v3/rooms/…/send/m.room.message/… status=400
```

`EOF` 看着像网络问题，其实是域名选错。现在按 bucket 查真实域名（缓存 1 小时），候选顺序是
`yunhu.upload_host`（只给 mock 用，默认留空）→ 查到的域名 → `upload-z2.qiniup.com`，
某个候选断连就换下一个，错误里带上每个 host 的失败原因。

发送时图片同时填 `content.image`（9，云湖客户端走这个，值就是 key）和 `content.image_url`
（3，文档要求填 URL，这里给 `https://chat-img.jwznb.com/<key>`）：服务端读哪个都能出图。

回归测试 `internal/yunhu/upload_test.go`（发现的域名优先、断连自动换 host、key 命名、bucket 映射）。

### 文件/图片/视频的备注（`body` 与 `filename` 不是一回事）

Matrix 的媒体消息有**两个**文本字段，云湖只有**一个**：

| Matrix | 含义 | 云湖 |
| --- | --- | --- |
| `filename` | 真实文件名 | `file_name` |
| `body` | 人读的描述（客户端显示成备注/说明） | **没有对应字段** |

所以 `{"body":"464635","filename":"DevCheck.apk"}` 里的 "464635" 是**备注**，
`{"body":"sjcjfjdg","filename":"Screenshot_….png"}` 里的 "sjcjfjdg" 同理。
老代码把 `body` 当作文件名兜底：

```go
name := orDefault(asString(content["filename"]), orDefault(body, "file.bin"))
```

于是备注要么被丢掉，要么（当 `filename` 缺失时）**文件被改名成备注** —— 截图、录屏、
APK 全都变成了发送者随手打的那几个字母。

现在的处理：

1. `matrixFileName` 只认 `filename`；只有当 `body` **看起来像文件名**（带扩展名）且
   `filename` 缺省时才用它；
2. 有备注/说明时拆成**两条云湖消息**，顺序是 **先媒体、后备注**；
3. 本地也把备注投影成一条独立事件，否则发送者自己的时间线里只有附件、看不到自己打的字。

**`m.video` 也不拆** —— 这条以前写反了，代价是你的备注看不见。

```
// MessageContentView.kt
10 -> {
    content.videoUrl?.let { videoUrl ->
        VideoMessageView(videoUrl = videoUrl, ...)
    }
}
```

云湖客户端对 `content_type = 10` **只渲染播放器，完全不画 `content.text`**。
所以把备注写进视频消息的 `text` 等于丢掉它 —— 这就是"视频能发了但备注没了"。

现在视频和其他媒体一样：**视频 + 独立文本消息（备注）**，顺序是先视频后备注。

### 发送视频：`content_type` 必须是 10，还要带 `Media`

**这是"视频发不出去 / 解析成空消息"的真正原因，两个字段都缺。**

`yhchatAPI` 文档的 `ContentType` 枚举里**没有视频这个值**（1 text / 2 image / 4 file /
5 form / 7 sticker / 8 html / 9 tip / 11 audio / 13 call / 14 a2ui），所以早期的实现只能
把视频当 `text` 发。云湖服务端收下了，但**客户端不认**：它按 `content_type` 选渲染器，
`text` 就是文本气泡 —— 于是视频变成一条 `{"body":"","msgtype":"m.text"}` 的空消息。

而且光有类型还不够。云湖官方 Android 客户端（`yhcanary` 的 `MessageRepository`）发媒体时
还会带 `SendMsgRequest` 的**字段 9**：

```protobuf
Media media = 9;
message Media {
  string file_key    = 1; // 对象 key
  string file_hash   = 2; // MD5
  string file_type   = 3; // MIME，video/mp4
  int64  image_height = 5;
  int64  image_width  = 6;
  int64  file_size    = 7;
  string file_key2    = 8; // 和 file_key 相同，不写会报错
  string file_suffix  = 9; // mp4
}
```

`yhchatAPI` 的 proto 把字段 9 整段注释成"其实没啥用,不要看这个!!!!!"，照它实现就永远
发不出能播的视频 —— 接收端拿不到 MIME 和尺寸，不知道这是个视频文件。

现在两处都补齐：

| 项目 | 值 |
| --- | --- |
| `ContentType` | 补 `video = 10`、`post = 6` |
| `SendMsgRequest.media` | 补 `Media` 子消息，图片/视频/语音/文件都填 |
| `media.file_key2` | 与 `file_key` 相同 |
| `media.file_hash` | 对象 key 的 base name（本服务端上传时它就是 MD5） |
| `media.file_suffix` | 从 key 推导，视频显式给 `mp4` |

绝对 URL（上传回退到 `public_url` 时会出现）**不填 media** —— `file_key` 必须是对象 key，
填 URL 会让云湖拼出一条无效路径。

云湖 → Matrix 反过来：`video_url` 非空**或** `content_type == 10` 都转成 `m.video`
（老客户端转发的是 `text` + `video_url`，两种形状都要认）。

回归测试：`internal/matrix/media_attachment_test.go`、
`internal/matrix/yunhu_video_test.go`。

### 云湖 → Matrix：视频

云湖**有一条**视频内容类型（10），但也有老消息把 `video_url` 挂在文本消息上。转 Matrix 时要点：

| 判断 | 依据 |
| --- | --- |
| 是不是视频 | **`video_url` 非空**，或 `content_type == 10` |

字段映射（`MsgContent` → `m.video`）：

| 云湖 | Matrix `info` | 换算 |
| --- | --- | --- |
| `video_url`(19) | `url` | 转成 `mxc://` 走本地反代 |
| `video_time`(20) | `info.duration` | **秒 → 毫秒** |
| `width`(33) / `height`(34) | `info.w` / `info.h` | 0 时**不写这个 key** |
| `file_size`(18) | `info.size` | 原样 |
| `text`(1) | `body` | 有就用它当字幕 |
| `file_name`(4) | `body` 的兜底 | 没字幕时才用文件名 |

`body` 的顺序是 **text → file_name → 从 url 推导**：Matrix 把 `body` 当字幕显示，
空字符串会渲染成一个空气泡，所以最后一定要有个兜底。

**顺带修了一个一直存在的隐藏 bug**：`video_time` 和 `audio_time` 以前**永远是 0**。
原因是 `c.GetVideoTime() * 1000` 的结果类型是 `int32`，塞进 `map[string]any` 之后
`asInt` 不认识 `int32`，读回来就是 0 —— 所有云湖视频和语音在 Matrix 里都显示成 0 秒。
现在 `asInt`/`asInt64` 都接受 `int32`。

回归测试：`internal/matrix/yunhu_video_test.go`
（视频转成 `m.video`、`text` 变字幕、`content_type` 不是 text 也认、0 尺寸不写、
时长按毫秒、语音时长同样修好）。

### `m.info` 尽量都填进云湖

Matrix 把描述信息全放在 `info` 里，云湖的 `MsgContent` 有对应字段但**单位不同**：

| Matrix `info` | 云湖字段 | 换算 |
| --- | --- | --- |
| `w` / `h` | `width`(33) / `height`(34) | 原样 |
| `size` | `file_size`(18) | 原样（**所有**媒体类型都填，不只文件） |
| `duration` | `video_time`(20) / `audio_time`(22) | **毫秒 → 秒**（四舍五入） |
| `mimetype` | — | 云湖没有这个字段，丢弃 |

以前只填了尺寸和文件大小，而且只有图片填了 `w`/`h`；视频/音频的时长按整数除法截断
（16.3 秒变成 16 而不是四舍五入）。现在统一走 `parseMediaInfo`。

云湖**没有**的：`thumbnail_url` / `thumbnail_info`（缩略图）、`xyz.amorgan.blurhash`
（模糊预览）、`mimetype`。这些只能在云湖自己生成，服务端没有对应字段可填。

回归测试：`internal/matrix/file_note_test.go`
（文件/图片带备注拆两条且顺序正确、视频不拆且备注进 `text`、无备注只发一条、
尺寸/大小/时长都送达、备注本地也有事件）。

加密：`/keys/upload`、`/keys/query`、`/keys/claim`、`/keys/changes`、
`/keys/device_signing/upload`、`/keys/signatures/upload`、`/room_keys/*`、`/account_data`（见第 7 节）

其它：`/sendToDevice/{type}/{txn}`、`/voip/turnServer`、`/publicRooms`、`/user_directory/search`、
`/search`、`/presence` 等按规范返回空结果，避免客户端报错。

### 会话归属：`chat_id` 不总是会话本身

云湖的推送里 `chat_id` / `chat_type` / `recv_id` 的含义**取决于会话类型**，照字面取
`chat_id` 会错。官方客户端（`ConversationViewModel`）的规则是：

```kotlin
val isPrivateChat = message.chatId == message.recvId
val targetChatId = if (isPrivateChat) message.sender.chatId else message.chatId
val targetChatType = if (isPrivateChat) message.sender.chatType else message.chatType
```

**私聊推送里 `chat_id` 和 `recv_id` 都是自己的 id**，真正的会话是**对方**。
直接拿 `chat_id` 当会话，就会在 `!yh-user-<自己的 id>` 下凭空建一个房间 ——
这就是"ws 收到机器人的消息，Matrix 单独开了个空聊天"。

`conversationOf` 现在照这个规则解析。两个要点：

1. **`chat_id == recv_id` 单独不足以判定私聊** —— **群聊消息也是 `recv_id == chat_id`**
   （群自己是接收者）。真正的判据是 `chat_type`：群推送说 group，私聊推送说 user 或 bot。
   漏了这个判断，所有群消息都会被错投到发送者的私聊里。
2. `chat_type` 缺失时**先推断再判定**：编辑和机器人推送经常不带类型，拿"已知房间的类型"
   补齐，再走上面的规则。

`IsDirect` 也算错了：以前只有 `ChatTypeUser` 算私聊，**bot 会话被当成群聊**。
`IsDirect` 驱动 `is_dm`（私聊布局）和 `heroes`（客户端用来给直连房间起名的参与者列表），
所以机器人会话在 Matrix 里显示成群聊、没有头像、没有名字。现在 user 和 bot 都算直连。

回归测试：`internal/matrix/conversation_kind_test.go`
（bot 会话是直连且有 heroes、机器人私聊不建幽灵房间、用户私聊同样、群消息仍归群、
`conversationOf` 三种形态直接断言）。

### 改群信息要合并，不能只发变化字段

`EditGroupRequest` 是**整份写**，不是 patch：零值字段意味着"把它清空"。

所以"改简介只发 `introduction`"会把群名清掉，"改名字只发 `name`"会把简介清掉 ——
这就是"改了描述之后群名没了"的原因。

现在先从 `group/info` 读出当前完整记录，只替换真正变化的那一个字段，再整份提交：

| Matrix 事件 | 合并后提交 |
| --- | --- |
| `m.room.name` | `name` 替换，其余保持 |
| `m.room.topic` | `introduction` 替换，其余保持 |
| `m.room.avatar` | `avatar_url` 替换（先上传拿 URL），其余保持 |

代价是每次改信息多一次 `group/info` —— 但总比悄悄清空其它字段好。拿不到当前记录时
**直接放弃**这次同步（记 warn），而不是发出一个会把资料抹掉的半成品。

### 群成员权限（`m.room.power_levels` ⇄ 云湖管理员）

客户端在"成员 → 权限"面板里改人，发的是一个 `PUT /state/m.room.power_levels/`，
body 里带整张 `users` 映射：

```json
{"users":{"@yh_8516939:localhost":100,"@yh_2037619:localhost":50,"@yh_6002836:localhost":0}}
```

等级的含义两边一致，只有中间那档数字不同：

| 角色 | Matrix | 云湖 `permission_level` | 云端接口 |
| --- | --- | --- | --- |
| 群主 | 100 | 100 | 不可改 |
| 管理员 | 50 | **2** | `userLevel: 2` |
| 普通成员 | 0 | 0 | `userLevel: 0` |

**云湖的这个接口不在公开文档里。** `POST /v1/group/manage-setting`，
`{"groupId","userId","userLevel"}` —— 只有官方 Android 客户端
（`GroupRepository.setMemberRole`）在用。文档里翻不到，只能从客户端代码里找。

同步逻辑（`syncGroupRolesFromPowerLevels`）有三个要点：

1. **当前状态从 `group/info` 取，不是从成员列表取。** 这正是你指出的问题：
   `list-member` 每页 100 条，管理员可能落在后面的页里；拿被截断的列表做对比，
   会把没出现在第一页的管理员**全部降级**。`group/info` 的 `owner` + `admin`
   才是权威且完整的。
2. **群主永不触碰。** 云湖拒绝改群主，而且客户端提交的 `users` 有时干脆不含群主 ——
   把"不在请求里"读成"降级群主"会直接失败。
3. **只发真正变化的条目。** Element 打开权限面板就会重提交整张表，把 30 个用户
   逐个 POST 一遍纯属浪费。

比较按**云湖的数字**做（Matrix 50 vs 云湖 2），不是直接比 50 和 2 —— 否则每一次
提交都会被判成"有变化"。

回归测试：`internal/matrix/power_levels_test.go`
（提升/降级能到云端、无变化不发请求、群主不被碰、
**用 `group/info` 而不是花名册**、1:1 房间不触发）。



**Matrix 没有"房间静音"这个开关。** 静音就是那条房间级推送规则的状态，但**客户端用的规则种类
不止一种**：

```
PUT /pushrules/global/room/<room_id>                                 {"actions": []}   ← 静音
PUT /pushrules/global/override/<room_id>
    {"actions": [], "conditions":[{"kind":"event_match","key":"room_id","pattern":"<room_id>"}]}
```

**Element X 用的是 `override`，Element Web 用 `room`。** 两者都要支持，而且读回来时
**两种都报**：

- `override` 能带 `event_match` 条件，客户端按它过滤；
- `room` 按房间 id 索引。

只支持 `room` 的后果：Element X 每次启动都会重新应用自己的静音列表，于是你这个房间
（`!yh-group-105836869`）每次都被重放一次 PUT，然后拿到 `M_INVALID_PARAM`。
只报 `room` 的后果：客户端读不到自己的静音，就认为没静音过 —— 又是一个重放的理由。

以前 `GET /pushrules` 恒返回空列表、`GET /pushrules/.../room/...` 恒 404，而且
**PUT 和 DELETE 路由压根没注册** —— 客户端点静音直接落到兜底 404，什么都不发生。

云湖那边对应的是会话免打扰：

```
POST /v1/friend/no-notify   {"chatId": "979377289", "noNotify": 0|1}
```

| 方向 | 路径 |
| --- | --- |
| 云湖 → Matrix | 会话列表的 `do_not_disturb` → `Room.Muted`（同时出现在 `room` 和 `override`） |
| Matrix → 云湖 | `PUT/DELETE /pushrules/global/{room|override}/<id>` → `/v1/friend/no-notify` |

写 `override` 时**优先用 `conditions` 里的 `pattern` 当目标房间**，没有才退回 rule id ——
那才是客户端过滤时用的值。

规则集是**从 `Room.Muted` 推导**的，不是单独存一份 —— 两个来源不可能打架。
只有静音的房间才出现在规则里：规则不存在就等于"会通知"，给每个房间都发一条会把响应撑爆。

`actions` 的判定只看有没有 `notify`：`[]`、`["dont_notify"]` 都算静音，
`["notify"]` 算不静音。

**一个关于假服务器的教训。** `no-notify` 的响应格式我一开始判断错了：假服务器返回
protobuf，于是"验证"通过了，真实接口却返回 JSON，线上报
`proto: cannot parse invalid wire-format data`。现在假服务器一律按真实格式返回 JSON，
并且 `SetGroupMemberLevel` 干脆**不解析响应体**（官方客户端也只检查 HTTP 状态码，
格式未公开，猜错一次已经付过代价）。

回归测试：`internal/matrix/mute_test.go`
（`override` 和 `room` 都能静音/取消、读回来两种都报且带条件、云湖静音 → 规则存在、
未静音 → 没有规则、未知房间 404）。

路径前缀 `/v1`、`/r0`、`/v3` 全部可用（同一个路由表）。

### 发现文档（`/.well-known/*`）

| 路径 | 作用 |
| --- | --- |
| `/.well-known/matrix/client` | `m.homeserver.base_url` + `org.matrix.msc3575.proxy` |
| `/.well-known/matrix/server` | `m.server`（不做联邦，只为兼容探测） |
| `/.well-known/matrix/support` | 服务器支持信息（Matrix v1.10 / MSC1929） |

`support` 这个文档客户端会主动来问：Element Web 拿它渲染设置里的"服务器管理员"，
**Element X 在"连不上服务器"那个页面直接显示管理员联系方式** —— 自建网桥最需要它的时候
恰好就是连不上的时候，所以这个端点不能 404。

文档结构（`contacts` 与 `support_page` 至少要有一个；每个 contact 的 `role` 必填，
`matrix_id` 和 `email_address` 至少要有一个）：

```json
{
  "contacts": [
    { "role": "m.role.admin", "matrix_id": "@yh_10001:localhost", "email_address": "admin@example.com" }
  ],
  "support_page": "https://example.com/help"
}
```

`role` 只认 `m.role.admin`（兜底）和 `m.role.security`（安全事件），也可以用自己的
命名空间值。

**默认就能用**：不写 `server.support` 时，服务端把本地第一个账号（按 user id 排序，
保证稳定）当作 `m.role.admin` 发布 —— 单用户网桥里账号主人就是管理员。
想自定义或者想彻底不公开，看 `config.example.yaml` 里的 `server.support` 段：
`contacts: []` 是显式关闭（此时端点返回 404，规范定义 404 = "本服务器不公开支持信息"）。

`support_page` 也可以用 `YHMATRIX_SERVER_SUPPORT_PAGE` 覆盖。

两个 well-known 都无条件带 `Access-Control-Allow-Origin: *`：规范对发现文档是
"SHOULD offer CORS headers"，而浏览器里的 Web 客户端是跨域 fetch 的。

回归测试：`internal/matrix/support_test.go`。

## 9. 边界与已知限制

- **没有端到端加密**：云湖不提供 E2EE，所以任何房间都不会出现 `m.room.encryption`，
  消息始终是明文。但 `/keys/*` 与 `/account_data` 现在会**真正存取**客户端上传的公钥、
  签名和 secret storage —— 否则 E2EE 优先的客户端（Element X）连自己的设备都看不见，
  会永久卡在身份确认页（见第 7 节）。服务端仍然不持有任何私钥。
- **不做联邦**：单机服务端，只服务本域名下的账号。
- **不能邀请**：云湖没有"通过 Matrix 邀请进群"的等价接口，`/invite` 返回 403 并提示去云湖客户端操作。
- **typing 只在本地可见**：云湖没有 typing 接口（只有草稿同步），所以不冒充。
- **缩略图不缩放**：`/thumbnail` 直接返回原图，避免引入图像处理依赖；客户端会自己缩放。
- **群成员列表是完整的**：群聊的 `/members` / `/joined_members` 会去调云湖
  `POST /v1/group/list-member` 翻页拉全量（5 分钟缓存），不是"本地见过的成员"。
  单聊没有花名册，仍然只用本地状态。群人数另外取 `group/info` 的 `headcount`
  （见第 8 节），因为 `list-member` 会被"隐藏群成员"之类的设置过滤。

  **这个缓存有两条容易踩的边**（都修过）：

  1. **失败也要起 TTL**。以前拉取失败直接 return，`GroupMembersTS` 还是 0，于是
     `rosterStaleLocked` 恒为 true —— 客户端每请求一次 `/members` 就打一次上游。
     邀请联系人面板恰好会连续打这个接口，所以表现为"一直无限请求"。
     失败仍然算"问过了"，5 分钟内不重试。
  2. **并发只允许一次**。`/members` 是同步的（要等翻页完才响应），没有在途标记时
     每个并发请求都会各自翻一遍全量。现在 `RosterFetching` 挡住后续请求。

  回归测试：`internal/matrix/members_cache_test.go`。

- **历史深度**：内存里每房间保留 `max_events_per_room` 条。**往上翻不会到头**：
  本地窗口翻完后 `/messages` 会带着最老一条的 `msg_id` 去问云湖 `POST /v1/msg/list-message`，
  把更早的消息接在同一页里返回（见第 6 节"翻页令牌"）。
- **滑动同步的排序固定为"最近活跃"**：`sort` / `bump_event_types` 不生效（投影里没有
  通知等级、标签这些维度），窗口按 `LastActivityTS` 排序。
- **连接状态在内存里**：滑动同步按 `(user, device, conn_id)` 记住已经发过哪些房间，
  进程重启后这张表清空，客户端会收到一次全量重发（幂等，只是多传一遍）。

## 10. 部署

反向代理（Caddy 最省事）：

```
matrix.example.com {
    reverse_proxy 127.0.0.1:8008
}
```

客户端只需要填 `https://matrix.example.com`。如果客户端要求 well-known，
服务端已经在 `/.well-known/matrix/client` 返回 `m.homeserver.base_url`。

**`server.public_url` 是这里唯一的坑，默认是注释掉的。** 一旦填了，well-known 就会
把它当成 `base_url` 发出去，客户端登录、媒体下载全部改打这个地址。填错的表现是：

- 客户端报「无法访问账号提供者」/ "cannot reach your account provider"
- 服务端日志里却只有一串 `GET /.well-known/matrix/client status=200 dur_ms=0`，
  **后面再没有别的请求** —— 因为客户端被指到别的地址去了
- 媒体显示 0 B / 加载不出来

留空时地址从每个请求的 `Host` 推导，局域网 IP、localhost、反向代理都能自动正确，
所以**没有反向代理就不要填**。现在启动时会检查：`public_url` 的主机和 `server.name`
不一致就打 WARN，如果还是 `example.com` 那种占位值会直接点名。

Docker（完整的多方式安装说明见 [docs/INSTALL.md](docs/INSTALL.md)）：

```bash
# ① 直接拉预构建镜像（最省事，tag 发布时由 workflow 自动构建）
docker run -d --name yhmatrix --restart unless-stopped -p 8008:8008 \
  -e YHMATRIX_SERVER_NAME=192.168.1.12 \
  -v yhmatrix-data:/app/data \
  ghcr.io/kauid323/yunhuuser2matrix:latest

# ② 用仓库根目录下的 compose.yaml
docker compose up -d

# ③ 从源码本地构建
docker build -t yhmatrix:local .
```

镜像里的二进制放在 `/app`（和 `config.yaml`、`data/` 同级），因为相对路径一律相对可执行文件目录解析；
容器以 UID 10001 运行，用 `-v $PWD/data:/app/data` 绑定挂载时要先 `chown 10001:10001 data`。
配置项全部可用 `YHMATRIX_*` 环境变量覆盖（例如 `YHMATRIX_SERVER_NAME`），
不挂 `config.yaml` 时首次启动会从 `config.example.yaml` 生成一份到 `/app/config.yaml`。
不跑容器也可以直接下载 Release 里的各平台二进制。

数据都在 `data/` 下：`accounts/*.json`（账号、设备、房间、事件）、`media/`（上传）、
`cache/`（代理缓存）。备份这个目录即可。

## 11. 代码结构

```
cmd/yhmatrix        # 服务端入口（含 -mock 模式）
cmd/yhprobe         # 直连云湖的探针工具
internal/config     # YAML + 环境变量配置
internal/yunhu      # 云湖客户端：REST、protobuf/JSON 协商、WebSocket、假服务端
internal/yunhu/pb   # 由 proto/yh.proto 生成的 protobuf 绑定
internal/matrix     # Matrix C-S API：路由、鉴权、sync、滑动同步、房间、媒体、E2EE、转换层
internal/store      # 账号持久化（每账号一个 JSON，去抖刷盘）
internal/model      # 共享数据结构
internal/hub        # /sync 长轮询的唤醒总线
internal/webdist    # 下载并解压 Element Web（-fetch-web）
proto/yh.proto      # 云湖协议定义（来自 yhchatAPI 文档）
```

重新生成 protobuf：

```bash
protoc -I proto --go_out=. --go_opt=module=github.com/yunhu/yhmatrix proto/yh.proto
```

## 12. 测试

```bash
go test ./...     # 路由、ID 映射、转换层、sync 组装、鉴权
go vet ./...
```

新增的回归测试盯住这一轮修的行为：

| 文件 | 覆盖 |
| --- | --- |
| `internal/matrix/recall_test.go` | 撤回变成 `m.room.redaction`、原事件不挪位置、`redacted_because`、机器人发送者 |
| `internal/matrix/conversation_test.go` | `/createRoom` 只进已有会话（`create-group` 一次都没被调）、群人数来自 `group/info` |
| `internal/matrix/history_test.go` | `/messages` 翻进云湖历史、令牌两族混用 |
| `internal/matrix/media_route_test.go` | 两套媒体路由、`Range`、`info` 不出 `size: 0`、表情裸 key 落到 `chat-img` |
| `internal/yunhu/media_test.go` | 裸 key 按前缀分流到图片/音频/视频/文件主机、分流后仍带 Referer |
| `internal/matrix/login_test.go` | 四种登录方式、Matrix ID 回登、`m.id.thirdparty`（email/msisdn）标识 |
| `internal/matrix/login_thirdparty_test.go` | 重放日志里那条 FluffyChat 请求；未知邮箱不许登入 |
| `internal/matrix/roles_test.go` | 群聊不伪造群主、`group/info` 驱动 power levels、老房间自动修复、滑动同步必带 power_levels |
| `internal/yunhu/upload_test.go` | 上传域名按 bucket 查、断连换 host、key 命名、bucket 映射 |
| `internal/matrix/threads_test.go` | `/threads` 路由存在（空列表 + `next_batch: null`），不是 `M_UNRECOGNIZED` |
| `internal/matrix/context_test.go` | `/context` 路由存在、看板事件可解析、`events_before` 倒序、数组不为 `null` |
| `internal/matrix/board_test.go` | 多看板全部置顶、某个机器人改版只换它自己的 pin、上游删掉的看板要取消置顶 |
| `internal/matrix/edit_test.go` | 云湖编辑不进时间线、`/relations` 返回 m.replace、`/sync` 带编辑聚合 |
| `internal/matrix/edit_roundtrip_test.go` | Matrix 编辑打到 `edit-message`、本地原地改、未知目标 404、撤回优先 |
| `internal/matrix/edit_marker_test.go` | 编辑出现在增量 sync、编辑事件 id 可解析、滑动同步带聚合、空 content 不清正文 |
| `internal/matrix/ws_edit_test.go` | WS 编辑推送缺 `chat_type`/`chat_id` 仍能命中、编辑/撤回不为未知消息建房间、启动清理幽灵房间 |
| `internal/matrix/mention_test.go` | 云湖 `@[名字]` ⇄ Matrix `m.mentions`、bot 与用户区分、裸名不误伤长词 |
| `internal/matrix/reply_test.go` | 引用带 `quote_msg_text` 且剥掉 `>` 块、缺 `chat_type` 时推断类型、retype 不丢历史 |
| `internal/matrix/file_note_test.go` | 文件/图片带备注拆两条且顺序正确、视频不拆、尺寸/大小/时长都送达 |
| `internal/matrix/yunhu_video_test.go` | 云湖视频转 `m.video`、`text` 变字幕、时长秒→毫秒、0 尺寸不写 |
| `internal/matrix/group_topic_test.go` | `introduction` → `m.room.topic`、改简介/改名只发对应字段、不互相清空 |
| `internal/matrix/media_attachment_test.go` | 媒体带 `Media` 子消息（key/hash/type/suffix/尺寸/大小）、视频备注独立成条、空 topic 只问一次、绝对 URL 不填 media |
| `internal/matrix/mute_test.go` | `override`/`room` 两种规则都能静音、读回两种都报、云湖静音 → 规则、未静音不发规则 |
| `internal/matrix/conversation_kind_test.go` | bot 会话是直连、机器人/用户私聊不建幽灵房间、群消息仍归群 |
| `internal/matrix/power_levels_test.go` | 权限变更同步到云湖、只发变化的、群主不碰、用 `group/info` 不用花名册 |
| `internal/matrix/unread_test.go` | 未读从已读位置推导、回执清零并被推送、重连不复活、已读位置只前进、跳到第一条未读 |
| `internal/matrix/receipt_test.go` | 回执返回 `{}` 且回显 `m.receipt`、初始同步带已读位置、未知房间 404、令牌落成事件 id |
| `internal/matrix/members_cache_test.go` | 拉取失败也起 TTL（不再无限重试）、并发只发一次、花名册成员进列表 |
| `internal/matrix/backfill_gap_test.go` | 停机空洞被补齐且不重复、回填失败不标记完成、对账限流、state 事件不算"最新消息" |
| `internal/matrix/send_image_test.go` | 图片 key 走 `content.image`(9) 而不是 `image_url`(3)、文件/语音字段不漂移 |
