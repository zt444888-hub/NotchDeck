# NotchDeck 直分发布清单（Developer ID + notarize）

> 状态：2026-08-04。产物 `.build/release/NotchDeck.app` 已通过本机构建 + 签名验证
> （`codesign --verify --deep --strict` 通过，Identifier=`com.notchdeck.mac`，TeamIdentifier=`2VBHV3VJ8N`）。
> Developer ID 证书已签发导入，notarytool 凭证已存（profile `NotchDeck`），
> build.sh 公证段已加 20min 超时保护。首次公证因 Apple 服务停滞待重提（见 §6）。

## 0. 现状（已就绪）

- [x] 产物名已改 NotchDeck（build.sh `APP_BINARY`/`APP_NAME` 分离，`CFBundleExecutable=CodeIsland` 与 MacOS 布局一致）
- [x] `swift build` 已加 `--disable-sandbox`（受限环境兼容）
- [x] appcast.xml / SUFeedURL 指向 `zt444888-hub/NotchDeck`
- [x] entitlements：无沙盒，含 bluetooth / automation / disable-library-validation（直分形态）
- [x] Developer ID Application 证书已导入钥匙串（G2 Sub-CA，2031-08 到期）
- [x] notarytool 凭证已存（`--keychain-profile NotchDeck`）
- [x] build.sh 公证段有 `--timeout 20m` + submission id 恢复逻辑

## 1. 你必须手动完成的两步（一次性）

### 1a. 申请 Developer ID Application 证书

当前钥匙串**只有 Apple Distribution（MAS）+ 2 个 Development 证书，无 Developer ID**。
`./build.sh --notarize` 的触发条件 `SIGN_ID == *"Developer ID"*` 目前永远为 false，
且无 Developer ID 时会 fallback 到个人开发证书签名 → 产物**仅本机可跑**。

申请（免费，约 2 分钟）：
1. 登录 https://developer.apple.com/account → Certificates, Identifiers & Profiles
2. Certificates → `+` → **Developer ID Application**（在 Software 分组）
3. 用你的 Mac 生成 CSR（钥匙串访问 → 证书助理 → 从证书颁发机构请求证书）
4. 下载 `.cer` 双击导入钥匙串

导入后确认：`security find-identity -v -p codesigning` 应出现
`"Developer ID Application: Shenzhen Yuanbei Technology Co., Ltd. (2VBHV3VJ8N)"`。

### 1b. 存储公证凭证（notarytool）

build.sh 已用 `--keychain-profile "NotchDeck"`，本机执行一次（Apple ID 密码需是**专用密码**，
https://appleid.apple.com 生成 App-Specific Password）：

```bash
xcrun notarytool store-credentials "NotchDeck" \
  --apple-id "<你的 Apple ID 邮箱>" \
  --team-id "2VBHV3VJ8N" \
  --password "<app-specific-password>"
```

验证：`xcrun notarytool history --keychain-profile "NotchDeck"` 能列出记录即可。

## 2. 首次发布流程

```bash
# 1) 构建 + 签名 + 公证 + 生成 DMG（约 3-5 分钟）
./build.sh --notarize

# 产物：
#   .build/release/NotchDeck.app
#   .build/release/NotchDeck.dmg
```

- 首次发布建议**先在第二台 Mac（或干净虚拟机）验证**：双击 DMG → 拖入 Applications →
  打开 → Gatekeeper 不应拦截（Developer ID + 公证已 stapled）。
- `codesign --verify --deep --strict` + `spctl -a -vv .build/release/NotchDeck.app` 自查。

## 3. 版本 bump 与 appcast（每次发布必做）

1. 决定版本号（当前 appcast 顶格 v1.0.31 是原版版本；NotchDeck 首个版本建议从
   **v1.1.0** 起，语义上与 fork 区分）。
2. 更新版本号位置：
   - `Info.plist` → `CFBundleShortVersionString` / `CFBundleVersion`
   - `Package.swift`（如有 version）
   - README 徽章（如引用版本）
3. 上传 `NotchDeck.dmg` 到 GitHub Release `v<新版本>`。
4. **重新生成 appcast 条目**：Sparkle 的 `edSignature` 是 DMG 的 EdDSA 签名，**不能沿用原版值**
   （当前 appcast.xml 里的签名是原版 CodeIsland DMG 的）。**NotchDeck 密钥对已生成并配置（2026-08-04）**：
   - 私钥：`~/dev-id-csr/NotchDeck-sparkle-ed25519.pem`（Ed25519，600 权限，**妥善备份**）
   - 公钥：`fXonIxJvmDAY3DmfcPZxoDjzMAcrrjDk1eSfFPjuCgc=`（已写入 Info.plist `SUPublicEDKey`）
   - 发布时生成 DMG 签名（openssl 3+，`-rawin` 对文件直接签名）：
   ```bash
   edSig=$(openssl pkeyutl -sign -inkey ~/dev-id-csr/NotchDeck-sparkle-ed25519.pem \
     -rawin -in .build/release/NotchDeck.dmg | base64)
   length=$(stat -f%z .build/release/NotchDeck.dmg)
   # 将 edSig / length 填入 appcast.xml 新 item（sparkle:edSignature / length 属性）
   ```
   - 或 Sparkle 官方 `generate_appcast`（`SPARKLE_ED25519_PRIVATE_KEY` 环境变量指向私钥）。
5. 更新 `appcast.xml`：新增 item（url 指向新 DMG、edSignature、length、版本号），
   移除或保留旧条目均可（Sparkle 按 `sparkle:version` 比较）。

## 4. 首次发布前最终检查清单

- [ ] `security find-identity` 出现 Developer ID Application 证书
- [ ] `notarytool history` 可用
- [ ] 干净机器安装验证通过（无 Gatekeeper 拦截、Sparkle 更新提示正常）
- [ ] 首次运行验证 hooks 安装链路（`~/.notchdeck/` 创建、各 CLI 配置写入 notchdeck 块）——
      开发机已确认零残留，首次运行即从干净状态安装
- [x] `SUPublicEDKey` 已配置（`fXonIxJvmDAY3DmfcPZxoDjzMAcrrjDk1eSfFPjuCgc=`，2026-08-04 生成密钥对）
- [ ] 隐私营养标签填写（developer.apple.com → App Store Connect → 你的 App → 隐私）
- [ ] README Buddy 占位链接（`idYOUR_BUDDY_APPSTORE_ID`）等 companion 上架后替换
- [ ] appcast.xml `sparkle:minimumSystemVersion` 与 Info.plist 的 LSMinimumSystemVersion 一致（14.0）

## 5. 已知边界

- **仅 arm64**：`build.sh` 固定 `--arch arm64`，Intel Mac 用户无法运行。若需要 universal，
  需在 build.sh 加 `--arch x86_64` 交叉构建 + `lipo` 合并（原版设计如此，发布 v1 可先 arm64-only）。
- **Sparkle 更新**：SUFeedURL 用 `raw.githubusercontent.com`，GitHub raw 有 CDN 缓存延迟
  （新版本发布后用户可能数小时才看到更新提示）。正式运营后可换自有域名/对象存储。
- **appcast 签名密钥**：确认是否有原版 Sparkle EdDSA 私钥；没有则按 §3.4 重新生成并配置
  `SUPublicEDKey`（影响所有存量测试用户的更新校验，首次发布前定稿）。

## 6. 公证排队/停滞应对（2026-08-04 实战）

Apple notary 服务偶发**吞吐停滞**：系统状态页显示 `available`，但提交长时间（4h+）停在
`In Progress`，log 一直返回 `Submission log is not yet available`。这不是本地问题，重提即可。

**识别**：
- `xcrun notarytool history --keychain-profile NotchDeck` → status 卡 `In Progress` > 1h
- `xcrun notarytool log <id> --keychain-profile NotchDeck` → `not yet available`
- Apple 状态页 https://developer.apple.com/system-status/ 只看"在线与否"，不反映处理吞吐

**应对流程**：
1. 杀掉 `--wait` 阻塞进程（build.sh 现在有 20min 超时保护，会自动退出并保留 submission id）
2. 用**现有 zip 重提**（不重新构建）：
   ```bash
   xcrun notarytool submit .build/release/NotchDeck.zip --keychain-profile NotchDeck \
     --wait --timeout 20m
   ```
3. 若仍排队：转**异步轮询**（提交不带 `--wait`，拿 submission id）：
   ```bash
   xcrun notarytool submit .build/release/NotchDeck.zip --keychain-profile NotchDeck
   # → 记下输出里的 id
   xcrun notarytool log <id> --keychain-profile NotchDeck --output-format json   # 轮询 status 字段
   ```
   `status: Accepted` → `xcrun stapler staple .build/release/NotchDeck.app`
4. 僵尸提交无需处理，Apple 最终会过期丢弃
5. 建议重提时段：美东工作时间（亚太的晚上/凌晨）通常最快；亚太下午高峰最差

**首次公证通过后**，剩余步骤（DMG 生成 + 公证 + staple）见 §2 的 `./build.sh --notarize`，
或按 `/tmp/notchdeck-notarize-continue.sh` 的续接逻辑手动执行。

