# 025 — Murmur Pro: scope & design

**Status:** approved direction (Matt, 2026-08-10); phase 1 not yet started.
**Canonical home:** this file, on `main` of the (now PRIVATE) `Murmur` repo.
**Repos:** app = `Murmur` (taken private 2026-08-10; Pro work on the `pro`
branch, never merged to `main` until launch); backend = `Murmur-server`
(private, forever). `Murmur-updates` stays PUBLIC — its release assets are the
Sparkle feed.

## Thesis

**Free** = local dictation, unlimited, forever — runs on the user's Mac, costs
us nothing, no account required. The install funnel.
**Pro** = the cloud (dictation, file transcription with speaker labels, AI
cleanup) plus file/batch transcription on any engine — a real account the user
signs into, manages, and can cancel any time.

The line is drawn by value, not purely by engine: cloud features cost real
money per minute and justify recurring billing; file transcription is the
feature MacWhisper charges €59 for, so it stays paid even when it runs
locally.

## Tiers

| | Free | Pro — $4.99/mo · $39/yr (recommended) |
|---|---|---|
| Push-to-talk dictation | Local (WhisperKit), unlimited | + cloud realtime streaming |
| File & batch transcription | — | Yes, with speaker labels (xAI, ≤20 speakers), TXT/SRT/VTT export |
| AI cleanup / transforms | — | Yes, no key needed |
| Account | none | Sign in with Apple / Google |
| Minute pool | — | 1,000–1,500 min/mo shared (final size: open decision) |
| BYO API keys | buried, grandfathered | n/a |
| Later | — | system-audio (meeting) capture |

Market anchors: MacWhisper €59 one-time (files only, no dictation, free tier
on small models); subscription dictation apps $8–15/mo. $39/yr reads "cheaper
than MacWhisper" outright.

## Unit economics (verified 2026-08-10)

Providers: ElevenLabs Scribe realtime $0.39/hr, batch $0.22/hr (post
June-2026 cut). xAI Grok STT streaming $0.20/hr, **batch $0.10/hr with
diarization included** (word-level speaker IDs, ≤20 speakers — launched
April 2026).

**Decided:** files route to xAI batch. Dictation engine (realtime) is an open
quality call — cost delta is pennies at dictation volumes; provider routing
lives server-side so it is reversible without an app update.

| Subscriber profile | Usage/mo | Cost | Margin on $4.99 |
|---|---|---|---|
| Typical dictation | 100 min | $0.33–0.65 | 87–93% |
| Heavy dictation | 300 min | $1.00–1.95 | 61–80% |
| Dictation + weekly meeting files | 100+240 min | $0.73–1.05 | 79–85% |
| Pool ceiling, all files (xAI batch) | 1,500 min | $2.50 | 50% |
| Pool ceiling, all realtime | 1,000 min | $3.33–6.50 | ~break-even |

The pool is an abuse guard, not a revenue lever: one meeting file eats 60 min
in a click, so size for the file use-case and soft-warn at 80%; never hard-cut
mid-dictation.

## Accounts & subscription management (decided)

- **Auth + user store:** Supabase — Auth ships Apple + Google sign-in;
  Postgres holds users, subscription state, usage counters. OAuth only, no
  passwords.
- **Billing:** Paddle as merchant of record (VAT handled). Checkout in the
  browser tied to the signed-in email; Paddle webhooks update subscription
  state in Supabase. "Manage subscription" opens Paddle's hosted customer
  portal (update card, switch plan, cancel) — the compliant cancellation flow
  is theirs, not ours. Note: Paddle Billing does not mint license keys — with
  accounts we don't need any; entitlement is the account's subscription row.
- **Entitlement:** app holds a Supabase session; the proxy validates the JWT
  and checks subscription + pool per request. Cached client-side with an
  offline grace window so a flaky network never blocks dictation mid-hold.
- **Free stays account-free.** Sign-in appears exactly once: first tap on a
  Pro feature.

## Architecture

```
Murmur.app ──OAuth──────────────► Supabase (Auth · users · sub state · usage)
    │                                  ▲                    ▲
    │ WSS dictation / HTTPS files      │ entitlement+pool   │ webhooks: sub status
    ▼                                  │                    │
Murmur proxy (JWT check · metering · provider routing)   Paddle (checkout ·
    ├──► ElevenLabs / xAI streaming (dictation — engine TBD)  customer portal · VAT)
    └──► xAI Grok STT (batch files + diarization; cleanup/transform LLM)
```

Proxy = one small always-on service (Cloudflare Workers + D1/KV, or a $5 VPS)
in `Murmur-server`: JWT validation, WSS relay for realtime, upload endpoint
for batch, usage counter. **Scope fact:** "cloud" in Murmur is ASR *and* the
xAI-backed cleanup/transforms (`TransformRunner`, `CleanupService`) — both
must be proxied or Pro users lose cleanup when BYO keys are buried.

## Pre-launch secrecy (revised 2026-08-10, same day)

The `Murmur` app repo was **taken private** (Matt: nobody was watching), which
replaced the planned private-fork split. Verified after the flip: the live
appcast contains zero links to the app repo, and the feed + stable DMG still
return 200 anonymously. Rules that remain:

- **`Murmur-updates` stays PUBLIC, permanently** — its release assets ARE the
  Sparkle feed; taking it private kills updates for every installed copy.
- **Pro work lives on the `pro` branch** (plus feature branches off it),
  never merged to `main` until launch. `main` stays free-app-only because
  `publish-sparkle.sh` ships whatever `main` contains — a premature merge
  would put dormant Pro code in the next free DMG.
- Free fixes land on `main` as today; `pro` merges `main` regularly.
- **Backend lives only in `Murmur-server`** (private forever).
- Pre-launch Pro beta builds, if wanted, get a separate private appcast URL.
- **If the repo ever goes public again**, everything committed while private
  (this file's pricing, Pro history) becomes visible — that future decision
  needs a deliberate scrub-or-accept step.
- The launch-day source-visibility question from Rev 3 is largely moot while
  the repo is private; it returns only if Matt re-publicizes.

## Build order — one-session slices (briefs point here; do not restate)

1. **Accounts + billing** (`Murmur-server`) — opens with the **SIWA spike**:
   Sign in with Apple in a Developer ID (non-App-Store) app wired to Supabase
   — the least-verified assumption in this plan; kill it first. Then Supabase
   project, Paddle product + portal, webhook → sub state. Exit: sign in on a
   test build, subscribe, cancel from portal, state visible in Postgres.
2. **Proxy + metering** (`Murmur-server`) — includes a spike verifying the
   chosen host can originate/relay WSS to the ASR provider. JWT validation,
   realtime relay, batch endpoint, cleanup relay, minute counter. Exit: a
   signed-in subscriber dictates and transcribes a file end-to-end on our
   keys.
3. **App: sign-in, account screen, gating, BYO burial** (`pro` branch) —
   sign-in UI, account screen (plan, minutes, manage/cancel), cloud through
   proxy, BYO behind advanced settings, grandfather detection. Local
   hardening pass rides along (the local path is the least exercised — see
   memory: 985/1000 dictations are cloud). Exit: fresh install is Free-local;
   sign-in + subscribe unlocks cloud.
4. **File transcription + speakers + export** (`pro` branch) — drag-drop /
   picker, progress UI, transcript view with speaker labels, TXT/SRT/VTT.
   Cloud via xAI batch; local WhisperKit path exists but ships Pro-gated (no
   speaker labels locally).
5. **Batch queue** (`pro` branch) — queue in front of phase 4.
6. **System-audio capture** (`pro` branch, later) — Core Audio taps, new TCC
   permission. Local diarization stays parked; cloud diarization ships in
   phase 4.

## Open decisions

- **Dictation engine:** xAI streaming vs ElevenLabs realtime — quality call
  from live use; server-side routing makes it reversible.
- **Pool size:** recommend 1,500 min/mo (funded by xAI batch pricing).
- **Price:** recommend $4.99/mo · $39/yr.
- **Grandfathering:** recommend existing BYO keys work forever; optionally
  gift early users 6 months of Pro at launch.
- **Free trial:** recommend 14-day, no card.
- **Launch-day source strategy:** moot while the repo is private; revisit
  only if it ever goes public again (see Pre-launch secrecy).

## Risks

- **Ops burden is permanent** — uptime, abuse, provider-price exposure.
  Mitigation: BYO fallback, boring infra, quarterly price re-check.
- **Accounts widen the surface** — token refresh bugs, account deletion (a
  legal requirement), support email. OAuth-only keeps the worst out.
- **SIWA-outside-App-Store** — phase-1 spike kills or confirms it first.
- **Local becomes load-bearing for Free** — hardening rides with phase 3.
- **Pool abuse** — xAI batch pricing caps a maxed 1,500-min pool at $2.50.
- **Premature merge to `main`** — Pro code on `main` ships in the next free
  DMG even with a private repo. The `pro`-branch discipline is the guard.
- **Crowded market** — the edge is "dictation + transcription + speakers in
  one lightweight menu-bar app," and shipping speed.
