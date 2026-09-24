# LOG-HARDENING implementer mutation evidence

Date: 2026-09-24

Branch: `fix/log-hardening`

Baseline: `origin/develop` at `682e701ddb2dc21bdee7cb36fca61fc8d55fcfa6`

Each mutation below was applied to the working tree, its focused test was run and
observed red, and the mutation was then removed. The final green suite is separate
evidence; Kieran must independently repeat these red runs under E5.

| Guard | Temporary mutation | Focused command | Recorded red result |
|---|---|---|---|
| G1 split literal | Added `"/Users/" + "alice/Desktop/secret.log"` to `BeeChatGateway` | `swift test --filter LoggingPolicyTests.testG1SourcePathPolicy` | Failed with both `/Users/alice/Desktop/secret.log` and Desktop-component diagnostics, proving the production scan normalizes fragments before both checks. |
| G1 App Desktop | Added `FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)` to `Sources/App/Utils/BeeChatLogger.swift` | same G1 command | Failed with `Sources/App/Utils/BeeChatLogger.swift: .desktopDirectory`, proving App sources are in scope. |
| G2 | Disabled the `existing + record > maximumBytes` trim branch | `swift test --filter LoggingPolicyTests.testG2WriterBoundsOneFileAndUsesPrivatePermissions` | Failed: observed 4,000-byte file exceeded the 1,024-byte fixture cap. |
| G3 | Changed the default gate to enabled unless explicitly `0` | `swift test --filter LoggingPolicyTests.testG3DefaultGateCreatesNoFileUnderInjectedHome` | Failed the disabled-state assertion and both no-directory/no-file assertions. |
| G4 handshake | Restored `debugLog("Sending handshake: \(text.prefix(500))")` | `swift test --filter GatewayLoggingSecurityTests.testG4ChallengeHandshakeAndReconnectNeverExposeCredentials` | **20/20 RED, 0 false greens, 0 unexpected failures, re-verified after N-1.** Every run failed exactly eight assertions: both sentinels appeared in file capture, disk file, print capture, and os-log mirror capture. |
| G4 URL | Restored logging of `url.absoluteString` after transport connect | same G4 command | Failed four assertions: the gateway-token sentinel appeared in all four captured outputs. |

G1 routes both its production scan and fixtures through the same adjacent-fragment
normalization, and its Desktop-component rule covers every Swift file under `Sources`,
including the App target. It also retains a must-pass bare-validator fixture.

G4's outbound frame encoders use `.sortedKeys`. The fixture proves two
credential-bearing handshakes occur around a forced transport failure/reconnect and has a
load-bearing precondition that both sentinels are present inside the exact first 500
characters the restored sink logs. The 20-run result above was collected after precreating
the fixture's bounded log file; all 20 runs produced the expected eight assertion failures
with no timing/file-creation exceptions.

N-1 fixture-race correction: the fake transport now waits for an explicit reconnect signal
from the test after the initial `connect()` has returned. This prevents the forced transport
error from moving the actor back to `.connecting` before `connect()` can observe the settled
`.connected` state, without weakening the production code-99 invariant. On the clean tree,
the focused G4 test passed **50/50** with **0 false-REDs and 0 unexpected failures**. With the
exact handshake-log mutation restored, it went **20/20 RED**; every run contained exactly the
eight credential-sink assertions, with **0 wrong-reason runs**, **0 unexpected failures**, and
**0 precondition failures**. The mutation was then removed before the final green verification.
Final clean-tree verification: `swift test` passed **164 tests, 1 skipped, 0 failures**, and
`swift build -c release` completed successfully (existing compiler warnings only).
