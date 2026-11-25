# Changelog

## 0.2.0

Added the rest of the API, alongside the bundle `render` path (unchanged):

- `create_job(request, idempotency_key)` — JSON jobs, with an `Idempotency-Key`
  so a retry returns the first job instead of a second charge.
- `create_batch(jobs, defaults)`, `get_job`, `list_jobs`,
  `download_output(id, index)` (and `output(id, index)`), `wait_for_job`.
- `compile_design`, `render_design`.
- `upload(data, content_type, name)` — direct, chunked uploads that never send
  the API key to the upload URL; `get_asset`, `delete_asset`.
- `operations`, `usage(from:, to:, end_user_id:, group_by:)`, `delete_end_user`,
  `create_embed_token`.
- `client.destinations` — list, create, get, update, delete, test, presign.
- `client.webhooks` — list, create, get, update, delete, rotate, deliveries, test.
- `SnappedCut.verify_webhook(secret, raw_body, header)` — constant-time check of
  `X-Snappedcut-Signature`, five-minute tolerance.
- `SnappedCut::Error#code` — the body's machine-readable code, when it has one.

## 0.1.0 — first release
