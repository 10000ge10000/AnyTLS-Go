# AnyTLS 协议草稿（重构版本 vNext）

> 状态：Draft / Work-In-Progress  
> 目标：统一结构、增强安全性、明确扩展与实现细节。本文档替代旧版 `docs/protocol.md`。

## 1. 概览
- 传输层：TLS (推荐模拟常见浏览器 TLS 指纹)
- 会话层：自定义多路复用（Session / Stream）
- 关键特性：认证、命令帧、心跳、流复用、可更新 paddingScheme、版本协商、分片、可扩展能力。
- 版本：协议版本 current = 2，向后兼容 v1（见版本协商章节）。

## 2. 术语
| 名称 | 描述 |
|------|------|
| Session | 运行在单一 TLS 连接之上的逻辑会话层循环 |
| Stream | Session 内的逻辑子通道（单向半双工聚合为全双工） |
| Frame | 会话层最小有序单元（命令 + 元信息 + 数据） |
| Command | 标识帧的类型（见第 6 章） |
| Padding Scheme | 流量分包 + 填充策略描述文本 |
| Heartbeat | 心跳请求/响应，用于探测及恢复卡死 |
| Degraded | 会话进入可疑宕死状态，准备迁移 |

## 3. 设计目标与原则
- 安全：减轻离线暴力破解、主动探测、流量特征识别。
- 兼容：老版本客户端 / 服务器在协商失败时安全降级。
- 可扩展：命令空间与 Settings 扩展机制提前保留。
- 性能：零拷贝友好、分片简单、内存受控、低握手开销。
- 可演进：支持未来特性（流控、优先级、复用增强、动态策略）。

## 4. 认证（改进提案）
> 若未实现本节新式“挑战响应”认证，可继续使用 v1 兼容模式（直接 sha256(password)）。新式认证推荐：防重放、防离线猜测。

### 4.1 认证阶段顺序
1. 建立 TLS 连接（外层加密）
2. （可选）服务器发送 `ServerHelloExt` 内嵌随机或单独发送 `ServerNonce` 帧（待定扩展）
3. 客户端发送认证请求帧：包含 `clientNonce` 与 HMAC
4. 服务器校验：成功 → 进入会话；失败 → 发送伪装 / fallback / 直接关闭。

### 4.2 新式认证帧格式（Draft）
| 字段 | 长度 | 说明 |
|------|------|------|
| version | 1 | 认证格式版本（=1 表示挑战响应） |
| serverNonce | 16 | 服务器随机（或 0 填充：无挑战模式） |
| clientNonce | 16 | 客户端随机 |
| kdfId | 2 | KDF 参数编号（0=PBKDF2#100k,1=Argon2id#m=64M,t=2） |
| hmac | 32 | HMAC-SHA256( DerivedKey , serverNonce || clientNonce ) |
| paddingLen | 2 | 后续 padding 长度 |
| padding | N | 随机字节（0..256 建议） |

### 4.3 降级兼容
- 若服务器未实现新式认证：继续接收旧格式（32B sha256(password)+paddingLen+padding），不回挑战。
- 若客户端未识别挑战：可按旧模式直接发送旧格式，服务器检测并接受。

### 4.4 安全建议
- 强制密码长度 ≥ 12，推荐 ≥ 16 随机 Base62。
- 禁止明文日志记录密码或其哈希。

## 5. 会话与 Stream 模型
### 5.1 流 ID 分配
- 客户端发起：在单 Session 内 streamId 单调递增（32-bit，无符号）。
- 溢出策略：当即将溢出时 MUST 关闭 Session 并新建。

### 5.2 状态机（概念）
```
Session: Init -> Active -> (Degraded?) -> Closing -> Closed
Stream: Idle -> Open -> HalfClose[*] -> Closed
```
> *是否支持半关闭取决于实现；若不支持，`FIN` 即全双工关闭。

### 5.3 关闭策略
- 正常：发送/接收 FIN → 释放资源
- 异常：心跳失败、协议错误、上层终止
- 会话关闭时 MUST 视为其内所有流关闭。

## 6. 命令集（Commands）
| 名称 | 值 | 方向 | 描述 |
|------|----|------|------|
| cmdWaste | 0 | 双向 | 填充数据（可被忽略） |
| cmdSYN | 1 | C→S | 打开新 Stream |
| cmdPSH | 2 | 双向 | 流数据帧（可分片） |
| cmdFIN | 3 | 双向 | 关闭流 |
| cmdSettings | 4 | C→S | 客户端设置上报（含协议版本、客户端标识、padding md5） |
| cmdAlert | 5 | S→C / 双向* | 警告 / 错误说明 |
| cmdUpdatePaddingScheme | 6 | S→C | 下发新的 paddingScheme |
| cmdSYNACK | 7 | S→C | v2：出站连接状态反馈 |
| cmdHeartRequest | 8 | 双向 | 心跳请求（streamId=0） |
| cmdHeartResponse | 9 | 双向 | 心跳响应（streamId=0） |
| cmdServerSettings | 10 | S→C | 服务器设置（确认版本 / features） |
| （预留） | 200-255 | - | 扩展区段 |

> *可选：允许客户端发送 cmdAlert 终止会话。

## 7. 帧格式（Frame）
| 字段 | 长度 | 编码 | 说明 |
|------|------|------|------|
| command | 1 | uint8 | 命令码 |
| streamId | 4 | uint32 BE | 流 ID（控制帧=0） |
| dataLen | 2 | uint16 BE | 数据长度（MAX=65535） |
| data | N | bytes | 有效负载 |

### 7.1 分片规则
- 单帧 `dataLen <= 65535`。
- 超出需拆分为多帧 `cmdPSH`，顺序发送。
- 接收端顺序聚合，直到 FIN 或会话关闭。
- 超长声明（>65535）帧：MUST 丢弃 + SHOULD 发 `cmdAlert`("FRAME_TOO_LARGE") + MAY 关闭。

## 8. Settings 与特性协商
### 8.1 cmdSettings（客户端发送）
示例：
```
v=2
client=anytls-go/0.0.1
padding-md5=abcd1234...
features=HB,PSH_SPLIT
```
- `v`：客户端支持的最高协议版本
- `features`：逗号分隔功能标识（HB=heartbeat, PSH_SPLIT=显式分片能力）

### 8.2 cmdServerSettings
```
v=2
features=HB,PSH_SPLIT
hb-int=30	hb-jitter=0.2
```
客户端未收到该帧 → 默认按 v1 降级。

## 9. 心跳（Heartbeat）
参考提案：
- 参数：interval / jitter_percent / miss_threshold / adaptive_quiet / warmup_grace / hard_timeout
- 抖动计算：`next = base * (1 + rand(-j,+j))` → clamp 到 [min_interval, max_interval]
- 进入 Degraded：连续 miss ≥ 阈值；可并行预建新 Session。
- 任意有效帧重置 miss 计数。

## 10. Padding Scheme
### 10.1 语法（示例）
```
stop=8
0=30-30
1=100-400
2=400-500,c,500-1000,c,500-1000
```
- `stop`：处理到第 (stop-1) 号包（0-based）停止策略
- `c`：检查符号（若上一包后无剩余用户数据，则跳过后续填充）

### 10.2 下发与更新
- 比对 md5 不同 → 服务器发送 `cmdUpdatePaddingScheme`
- 建议在新版中为下发内容添加 HMAC（待补充实现细节）

## 11. 复用策略（Session Reuse）
- 优先复用最新 Session
- 关闭最老空闲超过 `idleSessionTimeout` 的 Session
- 预留 `minIdleSession`

## 12. 错误与告警（Alerts）
建议格式：
```
ERR=FRAME_TOO_LARGE
Frame length > 65535
```
示例错误码（初稿）：
| 代码 | 场景 |
|------|------|
| BAD_AUTH | 认证失败 |
| FRAME_TOO_LARGE | 帧长度非法 |
| UNSUPPORTED_VERSION | 版本不支持 |
| PROTOCOL_VIOLATION | 命令顺序错误 |
| HEARTBEAT_TIMEOUT | 心跳超时 |

## 13. 安全注意事项
- 强密码策略与 KDF
- 不记录明文密码/哈希
- TLS 推荐套件 & 指纹伪装（待列）
- fallback 伪装策略（HTTP/1.1 200 + 可缓存资源）

## 14. 流控（未来扩展草案）
- 预留 WINDOW_UPDATE 命令或在 Settings 中协商 `maxConcurrentStreams`
- 暂不在当前版本强制

## 15. 兼容性与版本协商
- v2 双向支持 → 启用 SYNACK / Heartbeat / ServerSettings
- 单端低版本 → 降级 v1（不使用 v2-only 命令）

## 16. 实现建议（非规范）
- 解析层零拷贝分段读取
- 心跳协程 + 状态机
- 分片发送内聚批量写 TLS
- padding 应与应用数据发送策略解耦

## 17. 测试与验证清单
| 类别 | 关键用例 |
|------|----------|
| 认证 | 新式 / 旧式 / 伪造 HMAC / 重放 |
| 分片 | 65535 边界 / 200KB 大块 / 超长拒绝 |
| 心跳 | 抖动统计 / 丢包恢复 / Degraded 迁移 |
| padding | c 标记优化 / stop 边界 / 更新方案 |
| 复用 | 多 Session 循环回收 / 超时清理 |

## 18. 更新日志（草稿节选）
- v2：加入 cmdSYNACK / Heartbeat / ServerSettings / 分片规范化 / 认证改进提案（Draft）
- vNext：计划引入认证挑战 + paddingScheme HMAC + 流控扩展

## 19. 未决事项（TODO）
- 认证挑战落地字段与回退流程精确定稿
- paddingScheme HMAC 签名结构
- features 标识枚举列表写死还是动态注册
- WINDOW_UPDATE 是否进入 vNext 或 v3

---
> 说明：本草稿为结构化骨架，后续每节需要补足“ MUST / SHOULD / MAY ”用语与精确错误处理流程。欢迎以 PR 或 Issue 提交反馈。
