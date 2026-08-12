# lib/odysseus/deploy_log.rb

require 'shellwords'

module Odysseus
  # Append-only record of what has been deployed to one host, keyed by service.
  #
  # This is the host's own account of its history: it orders versions reliably,
  # which image timestamps cannot, and it survives container removal and image
  # pruning. It is also the host-side audit trail.
  class DeployLog
    PATH_ROOT = '/var/lib/odysseus'.freeze
    FILENAME = 'deploys.log'.freeze
    TIME_FORMAT = '%Y-%m-%dT%H:%M:%SZ'.freeze

    Entry = Data.define(:at, :version, :role, :ref, :deployer, :kind, :from)

    # @param ssh [Odysseus::Deployer::SSH] connection to the host
    # @param service [String] the service: value from deploy.yml, never role-suffixed
    def initialize(ssh:, service:)
      @ssh = ssh
      @service = service
    end

    # @return [String] absolute path of this service's log on the host
    def path
      File.join(PATH_ROOT, @service, FILENAME)
    end

    # Record one deploy of one role.
    #
    # @param kind [String] 'deployed' or 'rolled-back'
    # @param from [String, nil] the version replaced, for a rollback
    def append(version:, role:, ref:, deployer:, kind: 'deployed', from: nil)
      fields = [
        Time.now.utc.strftime(TIME_FORMAT), sanitize(version), sanitize(role.to_s),
        sanitize(ref || '-'), sanitize(deployer || '-'), sanitize(kind)
      ]
      fields << "from=#{sanitize(from)}" if from

      # Escape the assembled line as ONE argument. printf reuses its format for
      # every remaining argument, so passing the fields separately would write
      # one line per field instead of one line per deploy.
      line = Shellwords.escape(fields.map(&:to_s).join(' '))

      @ssh.execute("mkdir -p #{Shellwords.escape(File.dirname(path))}")
      @ssh.execute("printf '%s\\n' #{line} >> #{Shellwords.escape(path)}")
    end

    # @return [Array<Entry>] parsed entries, oldest first; empty when absent
    def entries
      raw = @ssh.execute("cat #{Shellwords.escape(path)} 2>/dev/null || true")

      raw.to_s.lines.filter_map { |line| parse_line(line) }
    end

    private

    # The log's shape -- one line per record, fields separated by single
    # spaces -- is load-bearing: phase 3's rollback ordering reads this file
    # and relies on exactly one record per line and stable field positions.
    # A field value is not guaranteed to be whitespace-free (git config
    # user.email, for instance, can contain a literal newline), and
    # `Shellwords.escape` treats a newline as safe to embed rather than
    # stripping it, so an unsanitised value could split one record across
    # multiple lines or shift every field after it. Collapse any run of
    # whitespace in a field to a single underscore so the shape can never be
    # broken, instead of raising and risking the record being dropped
    # entirely (callers log after a deploy has already succeeded).
    def sanitize(value)
      value.to_s.gsub(/\s+/, '_')
    end

    def parse_line(line)
      at, version, role, ref, deployer, kind, extra = line.strip.split(/\s+/, 7)
      return nil if at.nil? || version.nil? || kind.nil?
      return nil unless at.match?(/\A\d{4}-\d{2}-\d{2}T/)

      Entry.new(
        at: at, version: version, role: role, ref: ref, deployer: deployer,
        kind: kind, from: extra&.slice(/\Afrom=(\S+)/, 1)
      )
    end
  end
end
