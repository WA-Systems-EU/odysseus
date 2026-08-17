# spec/odysseus/deploy_log_spec.rb

require 'spec_helper'
require 'shellwords'

RSpec.describe Odysseus::DeployLog do
  let(:mock_ssh) { instance_double(Odysseus::Deployer::SSH, user: 'root') }
  let(:log) { described_class.new(ssh: mock_ssh, service: 'myapp') }
  let(:path) { '/var/lib/odysseus/myapp/deploys.log' }

  describe '#append' do
    it 'creates the directory and appends one line' do
      commands = []
      allow(mock_ssh).to receive(:execute) { |cmd|
        commands << cmd
        ''
      }

      log.append(version: 'abc123def456', role: :web, ref: 'main', deployer: 'dev@example.com')

      expect(commands.first).to include('mkdir -p /var/lib/odysseus/myapp')
      expect(commands.last).to include(">> #{path}")
      expect(commands.last).to include('abc123def456')
      expect(commands.last).to include('web')
      expect(commands.last).to include('deployed')
    end

    it 'records a rollback with the version it came from' do
      commands = []
      allow(mock_ssh).to receive(:execute) { |cmd|
        commands << cmd
        ''
      }

      log.append(
        version: '9f8e7d6c5b4a', role: :web, ref: 'main', deployer: 'dev@example.com',
        kind: 'rolled-back', from: 'abc123def456'
      )

      expect(commands.last).to include('rolled-back')
      # The whole entry is one escaped shell argument (see the "one line" spec
      # below), so "from=..." is backslash-escaped in the raw command text.
      # Decode it the way a real shell would before asserting on its content.
      decoded = Shellwords.split(commands.last.sub(/\s*>>.*\z/, '')).last
      expect(decoded).to include('from=abc123def456')
    end

    it 'escapes values so a hostile ref cannot inject a command' do
      commands = []
      allow(mock_ssh).to receive(:execute) { |cmd|
        commands << cmd
        ''
      }

      log.append(version: 'abc', role: :web, ref: 'main; rm -rf /', deployer: 'dev@example.com')

      # Parse the command the way a real shell would: the hostile ref must not
      # produce extra shell words (which is what would let `rm` run as its own
      # command). Its whitespace is also sanitised (see the field-sanitising
      # spec below), so what survives is the semicolon-joined, underscored form.
      tokens = Shellwords.split(commands.last.sub(/\s*>>.*\z/, ''))
      expect(tokens.length).to eq(3)
      expect(tokens).not_to include('rm')
      expect(tokens.last).to include('main;_rm_-rf_/')
    end

    it 'writes the whole entry as one line rather than one line per field' do
      commands = []
      allow(mock_ssh).to receive(:execute) { |cmd|
        commands << cmd
        ''
      }

      log.append(version: 'abc123def456', role: :web, ref: 'main', deployer: 'dev@example.com')

      # printf reuses its format for each argument, so the data must arrive as a
      # single argument. Drop the redirection, then count the words a shell sees.
      tokens = Shellwords.split(commands.last.sub(/\s*>>.*\z/, ''))
      expect(tokens.length).to eq(3)
      expect(tokens[0]).to eq('printf')
      expect(tokens[2]).to match(/\A\S+ abc123def456 web main dev@example\.com deployed\z/)
    end

    it 'sanitises whitespace in a field so one record cannot become two lines' do
      commands = []
      allow(mock_ssh).to receive(:execute) { |cmd|
        commands << cmd
        ''
      }

      log.append(version: 'abc', role: :web, ref: 'main', deployer: "dev@example.com\nrogue line")

      tokens = Shellwords.split(commands.last.sub(/\s*>>.*\z/, ''))
      payload = tokens.last
      expect(payload).not_to include("\n")
      expect(payload).to include('dev@example.com_rogue_line')
    end

    it 'maps a blank field to a placeholder instead of leaving it empty' do
      commands = []
      allow(mock_ssh).to receive(:execute) { |cmd|
        commands << cmd
        ''
      }

      # ref: '' rather than nil — append's own `ref || '-'` only catches nil.
      log.append(version: 'abc', role: :web, ref: '', deployer: 'dev@example.com')

      tokens = Shellwords.split(commands.last.sub(/\s*>>.*\z/, ''))
      fields = tokens.last.split

      expect(fields.length).to eq(6)
      expect(fields[3]).to eq('-')
    end

    it 'uses a timestamp in the format the log defines' do
      commands = []
      allow(mock_ssh).to receive(:execute) { |cmd|
        commands << cmd
        ''
      }

      log.append(version: 'abc', role: :web, ref: 'main', deployer: 'dev@example.com')

      expect(commands.last).to match(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z/)
    end
  end

  describe '#entries' do
    it 'parses the log newest last' do
      allow(mock_ssh).to receive(:execute).and_return(
        "2026-08-12T11:27:59Z abc123def456 web main dev@example.com deployed\n" \
        "2026-08-12T14:02:11Z 9f8e7d6c5b4a web main dev@example.com rolled-back from=abc123def456\n"
      )

      entries = log.entries

      expect(entries.map(&:version)).to eq(%w[abc123def456 9f8e7d6c5b4a])
      expect(entries.last.kind).to eq('rolled-back')
      expect(entries.last.from).to eq('abc123def456')
      expect(entries.first.role).to eq('web')
      expect(entries.first.deployer).to eq('dev@example.com')
    end

    it 'is empty when the log does not exist' do
      allow(mock_ssh).to receive(:execute).and_return('')

      expect(log.entries).to eq([])
    end

    it 'skips lines it cannot parse rather than raising' do
      allow(mock_ssh).to receive(:execute).and_return("garbage\n2026-08-12T11:27:59Z abc web main d deployed\n")

      expect(log.entries.map(&:version)).to eq(['abc'])
    end

    it 'rejects a well-formed-looking line whose first token is not a timestamp' do
      allow(mock_ssh).to receive(:execute).and_return(
        "hello world foo bar baz 123\n2026-08-12T11:27:59Z abc web main d deployed\n"
      )

      expect(log.entries.map(&:version)).to eq(['abc'])
    end

    # A shifted record (a blank field swallowed on write, or hand-edited log)
    # still starts with something that matches the timestamp regex and still
    # has non-nil at/version/kind once the limit-7 split merges the overflow
    # into the last field, so without a count check it parses as a plausible
    # -looking wrong record instead of being skipped.
    it 'rejects a valid-looking timestamp with the wrong number of fields' do
      allow(mock_ssh).to receive(:execute).and_return(
        "2026-08-12T11:27:59Z abc123def456 web main dev@example.com deployed extra_word extra_word2\n" \
        "2026-08-12T11:27:59Z abc web main d deployed\n"
      )

      expect(log.entries.map(&:version)).to eq(['abc'])
    end

    # For a root connection, path and legacy_path are the same file: `entries`
    # must not read it twice. The command has to stay byte-identical to what
    # it was before the deploy-user change, or "Nothing changes for a root
    # install" in the changelog is not true.
    it 'reads the log once for a root connection, where the two locations are the same' do
      command = nil
      allow(mock_ssh).to receive(:execute) do |cmd|
        command = cmd
        ''
      end

      log.entries

      expect(command).to eq("cat #{Shellwords.escape(path)} 2>/dev/null || true")
    end
  end

  describe 'where the log lives' do
    it 'is the system location for root' do
      ssh = instance_double(Odysseus::Deployer::SSH, user: 'root')
      expect(described_class.new(ssh: ssh, service: 'myapp').path)
        .to eq('/var/lib/odysseus/myapp/deploys.log')
    end

    it 'is under the home directory for a deploy user' do
      ssh = instance_double(Odysseus::Deployer::SSH, user: 'odysseus')
      allow(ssh).to receive(:execute).with('echo $HOME').and_return("/home/odysseus\n")

      expect(described_class.new(ssh: ssh, service: 'myapp').path)
        .to eq('/home/odysseus/.odysseus/myapp/deploys.log')
    end

    it 'knows the location a root install used, whoever is connected' do
      ssh = instance_double(Odysseus::Deployer::SSH, user: 'odysseus')
      allow(ssh).to receive(:execute).with('echo $HOME').and_return("/home/odysseus\n")

      expect(described_class.new(ssh: ssh, service: 'myapp').legacy_path)
        .to eq('/var/lib/odysseus/myapp/deploys.log')
    end
  end

  describe 'reading a host that used to deploy as root' do
    let(:ssh) { instance_double(Odysseus::Deployer::SSH, user: 'odysseus') }
    let(:log) { described_class.new(ssh: ssh, service: 'myapp') }
    let(:record) { '2026-08-16T10:00:00Z abc123 web - thomas@imfiny.com deployed' }

    before { allow(ssh).to receive(:execute).with('echo $HOME').and_return("/home/odysseus\n") }

    it 'still reads the location a root install wrote, so history survives the move' do
      command = nil
      allow(ssh).to receive(:execute) do |cmd|
        if cmd == 'echo $HOME'
          "/home/odysseus\n"
        else
          (command = cmd
           "#{record}\n")
        end
      end

      log.entries

      # The fallback itself happens in the shell (`cat a || cat b`), not in
      # Ruby, so a doubled connection cannot exercise it. What IS testable —
      # and what actually fails if the fallback is dropped — is that the legacy
      # path appears in the command at all. Asserting on the parsed entries
      # instead would pass whether or not the fallback were there, because the
      # double answers every cat identically.
      expect(command).to include('/var/lib/odysseus/myapp/deploys.log')
    end

    it 'reads the new location in preference to the old' do
      command = nil
      allow(ssh).to receive(:execute) do |cmd|
        if cmd == 'echo $HOME'
          "/home/odysseus\n"
        else
          (command = cmd
           "#{record}\n")
        end
      end

      log.entries

      # The new path must be attempted before the legacy one, or a migrated
      # host would keep reading its frozen history forever.
      expect(command.index('/home/odysseus/.odysseus/myapp/deploys.log'))
        .to be < command.index('/var/lib/odysseus/myapp/deploys.log')
    end

    # `&&` would preserve both existing assertions above — path presence and
    # ordering — while changing what the command does: it would only read the
    # legacy path when the new one succeeds, merging old history under new
    # history for a migrated host instead of falling back to it.
    it 'joins the new and legacy locations with || rather than &&' do
      command = nil
      allow(ssh).to receive(:execute) do |cmd|
        if cmd == 'echo $HOME'
          "/home/odysseus\n"
        else
          (command = cmd
           "#{record}\n")
        end
      end

      log.entries

      expect(command).to include(
        "cat #{Shellwords.escape(log.path)} 2>/dev/null || cat #{Shellwords.escape(log.legacy_path)} 2>/dev/null"
      )
    end

    it 'appends only to the new location' do
      written = nil
      allow(ssh).to receive(:execute) do |cmd|
        written = cmd if cmd.start_with?('printf')
        cmd == 'echo $HOME' ? "/home/odysseus\n" : ''
      end

      log.append(version: 'abc123', role: :web, ref: nil, deployer: 'thomas@imfiny.com')

      expect(written).to include('/home/odysseus/.odysseus/myapp/deploys.log')
      expect(written).not_to include('/var/lib/odysseus')
    end
  end
end
