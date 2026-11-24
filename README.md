# snappedcut

Ruby client for the [Snapped Cut](https://snappedcut.com) cloud render API.
**The standard library and nothing else** — no gem dependencies, so it drops
into a Rails app or a bare script without touching the bundle.

```sh
gem install snappedcut
```

```ruby
require "snappedcut"

snapcut = SnappedCut.new                        # reads SNAPCUT_KEY

job = snapcut.render(File.open("project.zip", "rb"))
puts "charged #{job.charged} credits for #{job.priced.seconds}s"

File.binwrite("out.webm", snapcut.wait(job.id) { |j| puts j.state })
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
| `#output(id)` | The rendered bytes. Raises unless the job is done. |
| `#wait(id, timeout:) { \|job\| }` | Polls to completion, returns the bytes. Yields each poll. |

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

Every failure raises `SnappedCut::Error` with the HTTP `status` on it, and the
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
