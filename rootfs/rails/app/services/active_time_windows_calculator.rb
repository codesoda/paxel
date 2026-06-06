# Gap-splits an array of ISO timestamps into [start, end] windows using
# TranscriptSession::PARALLELISM_GAP_MINUTES. Used by:
#   - TranscriptChunker — fresh chunking from JSONL message timestamps
#   - parallelism:backfill_active_time_windows — legacy sessions whose
#     message timestamps were never persisted but whose session_events
#     (each tagged with a timestamp) survive in the DB
class ActiveTimeWindowsCalculator
  def self.from_timestamps(timestamps)
    return [] if timestamps.blank?

    parsed = timestamps.filter_map { |t| Time.parse(t.to_s) rescue nil }.sort
    return [] if parsed.empty?

    gap_seconds = TranscriptSession::PARALLELISM_GAP_MINUTES * 60
    windows = []
    window_start = parsed.first
    window_end = parsed.first
    parsed[1..].each do |t|
      if t - window_end > gap_seconds
        windows << [ window_start.iso8601, window_end.iso8601 ]
        window_start = t
      end
      window_end = t
    end
    windows << [ window_start.iso8601, window_end.iso8601 ]
    windows
  end
end
