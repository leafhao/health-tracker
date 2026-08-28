# Health Sync Envelope v1

## 目标与威胁模型

该协议保护 iPhone 到 Receiver 之间经过第三方对象存储的健康数据。对象存储、网络代理和被动监听者不能读取或修改健康内容。

可以观察但暂不隐藏的信息：上传时间、对象大小、对象数量和随机设备目录之间的关联。可选 padding 用于降低长度泄漏。

协议不能防止持有 S3 凭据的攻击者删除密文，因此批次序列检查、本地重试、云端版本/保留策略和 Receiver 备份仍然必要。

## 密钥

- Receiver Encryption Key：HPKE X25519 长期密钥对；私钥只在 Receiver，公钥配对到 iPhone。
- Device Signing Key：Ed25519 长期密钥对；私钥存 iPhone Keychain，公钥在配对时注册到 Receiver。
- HPKE 为每个 Envelope 自动生成新的临时密钥材料。

密钥使用 `key_id` 标识，允许新旧密钥并行完成轮换。

## 加密流程

1. 将 `HealthEventBatch` 编码为 UTF-8 JSON。
2. 可选使用 gzip 压缩，并补齐到固定块大小；当前 iOS Collector 使用 identity + 4 KiB 补齐，Receiver 同时兼容 gzip。
3. 生成 header JSON 的原始 UTF-8 字节；后续不重新序列化这些字节。
4. 使用 RFC 9180 HPKE Base Mode 加密，固定 cipher suite：DHKEM(X25519, HKDF-SHA256)、HKDF-SHA256、ChaCha20-Poly1305。
   - info：UTF-8 `health-envelope-v1\0` 拼接 `SHA256(header_bytes)`
   - 不另设 AAD；header 通过 info 摘要与外层设备签名双重绑定
   - 输出：`encapsulated_key || ciphertext_and_tag`
5. Device Signing Key 对以下原始字节签名：

```text
"HEALTH-ENVELOPE-V1\0" ||
header_bytes || hpke_ciphertext
```

6. 所有二进制字段使用无换行 Base64 编码，写入 envelope JSON。

Receiver 先按已注册的设备公钥验签，再进行 HPKE 解密。任何失败对象进入 quarantine，不写入健康数据表。协议直接采用 RFC 9180，避免维护自定义 ECIES 组合。

## Header

Header 至少包含：

```json
{
  "protocol": "health-envelope/1",
  "batch_id": "0198...",
  "device_id": "opaque-random-id",
  "sequence": 42,
  "receiver_key_id": "receiver-2026-01",
  "signing_key_id": "iphone-01",
  "created_at": "2026-08-28T14:00:00.000Z",
  "content_type": "application/vnd.health-event-batch+json;v=1",
  "content_encoding": "gzip",
  "plaintext_size": 123456,
  "padding_size": 0
}
```

Header 本身不包含健康类型、真实姓名、Apple 设备名称或样本日期范围。

## Event Batch

每个设备维护单调递增的 `sequence`。`previous_batch_id` 允许 Receiver 检查缺口和链路异常。

事件分为 `upsert` 和 `delete`：

- upsert：包含稳定 source UUID、实体类型、观察时间和原始 payload。
- delete：包含被 HealthKit 删除对象的 UUID，不要求旧 payload 仍可读取。

Receiver 的幂等键：

- 批次：`(owner_id, device_id, batch_id)`。
- 序列：`(owner_id, device_id, sequence)`。
- HealthKit 对象：`(owner_id, entity_type, source_uuid)`。
- 事件：`event_id`。

## Receipt

Receiver 成功提交数据库事务后写入 receipt：

```json
{
  "protocol": "health-receipt/1",
  "device_id": "opaque-random-id",
  "batch_id": "0198...",
  "sequence": 42,
  "status": "committed",
  "committed_at": "2026-08-28T14:01:00.000Z",
  "accepted": 380,
  "rejected": 0
}
```

iPhone 不依赖 receipt 才能推进 HealthKit anchor；本地 Outbox 只需确认密文已经可靠上传到对象存储。Receipt 用于状态展示、云端清理和缺口诊断。直连模式通过 HTTPS/受信网络返回 receipt；Relay 模式下 receipt 的防伪签名将在 S3 Transport 阶段加入，在此之前手机不会把第三方 Relay 中出现的 receipt 当作可信删除依据。

## 兼容性

- Reader 必须拒绝未知 major version。
- 新增可选字段不升级 major version。
- 算法替换通过新 protocol major version或 header 中受约束的 cipher suite 完成。
- v1 固定使用 RFC 9180 的 X25519/HKDF-SHA256/ChaCha20-Poly1305 cipher suite 和 Ed25519，避免算法协商降级。
- Apple 原生 HPKE 从 iOS 17 可用，因此 Collector 的 v2 最低系统版本调整为 iOS 17。
