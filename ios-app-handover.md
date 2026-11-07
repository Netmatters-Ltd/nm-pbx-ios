# Shared extension status: iOS app changes

Handover for the agent implementing the iOS side of the `shared-extension-status` change. The design was made in the NMPBX Portal repository (`openspec/changes/shared-extension-status/`), and the phone server and Portal sides are built there. The Android app (from version 6.5) and the Windows app (from version 6.4.0) have already been updated and work as designed, so the server side has been proven end to end with two apps. This file holds everything the iOS app needs; you should not need the Portal repository.

Matching tasks in the Portal's plan: 8.0 to 8.4.

## Why

One extension can be signed in on several NMPBX apps (Android, iOS, Windows). Today each app keeps its own status. Setting Away on the desktop leaves the phone showing whatever it last chose, and when the phone comes back to the foreground it republishes its own saved status, which can undo a newer choice made elsewhere.

Flexisip cannot fix this alone. It merges every app's presence into one document, pools every RPID activity into a single `<person id="">` in no stable order, and drops the time the status was chosen. Nothing in the merged document says which app set which status, or when.

So the phone server now keeps one **shared status** per extension and publishes it into Flexisip as its own tuple. Each app says exactly what its user chose and when, and every app follows the server's shared status.

## How it fits together

```
 Android app ── PUBLISH (tuple nmpbx-c.<status>.<chosen>.<device>) ──┐
 iOS app     ── PUBLISH ─────────────────────────────────────────────┤
 Windows app ── PUBLISH ─────────────────────────────────────────────┤
                                                                     ▼
                                                     Flexisip presence server
                                                                     │ NOTIFY (merged)
                                                                     ▼
                                         status service on the phone server
                                         (dnd-presence.py, newest choice wins,
                                          also takes Portal requests and *78/*79/*76)
                                                                     │
                                         PUBLISH (tuple nmpbx-s.<status>.<chosen>.<source>)
                                                                     ▼
                                                     Flexisip presence server
                                                                     │ NOTIFY (merged)
                                                                     ▼
                              every app (own extension and colleagues), wallboard, routing
```

The app keeps using the Linphone SDK's normal presence publishing and subscriptions. There is no new connection or API.

## Switched on per customer

Shared status is switched on per customer by a Netmatters administrator, only once that customer's apps are updated. While it is off, the server publishes no `nmpbx-s.` tuples and ignores `nmpbx-c.` ids.

**The updated app must work exactly as today when there is no `nmpbx-s.` tuple.** The app never needs to know whether the customer is switched on: the presence of an `nmpbx-s.` tuple for an extension is the signal.

## Wire format

### What the app publishes: the choice tuple id

Every publication from the updated app uses this tuple id:

```
nmpbx-c.<status>.<chosen>.<device>
```

| Part | Value |
|---|---|
| `<status>` | `available`, `away`, `busy` or `dnd` (lower case) |
| `<chosen>` | Unix time in **seconds** when the user chose the status (or the message). `0` means "no choice yet" and can never win |
| `<device>` | Stable per-installation token, 1 to 64 characters of `A-Z a-z 0-9 -` only |

The server matches it with exactly this pattern, so anything else is silently ignored:

```
^nmpbx-c\.(available|away|busy|dnd)\.(\d{1,12})\.([A-Za-z0-9-]{1,64})$
```

Example: `nmpbx-c.away.1793963980.3f2a9c1e-7b4d-4e0a-9d1b-55c0a1e2f003`

Rules:

- The id is the same for every publish of the same choice. It changes only when the user makes a new choice. (Today the app generates a new random id each publish; that must stop.)
- Keep the custom message in the tuple's `<note>`, as today.
- **Keep publishing the RPID activity exactly as today** (`<away/>`, `<busy/>`, `<other>dnd</other>`, none for Available). Older readers, the old DND rules and customers who are switched off depend on it.
- `<chosen>` is when the user chose it, not when it is published. Republishing an old choice (on returning to the foreground, after a refresh, on re-registration, after a network change) carries its original time.
- Changing only the message counts as a new choice: same status, new `<chosen>`.
- A new installation, or one whose settings were cleared, publishes `<chosen>` = `0` until it has seen the shared status.
- `<device>`: use the account's `+sip.instance` UUID (strip `urn:uuid:`, `<`, `>` so only letters, digits and hyphens remain). The Android app does this and Windows is moving to it, so the Portal can later match a status to the device that set it. Only if the SDK does not expose it, generate a UUID once and keep it in the app's config. It must differ for every installation, because two publications with the same tuple id hide each other in Flexisip.
- A `<chosen>` more than 60 seconds ahead of the server's clock is treated as "now" by the server. A slow clock simply loses to newer choices made elsewhere.

### What the server publishes: the shared status tuple

```
nmpbx-s.<status>.<chosen>.<source>
```

`<source>` is one of `app-<device>`, `portal-<user id>` or `fc` (feature code `*78`/`*79`/`*76` or FreePBX's user panel). Parse it with:

```
^nmpbx-s\.(available|away|busy|dnd)\.(\d{1,12})\.([A-Za-z0-9-]{1,64})$
```

The full document the server publishes, as it reaches subscribers merged with other tuples:

```xml
<presence xmlns="urn:ietf:params:xml:ns:pidf"
          xmlns:dm="urn:ietf:params:xml:ns:pidf:data-model"
          xmlns:rpid="urn:ietf:params:xml:ns:pidf:rpid"
          entity="sip:102@example.nmpbx.uk">
  <tuple id="nmpbx-s.away.1793963980.portal-12">
    <status><basic>open</basic></status>
    <note xml:lang="en">Holiday, back 3 Feb</note>
  </tuple>
  <dm:person id="nmpbx-s-person">
    <rpid:activities><rpid:away/></rpid:activities>
  </dm:person>
</presence>
```

- Away, Busy and Do Not Disturb: `<basic>open</basic>` plus the RPID activity, so colleagues see it with no app connected.
- Available: `<basic>closed</basic>` and no activity, so the shared status alone never makes an empty extension look online. Do not treat a closed `nmpbx-s.` tuple as "offline"; read its status from the id.
- No `<note>` element means an empty message.
- Take the status from the **tuple id**, not from the activities. Flexisip pools every activity from every publisher into one person, in no stable order.

### Other tuples you will see

| Tuple id | Publisher | What to do |
|---|---|---|
| `nmpbx-s.…` | Status service | The shared status. Prefer it |
| `nmpbx-c.…` | Updated NMPBX apps (Android and Windows now) | Another app's choice. Never follow it directly |
| `nmpbx-callstate…` | Call-state bridge (on a call) | Keep showing "on the phone" as today |
| anything else | Older apps, handsets | Today's behaviour only when there is no `nmpbx-s.` tuple |

### Reading tuples through the SDK

The SDK controls the XML. liblinphone's `PresenceService::toXml` writes only `<basic>` and `pidfonline:online` inside `<status>`, and its parser keeps only those, the tuple id, `<contact>`, `<timestamp>` and per-tuple notes. Custom XML elements are not an option, which is why the data travels in the tuple id.

What is available (public in the Swift wrapper):

- Writing: build a `PresenceModel`, add a `PresenceService` with its id set to `nmpbx-c.…`, add the note to that service, add the activity as today, and set the core's (or the account's) presence model.
- Reading: from a friend's presence model, iterate `getNthService(i)`, read each service's `id` and its notes with `getNthNote(j)`.

**Important:** the SDK writes whatever id the model's service has, and generates a random one only when the model has no service (for example a bare `createPresenceModel()` with just an activity). So always add a service carrying the id. This was confirmed from the 5.4.114 source, and in practice on Android (SDK 5.5.16) and Windows (5.4.114): every publish, including the SDK's own refreshes and the start-up publish, carried exactly the id the app had set. The spike below still checks it on the iOS build.

## What the other apps found

These come from the Android and Windows work and should save you some checking:

- The SDK kept the tuple id and note unchanged on automatic refreshes, rebuilding the PUBLISH from the same model with only the timestamp updated.
- The start-up publish carried the saved choice with its original time.
- A clean exit sent `PUBLISH` with `Expires: 0` and no body.
- Android's `+sip.instance` was readable and is used as its device token.
- Windows first used a generated UUID to protect against a copied config file. We decided against that: if two devices shared a `+sip.instance`, registration would already be broken, so it adds no protection, and it stops the Portal matching the device.

## Behaviour to implement

### 1. Publish the choice (task 8.1)

In `PresenceViewModel`:

- Store `chosen` alongside the existing saved status and note in the app config.
- Store the device token once (or read `+sip.instance` each time, if it is stable).
- Every publish uses the `nmpbx-c.` tuple id, the note, and today's activity. Check every place the app builds or sets a presence model, so none falls back to a model with no service.
- Limit the custom message input to **80 characters** (same as the Portal, the server and the other apps). The server also trims notes to 80 printable characters on one line.
- The app SHALL only publish a status the user chose, or one it is following. Never change the published status by itself (for example because of a call).

### 2. Follow the shared status for its own extension (task 8.2)

Replace the one-shot `restoreOrGoOnline()` self-sync. Today it publishes the saved status, reads the merged document once and takes the first status that is not the call-state bridge's. That "worked" only by luck of activity order.

New behaviour:

1. Subscribe **permanently** to the app's own extension, as a friend that is not shown in contacts, whether or not the user has their own extension in contacts. Keep the listener for as long as the account is registered.
2. On each NOTIFY for the own extension, look for an `nmpbx-s.` tuple.
   - **If there is one:** show its status, note and `chosen` as the app's own, save them, and publish them with this app's own device token and **that same `chosen`**: `nmpbx-c.<shared status>.<shared chosen>.<my device>`. The server ignores this as not newer, so following never creates a new choice. Never republish with a new time when following, or two apps will ping-pong.
   - **Pending-choice exception:** if the user made a choice on this device in the last 30 seconds and the `nmpbx-s.` tuple does not yet show it (compare status, note and `chosen`), keep showing the user's choice. After 30 seconds, follow the server regardless.
   - **If there is none:** behave exactly as today. This is the switched-off case.
3. On starting or returning to the foreground, publish the saved choice as today, with its original `chosen`. If the server holds something newer, it ignores this, and the next NOTIFY brings the shared status for the app to follow. Use the saved status only until the server's presence arrives, and only when it carries no `nmpbx-s.` tuple.
4. Never take the app's own status from another app's `nmpbx-c.` tuple, an old-style tuple, or the first activity in the merged person.
5. Follow the shared status whatever the app's own saved `chosen` says. The server is the judge of "newest"; a phone with a slow clock must still show a newer status set elsewhere.

Timing requirement: in the foreground, show a changed shared status within **5 seconds**; on returning to the foreground, as soon as the server's presence arrives.

When the app is woken in the background only to take a call (PushKit and CallKit), keep today's presence behaviour. It does not need to follow or publish anything extra then, and must never publish a new choice.

### 3. Colleagues (task 8.3)

When showing another extension's presence:

- If its document has an `nmpbx-s.` tuple, take the chosen status and message from it, and do not pick between disagreeing statuses from individual apps' tuples or the pooled activities.
- Otherwise, show presence as today.
- "On the phone" from the call-state bridge is still shown as today, alongside a shared Busy for example.
- A colleague whose shared status is Away, Busy or DND shows that status and message even with no app of theirs connected (the server's tuple is open). A shared Available with nothing connected must not make them look online.

### 4. Things not to change

- Registration, push, CallKit, calls and the call-state display.
- The RPID activities published, as described above.
- There is no Offline or "appear offline" status, and statuses do not expire on a date.

## Status mapping

| UI status | Tuple id token | RPID activity (unchanged) | Phone system DND (server side, once switched on) |
|---|---|---|---|
| Available / Online | `available` | none | off |
| Away | `away` | `<away/>` | on |
| Busy | `busy` | `<busy/>` | off |
| Do Not Disturb | `dnd` | `<other>dnd</other>` | on |

DND is applied on the server, not in the app. Feature codes count as choices: `*78` becomes Do Not Disturb (or stays Away if already Away), `*79` becomes Available, both keeping the current message. The app simply follows the resulting `nmpbx-s.` tuple.

## Known iOS behaviour today (from test-a, Oct to Nov 2026)

- On backgrounding, the app sends `PUBLISH` with `Expires: 0` but stays registered for push. This is fine: the server's tuple keeps the status visible while the app is in the background.
- It starts a new publication each time it is opened, with a new random tuple id on every publish.
- It removed its publication cleanly in our tests, except after a connection problem, when an orphaned publication can last up to 600 seconds (the presence server's granted expiry). With shared status on, an orphan no longer changes anyone's status (it is an old choice).
- With CardDAV contacts that have phone numbers, it also subscribes to `;user=phone` URIs, which never carry presence. Not a problem, but don't mistake them for the own-extension subscription.
- Registrar User-Agent looks like `NMPBXiOS/v6.1.6 (iPhone) LinphoneSDK/5.5.0`. Keep that format, including `NMPBX` at the very start (Flexisip relies on it to pass activities through to our apps). The Portal parses `NMPBXiOS/<version> (<description>)` for its app version inventory, and a per-customer minimum iOS version decides when the customer can be switched on. Tell us the first version that ships this change so we can set it.

## Step 0: spike first (task 8.0)

Before building the rest, in a test build on the iOS app's current SDK (please tell us which version):

1. Set a fixed tuple id `nmpbx-c.busy.<now>.<device>` on the published model, with a note.
2. On test-a, subscribe to the extension and confirm the id and note arrive unchanged, including after the SDK's own refreshes, the publish it makes on registration, returning to the foreground, and a network change (Wi-Fi to mobile data):
   ```sh
   ssh claude-nmpbx@test-a.nmpbx.uk -i claude-nmpbx
   /usr/local/bin/presence-probe.py subscribe --ext <ext> --domain <domain> \
       --as-ext <another ext> --user-agent NMPBX-Probe/1.0 --watch 3
   ```
   The probe's User-Agent must start with `NMPBX` so Flexisip passes the activities through.
3. Confirm the app can read another tuple's id and notes via `getNthService` / `getNthNote` on a friend's presence model. The updated Android and Windows apps on the same extension are a ready source of `nmpbx-c.` tuples, and a switched-on test customer gives `nmpbx-s.` tuples.
4. Confirm the SDK exposes `+sip.instance` for the device token, and that it stays the same across app restarts and updates. Also check whether restoring an iPhone backup onto a new phone carries the same `+sip.instance` across; if it does, tell us, as that would affect registration as well as this change.

Report what was found before going further. If the SDK rewrites or drops the id, the design needs revisiting.

## Testing (task 8.4)

Test against test-a with a Netmatters colleague who can switch the customer on and off in the Portal and set statuses there. The updated Android and Windows apps can share the extension for the cross-app checks.

**Switched off** (no `nmpbx-s.` tuples):
- Status, message and DND work as today, including alongside an older app version on the same extension.
- Colleagues' presence, the wallboard and DND all unchanged.

**Switched on:**
- Set Away with a message on Windows (or Android); iOS in the foreground shows it within 5 seconds.
- Set Away on iOS; Windows and Android show it within 5 seconds.
- Set Away on iOS, background it, set Busy with "On site" elsewhere, reopen iOS: it shows Busy "On site" and never flips back to Away.
- Take a call while backgrounded (woken by push): the shared status does not change.
- Switch between Wi-Fi and mobile data in the foreground: the same choice is republished with its original time, and a newer shared status is still followed.
- New installation on an extension whose shared status is Away "Holiday, back 3 Feb": shows that status and does not change it.
- New installation on an extension with no shared status: shows Available; the first choice becomes the shared status.
- Status set from the Portal reaches the foreground app within 5 seconds.
- `*78` from a desk phone on the same extension shows as Do Not Disturb in the app.
- Phone clock set two minutes slow (turn off automatic date and time) still shows a newer status set on the desktop.
- Own extension not in contacts: still follows.
- Colleague with conflicting app statuses shows the shared one; colleague on holiday with no app connected shows Away and the message.
- Choose Away then Available quickly: settles on Available with no flicker back.
- A message of 81 characters cannot be typed.
- The server's log (`journalctl -u dnd-presence -f` on test-a) shows each choice, and "ignored, newer held" for older republished ones. Following the shared status must log no new choice.

## Requirements (from the spec, `app-status-sync`)

- **Apps say which status was chosen and when.** Every publication states the chosen status, when it was chosen and a per-installation device id, in a form the server and other apps can read. Republishing keeps the original time. Changing the message counts as a new choice. No automatic status changes. A new installation states a choice that can never win until it has seen the shared status.
- **Custom messages are at most 80 characters.**
- **Apps follow the shared status for their own extension.** Watch the own extension regardless of contacts; show a changed shared status within 5 seconds in the foreground; follow it whatever the app's own saved time says, except for at most 30 seconds while the user's own choice on this device has not yet been taken up; republish with the original time when following. On starting or waking, use the saved status only until the server's presence arrives, and only when there is no shared status. Never take a status from another app's publication or the first status in the merged presence.
- **Apps show colleagues' shared status** where published, falling back to today's behaviour; on-a-call shown as today.
- **All three apps behave the same.** An updated app works as today where switched off; an older app keeps registering, calling and showing colleagues where switched on.
