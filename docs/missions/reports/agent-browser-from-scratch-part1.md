# agent-browser-from-scratch - Part 1: what his own web product needs in order to be driven

Read-only report. No code changed, no installer row, no build, nothing enters v0.1.2.
Measured on avell, 25/11.

## 0. What was measured, and the premises that were stale

- The product tree measured is `/home/victor/cloud` at commit `e4a203a` (PHP 8.3 + Swoole, SQLite).
- Stale premise (1): that checkout is not the deployed build. Deployed `/app.js` is 49,339 B
  (sha256 `cb87a730...`); the checkout's `public/app.js` is 45,183 B (`d5270000...`); 306 diff
  lines, all layout/UI (title row with workspace name, workspace select removed, notice wrapper).
  The data plane is identical in both: the deployed bundle calls exactly two endpoints
  (`/api/me` x2, `/api/operation` x2) and 26 distinct operations, the checkout 25. Counts below say
  which artifact they come from.
- Stale premise (2): there is no PHP on this node (`php -v` -> command not found), so the product was
  never booted locally. Every latency row in section 7 is measured against the deployed origin,
  anonymously.
- Confirmed premise: code mode's JavaScript runs on a QuickJS sandbox hosted by the kernel, not one a
  component contains - `rust/components/codemode/Cargo.toml:9-10` (imports `wa:kernel/quickjs`, in
  since `6e471463`), `rust/wa-capabilities/Cargo.toml:8` (the QuickJS sandbox, since `3107a2ac`).

## 1. What the product is, in bytes

| artifact | bytes | note |
|---|---|---|
| `public/index.html` (served, measured over TLS) | 656 | body is one empty `<colmeio-app>` and one module script |
| `public/app.js` | 45,183 (checkout) / 49,339 (deployed) | the shell, router, transport, offline queue driver |
| `public/components/core.js` | 29,318 | base class: shadow root + innerHTML render, CSS as a string |
| `public/components/*.js` (10 files) | 77,142 | bills, calendar, holidays, notifications, workspaces, ... |
| `i18n.js` + `theme.js` + `sync-queue.js` + `offline-records.js` | 26,967 | translations, theme, offline write queue |
| total delivered before any text exists | 149,948 (149,292 of it JS) | `wc -c` over that set |

The only text in the document is its `<title>` and meta description. Every view of the product is a
page that needs scripts: measured, the served HTML has no content node at all.

## 2. The data plane: one JSON endpoint, 31 operations

Routes in `src/server.php`: `/health` (:30), `/dev/version` (:34), `/auth/google` GET (:40),
`/api/me` GET (:47), `/auth/logout` POST (:54), `/files/{id}` GET (:62),
`/api/operation` and `/mcp` POST (:71).

The operations are 31 `match` arms in `src/Domain.php:58-91` (workspaces 4, holidays 8,
notifications 3, bills 7, attachments 2, members 3, audit 1, agents 3). The client uses 25 of them
(checkout) / 26 (deployed).

So "the web APIs its pages call" is one RPC: `POST /api/operation` with
`{"operation": ..., "arguments": ...}`, plus `GET /api/me` once at startup. There is no REST
resource per view and no HTML fragment endpoint.

## 3. What the login does - and why it needs no browser

Measured from `src/Auth.php` and `src/server.php:40-46`:

- `GET /auth/google` answers 302 to `accounts.google.com` with `scope=openid email profile`,
  PKCE `S256`, a `state` and a `nonce`, `prompt=select_account`, and cookie `cloud_oauth`
  (path `/auth`, 600 s).
- The callback compares `state` with that cookie, exchanges the code at
  `oauth2.googleapis.com/token`, verifies the RS256 `id_token` against Google's JWKS (cached
  3600 s on disk), then checks `iss`, `aud`, `nonce`, `email_verified`, `exp`/`iat` and an
  allow-list of e-mail addresses; it creates the user and a default workspace on first sign-in.
- The session is cookie `cloud_session` (HttpOnly, Secure, SameSite=Lax, path `/`, 7 days); the row
  keeps `sha256(token)` and a CSRF value. Every non-GET request must carry `X-CSRF-Token` equal to
  it (`Auth.php:43-44`).
- `GET /api/me` returns `{user, csrf, workspaces, currency, timezone}` (`server.php:47-53`): the CSRF
  token arrives as JSON, so a client without JavaScript has everything it needs from one JSON body
  and a cookie jar.
- An agent path already ships: `Authorization: Bearer <token>` resolves through
  `agent_credentials` with workspace and permission scoping and no CSRF token (`Auth.php:30-40`);
  `/mcp` requires it (`server.php:72-73`).

The browser is in no part of the login: it is a chain of GET redirects and one 302 back to `/`.
0 bytes of JavaScript are needed to log in.

## 4. The measured cost of the scripted path

- 15 `customElements.define` calls, one base class that calls `attachShadow`, 87 `shadowRoot`
  references, 5 `innerHTML` writes (`public/`). The whole UI is created at runtime inside shadow
  roots: a parse of the fetched HTML sees an empty body, so an accessibility-style tree can only come
  from executing the JavaScript in a DOM that implements custom elements, shadow roots and
  `innerHTML`.
- Browser APIs used across `public/*.js`: `serviceWorker` 9 (app.js, notifications.js), `PushManager`
  1, `Notification.requestPermission` 2, `localStorage` 7, `indexedDB` 1, `navigator.onLine` 8,
  `matchMedia` 3, `Intl.` 4, `crypto.` 6, `confirm(` 12; layout: `getBoundingClientRect` 9
  (core.js, calendar.js, bills.js, scroll-row.js) and `ResizeObserver` 3
  (`components/scroll-row.js:131`, `components/calendar.js:28`, `components/bills.js:113`).
- Only the layout APIs are out of reach for an engine with no layout, and they serve two
  interactions: dropping a payment onto another day (`components/calendar.js:39-43`) and overflow
  detection in scroll rows. Every action the UI offers is also one of the 26 operations, so `act`
  can be expressed on the operation plane without any DOM.

## 5. Victor's test, exactly - and it costs two operations

Read one day: `bills.list {workspace_id, from: D, to: D}` - `from`/`to` are filtered server-side
(`src/Domain.php:219-227`, `LIMIT 500`, no pagination) - plus
`holidays.list {workspace_id, from: D, to: D}`.

The client does the same over a month (`public/app.js:334`) and then reduces it in JavaScript into
per-day totals and counts (`components/calendar.js:58-102`): a "calendar day" is not a server view,
it is a client-side reduction of two list results. An agent needs no reduction, only the date
filter.

The strongest measured evidence that stage 1 already covers this product: the product's own
`tests/transport.py` - 52 lines of python `urllib`, no browser - drives 28 checks through exactly this
plane with one cookie and one CSRF header: create/get/update/delete, revision conflict, idempotent
replay, workspace isolation over HTTP and over MCP, bearer revocation, attachment visibility.
`tests/run.sh` boots the app with its own fixture and then runs it.

## 6. Verdict on the proposed shape, with numbers

- Stage 1 (HTTP + cookie jar + JSON, allow-list, vault credentials) covers the login, every read and
  every write of his product: 0 JS bytes, 2 requests per read of a day, 31 operations available, one
  CSRF header.
- Stage 2 (HTML parser + DOM + JS on QuickJS) buys nothing for this product and costs the most: to
  run this UI an engine must implement custom elements, shadow roots, `innerHTML`, `Intl`,
  `crypto`, `localStorage` and an absent service worker, and then execute 149,948 B of JavaScript
  whose output is a re-rendering of the JSON stage 1 already holds. Stage 2 pays on other people's
  sites: server-rendered HTML with forms and inline script.
- Stage 3 (host-supervised headless browser) is what shadow DOM and layout really need, and should
  stay a named fallback with a named trigger, not a silent one. Its cost is measured, not guessed:
  Chromium exists on this node (`/usr/bin/chromium`), and the product's own UI suite needs
  Playwright plus Chromium inside a container (`tests/browser.cjs:2`, `tests/run.sh`), which is
  exactly the "extra install" his test forbids.
- Recommendation: the four verbs - open, read, act, eval - on the HTTP plane first; `read` returns
  text plus an accessibility-style tree only for documents that are served as HTML with content;
  stage 2 for HTML-with-forms; stage 3 behind an explicit `needs_shadow_dom` / `needs_layout`
  refusal.

## 7. Budgets proposed from measurement

| budget | proposal | measured baseline on this node |
|---|---|---|
| module size, stage 1 (no JS) | <= 250 KB | mesh 209,983 B, codemode 216,485 B, hooks 215,897 B in `~/.wasm-agent/components` |
| module size, with the stage-2 DOM | <= 400 KB | agent-core 392,561 B, model-gateway 404,558 B |
| memory, open + read | <= 40 MB RSS | `wa --version`: 11,840 KB max RSS, 3 ms |
| ms to the first read | <= 150 ms | TLS connect 21.4-23.1 ms on two requests and 84.3 ms on a third (fresh handshake); `/health` 32 ms; `GET /` 30 ms (656 B); `/app.js` 111 ms (49,339 B); `POST /api/operation` 401 in 35.7 ms |

The provision rows are targets for Part 2 to hold against; only the baseline column is measured.
Sized against the components this node already ships, a web component of 250-400 KB would sit in the
existing class rather than above it.

## 8. What I did not do, and cannot claim

- I did not log in, used no credential, and read no account, bill, amount, recipient or attachment.
  My whole traffic to the product was: `/health`, `/`, `/app.js` twice, `/dev/version`, and one
  deliberately unauthenticated `POST /api/operation` that answered 401.
- I did not boot the product (no PHP on this node), did not run its test suite, did not drive a
  browser, and installed nothing.
- Latency rows are one sample each; they are a floor, not a distribution.

## 9. Texts to approve

No model- or operator-facing string is added by this change (documentation only). The four verb names
proposed for Part 2 (`open`, `read`, `act`, `eval`) and the refusal reasons
(`needs_shadow_dom`, `needs_layout`) will be listed verbatim there, before they land.

## Rows

- Installer rows: none in Part 1, by design (read-only, nothing to install).
- Test rows: none - no code changed, `scripts/test.sh` untouched.
