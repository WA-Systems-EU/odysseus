# odysseus-cli/lib/odysseus/cli/ui.rb
#
# Terminal UI renderer for Odysseus CLI.
#
# Default mode: numbered steps with animated spinners that resolve to ✓/✗.
# Debug mode (--debug): verbose plain-text output, no spinners.

module Odysseus
  module CLI
    # IO wrapper that redacts sensitive values before writing
    class RedactingIO
      def initialize(io, redact_fn)
        @io = io
        @redact = redact_fn
      end

      def write(str)
        @io.write(@redact.call(str.to_s))
      end

      def puts(*args)
        args.each { |a| @io.puts(@redact.call(a.to_s)) }
        @io.puts if args.empty?
      end

      def print(*args)
        args.each { |a| @io.print(@redact.call(a.to_s)) }
      end

      def flush
        @io.flush
      end

      def respond_to_missing?(method, include_private = false)
        @io.respond_to?(method, include_private)
      end

      def method_missing(method, *args, &block)
        @io.send(method, *args, &block)
      end
    end

    class UI
      SPINNER_FRAMES = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏].freeze

      # ANSI color helpers
      COPPER  = "\e[38;2;255;183;123m".freeze
      MINT    = "\e[38;2;112;216;200m".freeze
      RED     = "\e[38;2;255;100;100m".freeze
      DIM     = "\e[2m".freeze
      RESET   = "\e[0m".freeze

      def initialize(debug: false)
        @debug = debug
        @step_number = 0
      end

      def debug?
        @debug
      end

      def reset_steps!
        @step_number = 0
      end

      def next_step!
        @step_number += 1
      end

      # --- Header ---

      def header(title)
        reset_steps!
        if debug?
          puts "\e[36m#{title}\e[0m"
        else
          puts ""
          puts "  #{COPPER}#{title}#{RESET}"
        end
      end

      def info(label, value)
        if debug?
          puts "  #{label}: #{value}"
        else
          puts "  #{DIM}#{label}:#{RESET} #{value}"
        end
      end

      def blank
        puts ""
      end

      # --- Single spin step ---
      # Shows spinner while block runs, resolves to ✓/✗.
      # Captures stdout from the block so it doesn't leak.

      def spin_step(message)
        next_step!
        num = step_num_str

        if debug?
          puts "  #{num}  #{redact(message)}"
          result = yield
          puts "  #{num}  ✓ #{redact(message)}"
          return result
        end

        result = nil
        err = nil
        done = false

        # Capture stdout from the block
        old_stdout = $stdout
        rd, wr = IO.pipe
        $stdout = wr

        thread = Thread.new do
          begin
            result = yield
          rescue => e
            err = e
          ensure
            done = true
            wr.close
          end
        end

        frame_idx = 0
        loop do
          break if done
          frame = SPINNER_FRAMES[frame_idx % SPINNER_FRAMES.size]
          old_stdout.print "\r  #{DIM}#{num}#{RESET}  #{COPPER}#{frame}#{RESET}  #{message}"
          old_stdout.flush
          frame_idx += 1
          sleep 0.08
        end

        rd.close
        $stdout = old_stdout
        thread.join

        print "\r\e[K"

        if err
          puts "  #{DIM}#{num}#{RESET}  #{RED}✗#{RESET}  #{message}"
          raise err
        else
          puts "  #{DIM}#{num}#{RESET}  #{MINT}✓#{RESET}  #{message}"
        end

        result
      end

      # --- Streaming steps ---
      # Runs a block, captures its stdout line by line, and renders each
      # meaningful line as a sub-step with spinner → ✓.
      # All sub-steps share the same step number.

      def stream_steps(title: nil)
        next_step!
        num = step_num_str

        if debug?
          puts "  #{num}  > #{title}" if title
          # In debug mode, let output flow but redact sensitive values
          old_stdout = $stdout
          $stdout = RedactingIO.new(old_stdout, method(:redact))
          begin
            yield
          ensure
            $stdout = old_stdout
          end
          return
        end

        # Show section header if provided
        puts "  #{DIM}#{num}#{RESET}  #{COPPER}>#{RESET}  #{title}" if title

        result = nil
        err = nil
        done = false
        current_line = nil

        # Capture stdout
        old_stdout = $stdout
        rd, wr = IO.pipe

        thread = Thread.new do
          $stdout = wr
          begin
            result = yield
          rescue => e
            err = e
          ensure
            done = true
            wr.close
          end
        end

        frame_idx = 0
        buf = ""

        loop do
          # Non-blocking read from pipe
          begin
            chunk = rd.read_nonblock(4096)
            buf << chunk
          rescue IO::WaitReadable
            # No data available yet
          rescue EOFError
            break
          end

          # Process complete lines
          while (nl = buf.index("\n"))
            line = buf.slice!(0..nl).strip
            next if line.empty?
            line = clean_line(line)
            next unless line

            # Note lines (prefixed with ~) render as indented grey text, no spinner
            if line.start_with?('~')
              if current_line
                old_stdout.print "\r\e[K"
                old_stdout.puts "  #{DIM}#{num}#{RESET}  #{MINT}✓#{RESET}  #{current_line}"
                current_line = nil
              end
              old_stdout.puts "  #{DIM}#{num}#{RESET}     #{DIM}#{line[1..]}#{RESET}"
              next
            end

            # Resolve previous sub-step
            if current_line
              old_stdout.print "\r\e[K"
              old_stdout.puts "  #{DIM}#{num}#{RESET}  #{MINT}✓#{RESET}  #{current_line}"
            end

            current_line = line
          end

          # Animate spinner on current line
          if current_line
            frame = SPINNER_FRAMES[frame_idx % SPINNER_FRAMES.size]
            old_stdout.print "\r  #{DIM}#{num}#{RESET}  #{COPPER}#{frame}#{RESET}  #{current_line}"
            old_stdout.flush
          end

          frame_idx += 1
          sleep 0.06

          break if done && buf.empty?
        end

        rd.close
        $stdout = old_stdout
        thread.join

        # Resolve the final sub-step
        if current_line
          print "\r\e[K"
          puts "  #{DIM}#{num}#{RESET}  #{MINT}✓#{RESET}  #{current_line}"
        end

        raise err if err
        result
      end

      # --- Immediate steps (no async) ---

      def step_ok(message)
        next_step!
        puts "  #{DIM}#{step_num_str}#{RESET}  #{MINT}✓#{RESET}  #{message}"
      end

      def step_fail(message)
        next_step!
        puts "  #{DIM}#{step_num_str}#{RESET}  #{RED}✗#{RESET}  #{message}"
      end

      def step_info(message)
        next_step!
        puts "  #{DIM}#{step_num_str}#{RESET}  #{COPPER}➜#{RESET}  #{message}"
      end

      # --- Simple output (no numbering) ---

      def success(message)
        puts "  #{MINT}✓#{RESET} #{message}"
      end

      def error(message)
        puts "  #{RED}✗#{RESET} #{message}"
      end

      def warn(message)
        puts "  \e[33m!#{RESET} #{message}"
      end

      def step(message)
        if debug?
          puts "  #{redact(message)}"
        else
          puts "  #{DIM}›#{RESET} #{message}"
        end
      end

      def detail(message)
        puts "    #{DIM}#{redact(message)}#{RESET}" if debug?
      end

      # --- Tables ---

      def table(headers:, rows:)
        return if rows.empty?

        widths = headers.map.with_index do |h, i|
          [h.to_s.length, rows.map { |r| r[i].to_s.length }.max || 0].max
        end

        header_line = headers.map.with_index { |h, i| h.to_s.ljust(widths[i]) }.join("  ")
        puts "  #{COPPER}#{header_line}#{RESET}"
        puts "  #{widths.map { |w| '─' * w }.join('  ')}"

        rows.each do |row|
          line = row.map.with_index { |c, i| c.to_s.ljust(widths[i]) }.join("  ")
          puts "  #{line}"
        end
      end

      # --- Section divider ---

      def section(title)
        if debug?
          puts "\e[36m=== #{title} ===\e[0m"
        else
          puts "  #{COPPER}▸ #{title}#{RESET}"
        end
      end

      # --- Deploy-specific helpers ---

      def deploy_header(service:, image:, image_tag:, build: false, distribution: nil)
        header "Odysseus Deploy"
        info "Service", service
        info "Image", "#{image}:#{image_tag}"
        info "Distribute", distribution if build && distribution
        blank
      end

      def deploy_complete(duration: nil)
        msg = "Deployment successful"
        msg += " in #{duration}s" if duration
        step_ok msg
      end

      # --- Logger adapter ---

      def build_logger
        ui = self
        Object.new.tap do |l|
          l.define_singleton_method(:info) { |msg| ui.step(msg) }
          l.define_singleton_method(:warn) { |msg| ui.warn(msg) }
          l.define_singleton_method(:error) { |msg| ui.error(msg) }
          l.define_singleton_method(:debug) { |msg| ui.detail(msg) }
          l.define_singleton_method(:verbose?) { ui.debug? }
        end
      end

      private

      def step_num_str
        format('%02d', @step_number)
      end

      # Redact sensitive values from output.
      # Matches common patterns for API keys, tokens, passwords, and secrets
      # passed as env vars or command flags.
      def redact(text)
        text
          .gsub(/(-e\s+\w*(?:KEY|TOKEN|SECRET|PASSWORD|MASTER_KEY|API_KEY|CREDENTIALS)\s*=\s*)\S+/i, '\1[REDACTED]')
          .gsub(/((?:KEY|TOKEN|SECRET|PASSWORD|MASTER_KEY|API_KEY|CREDENTIALS)\s*[=:]\s*)\S+/i, '\1[REDACTED]')
          .gsub(/(-p\s+)\S+/, '\1[REDACTED]')
          .gsub(/(--password\s+)\S+/, '\1[REDACTED]')
      end

      # Clean up raw output lines from core orchestrators.
      # Returns nil for lines we should skip.
      def clean_line(line)
        # Strip leading whitespace
        line = line.sub(/^\s+/, '')

        # Skip empty / decorative / noise
        return nil if line.empty?
        return nil if line.start_with?('===', '---', '[WARN]', '[ERROR]')

        # Skip verbose detail lines
        return nil if line.match?(/^Image: /)
        return nil if line.match?(/^Environment: /)
        return nil if line.match?(/^Resources: /)
        return nil if line.match?(/^Volumes: /)
        return nil if line.match?(/^Found \d+ existing container/)
        return nil if line.match?(/^Deploying .+ \(role: .+\)/)
        return nil if line.match?(/^Building locally/)
        return nil if line.match?(/^Pushing image via SSH to/)
        return nil if line.match?(/^Deploy complete for /)
        return nil if line.match?(/^Rolling deploy complete/)

        # Skip "done" echo lines — the spinner→✓ already shows completion
        return nil if line.match?(/^Container started: /)
        return nil if line.match?(/^Health check passed$/)
        return nil if line.match?(/^Caddy routing configured$/)
        return nil if line.match?(/^Old container removed$/)
        return nil if line.match?(/^Image pulled$/)
        return nil if line.match?(/^Attached to proxy$/)

        # Note lines — indented grey text under the previous step
        return '~Caddy already running' if line.match?(/^Caddy already running$/)
        return '~Caddy started' if line.match?(/^Caddy started$/)
        return '~Caddy is ready' if line.match?(/^Caddy is ready$/)

        # Map known messages to clean versions
        CLEAN_MESSAGES.each do |pattern, replacement|
          if line.match?(pattern)
            return line.sub(pattern, replacement)
          end
        end

        line
      end

      CLEAN_MESSAGES = {
        /^Ensuring Caddy proxy is running\.\.\./ => 'Starting Caddy',
        /^Starting new container\.\.\.$/ => 'Starting container',
        /^Waiting for health check.*/ => 'Health check',
        /^Adding to Caddy proxy.*/ => 'Caddy route update',
        /^Draining old container.*/ => 'Draining old container',
        /^Pulling image\.\.\.$/ => 'Pulling image',
        /^Building image: .+$/ => 'Building image',
        /^Pushing to (.+)\.\.\./ => 'Pushing image to \1',
        /^Starting (.+)\.\.\.$/ => 'Starting \1',
        /^Stopping (.+) .*/ => 'Stopping \1',
        /^Attaching (.+) to proxy.*/ => 'Attaching \1 to proxy',
      }.freeze
    end
  end
end
