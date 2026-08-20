# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Odysseus::CommandRedaction do
  describe '.redact' do
    # The case this was written for. `docker login --password-stdin` is the
    # recommended idiom precisely because it keeps the password off the argv,
    # but odysseus feeds it by interpolating into `echo '...' |`, which puts it
    # right back into the command string that SSH#execute echoes under
    # --debug. No -p and no --password, so every pattern the CLI's own redactor
    # uses misses it.
    it 'hides a password piped into docker login' do
      command = "echo 'hunter2' | docker login registry.example.com -u deploy --password-stdin"

      redacted = described_class.redact(command)

      expect(redacted).not_to include('hunter2')
      expect(redacted).to include('docker login registry.example.com')
      expect(redacted).to include('--password-stdin')
    end

    it 'hides a password with shell metacharacters in it' do
      command = "echo 'p@ss|w0rd$(x)' | docker login r -u u --password-stdin"

      expect(described_class.redact(command)).not_to include('p@ss|w0rd')
    end

    it 'hides -p and --password arguments' do
      expect(described_class.redact('mysql -p s3cret')).not_to include('s3cret')
      expect(described_class.redact('tool --password s3cret')).not_to include('s3cret')
    end

    it 'hides secret-shaped environment assignments' do
      %w[API_KEY TOKEN SECRET PASSWORD MASTER_KEY].each do |name|
        expect(described_class.redact("docker run -e #{name}=abc123 img")).not_to include('abc123')
      end
    end

    # The property that matters as much as redacting: a redactor that mangles
    # ordinary commands makes --debug useless, which is the same outcome as not
    # having it. These are real commands odysseus sends.
    it 'leaves ordinary commands untouched' do
      [
        "docker ps --filter label=odysseus.service=myapp --format '{{json .}}'",
        'sudo -n usermod -aG docker deploy',
        'getent passwd deploy | cut -d: -f6',
        'docker info --format \'{{.ServerVersion}}\''
      ].each do |command|
        expect(described_class.redact(command)).to eq(command)
      end
    end

    it 'does not redact the word password when it names nothing' do
      command = 'grep -q password /etc/shadow'

      expect(described_class.redact(command)).to eq(command)
    end
  end
end
