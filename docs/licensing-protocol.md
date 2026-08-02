# CopyAttach Licensing Protocol v1

- 产品 ID：`copyattach`
- 试用：服务端首次登记后连续 30 天
- 正式许可证：永久权益，同时最多 3 个 active 设备
- 设备身份：macOS Keychain 中的 P-256 私钥；`device_id = SHA256(SEC1 public key)`
- Lease：服务端 Ed25519 签名，客户端仅内置验证公钥
- 本地开发 API：`http://127.0.0.1:8787/v1`

签名信封：`key_id`、base64url `payload`、base64url Ed25519 `signature`。签名对象是 payload 解码后的原始 JSON 字节。

正式 Lease 续租使用一次性 5 分钟 challenge。客户端以 P-256 ECDSA（DER signature）签名 nonce。challenge 使用一次后失效。

### 永久许可证的离线策略

永久权益（`license_expires_at` 为空）的 Lease 即使超过 `expires_at`（服务端按 `LICENSE_LEASE_SECONDS` 签发，仅为续租节奏，不代表权益边界）仍视为有效：客户端校验 Ed25519 签名 + 设备绑定后即离线可用，不安排 Lease 中点续租，也不做周期性的在线状态轮询。后台的暂停/撤销对已激活的永久设备不强制生效，只影响该密钥的新设备激活与座位管理。试用/订阅的 Lease 到期、权益到期与在线状态检查照常执行。

接口：

- `GET /v1/health`
- `POST /v1/trials/start`
- `POST /v1/licenses/activate`
- `POST /v1/licenses/challenge`
- `POST /v1/licenses/refresh`
- `POST /v1/licenses/deactivate`

本地和生产必须使用不同的数据库、pepper、Ed25519 密钥和客户端构建配置。正式 App 不得信任开发公钥，也不得自动回退 localhost。
