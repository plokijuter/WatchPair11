# v8.1 — BLE Nearby-Action ACK refresh experiment

Status: candidate (8.1-1), gated behind a runtime pref. v8.0-3 behaviour is
the default; users opt in to test.

## Problem recap

watchOS 11.5 (Series 10+) emits a Nearby Action V2 BLE advertisement with
`type=0x14` that iOS 16.6's `bluetoothd` does not understand. The parser
falls through and ends up calling `-[CBDevice setNearbyActionV2Type:0x00]`.

`v8.0` BLOCKs that 0x00 setter to stop the device-class corruption that was
draining the **iPhone** battery (heavy `nanoregistryd` flapping). That fix
worked: 6796 BLOCKED entries today, no iPhone drain.

New symptom: **the Watch is now draining fast**. Live monitoring shows
bursts of ~250 BLOCKED/s. Hypothesis: because we drop the setter call
silently, the iPhone never fires the downstream "I parsed your nearby
action, here's my refreshed payload" path, so its outgoing
`_nearbyActionV2WiProxContext` stays stale. The Watch never sees the
implicit ack adv it expects → it retry-storms its scan-response payload.

## Background — what the iPhone normally does after a parse

`strings(1)` on `/home/plokijuter/legizmo/ios16-dump/bluetoothd` confirms:

- `-[CBDevice setNearbyActionV2Type:]` is the receive-side setter we already
  hook. It is the LAST thing the parser does on the inbound `CBDevice`.
- `-[CBAdvertiserDaemon _updateNearbyActionV2Payload:]` rebuilds the
  iPhone's OWN outgoing nearby-action payload from current state.
- `-[CBAdvertiserDaemon _wiProxUpdateAdvertising:]` and
  `_wiProxUpdatePayload:payloadData:advertiseRate:` push the rebuilt
  payload to the controller. `_nearbyActionV2WiProxContext` is the
  matching iVar.
- `-[CBDaemonServer _identitiesResolveNearbyDevice:]` and
  `_identitiesReevaluateDevices` are the post-parse identity resolution
  hooks; they implicitly drive the same chain.

So: parse → set type → resolve identity → update WiProx ctx → push outgoing
adv. Cutting the chain at "set type" stops the rest.

## Options considered

- **A** Don't BLOCK; set the type to last-known-good before the original
  setter. *Risk:* on first contact we have no last-known-good and would
  set 0x00 anyway, recreating the v8.0 drain.
- **B** Find the exact "send ack to Watch" function and force-call it.
  *Risk:* high — there's no obvious single ack symbol; the ack is implicit
  via WiProx adv.
- **C** Hook `_parseNearbyActionV2Ptr:end:` and forge a SUCCESS result.
  *Risk:* feeds bogus device-class / target-data into the rest of the
  pipeline. Same class of corruption v8.0 was added to prevent.
- **D** Hook earlier (pre-store). *Risk:* needs reverse engineering more
  internals; high effort, high regression surface.

## Picked: hybrid A/B

Keep v8.0's BLOCK on `setNearbyActionV2Type:0x00` (proven safe). On each
blocked call, if the experiment pref is on, **trigger the iPhone's own
outgoing-payload refresh** by calling
`-[CBAdvertiserDaemon _updateNearbyActionV2Payload:nil]` (fallback:
`_wiProxUpdateAdvertising:`). The iPhone re-broadcasts its current state;
the Watch sees the refreshed iPhone adv and is satisfied that someone is
listening. This is the same path the legitimate parser would have hit had
0x00 been a real type — we just kick it without contaminating the
inbound `CBDevice`.

Why this should work: the Watch's retry storm is driven by "I'm not seeing
an iPhone WiProx adv with my expected counter / state". Refreshing iPhone's
adv is the very signal it's waiting for, even if our refresh is
content-identical — the new TX timestamp / payload counter is enough.

Coalesced to once per 250 ms so we never out-spam the BLE stack.

## Implementation

`Tweak.xm`, around the existing `hooked_setNearbyActionV2Type`:

- New `ackExperimentEnabled()` reads
  `CFPreferencesCopyAppValue(WP11AckExperiment, com.apple.bluetoothd)`.
  Also honours env var `WP11_ACK_EXPERIMENT=1`.
- New `resolveAdvertiserDaemon()` probes
  `+sharedAdvertiser/+sharedInstance/+sharedDaemon/+defaultAdvertiser/+shared`
  on `CBAdvertiserDaemon` and caches the singleton.
- New `triggerOutgoingAckRefresh()` calls `_updateNearbyActionV2Payload:nil`
  (fallback `_wiProxUpdateAdvertising:nil`) with a 250 ms cooldown. Logs
  the first 5 firings then 1-in-50.
- The existing BLOCK path now also increments a counter and, if enabled,
  calls `triggerOutgoingAckRefresh()`. Default off → byte-for-byte v8.0.

No other file changed.

## Testing

1. Install: `dpkg -i com.watchpair11_8.1-1_iphoneos-arm64.deb` (or via
   Sileo). Reboot is NOT required; the experiment is off by default and the
   tweak file already runs in `bluetoothd`.
2. Enable: SSH to iPhone (`ssh iphone`) and run
   `defaults write com.apple.bluetoothd WP11AckExperiment YES && killall -9 bluetoothd`.
3. Verify in `/var/tmp/wp11.log`:
   - `[BLE-ACK] WP11AckExperiment = ON` (one line at startup)
   - `[BLE-ACK] resolved CBAdvertiserDaemon via +sharedAdvertiser -> 0x...`
     (or another candidate). If we see "could NOT resolve" the experiment
     is a no-op and we need a different singleton accessor.
   - `[BLE-ACK] fired _updateNearbyActionV2Payload: (#1)` then occasional
     `(#50)`, `(#100)`. We should see far FEWER than the BLOCKED rate
     because of the 250 ms coalesce window.
   - `[BLE-ACK] block#... -> refresh#...` summary every 500 blocks.
4. On the Watch: read battery-drain rate at 5/15/30 min after enable.
   Pre-experiment: roughly N% per 30 min (record actual). Target: at
   least 30 % reduction.
5. Disable rollback if anything regresses:
   `defaults delete com.apple.bluetoothd WP11AckExperiment && killall -9 bluetoothd`.
   That returns to exact v8.0-3 behaviour.

## What could go wrong

- `+sharedAdvertiser` (or any other candidate) returns nil → log says
  "could NOT resolve CBAdvertiserDaemon singleton" and the experiment is
  silently inert. Need to enumerate `objc_getClassList` for the live
  instance, or hook `-[CBAdvertiserDaemon init]` to capture it. Easy
  follow-up.
- `_updateNearbyActionV2Payload:` actually requires a non-nil change-context
  dict and will throw / no-op when called with nil. Catch block logs the
  exception and we move on; in that case the fallback `_wiProxUpdateAdvertising:`
  may help, otherwise we need to capture a real arg from a normal call
  via NSInvocation interception.
- Refreshing iPhone's adv at the WRONG cadence could itself spam the
  Watch in a different way. Coalesced to 4 Hz max — well below BLE adv
  rate caps. If the Watch dislikes a stale-content refresh we'll see
  paired-state churn in `nanoregistryd` (it isn't injected on v8.x, so
  the symptom would be Watch UI showing "iPhone disconnected" briefly).

## Confidence

Honest read: medium-low. The model fits the symptom, but I can't prove
without on-device traces that the WiProx push actually constitutes the
ack the Watch is waiting for. The retry storm could equally be driven by
GATT-layer expectations that BLE adv refresh won't satisfy. Worst case
this is a no-op; best case it cuts Watch drain by 30-70 %. Either way,
default-off keeps existing users safe.
