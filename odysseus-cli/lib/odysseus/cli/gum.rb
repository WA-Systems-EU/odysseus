# odysseus-cli/lib/odysseus/cli/gum.rb
# Wrapper for Charm's gum CLI tool
# https://github.com/charmbracelet/gum

require 'open3'
require 'tempfile'

module Odysseus
  module CLI
    module Gum
      class << self
        # Check if gum is installed and available
        def available?
          @available ||= system('which gum > /dev/null 2>&1')
        end

        # Display a spinner while executing a block
        # Returns the block's result
        def spin(title:, spinner: 'dot')
          return yield unless available?

          result = nil
          error = nil

          # We can't use gum spin directly with Ruby blocks, so we show spinner
          # and run the block in a thread
          spin_pid = spawn("gum spin --spinner #{spinner} --title #{shell_escape(title)} -- sleep infinity",
                           out: '/dev/null', err: '/dev/null')

          begin
            result = yield
          rescue => e
            error = e
          ensure
            Process.kill('TERM', spin_pid) rescue nil
            Process.wait(spin_pid) rescue nil
          end

          raise error if error
          result
        end

        # Interactive selection menu
        # Returns selected option or nil if cancelled
        def choose(options, header: nil)
          return nil unless available?

          args = ['gum', 'choose']
          args += ['--header', header] if header
          args += options

          stdout, status = Open3.capture2(*args)
          return nil unless status.success?

          stdout.strip
        end

        # Yes/No confirmation dialog
        # Returns true for yes, false for no
        def confirm(message)
          return true unless available?

          system('gum', 'confirm', message)
        end

        # Style text with borders, colors, padding
        def style(text, border: nil, foreground: nil, background: nil, padding: nil, margin: nil, bold: false)
          return text unless available?

          args = ['gum', 'style']
          args += ['--border', border] if border
          args += ['--foreground', foreground.to_s] if foreground
          args += ['--background', background.to_s] if background
          args += ['--padding', padding.to_s] if padding
          args += ['--margin', margin.to_s] if margin
          args << '--bold' if bold
          args << text

          stdout, status = Open3.capture2(*args)
          status.success? ? stdout : text
        end

        # Display a table from headers and rows
        # Returns formatted table string
        def table(headers:, rows:)
          return simple_table(headers, rows) unless available?

          # gum table reads CSV from stdin
          csv_data = [headers.join(',')]
          rows.each do |row|
            csv_data << row.map { |cell| csv_escape(cell.to_s) }.join(',')
          end

          stdout, status = Open3.capture2('gum', 'table', stdin_data: csv_data.join("\n"))
          status.success? ? stdout : simple_table(headers, rows)
        end

        # Format text (markdown, code, etc.)
        def format(text, type: 'markdown')
          return text unless available?

          stdout, status = Open3.capture2('gum', 'format', '-t', type, stdin_data: text)
          status.success? ? stdout : text
        end

        # Display a log message with level styling
        def log(message, level: 'info')
          return puts(message) unless available?

          system('gum', 'log', '-l', level, message)
        end

        # Join multiple styled blocks horizontally or vertically
        def join(*texts, horizontal: false)
          return texts.join("\n") unless available?

          args = ['gum', 'join']
          args << '--horizontal' if horizontal
          args += texts

          stdout, status = Open3.capture2(*args)
          status.success? ? stdout : texts.join(horizontal ? ' ' : "\n")
        end

        private

        def shell_escape(str)
          "'#{str.gsub("'", "'\\\\''")}'"
        end

        def csv_escape(str)
          if str.include?(',') || str.include?('"') || str.include?("\n")
            "\"#{str.gsub('"', '""')}\""
          else
            str
          end
        end

        # Fallback simple table for when gum is not available
        def simple_table(headers, rows)
          widths = headers.map.with_index do |h, i|
            [h.to_s.length, rows.map { |r| r[i].to_s.length }.max || 0].max
          end

          lines = []
          lines << headers.map.with_index { |h, i| h.to_s.ljust(widths[i]) }.join('  ')
          lines << widths.map { |w| '-' * w }.join('  ')
          rows.each do |row|
            lines << row.map.with_index { |c, i| c.to_s.ljust(widths[i]) }.join('  ')
          end
          lines.join("\n")
        end
      end
    end
  end
end
