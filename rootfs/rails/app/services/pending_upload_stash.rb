# Pure filesystem I/O for stashed-upload payloads.
#
# When `ClientPipeline#upload_results!` exhausts its retry budget, the full POST
# body is written here so the next `bin/upload` can replay it via
# `PendingUploadReplayService`.
#
# Layout on disk (<stash_dir> = ~/.paxel/data/pending-uploads/ on host,
# /rails/data/pending-uploads/ in the client container):
#
#   pending-uploads/
#   ├── <client_request_id>.meta.json         # uncompressed metadata, read by `list`
#   ├── <client_request_id>.json.gz           # gzipped primary payload
#   └── failed/
#       ├── <client_request_id>.meta.json
#       ├── <client_request_id>.json.gz
#       └── <client_request_id>.error.json    # {quarantined_at, reason, ...}
#
# Design notes:
# - Atomic writes: payload FIRST (tmp + rename), meta sidecar SECOND. `list`
#   globs *.meta.json so a half-written stash (payload present but meta missing)
#   is invisible until the final rename.
# - `write!` never swallows ENOSPC — callers must surface "local stash failed"
#   to the user so they can free disk space.
# - Mode 0600 on files, 0700 on the directory. Same posture as ~/.paxel/token.
# - No flock. `bin/upload` is human-invoked; server-side X-Idempotency-Key
#   handles the worst-case concurrent-replay race.
module PendingUploadStash
  class DiskFullError < StandardError; end
  class CorruptStashError < StandardError; end

  Entry = Struct.new(
    :client_request_id,
    :meta_path,
    :payload_path,
    :created_at,
    :last_attempt_at,
    :attempt_count,
    :pipeline_version,
    :token_fingerprint,
    :url,
    :endpoint_source,
    :payload_bytes,
    :last_error,
    keyword_init: true
  )

  class << self
    def stash_dir
      ENV["PAXEL_PENDING_UPLOAD_DIR"].presence ||
        (File.directory?("/rails/data") ? "/rails/data/pending-uploads" : File.expand_path("~/.paxel/data/pending-uploads"))
    end

    def failed_dir
      File.join(stash_dir, "failed")
    end

    def write!(payload:, client_request_id:, url:, endpoint_source:, token_fingerprint:, last_error: nil, attempt_count: 1, pipeline_version:)
      ensure_dir!(stash_dir)

      payload_path = File.join(stash_dir, "#{client_request_id}.json.gz")
      meta_path = File.join(stash_dir, "#{client_request_id}.meta.json")

      # Write payload first. list() only finds meta sidecars, so a half-written
      # payload with no sidecar is invisible (picked up on next write retry or
      # by the user via `--clear-pending`).
      atomic_write_gzipped!(payload_path, payload)

      payload_bytes = File.size(payload_path)
      meta = {
        "client_request_id" => client_request_id,
        "created_at" => Time.now.utc.iso8601,
        "last_attempt_at" => Time.now.utc.iso8601,
        "attempt_count" => attempt_count,
        "pipeline_version" => pipeline_version,
        # Forensics only. The historical Gate 2 in
        # PendingUploadReplayService (token-fingerprint mismatch
        # quarantine) was removed when server idempotency moved to
        # user_id scoping. Retained in the meta so support can
        # correlate a stashed upload to the token that wrote it.
        "token_fingerprint" => token_fingerprint,
        "url" => url,
        "endpoint_source" => endpoint_source,
        "payload_bytes" => payload_bytes,
        "last_error" => last_error
      }
      atomic_write_json!(meta_path, meta)

      payload_path
    rescue Errno::ENOSPC => e
      # Clean up any partial payload from the failed write.
      File.delete(payload_path) if defined?(payload_path) && payload_path && File.exist?(payload_path)
      raise DiskFullError, "no disk space to stash upload at #{stash_dir} (#{e.message})"
    end

    def list(include_failed: false)
      dir = include_failed ? failed_dir : stash_dir
      return [] unless File.directory?(dir)

      Dir.glob(File.join(dir, "*.meta.json")).sort.filter_map do |meta_path|
        parse_entry(meta_path, dir)
      end
    end

    def read_payload(entry)
      raw = File.binread(entry.payload_path)
      json = Zlib.gunzip(raw)
      JSON.parse(json)
    rescue Zlib::GzipFile::Error, Zlib::DataError, Zlib::BufError, JSON::ParserError => e
      raise CorruptStashError, "failed to read payload #{entry.payload_path}: #{e.class}: #{e.message}"
    end

    def delete!(entry)
      File.delete(entry.payload_path) if entry.payload_path && File.exist?(entry.payload_path)
      File.delete(entry.meta_path) if entry.meta_path && File.exist?(entry.meta_path)
    end

    def quarantine!(entry, reason:, response_status: nil, response_body: nil)
      ensure_dir!(failed_dir)

      dest_meta = File.join(failed_dir, File.basename(entry.meta_path))
      error_path = File.join(failed_dir, "#{entry.client_request_id}.error.json")

      if entry.payload_path && File.exist?(entry.payload_path)
        File.rename(entry.payload_path, File.join(failed_dir, File.basename(entry.payload_path))) rescue nil
      end
      File.rename(entry.meta_path, dest_meta) if entry.meta_path && File.exist?(entry.meta_path)

      error = {
        "quarantined_at" => Time.now.utc.iso8601,
        "reason" => reason,
        "last_response_status" => response_status,
        "last_response_body" => response_body.is_a?(String) ? response_body[0, 500] : response_body
      }.compact
      atomic_write_json!(error_path, error)
    end

    def touch!(entry, last_attempt_at:, attempt_count:, last_error: nil)
      return unless File.exist?(entry.meta_path)

      raw = File.read(entry.meta_path)
      meta = JSON.parse(raw)
      meta["last_attempt_at"] = last_attempt_at.utc.iso8601 if last_attempt_at.respond_to?(:utc)
      meta["attempt_count"] = attempt_count
      meta["last_error"] = last_error if last_error

      atomic_write_json!(entry.meta_path, meta)
    end

    def prune_expired!(ttl_days: 14)
      cutoff = Time.now.utc - (ttl_days * 86_400)
      list.each do |entry|
        next unless entry.created_at.is_a?(Time) && entry.created_at < cutoff
        quarantine!(entry, reason: "ttl_expired")
      end
    end

    # Drops oldest quarantined entries (meta + payload + error sidecar) if the
    # failed/ directory's combined byte size exceeds max_bytes. Best-effort: if
    # a delete fails we move on — next invocation will try again.
    def prune_failed!(max_bytes: 500_000_000)
      return unless File.directory?(failed_dir)

      entries = list(include_failed: true)
      total = entries.sum { |e| e.payload_bytes.to_i }
      return if total <= max_bytes

      entries.sort_by! { |e| e.created_at.is_a?(Time) ? e.created_at : Time.at(0) }
      while total > max_bytes && (oldest = entries.shift)
        begin
          size = oldest.payload_bytes.to_i
          File.delete(oldest.payload_path) if oldest.payload_path && File.exist?(oldest.payload_path)
          File.delete(oldest.meta_path) if oldest.meta_path && File.exist?(oldest.meta_path)
          error_path = File.join(failed_dir, "#{oldest.client_request_id}.error.json")
          File.delete(error_path) if File.exist?(error_path)
          total -= size
        rescue StandardError
          next
        end
      end
    end

    private

    def ensure_dir!(dir)
      FileUtils.mkdir_p(dir)
      # chmod is a no-op if already 0700 — idempotent + cheap.
      File.chmod(0o700, dir)
    end

    def atomic_write_gzipped!(path, payload)
      tmp = "#{path}.#{Process.pid}.#{SecureRandom.hex(4)}.tmp"
      compressed = Zlib.gzip(payload.to_json)
      File.binwrite(tmp, compressed)
      File.chmod(0o600, tmp)
      File.rename(tmp, path)
    ensure
      File.delete(tmp) if tmp && File.exist?(tmp)
    end

    def atomic_write_json!(path, data)
      tmp = "#{path}.#{Process.pid}.#{SecureRandom.hex(4)}.tmp"
      File.write(tmp, JSON.pretty_generate(data))
      File.chmod(0o600, tmp)
      File.rename(tmp, path)
    ensure
      File.delete(tmp) if tmp && File.exist?(tmp)
    end

    def parse_entry(meta_path, dir)
      raw = File.read(meta_path)
      meta = JSON.parse(raw)
      # Non-Hash JSON (e.g. `"42"`, `[1,2]`, `null`) parses cleanly but would
      # raise TypeError on the meta["..."] access below. Normalize to an empty
      # hash so the downstream code can still extract the fallback id from the
      # filename and quarantine it as corrupt_meta.
      meta = {} unless meta.is_a?(Hash)
      client_request_id = meta["client_request_id"] || File.basename(meta_path, ".meta.json")

      # Legacy archive_only + primary_with_archive stashes (written by old
      # clients before the --full-upload removal) are no longer replayable —
      # quarantine them rather than surface an unhandled shape to the replay
      # service.
      legacy_mode = meta["pending_mode"]
      if legacy_mode == "archive_only" || legacy_mode == "primary_with_archive"
        legacy_archive = File.join(dir, "#{client_request_id}.archive.tar.gz")
        quarantine_corrupt_meta!(meta_path, legacy_archive, client_request_id, reason: "#{legacy_mode}_deprecated")
        return nil
      end

      payload_path = File.join(dir, "#{client_request_id}.json.gz")
      unless File.exist?(payload_path)
        quarantine_corrupt_meta!(meta_path, payload_path, client_request_id, reason: "missing_payload")
        return nil
      end

      Entry.new(
        client_request_id: client_request_id,
        meta_path: meta_path,
        payload_path: payload_path,
        created_at: parse_time(meta["created_at"]),
        last_attempt_at: parse_time(meta["last_attempt_at"]),
        attempt_count: meta["attempt_count"].to_i,
        pipeline_version: meta["pipeline_version"],
        token_fingerprint: meta["token_fingerprint"],
        url: meta["url"],
        endpoint_source: meta["endpoint_source"],
        payload_bytes: meta["payload_bytes"].to_i,
        last_error: meta["last_error"]
      )
    rescue JSON::ParserError, Errno::ENOENT, TypeError, NoMethodError
      # `list` runs on a best-effort basis — a corrupt-meta stash gets
      # quarantined with a synthetic id so the user can see it in failed/.
      # TypeError + NoMethodError cover pathological JSON shapes that parse
      # cleanly but blow up on Hash-like access.
      fallback_id = File.basename(meta_path, ".meta.json")
      quarantine_corrupt_meta!(meta_path, File.join(dir, "#{fallback_id}.json.gz"), fallback_id, reason: "corrupt_meta")
      nil
    end

    def parse_time(str)
      Time.iso8601(str) if str.is_a?(String) && !str.empty?
    rescue ArgumentError
      nil
    end

    # Shallow copy of quarantine! that takes raw paths (the full Entry can't
    # be constructed when meta is corrupt). Also removes any sibling
    # .archive.tar.gz — legacy archive-only stashes from old clients that
    # carry an orphan tarball no longer have a replay path.
    def quarantine_corrupt_meta!(meta_path, payload_path, client_request_id, reason:)
      ensure_dir!(failed_dir)

      dir = File.dirname(meta_path)
      dest_meta = File.join(failed_dir, File.basename(meta_path))
      legacy_archive = File.join(dir, "#{client_request_id}.archive.tar.gz")
      error_path = File.join(failed_dir, "#{client_request_id}.error.json")

      if payload_path && File.exist?(payload_path)
        File.rename(payload_path, File.join(failed_dir, File.basename(payload_path))) rescue nil
      end
      if File.exist?(legacy_archive)
        begin
          File.rename(legacy_archive, File.join(failed_dir, File.basename(legacy_archive)))
        rescue Errno::ENOSPC, Errno::EXDEV
          nil
        end
      end
      File.rename(meta_path, dest_meta) if File.exist?(meta_path)

      atomic_write_json!(error_path, {
        "quarantined_at" => Time.now.utc.iso8601,
        "reason" => reason
      })
    rescue StandardError
      # Even quarantining failed — nothing we can do, move on.
    end
  end
end
