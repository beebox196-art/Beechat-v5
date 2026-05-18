# Gate 2B — Rollback Plan

## Baseline Commits (Last Known Stable)

| Repo | Baseline Commit | Description |
|------|----------------|-------------|
| BeeChat-v5 | `8edfafa` | fix(AnyCodable): type-explicit Equatable switch for iOS compatibility |
| BeeChat-Mobile | `3ca8587` | (iOS baseline — unchanged) |

## Changes Since Baseline

| Commit | Change | Risk |
|--------|--------|------|
| `99e3b69` | Upgrade gateway protocol to v4 | Medium — protocol version bump + min/maxProtocol fields |
| `5b60f6c` | Always send device identity during handshake | Low — same result, more secure path |
| `bc26a9e` | Fix scroll: macOS 14 compat + whitespace jump fixes | Low — UI only |
| `6aa7aee` | Add deviceFamily to ClientInfo for auth v3 canonical string | Low — fixes signature mismatch |

## Rollback Procedure (macOS BeeChat)

If macOS BeeChat breaks after these changes:

```bash
cd /Users/openclaw/Projects/BeeChat-v5
git stash  # in case of uncommitted changes
git checkout 8edfafa -- .
swift build
cp .build/debug/BeeChatApp ~/Desktop/BeeChatApp.app/Contents/MacOS/BeeChatApp
xattr -cr ~/Desktop/BeeChatApp.app
# Remove resource forks that block codesigning
find ~/Desktop/BeeChatApp.app -name "._*" -delete
dot_clean -m ~/Desktop/BeeChatApp.app
codesign --force --deep --sign "Apple Development: beebox196@gmail.com (3GH395JXZT)" ~/Desktop/BeeChatApp.app
pkill BeeChatApp; sleep 2; open ~/Desktop/BeeChatApp.app
```

## Validation Checklist

After rollback, verify:
- [ ] BeeChat connects to gateway (check debug log at `/Users/openclaw/Desktop/BeeChat-debug.log`)
- [ ] No `DEVICE_AUTH_SIGNATURE_INVALID` errors
- [ ] State transitions: `disconnected` → `connecting` → `handshaking` → `connected`
- [ ] WebSocket shows ESTABLISHED: `lsof -i :18789 | grep BeeChat`

## Notes

- The baseline commit `8edfafa` was from **before** the v4 protocol upgrade. If the gateway has already upgraded to v4, rolling back to `8edfafa` may cause BeeChat to fail with `invalid request frame` because it sends protocol v3 while the gateway expects v4.
- If a rollback is needed, the safer approach is to roll back to `5b60f6c` (device identity fix) or `bc26a9e` (scroll fix) rather than the full baseline, since those are tested and working.
- **As of May 18, 2026**: All 4 commits are live and working. BeeChat connects successfully with device identity and full operator scopes.

## iOS Rollback

BeeChat-Mobile is at baseline `3ca8587` — no changes have been applied yet. When the iOS clientMode change is applied, add a separate rollback commit reference here.