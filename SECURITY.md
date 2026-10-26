# Security

## Reporting a vulnerability

Email **security@naijacloud.com**. Please do not open a public issue, and do not
post a proof of concept anywhere public before we have shipped a fix.

Include what you did, what happened, and the version of the gem. We acknowledge
within two business days (West Africa Time) and will tell you what we intend to
do and by when.

## What the DSN is, and is not

The DSN's key is a **public, send-only** credential: it can add events to one
Argus source and read nothing. It is not a secret in the way an API key is, so
a leaked DSN is a spam risk for that source, not a data breach. Rotate it from
the source's settings if it is being abused.

Even so, the gem keeps it tidy: on a server it travels in a header
(`X-Sentry-Auth` or `Authorization: Bearer`), never in the URL, so it does not
end up in proxy access logs. `Dsn#inspect` and `Client#inspect` do not print it.

## What the gem does with your users' data

The gem sits inside your app and sees its exceptions, requests and logs, so it
is built to send as little as it can:

1. **Sensitive keys are filtered before anything leaves the process,** at any
   depth: `password`, `token`, `secret`, `authorization`, `cookie`, `bvn`,
   `card`, `cvv`, `session` and the rest of the list in the Argus SDK contract
   (§7). Card numbers (Luhn-checked), bearer/basic tokens, JWTs and
   `password=…` pairs are filtered inside strings.
2. **Request bodies and cookies are never sent.** Request headers are an
   allowlist (host, user agent, accept, referer, request id, content type), not
   a denylist, so a header nobody thought of is not sent.
3. **Query strings are removed** from every URL the gem records.
4. **IP addresses are not sent** unless you set `send_default_pii: true`.
5. **TLS is verified** (`VERIFY_PEER`, set explicitly) and **redirects are never
   followed**: a followed redirect would resend the key to a host the response
   chose.
6. **Debug output** (`debug: true`) prints what the SDK does, never payloads or
   headers. `Net::HTTP#set_debug_output` is never called.

Argus filters again on arrival; the gem does not rely on that.

## Supply chain

The gem has **zero runtime dependencies**. Everything is standard library:
`net/http`, `openssl`, `json`, `zlib`, `securerandom`, `socket`, `uri`, and
`logger` only if you use `NaijaCloud::Argus::Logger`.

That is deliberate. This package runs in every process of the apps that use
it, so every third-party dependency would be another maintainer whose account
compromise becomes our customers' incident. Releases require MFA on the
RubyGems account (`rubygems_mfa_required`).

## Supported versions

Security fixes are released for the latest minor version. Ruby 3.0 and newer
are supported.
