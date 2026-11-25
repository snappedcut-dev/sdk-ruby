# snappedcut

Ruby client for the [Snapped Cut](https://snappedcut.com) API.
**The standard library and nothing else** — no gem dependencies, so it drops
into a Rails app or a bare script without touching the bundle.

```sh
gem install snappedcut
```

```ruby
require "snappedcut"

sc = SnappedCut.new                                 # reads SNAPCUT_KEY
clip = File.open("clip.webm", "rb") { |f| sc.upload(f, "video/webm", "clip.webm") }

design = { width: 1080, height: 1920, clips: [{ type: "video", asset: clip["id"] }] }
created = sc.render_design(design, {
  outputs: [{ format: "mp4", preset: "vertical" }, { format: "webm", preset: "square" }]
}, "launch-video-1")                                # Idempotency-Key: a retry is not a second charge

job = sc.wait_for_job(created["job"]["id"])
File.binwrite("out.mp4", sc.download_output(job["id"], 0))
File.binwrite("out.webm", sc.download_output(job["id"], 1))
```

Presets: `source`, `vertical`, `square`, `portrait`, `landscape`, `hd720`,
`uhd2160`. The JSON surface returns Hashes with string keys, exactly as the
server sent them, so a field added within a version never breaks anything.

Or render a bundle the editor exported:

```ruby
job = sc.render(File.open("project.zip", "rb"))
puts "charged #{job.charged} credits for #{job.priced.seconds}s"
File.binwrite("out.webm", sc.wait(job.id) { |j| puts j.state })
```

Get a key from [your account page](https://snappedcut.com/account) — it looks
like `sk_snapcut_…`. Keep it in credentials, not in the repo; it spends credits.

## API

| | |
| --- | --- |
| `SnappedCut.new(key:, base:, timeout:, chunk_size:)` | `key` falls back to `ENV["SNAPCUT_KEY"]`. All keyword, all optional. |
| `#account` | Who the key belongs to, credits left, the price list. |
| `#render(bundle, kind:)` | Queue a render. `bundle` is a String **or any IO**. |
| `#job(id)` / `#jobs` | One job, or every job on the account. |
| `#output(id, index = 0)` | The rendered bytes. Raises unless the job is done. Alias `#download_output`. |
| `#wait(id, timeout:) { \|job\| }` | Polls to completion, returns the bytes. Yields each poll. |
| `#create_job(request, idempotency_key)` | A JSON job (tool, design, asset). Returns `job`, `charged`, `price`, `credits`, `idempotent`. |
| `#create_batch(jobs, defaults)` | Up to 100 jobs, each answered on its own. |
| `#get_job(id)` / `#list_jobs` / `#wait_for_job(id, timeout:)` | The same as Hashes; `wait_for_job` returns the done job. |
| `#compile_design(design, vars)` / `#render_design(design, options, idempotency_key)` | |
| `#upload(data, content_type, name)` | String or IO, chunked; returns the confirmed asset. `#get_asset` / `#delete_asset`. |
| `#operations` / `#usage(from:, to:, end_user_id:, group_by:)` / `#delete_end_user(id)` | |
| `#create_embed_token(pk, end_user_id, max_credits:, ttl_seconds:, origin:, features:)` | |
| `#destinations` | `list`, `create`, `get`, `update`, `delete`, `test` (a 422 is returned, not raised), `presign`. |
| `#webhooks` | `list`, `create(url, events)`, `get`, `update(id, url:, events:, enabled:)`, `delete`, `rotate`, `deliveries`, `test`. |

## Verifying webhooks

```ruby
ok = SnappedCut.verify_webhook(secret, request.raw_post, request.headers["X-Snappedcut-Signature"])
head(ok ? :ok : :unauthorized)
```

Pass the raw body, not re-serialised JSON. Signatures more than five minutes
from now are refused, and the comparison is constant-time.

## Pass an IO for anything large

A **String** bundle holds the whole file in memory; an **IO** holds one chunk:

```ruby
snapcut.render(File.open("project.zip", "rb"))  # one chunk in memory
snapcut.render(File.binread("project.zip"))     # the whole file, twice
```

If the process is memory-constrained — a Sidekiq worker with a tight limit —
lower the chunk size rather than raising the limit:

```ruby
SnappedCut.new(chunk_size: 8 * 1024 * 1024)
```

## Large bundles resume themselves

A bundle over the chunk size uploads in pieces, and if the connection drops it
carries on from **the server's** count of what it holds, not its own — a `409`
carries the expected offset and the client believes it. Three attempts per
chunk; a `4xx` that is not `409` is a real refusal (no credits, bad bundle, bad
key) and stops immediately rather than retrying its way through your balance.

## You cannot set the price

There is no `seconds:` argument, deliberately. The server reads the timeline
duration out of the bundle's own `project.json` and prices on that, because a
duration supplied by the caller is a price supplied by the caller. What you were
actually charged is in `charged`, with the server's reasoning in `priced`.

## Errors

Every failure raises `SnappedCut::Error` with the HTTP `status` (and the body's
`code`, when it has one) on it, and the
two failures you actually branch on have predicates:

```ruby
begin
  snapcut.render(bundle)
rescue SnappedCut::Error => e
  if e.out_of_credits?              # 402
    top_up
  elsif e.rate_limited?             # 429
    sleep(e.retry_after_ms / 1000.0)
  elsif e.status.zero?              # never reached the server
    retry
  else
    raise
  end
end
```

A job that fails server-side has **already been refunded** by the time `#wait`
raises, so there is nothing to reconcile.

`#inspect` never contains the key — an inspect ends up in logs and exception
reports.

## What a bundle is

A zip of the project: `project.json` plus the media it names. The editor writes
one from **Share → Export bundle**, and
[`@snappedcut/mcp`](https://github.com/snappedcut-dev/mcp) builds one headlessly.
A bundle whose media is missing is refused at submit, before any charge — it
would otherwise render successfully as the right number of blank frames, and
nothing downstream could tell.

## Releases

Published from CI through [RubyGems trusted publishing](https://guides.rubygems.org/trusted-publishing/),
which authenticates the workflow by OIDC rather than a long-lived API key.
Nothing is published from anyone's laptop.

MIT
