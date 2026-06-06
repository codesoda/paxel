# Lightweight dual-output logger for the client pipeline.
#
# info()  → stdout + file  (user-visible, same as the old lambda)
# debug() → file only      (admin diagnostics, prefixed [DEBUG])
# call()  → alias for info (backward compat with lambda callers)
#
# When stdout is a TTY (the container runs with `docker run -t`), the logger
# also maintains a sticky multi-line "footer" pinned to the bottom of the
# screen — ClientPipeline uses it to render live progress bars. Permanent
# lines (info / ✗ errors) scroll cleanly above the footer; the footer repaints
# in place. The footer is stdout-only and TTY-only: the log file and every
# non-TTY surface (CI, `> file`, `| pipe`) stay byte-for-byte unchanged.
#
# All writes are mutex-protected so concurrent threads (narrative analysis,
# episode scoring) don't interleave lines or desync the footer's cursor math.
#
# INVARIANT: while a footer is painted, nothing may write raw stdout directly.
# Every user-facing line must go through this logger (info / set_footer /
# stderr_line); a stray `puts`/`$stdout.write` from a pipeline service would
# scroll under the footer and desync the cursor math. Client-path services log
# via Rails.logger or the injected @log, never bare puts (see CLAUDE.md memory
# reference_v3_scoring_pipeline_dual_context).
begin
  require "io/console" # IO#winsize for footer truncation; degrades to $COLUMNS/80
rescue LoadError
  nil
end

class PipelineLogger
  MAX_DEBUG_SECTION_LINES = 100

  CSI = "\e[".freeze
  CLEAR_TO_EOL = "#{CSI}K".freeze   # erase from cursor to end of line
  CLEAR_BELOW  = "#{CSI}J".freeze   # erase from cursor to end of screen

  # Codepoint ranges that render two terminal columns wide (a wcwidth-lite
  # table, no gem). Footer truncation measures display columns, not character
  # count — a CJK or emoji glyph in a step detail/title would otherwise slip
  # past a char-count guard, wrap to a second physical row, and desync the
  # footer's cursor math.
  WIDE_CODEPOINTS = [
    0x1100..0x115F,    # Hangul Jamo
    0x2329..0x232A,    # angle brackets
    0x2E80..0x303E,    # CJK radicals, Kangxi
    0x3041..0x33FF,    # Hiragana, Katakana, CJK symbols/punctuation
    0x3400..0x4DBF,    # CJK Unified Ext A
    0x4E00..0x9FFF,    # CJK Unified
    0xA000..0xA4CF,    # Yi
    0xAC00..0xD7A3,    # Hangul Syllables
    0xF900..0xFAFF,    # CJK Compatibility Ideographs
    0xFE30..0xFE4F,    # CJK Compatibility Forms
    0xFF00..0xFF60,    # Fullwidth Forms
    0xFFE0..0xFFE6,    # Fullwidth signs
    0x1F300..0x1FAFF,  # emoji & pictographs
    0x20000..0x3FFFD   # CJK Unified Ext B+
  ].freeze

  # out/err/tty are injectable for specs; production uses the live std streams.
  def initialize(log_file, out: $stdout, err: $stderr, tty: nil)
    @log_file = log_file
    @out = out
    @err = err
    @tty = tty.nil? ? safe_tty?(out) : tty
    @mutex = Mutex.new
    @footer = []        # logical footer lines (may carry ANSI color)
    @footer_height = 0  # physical lines currently painted on screen
  end

  def tty?
    @tty
  end

  # User-visible: stdout + file. Scrolls cleanly above the sticky footer.
  def info(msg)
    line = "[#{Time.current.strftime('%H:%M:%S.%L')}] #{msg}"
    @mutex.synchronize do
      if @tty && @footer_height.positive?
        @out.write(erase_footer_seq)
        @out.puts(line)
        @out.write(paint_footer_seq)
        @out.flush
      else
        @out.puts(line)
      end
      @log_file.puts(line)
    end
  rescue
    # Never crash on logging
  end

  # File-only: verbose debug info for admin diagnostics
  def debug(msg)
    line = "[#{Time.current.strftime('%H:%M:%S.%L')}] [DEBUG] #{msg}"
    @mutex.synchronize { @log_file.puts(line) }
  rescue
    # Never crash on logging
  end

  # File-only: structured multi-line debug section with header.
  # Capped at MAX_DEBUG_SECTION_LINES to prevent bloat on large uploads.
  def debug_section(header, lines)
    lines = Array(lines)
    @mutex.synchronize do
      ts = Time.current.strftime("%H:%M:%S.%L")
      @log_file.puts "[#{ts}] [DEBUG] ── #{header} ──"
      display_lines = lines.first(MAX_DEBUG_SECTION_LINES)
      display_lines.each { |l| @log_file.puts "[#{ts}] [DEBUG]   #{l}" }
      if lines.size > MAX_DEBUG_SECTION_LINES
        @log_file.puts "[#{ts}] [DEBUG]   ... and #{lines.size - MAX_DEBUG_SECTION_LINES} more"
      end
      @log_file.puts "[#{ts}] [DEBUG] ── /#{header} ──"
    end
  rescue
    # Never crash on logging
  end

  # Replace the sticky footer with `lines` and repaint it in place.
  # No-op when stdout isn't a TTY, so non-interactive runs stay plain.
  def set_footer(lines)
    return unless @tty
    lines = Array(lines)
    @mutex.synchronize do
      @out.write(erase_footer_seq)
      @footer = lines
      @out.write(paint_footer_seq)
      @out.flush
    end
  rescue
    # Never crash on logging
  end

  # Erase the footer entirely. Call once when the pipeline finishes so the
  # final output (completion banner / shell prompt) lands on a clean line.
  def clear_footer
    return unless @tty
    @mutex.synchronize do
      @out.write(erase_footer_seq)
      @footer = []
      @footer_height = 0
      @out.flush
    end
  rescue
    # Never crash on logging
  end

  # Footer-safe stderr line: scrolls above the footer, never hits the file.
  # Used for the per-session ✗ error lines during parallel analysis.
  def stderr_line(msg)
    @mutex.synchronize do
      if @tty && @footer_height.positive?
        @out.write(erase_footer_seq)
        @out.flush
        @err.puts(msg)
        @err.flush
        @out.write(paint_footer_seq)
        @out.flush
      else
        @err.puts(msg)
        @err.flush
      end
    end
  rescue
    # Never crash on logging
  end

  # Backward compat: code that does @log.call(msg) still works
  alias_method :call, :info

  private

  def safe_tty?(io)
    io.respond_to?(:tty?) && io.tty?
  rescue
    false
  end

  # Move the cursor to the top-left of the painted footer and clear everything
  # below it. Cursor ends where the footer's first line began — the position a
  # permanent line or a repaint should start from.
  def erase_footer_seq
    return "" if @footer_height.zero?
    seq = +"\r"
    seq << "#{CSI}#{@footer_height - 1}A" if @footer_height > 1
    seq << CLEAR_BELOW
    seq
  end

  # Paint @footer at the cursor. Each line is cleared-to-EOL first so a shorter
  # line never leaves stale characters behind. No trailing newline: the cursor
  # rests at the end of the last footer line — the invariant erase expects.
  def paint_footer_seq
    if @footer.empty?
      @footer_height = 0 # reset so a later erase doesn't miscount stale lines
      return ""
    end
    cols = terminal_cols
    painted = @footer.map { |l| CLEAR_TO_EOL + fit_width(l, cols) }
    @footer_height = painted.size
    painted.join("\n")
  end

  # Keep each footer line within the terminal width so it never wraps — a wrap
  # would add a physical line the cursor-up math doesn't know about and desync
  # the whole footer. ANSI color codes are zero-width, so measure against the
  # stripped string and only hard-truncate (dropping color) on real overflow;
  # the common case keeps its color untouched.
  def fit_width(line, cols)
    limit = [ cols - 1, 1 ].max
    visible = strip_ansi(line)
    return line if display_width(visible) <= limit
    # Overflow: drop color and truncate to `limit` display columns. Wide glyphs
    # count as two so the rendered line can't exceed the terminal width and wrap.
    truncate_to_width(visible, limit)
  end

  def strip_ansi(str)
    str.gsub(/\e\[[0-9;]*m/, "")
  end

  # Approximate display width (East-Asian-Wide / emoji count as two columns).
  def display_width(str)
    str.each_char.sum { |c| char_width(c) }
  end

  def char_width(char)
    WIDE_CODEPOINTS.any? { |range| range.cover?(char.ord) } ? 2 : 1
  end

  def truncate_to_width(str, limit)
    width = 0
    out = +""
    str.each_char do |c|
      cw = char_width(c)
      break if width + cw > limit
      out << c
      width += cw
    end
    out
  end

  def terminal_cols
    if @out.respond_to?(:winsize)
      @out.winsize[1]
    elsif ENV["COLUMNS"].to_i.positive?
      ENV["COLUMNS"].to_i
    else
      80
    end
  rescue
    80
  end
end
