# RStudio ⇄ StatDataViewer 会话通道：协议与改动清单

**状态**：已实现（sdv 0.3.0 `R/bridge.R`；StatDataViewer `rstudio/rstudiobridge.{h,cpp}` + `mainwindow/mainwindow_rstudio.cpp`）。第 8 节的六个决定全部按推荐选项落地。2026-11-02。
**目标**：把 RStudio 会话的全局环境放进 StatDataViewer 左侧树，双击即开，每条命令后自动刷新；同时让 ⌘⇧V 这类发送不再依赖 `open -b`，由 SDV 自己决定窗口要不要跳到当前 Space。

---

## 0. 和原来的方式并存

这是前提，不是附带要求：

| | 不连接（和今天一样） | 连接后 |
|---|---|---|
| `sdv_view(x)`、⌘⇧V、Addins、`View()` 接管 | 写文件，`open -b com.statdataviewer`（Windows 走 exe 参数） | 写文件，改发一条 `r.open` 消息，SDV 自己打开并前置 |
| 对象列表 | `sdv_view_env()` 发一张快照表 | 树节点 "RStudio: 项目名" 常驻，每条命令后自动更新；`sdv_view_env()` 仍可用 |
| 断线或 SDV 没开 | 不适用 | 自动回落到 `open -b`；后台每 5 s 重连一次，不打扰用户 |
| 依赖 | 只有 rstudioapi | `later` + `websocket` 放在 Suggests，第一次 `sdv_connect()` 时才需要装 |
| SDV 树里的其他节点 | "R Session"（SDV 自己的 R 进程 / Rserve）、"SAS Studio" | 不动，RStudio 节点是它们的兄弟节点 |
| SAS Studio bridge | 127.0.0.1:53210，单客户端 | 不改一行；RStudio 通道走另一个端口、另一个类 |

用户什么都不做，行为和 0.2.0 完全一样；只有运行了 `sdv_connect()`（或把它放进 `.Rprofile`）才启用通道。

---

## 1. 为什么要一条通道

RStudio 的 R 会话不是服务器，只能在控制台空闲时做事。能在空闲期响应外部请求的唯一正规机制是 `later` 事件循环（httpuv、Shiny 的后台服务都是这么跑的）。Rserve 不行：`run.Rserve()` 卡住控制台，`Rserve()` fork 的是另一个进程，没有用户的全局变量。所以 R 侧必须用 `later`，通道客户端用 `websocket` 包（CRAN 1.4.4，Imports 只有 R6 和 later，mac/Windows 有二进制）。

R 侧做客户端、SDV 做服务端，原因和 SAS Studio 一样：端口固定好发现，多个 RStudio 会话各连各的，R 里不用开端口。

---

## 2. 拓扑与传输

```
RStudio 会话 A ──ws──┐
RStudio 会话 B ──ws──┼──▶ StatDataViewer  127.0.0.1:53211  /v1/r
                     │        HTTP GET /health
                     └──▶     WS  /v1/r
```

| 项 | 值 |
|---|---|
| 监听 | 仅 `127.0.0.1` |
| 默认端口 | `53211`（AppSettings `rstudio/port`；R 侧 `options(sdv.port)`） |
| 协议 | HTTP/1.1 + WebSocket RFC 6455，文本帧，UTF-8 JSON |
| token | 可选，AppSettings `rstudio/token`；R 侧 `options(sdv.token)` 或环境变量 `SDV_TOKEN`。不匹配则 `viewer.hello` 后以 1008 关闭 |
| 客户端数 | 多个；一个 WebSocket 对应一个 RStudio 会话 |
| 心跳 | SDV 每 30 s `viewer.ping`，两次无 `r.pong` 视为断开 |

为什么不复用 53210：`SasStudioBridge` 按规范只服务一个扩展实例（一个 `SasStudioWebSocket` 成员、`hasExtensionConnected()`），消息命名空间也不同。新建 `RStudioBridge` 类，复用 `SasStudioWebSocket` 的 RFC 6455 帧处理和握手计算（`computeAccept`），不碰已发布的协议。

---

## 3. 握手

R → SDV，连接后第一条：

```json
{ "type": "r.hello", "token": "", "pkgVersion": "0.3.0", "rVersion": "4.6.1",
  "session": { "id": "9f1c…", "pid": 48213, "project": "navigator",
               "cwd": "/Users/x/navigator", "ide": "RStudio 2026.09.0" } }
```

SDV → R：`{ "type": "viewer.hello", "viewerVersion": "2.7" }`，随后 R 立即推一次 `r.inventory`。

`session.id` 由 R 侧生成一次（`tempdir()` 的 basename 够唯一，重连不变），SDV 用它找回同一个树节点。

---

## 4. 消息

### 4.1 R → SDV

| type | 字段 | 说明 |
|---|---|---|
| `r.hello` | 见上 | 握手 |
| `r.inventory` | `seq`, `objects[]`, `truncated` | 全局环境清单，全量。`objects[]` 每项 `name, kind, class, dim, size, sizeBytes, value`，和 0.2.0 的清单表同一套字段，`kind` 取 Data / Values / Functions。上限 5000 个对象，超出 `truncated: true` |
| `r.object.ready` | `requestId, name, path, kind, ext, rows, cols` | 对 `viewer.object.open` 的回复。文件已由 `sdv_write()` 写好；`kind` 为 `table`（.rds）或 `text`（.R / .txt）。SDV 读完即删 |
| `r.open` | `requestId, name, path, kind, ext` | R 侧主动发送（⌘⇧V、`sdv_view()`、`View()` 接管）。语义同今天的 `open -b` |
| `r.error` | `requestId, code, message` | `not_found` / `convert_failed` / `busy` |
| `r.pong` | `requestId` | |
| `r.bye` | | `sdv_disconnect()` 或会话退出时尽力发送 |

### 4.2 SDV → R

| type | 字段 | 说明 |
|---|---|---|
| `viewer.hello` | `viewerVersion` | |
| `viewer.object.open` | `requestId, name` | 双击树节点。R 侧 `sdv_prepare(get(name, .GlobalEnv))` → `sdv_write()` → `r.object.ready` |
| `viewer.inventory.request` | `requestId` | 右键 Refresh |
| `viewer.opened` | `requestId` | 对 `r.open` 的确认；R 侧 2 s 内没收到就回落 `open -b` 一次 |
| `viewer.ping` | `requestId` | |

R 忙着跑长计算时所有请求都没有回应；SDV 在节点上显示 "R busy…"，请求保留到 R 回来。不设 `r.busy` 消息，因为 R 忙的时候发不出任何东西。

---

## 5. R 侧（sdv 包 0.3.0）改动清单

| 文件 | 改动 |
|---|---|
| `DESCRIPTION` | Imports 加 `jsonlite`；Suggests 加 `websocket`, `later`, `httpuv`（测试用的假 Viewer） |
| `R/bridge.R` 新 | `sdv_connect(port, token, auto = TRUE)`、`sdv_disconnect()`、`sdv_connected()`；`.sdv_state$ws`；`onOpen` 发 hello + inventory；`onMessage` 分发；`onClose` 用 `later` 定时重连（5 s 起，封顶 60 s）；所有回调 `tryCatch`，错误只 `message()` 一次，绝不抛进用户控制台 |
| `R/bridge.R` | `addTaskCallback("sdv")`：每条顶层命令后算清单摘要（name/class/dim/sizeBytes 拼接），变了才推 `r.inventory`。性能要测：`object.size()` 对巨大 list 会遍历，上限之外用 `length()` 代替 |
| `R/prepare.R` | `sdv_env_table()` 拆出 `sdv_env_records()` 返回 list，供清单表和 `r.inventory` 共用 |
| `R/launch.R` | `sdv_launch(path)` 开头加一段：已连接则发 `r.open` 并等 `viewer.opened`，否则走原路 |
| `R/viewer_override.R` | `.Rprofile` 片段加一行 `sdv::sdv_connect()`（可选） |
| `tests/testthat/test-bridge.R` 新 | 用 `httpuv` 起一个假 SDV（Suggests，没装就 skip）：握手、token 拒绝、inventory 推送与去重、`viewer.object.open` 往返、`r.open` 超时回落 |
| README / NEWS | 新一节「Live environment in StatDataViewer」 |

工作量约 1.5 天。

---

## 6. SDV 侧改动清单

| 文件 | 改动 |
|---|---|
| `sashelper_qt/rstudio/rstudiobridge.{h,cpp}` 新 | QTcpServer + `/health` + WS 升级（把 `SasStudioBridge::tryWebSocketHandshake` 的 header 解析抽成共享静态函数）；`QHash<sessionId, Client>`；信号 `sessionConnected(id, info)`、`sessionDisconnected(id)`、`inventoryArrived(id, QJsonArray)`、`objectReady(id, requestId, name, path, kind)`、`openRequested(id, requestId, name, path, kind)`、`errorReceived`；`sendObjectOpen(id, name)`、`sendInventoryRequest(id)`、`sendOpened(id, requestId)` |
| `mainwindow/treeitemtypes.h` | `RStudioSession`, `RStudioObject` |
| `mainwindow/mainwindow_rstudio.cpp` 新 | 节点 "RStudio: 项目名"（无项目用 "RStudio: Global Environment"，多会话加 pid）；按 `kind` 配图标，tooltip 放 `value`；双击 → `sendObjectOpen`，`objectReady` → 按 `openRSessionObjectSnapshot` 的方式打开，key `__rstudio__/<id>/<name>`，标题 "name — RStudio"，text 类走 `openTextDocument` 只读；`openRequested` → 打开文件并前置窗口；断开 → 节点灰显 "(disconnected)"，60 s 后移除，重连找回 |
| `mainwindow/mainwindow_state.cpp` | 双击分支 `RStudioObject` |
| `mainwindow/mainwindow_workspace.cpp` | 右键菜单：Open、Refresh、Copy name |
| `mainwindow/mainwindow.h` | 成员与槽 |
| AppSettings | `rstudio/listen`（默认 on）、`rstudio/port`、`rstudio/token` |
| Options 对话框 | 一页：开关、端口、token、当前连接列表 |
| `utilities/fileopenfilter.cpp` + 新 `macwindowactivate.mm` | 外部送来文件时（`r.open`、QFileOpenEvent）临时加 `NSWindowCollectionBehaviorMoveToActiveSpace`，取消最小化，activate + makeKeyAndOrderFront，再恢复。这是用户反馈第一条的修法，顺手做掉 |
| `tests/tst_rstudiobridge.cpp` 新 | QTcpSocket 假客户端：握手、token 拒绝、inventory → 树行数与图标、open 往返（预写一个 .rds）、断线灰显。`SASHELPER_TEST_CASE=rstudiobridge`，Qt 5.15 和 6.8 都要过 |
| 网站 / 帮助 | 一段说明 + 截图 |

工作量约 3 天：bridge 1 天，树和打开 1 天，Options、Spaces、测试 1 天。

---

## 7. 安全边界

- 只监听回环；token 可选，与 SAS Studio 同一套 UX。
- R 侧只执行 `get(name, envir = .GlobalEnv)` 加序列化，不接受任意代码；`name` 经 `make.names` 校验失败即 `r.error`。
- SDV 只读 R 写在 `sdv.dir` 下的文件，路径必须在该目录内，否则拒绝。

---

## 8. 决定（已按推荐选项实现）

1. 新端口 53211 加独立 `RStudioBridge` 类，还是把 `SasStudioBridge` 改成多客户端？我选前者。
2. SDV 启动即监听（默认 on），还是像 SAS Studio 那样要用户在 File 菜单里手动开？我选默认 on，Options 里可关。
3. 连接后 ⌘⇧V 改走通道、由 SDV 前置窗口？我选是，带 `open -b` 回落。
4. jsonlite 进 Imports，还是手写 JSON？我倾向 Imports jsonlite。
5. v1 只列全局环境；attached 包、`sys.frames` 留到以后。
6. 清单上限 5000 个对象，`object.size()` 只对 length ≤ 1e5 的 list 计算。

---

## 9. 实现备注（2026-11-02）

- SDV 侧没有任何心跳超时：R 跑长计算时连 pong 都答不了，只有 TCP 断开才算断线。每 30 s 的 ping 只刷新 lastSeen。
- 节点断线后灰显 "(disconnected)" 60 s 再移除；同一 session id 重连时新 socket 静默顶替旧的，不发 sessionDisconnected。
- `r.open` 的确认超时默认 2 s（`sdv.open_timeout`），超时回落到 `open -b`。测试里设 0.5 s。
- 本机 Homebrew R 对 OpenSSL 4 编不过 `websocket`（AsioHeaders 的 rfc2818_verification 用了不透明的 ASN1 结构）；用 `PKG_CONFIG_PATH=/opt/homebrew/opt/openssl@3/lib/pkgconfig` 装。CRAN 二进制用户不受影响。
- 测试：SDV `SASHELPER_TEST_CASE=rstudiobridge`（11 例，含 MainWindow 树和快照）；R `testthat::test_local(filter = "bridge")`（httpuv 假 Viewer）。tests/main.cpp 全局设 `SDV_NO_RSTUDIO_BRIDGE=1`，测试窗口不抢 53211。
- 真机 E2E（Rscript 用 `later::run_now()` 自己泵事件循环）：连接 → 树节点 → 新变量出现 → `sdv_view(mtcars)` 走 `r.open` 打开标签页 → `sdv_disconnect()` 节点灰显，全部通过。
