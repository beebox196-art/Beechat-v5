# OpenClaw Gateway Authentication Research

**Date:** 2026-04-17  
**Researcher:** Bee (AI Subagent)  
**Purpose:** Document the correct, documented authentication flow for external clients connecting to the OpenClaw Gateway

---

## Executive Summary

**Problem:** BeeChat v5 integration test connects to gateway WebSocket and completes handshake, but ALL RPC calls fail with "missing scope: operator.read".

**Root Cause:** Channel plugins (Telegram, Discord, Signal) do NOT connect as external clients. They run **inside** the OpenClaw Gateway process as plugins with internal access. External clients like BeeChat must use the **device identity authentication flow** with proper scope negotiation.

**Solution:** BeeChat must:
1. Generate and persist a device identity (Ed25519 keypair)
2. Connect with device signature + gateway token (or bootstrap token for first-time pairing)
3. Request scopes explicitly in the `connect` request
4. Store the returned `deviceToken` from `hello-ok.auth` for subsequent connections
5. Use the stored device token for reconnection (not the gateway token)

---

## Key Finding: Channel Plugins vs External Clients

### Channel Plugins (Telegram, Discord, Signal)

Channel plugins are **NOT external clients**. They:
- Run as **plugins inside the OpenClaw Gateway process**
- Have **internal access** to gateway methods via the plugin runtime
- Do NOT use WebSocket connections to the gateway
- Do NOT need operator scopes (they're part of the gateway itself)
- Are registered in `/Users/openclaw/.local/lib/node_modules/openclaw/dist/plugins/`
- Execute as Node.js modules loaded by the gateway

**Source:** `plugin-sdk/channel-runtime.js`, `plugin-sdk/src/channels/plugins/types.core.d.ts`

### External Clients (BeeChat, Control UI, CLI)

External clients MUST:
- Connect via WebSocket to the gateway
- Complete the `connect.challenge` → `connect` → `hello-ok` handshake
- Use **device identity authentication** with Ed25519 signatures
- Request and receive **operator scopes** (operator.read, operator.write, etc.)
- Store and reuse **device tokens** for subsequent connections

**Source:** `client-DkWAat_P.js` (GatewayClient class)

---

## Authentication Flow

### Step 1: Device Identity Generation

External clients must generate a persistent Ed25519 keypair:

```typescript
// From device-identity-TBOlRcQx.js
function loadOrCreateDeviceIdentity(filePath) {
  // Generate Ed25519 keypair
  const { publicKey, privateKey } = crypto.generateKeyPairSync("ed25519");
  
  // Derive deviceId from SHA-256 hash of public key
  const deviceId = fingerprintPublicKey(publicKeyPem);
  
  // Store in file (mode 0o600)
  const identity = {
    version: 1,
    deviceId,
    publicKeyPem,
    privateKeyPem,
    createdAtMs: Date.now()
  };
}
```

**For BeeChat (Swift):**
- Use Security framework `SecKeyCreateRandomKey` with Ed25519
- Store in Keychain with service `"com.beechat.device-identity"`
- Derive deviceId from SHA-256 hash of public key raw bytes (hex-encoded)

**Source:** `device-identity-TBOlRcQx.js`

### Step 2: WebSocket Connection

Connect to gateway URL. The token can be passed as:
- Query parameter: `ws://localhost:18789/?token=<gatewayToken>`
- OR in the `connect` request auth field

**Note:** The gateway token is used for **initial authentication only**. After the first successful connection, the client receives a device-specific token.

### Step 3: Connect Challenge

Gateway sends `connect.challenge` event:

```json
{
  "type": "event",
  "event": "connect.challenge",
  "payload": {
    "nonce": "random-nonce-string",
    "ts": 1737264000000
  }
}
```

**Client must:**
- Capture the `nonce`
- Use it in the device signature (prevents replay attacks)

### Step 4: Connect Request

Send `connect` request with device signature:

```typescript
// From client-DkWAat_P.js - sendConnect() method
const role = this.opts.role ?? "operator";
const scopes = this.opts.scopes ?? ["operator.admin"];
const signedAtMs = Date.now();  // MUST be current time, NOT challenge timestamp

// Build signature payload (v3 format)
const payload = [
  "v3",
  deviceId,
  clientId,           // e.g., "beechat"
  clientMode,         // e.g., "backend" or "operator"
  role,               // "operator"
  scopes.join(","),   // "operator.read,operator.write"
  String(signedAtMs),
  token ?? "",        // gateway token or bootstrap token
  nonce,              // from connect.challenge
  platform,           // "darwin", "macos", etc.
  deviceFamily        // optional
].join("|");

// Sign with device private key
const signature = signDevicePayload(privateKeyPem, payload);

// Send connect request
const params = {
  minProtocol: 3,
  maxProtocol: 3,
  client: {
    id: clientId,
    displayName: "BeeChat",
    version: "5.0.0",
    platform: "macos",
    mode: "backend"
  },
  role: "operator",
  scopes: ["operator.read", "operator.write"],  // Requested scopes
  auth: {
    token: gatewayToken,  // OR bootstrapToken for first-time pairing
  },
  device: {
    id: deviceId,
    publicKey: publicKeyBase64Url,  // Raw public key, base64url-encoded
    signature: signature,
    signedAt: signedAtMs,
    nonce: nonce
  }
};

await gatewayClient.request("connect", params);
```

**Critical Rules:**
1. `signedAtMs` MUST be current timestamp (not challenge timestamp)
2. `nonce` MUST match the one from `connect.challenge`
3. `signature` is over the canonical payload string (pipe-delimited)
4. `publicKey` is raw bytes, base64url-encoded (NOT PEM format)
5. Only send `device` field when you have a device identity

**Source:** `client-DkWAat_P.js`, `device-auth-tzV3Kb-2.js`

### Step 5: Hello-Ok Response

Gateway responds with `hello-ok`:

```typescript
interface HelloOk {
  protocol: number;
  server: ServerInfo;
  features: Features;
  policy: {
    maxPayload: number;
    tickIntervalMs?: number;
  };
  auth?: {
    deviceToken?: string;    // ← PERSIST THIS
    role?: string;
    scopes?: string[];       // ← Granted scopes
  };
}
```

**Client MUST:**
- Persist `auth.deviceToken` to secure storage (Keychain)
- Store `auth.scopes` alongside the token
- Use this device token for ALL subsequent connections (not the gateway token)

**Source:** `client-DkWAat_P.js` line ~260

### Step 6: Subsequent Connections

On reconnection, use the **stored device token**:

```typescript
// From client-DkWAat_P.js - selectConnectAuth()
const storedAuth = loadDeviceAuthToken({
  deviceId: this.opts.deviceIdentity.deviceId,
  role: "operator"
});

// storedAuth contains:
{
  token: "device-token-from-hello-ok",
  scopes: ["operator.read", "operator.write"]
}

// Use stored token in connect request
const params = {
  auth: {
    deviceToken: storedAuth.token  // ← Use this, not gateway token
  },
  scopes: storedAuth.scopes,  // ← Re-request same scopes
  device: { ... }  // Same device signature flow
};
```

**Token Storage Format:**

```json
// Stored in device-auth.json (or Keychain equivalent)
{
  "version": 1,
  "deviceId": "sha256-of-public-key",
  "tokens": {
    "operator": {
      "token": "device-token-string",
      "role": "operator",
      "scopes": ["operator.read", "operator.write"],
      "updatedAtMs": 1737264000000
    }
  }
}
```

**Source:** `client-DkWAat_P.js` lines 30-60, 240-280

---

## Operator Scopes

### Available Scopes

From `operator-scopes.d.ts`:

| Scope | Description |
|-------|-------------|
| `operator.admin` | Full admin access (implies read + write) |
| `operator.read` | Read-only: sessions.list, chat.history, config.get, etc. |
| `operator.write` | Write access: chat.send, sessions.send, message.action, etc. |
| `operator.approvals` | Access exec/plugin approval methods |
| `operator.pairing` | Device pairing management |
| `operator.talk.secrets` | Access to secrets/tokens in talk config |

### Scope Hierarchy

From `device-auth-tzV3Kb-2.js`:

```typescript
function normalizeDeviceAuthScopes(scopes) {
  // operator.admin implies read + write
  if (out.has("operator.admin")) {
    out.add("operator.read");
    out.add("operator.write");
  }
  // operator.write implies read
  else if (out.has("operator.write")) {
    out.add("operator.read");
  }
  return [...out].toSorted();
}
```

### Method-to-Scope Mapping

From `method-scopes-D3xbsVVt.js`:

**operator.read** (required for BeeChat):
- `sessions.list`, `sessions.get`, `sessions.preview`
- `chat.history`
- `status`, `health`
- `node.list`, `node.describe`
- `config.get`
- And many more read-only methods

**operator.write** (required for sending messages):
- `chat.send`
- `sessions.send`
- `message.action`
- `send`, `poll`

**operator.admin** (full access):
- `connect`
- `sessions.delete`, `sessions.reset`
- `agents.create`, `agents.delete`
- `cron.add`, `cron.remove`

### Bootstrap Profile (First-Time Pairing)

From `device-bootstrap-profile-TTjBZgaz.js`:

```typescript
const BOOTSTRAP_HANDOFF_OPERATOR_SCOPES = [
  "operator.approvals",
  "operator.read",
  "operator.talk.secrets",
  "operator.write"
];

const PAIRING_SETUP_BOOTSTRAP_PROFILE = {
  roles: ["node", "operator"],
  scopes: [...BOOTSTRAP_HANDOFF_OPERATOR_SCOPES]
};
```

**This means:** When a device pairs via QR code or bootstrap token, it automatically gets these 4 scopes.

---

## Why BeeChat Gets "missing scope: operator.read"

### Likely Causes

1. **Not requesting scopes in connect request**
   - If `scopes` is omitted, gateway may default to no scopes
   - Solution: Always include `scopes: ["operator.read", "operator.write"]` in connect params

2. **Using gateway token without device identity**
   - Gateway token alone doesn't grant operator scopes
   - Solution: Use device identity + signature + gateway token

3. **Not storing/using device token**
   - First connection succeeds but device token not persisted
   - Subsequent connections use gateway token again (no scopes)
   - Solution: Store `hello-ok.auth.deviceToken` and use it for reconnects

4. **Device identity mismatch**
   - Device ID changed between connections
   - Gateway doesn't recognize device, doesn't grant stored scopes
   - Solution: Persist device identity securely and reuse

5. **Connecting without bootstrap token (first time)**
   - First connection needs bootstrap token OR gateway token with pairing enabled
   - Solution: Use gateway token for first connection, ensure gateway allows it

### Debug Steps

Check the `hello-ok` response:

```typescript
gatewayClient.onHelloOk = (helloOk) => {
  console.log("Auth result:", helloOk.auth);
  // Should show:
  // {
  //   deviceToken: "...",
  //   role: "operator",
  //   scopes: ["operator.read", "operator.write", ...]
  // }
};
```

If `helloOk.auth.scopes` is missing or empty, the gateway didn't grant scopes.

---

## Recommended BeeChat Implementation

### 1. Device Identity Manager (Swift)

```swift
import Security
import CryptoKit

actor DeviceIdentityManager {
    static let shared = DeviceIdentityManager()
    
    private var identity: DeviceIdentity?
    
    struct DeviceIdentity {
        let deviceId: String
        let publicKey: Data  // Raw bytes
        let publicKeyBase64Url: String
        let privateKey: SecKey
    }
    
    func getOrCreateIdentity() throws -> DeviceIdentity {
        // Try load from Keychain
        if let existing = try loadFromKeychain() {
            return existing
        }
        
        // Generate new Ed25519 keypair
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeEd25519,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrLabel as String: "com.beechat.device-identity",
                kSecAttrApplicationTag as String: "com.beechat.device-identity"
            ]
        ]
        
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw error!.takeRetainedValue() as Error
        }
        
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw NSError(domain: "DeviceIdentity", code: 1)
        }
        
        // Export public key as raw bytes
        var pubError: Unmanaged<CFError>?
        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &pubError) as Data? else {
            throw pubError!.takeRetainedValue() as Error
        }
        
        // Derive deviceId from SHA-256 hash
        let hashed = SHA256.hash(data: publicKeyData)
        let deviceId = hashed.compactMap { String(format: "%02x", $0) }.joined()
        
        let identity = DeviceIdentity(
            deviceId: deviceId,
            publicKey: publicKeyData,
            publicKeyBase64Url: publicKeyData.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: ""),
            privateKey: privateKey
        )
        
        self.identity = identity
        return identity
    }
    
    func signChallenge(
        nonce: String,
        clientId: String,
        clientMode: String,
        role: String,
        scopes: [String],
        token: String?
    ) throws -> (signature: String, signedAtMs: Int, payload: String) {
        guard let identity = identity ?? (try? getOrCreateIdentity()) else {
            throw NSError(domain: "DeviceIdentity", code: 2)
        }
        
        let signedAtMs = Int(Date().timeIntervalSince1974 * 1000)
        
        // Build v3 payload (pipe-delimited)
        let payload = [
            "v3",
            identity.deviceId,
            clientId,
            clientMode,
            role,
            scopes.joined(separator: ","),
            String(signedAtMs),
            token ?? "",
            nonce
        ].joined(separator: "|")
        
        // Sign with Ed25519
        let payloadData = Data(payload.utf8)
        var signError: Unmanaged<CFError>?
        guard let signatureData = SecKeyCreateSignature(
            identity.privateKey,
            .signMessageEd25519,
            payloadData as CFData,
            &signError
        ) as Data? else {
            throw signError!.takeRetainedValue() as Error
        }
        
        // Base64url encode signature
        let signature = signatureData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        
        return (signature, signedAtMs, payload)
    }
}
```

### 2. Token Store (Swift)

```swift
import Security

protocol TokenStore: Sendable {
    func getDeviceToken() throws -> String?
    func setDeviceToken(_ token: String, scopes: [String]) throws
    func getDeviceTokenScopes() throws -> [String]
    func deleteDeviceToken() throws
}

final class KeychainTokenStore: TokenStore {
    private let service = "com.beechat.tokens"
    
    func getDeviceToken() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "deviceToken",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        
        return String(data: data, encoding: .utf8)
    }
    
    func setDeviceToken(_ token: String, scopes: [String]) throws {
        let data = Data(token.utf8)
        
        // Store token
        let tokenQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "deviceToken",
            kSecValueData as String: data
        ]
        
        // Try update first, then add
        var status = SecItemUpdate(tokenQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(tokenQuery as CFDictionary, nil)
        }
        
        guard status == errSecSuccess else {
            throw NSError(domain: "Keychain", code: Int(status))
        }
        
        // Store scopes separately
        let scopesData = try JSONSerialization.data(withJSONObject: scopes)
        let scopesQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "deviceTokenScopes",
            kSecValueData as String: scopesData
        ]
        
        status = SecItemUpdate(scopesQuery as CFDictionary, [kSecValueData as String: scopesData] as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(scopesQuery as CFDictionary, nil)
        }
        
        guard status == errSecSuccess else {
            throw NSError(domain: "Keychain", code: Int(status))
        }
    }
    
    func getDeviceTokenScopes() throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "deviceTokenScopes",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess,
              let data = result as? Data,
              let scopes = try JSONSerialization.jsonObject(with: data) as? [String] else {
            return []
        }
        
        return scopes
    }
    
    func deleteDeviceToken() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "deviceToken"
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: "Keychain", code: Int(status))
        }
    }
}
```

### 3. Gateway Client Connection (Swift)

```swift
actor GatewayClient {
    private let config: Configuration
    private let identityManager = DeviceIdentityManager.shared
    private let tokenStore: TokenStore
    
    struct Configuration {
        let url: String
        let gatewayToken: String  // For first connection only
        let clientId: String
        let clientVersion: String
    }
    
    func connect() async throws {
        // Load or create device identity
        let identity = try await identityManager.getOrCreateIdentity()
        
        // Load stored device token (if exists)
        let storedToken = try? tokenStore.getDeviceToken()
        let storedScopes = try? tokenStore.getDeviceTokenScopes()
        
        // Connect to WebSocket
        let wsUrl = URL(string: config.url)!
        let transport = WebSocketTransport(url: wsUrl)
        try await transport.connect()
        
        // Wait for connect.challenge
        let challenge = try await transport.waitForEvent("connect.challenge")
        guard let nonce = challenge.payload?["nonce"] as? String else {
            throw NSError(domain: "Gateway", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing nonce"])
        }
        
        // Sign challenge
        let scopes = storedScopes ?? ["operator.read", "operator.write"]
        let (signature, signedAtMs, payload) = try await identityManager.signChallenge(
            nonce: nonce,
            clientId: config.clientId,
            clientMode: "backend",
            role: "operator",
            scopes: scopes,
            token: storedToken ?? config.gatewayToken
        )
        
        // Send connect request
        let connectParams: [String: Any] = [
            "minProtocol": 3,
            "maxProtocol": 3,
            "client": [
                "id": config.clientId,
                "displayName": "BeeChat",
                "version": config.clientVersion,
                "platform": "macos",
                "mode": "backend"
            ],
            "role": "operator",
            "scopes": scopes,
            "auth": [
                "token": storedToken ?? config.gatewayToken
            ],
            "device": [
                "id": identity.deviceId,
                "publicKey": identity.publicKeyBase64Url,
                "signature": signature,
                "signedAt": signedAtMs,
                "nonce": nonce
            ]
        ]
        
        let helloOk = try await transport.request("connect", params: connectParams)
        
        // Store device token from response
        if let auth = helloOk["auth"] as? [String: Any],
           let deviceToken = auth["deviceToken"] as? String,
           let grantedScopes = auth["scopes"] as? [String] {
            try tokenStore.setDeviceToken(deviceToken, scopes: grantedScopes)
            print("✅ Stored device token with scopes: \(grantedScopes)")
        }
        
        // Now connected and ready for RPC calls
        print("✅ Connected to gateway")
    }
}
```

---

## Testing Checklist

- [ ] Device identity generated and persisted to Keychain
- [ ] Device identity reused across app restarts
- [ ] connect.challenge received and nonce captured
- [ ] Device signature generated with correct v3 payload format
- [ ] signedAtMs is current timestamp (not challenge timestamp)
- [ ] connect request sent with scopes array
- [ ] hello-ok received with auth.deviceToken
- [ ] Device token persisted to Keychain
- [ ] Device token scopes persisted
- [ ] Reconnection uses stored device token (not gateway token)
- [ ] sessions.list call succeeds (requires operator.read)
- [ ] chat.send call succeeds (requires operator.write)

---

## References

### OpenClaw Source Files

- `client-DkWAat_P.js` - GatewayClient implementation
- `device-identity-TBOlRcQx.js` - Device identity generation and signing
- `device-auth-tzV3Kb-2.js` - Device auth scope normalization
- `method-scopes-D3xbsVVt.js` - Method-to-scope mapping
- `operator-scopes.d.ts` - Operator scope definitions
- `device-bootstrap-profile-TTjBZgaz.js` - Bootstrap profile for pairing

### BeeChat Component 2 Spec

- `/Users/openclaw/projects/BeeChat-v5/Docs/Architecture/COMPONENT-2-GATEWAY-SPEC.md`

---

## Conclusion

**The correct authentication flow for BeeChat v5:**

1. **First connection:**
   - Generate device identity (Ed25519 keypair)
   - Connect with gateway token + device signature
   - Request scopes: `["operator.read", "operator.write"]`
   - Store device token from hello-ok response

2. **Subsequent connections:**
   - Load stored device identity
   - Load stored device token and scopes
   - Connect with device token + device signature
   - Re-request same scopes

3. **Key insight:** Channel plugins don't authenticate as external clients. BeeChat must use the device identity flow, which is the documented, supported method for external clients (Control UI, CLI, mobile apps).

**Next step:** Update COMPONENT-2-GATEWAY-SPEC.md to reflect the correct scope negotiation and device token persistence flow.
