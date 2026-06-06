require "fileutils"
require "json"
require "securerandom"

# Merges external-agent session mounts (Cursor, Codex, etc.) into
# transcript_dir so TranscriptDiscoverer sees one Project per
# `_<agent>_<slug>_<hash>` bucket. Extracted from lib/tasks/analyze_local.rake
# so the merge logic has direct rspec coverage instead of inline-duplicated
# test bodies — PR #746 follow-up review flagged that the prior inline
# Cursor-only block had zero executable coverage: refactor bugs would slip
# past CI since no test called the code under change.
#
# Each mount spec is [mount_dir, bucket_glob]. For each mount that exists
# AND has matching subdirs:
#   1. If transcript_dir isn't already under Dir.tmpdir, rehome it into
#      an paxel-merged-* tmpdir with symlinks to the original entries.
#      The rehome is persistent across iterations — a second agent mount
#      adds to the same merged_dir rather than creating a parallel one.
#   2. Symlink each bucket subdir into transcript_dir.
#   3. Merge the mount's `_metadata.json` into the transcript sidecar
#      (non-destructive: existing keys win over mount-provided keys).
#
# Returns the (possibly-new) transcript_dir. Callers pass it back into
# ClientPipeline.new(transcript_dir: ...).
module AnalyzeLocalMerge
  module_function

  def mirror_tree_with_symlinks(source, target)
    # Read `source` first so an unreadable directory is skipped without leaving
    # an empty target behind. Dir.children excludes "." / ".." and, like the
    # Dir.foreach it replaces, raises a SystemCallError when `source` can't be
    # opened.
    entries =
      begin
        Dir.children(source)
      rescue SystemCallError => e
        # A transcript directory the container can't read — e.g. a host dir with
        # restrictive permissions bind-mounted read-only at /transcripts raises
        # Errno::EACCES on Dir.open (PAXEL-CLIENT-10). Skip this subtree and keep
        # mirroring the rest rather than crashing the whole upload. Sibling of the
        # PAXEL-CLIENT-Z degradation: one unprocessable item must not sink the
        # entire report. Downstream discovery (TranscriptDiscoverer) already walks
        # with Dir.glob, which silently skips unreadable dirs, so dropping it here
        # is the complete fix — nothing else re-reads this path.
        warn "[paxel:merge] Skipping unreadable transcript directory #{source}: #{e.message}"
        return
      end

    FileUtils.mkdir_p(target)
    entries.each do |entry|
      src_path = File.join(source, entry)
      tgt_path = File.join(target, entry)
      if File.directory?(src_path)
        mirror_tree_with_symlinks(src_path, tgt_path)
      else
        FileUtils.ln_s(src_path, tgt_path)
      end
    end
  end

  def merge_agent_sessions!(transcript_dir, mount_specs)
    mount_specs.each do |mount_dir, bucket_glob|
      next unless Dir.exist?(mount_dir)
      subdirs = Dir.glob(File.join(mount_dir, bucket_glob)).select { |d| File.directory?(d) }
      next if subdirs.empty?

      unless transcript_dir.start_with?(Dir.tmpdir)
        merged_dir = File.join(Dir.tmpdir, "paxel-merged-#{SecureRandom.hex(4)}")
        FileUtils.mkdir_p(merged_dir)
        Dir.glob(File.join(transcript_dir, "*")).each do |entry|
          target = File.join(merged_dir, File.basename(entry))
          if File.directory?(entry)
            mirror_tree_with_symlinks(entry, target)
          else
            FileUtils.ln_s(entry, target)
          end
        end
        transcript_dir = merged_dir
      end

      subdirs.each do |subdir|
        target = File.join(transcript_dir, File.basename(subdir))
        mirror_tree_with_symlinks(subdir, target) unless File.exist?(target)
      end

      mount_meta_path = File.join(mount_dir, "_metadata.json")
      transcript_meta_path = File.join(transcript_dir, "_metadata.json")
      if File.exist?(mount_meta_path)
        mount_meta = JSON.parse(File.read(mount_meta_path)) rescue {}
        transcript_meta = File.exist?(transcript_meta_path) ? (JSON.parse(File.read(transcript_meta_path)) rescue {}) : {}
        transcript_meta["directories"] ||= {}
        (mount_meta["directories"] || {}).each do |key, val|
          transcript_meta["directories"][key] ||= val
        end
        FileUtils.rm_f(transcript_meta_path) if File.symlink?(transcript_meta_path)
        File.write(transcript_meta_path, JSON.pretty_generate(transcript_meta))
      end
    end
    transcript_dir
  end
end
