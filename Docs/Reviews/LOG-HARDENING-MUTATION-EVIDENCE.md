# LOG-HARDENING implementer mutation evidence

Date: 2026-09-24

Branch: `fix/log-hardening`

Baseline: `origin/develop` at `682e701ddb2dc21bdee7cb36fca61fc8d55fcfa6`

Each mutation below was applied to the working tree, its focused test was run and
observed red, and the mutation was then removed. The final green suite is separate
evidence; Kieran must independently repeat these red runs under E5.

| Guard | Temporary mutation | Focused command | Recorded red result |
|---|---|---|---|
| G1 | Added `/Users/mutation/Desktop/secret.log` to `BeeChatGateway` | `swift test --filter LoggingPolicyTests.testG1SourcePathPolicy` | Failed with both the unexpected absolute-path and non-UI Desktop-component diagnostics. |
| G2 | Disabled the `existing + record > maximumBytes` trim branch | `swift test --filter LoggingPolicyTests.testG2WriterBoundsOneFileAndUsesPrivatePermissions` | Failed: observed 4,000-byte file exceeded the 1,024-byte fixture cap. |
| G3 | Changed the default gate to enabled unless explicitly `0` | `swift test --filter LoggingPolicyTests.testG3DefaultGateCreatesNoFileUnderInjectedHome` | Failed the disabled-state assertion and both no-directory/no-file assertions. |
| G4 handshake | Restored `debugLog("Sending handshake: \(text.prefix(500))")` | `swift test --filter GatewayLoggingSecurityTests.testG4ChallengeHandshakeAndReconnectNeverExposeCredentials` | Failed eight assertions: both sentinels appeared in file capture, disk file, print capture, and os-log mirror capture. |
| G4 URL | Restored logging of `url.absoluteString` after transport connect | same G4 command | Failed four assertions: the gateway-token sentinel appeared in all four captured outputs. |

G1 also has must-fail split-literal and must-pass bare-validator fixtures. G4's fake
transport proves two credential-bearing handshakes occur around a forced transport
failure/reconnect before inspecting all diagnostic sinks.
