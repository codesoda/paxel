# Replay any stashed uploads from prior failed `bin/upload` runs.
#
# Invoked by the bash wrapper inside a minimal Docker container when it
# detects entries in ~/.paxel/data/pending-uploads/. NOT part of the
# user-facing pipeline — users never run this directly.
#
# Exit codes (consumed by the wrapper's case statement):
#   0 — nothing left to retry (all stashes either replayed or quarantined)
#   1 — at least one stash deferred (transient server error); next run retries
#   2 — re-authentication required (current token got 401/403)
namespace :pending_uploads do
  desc "Replay stashed pending uploads (container-internal; called by bin/upload wrapper)"
  task replay: :environment do
    # Replay is pure filesystem + HTTP; Rails.cache is never used. The client
    # image runs RAILS_ENV=production which defaults to SolidCache, and the
    # cache DB isn't guaranteed to exist in a replay-only container. Swap to
    # NullStore so any accidental Rails.cache access fails silently instead
    # of crashing boot.
    Rails.cache = ActiveSupport::Cache::NullStore.new if defined?(Rails.cache)

    result = PendingUploadReplayService.replay_all!(
      logger: ->(msg) { puts msg },
      current_endpoint: ENV["YC_RESULTS_ENDPOINT"].presence
    )

    puts ""
    puts "[paxel] Pending uploads: #{result.replayed.size} replayed, #{result.deferred.size} deferred, #{result.quarantined.size} quarantined"
    if result.reauth_required
      # Env-aware remediation copy (matches AnthropicClient#auth_user_action).
      # bin/upload exports PAXEL_CLIENT_MODE=dev; public curl|bash leaves it unset.
      # Propagated into the replay container via upload_script.text.erb:4773.
      if ENV["PAXEL_CLIENT_MODE"] == "dev"
        puts "[paxel] One or more stashes need re-authentication. Run `bin/upload` interactively to refresh your token."
      else
        # "Get a fresh" (not "re-run the same") — the baked token in the
        # stash's original curl is the one that expired. User needs a new
        # command with a new token from the dashboard.
        puts "[paxel] One or more stashes need re-authentication. Get a fresh `curl | bash` command from your Paxel dashboard to refresh your token."
      end
    end

    exit result.exit_code
  end
end
