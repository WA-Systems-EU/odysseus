# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

RSpec.describe Odysseus::Setup::PublicKey do
  # A real keypair on disk, because the whole point of this class is reading
  # real files and shelling out to real ssh-keygen. Stubbing either would test
  # the stub.
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      system('ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-C', 'test@example',
             '-f', File.join(dir, 'id_test'), out: File::NULL, err: File::NULL)
      example.run
    end
  end

  let(:private_key) { File.join(@dir, 'id_test') }
  let(:public_key)  { "#{private_key}.pub" }

  describe '.resolve' do
    it 'reads the .pub sibling of a private key' do
      lines = described_class.resolve(keys: [private_key])

      expect(lines.size).to eq(1)
      expect(lines.first).to start_with('ssh-ed25519 ')
    end

    it 'prefers an explicit path over the sibling' do
      other = File.join(@dir, 'explicit.pub')
      File.write(other, "ssh-ed25519 AAAAexplicit explicit@example\n")

      lines = described_class.resolve(keys: [private_key], explicit: [other])

      expect(lines).to eq(['ssh-ed25519 AAAAexplicit explicit@example'])
    end

    # Common on machines where keys were copied rather than generated.
    it 'derives the public half when only the private key exists' do
      File.delete(public_key)

      lines = described_class.resolve(keys: [private_key])

      expect(lines.size).to eq(1)
      expect(lines.first).to start_with('ssh-ed25519 ')
    end

    # ssh-keygen -y -f prompts for a passphrase on an encrypted key. With no
    # terminal and no stdin, that prompt fails fast rather than hanging odysseus
    # waiting for input it can never supply -- the same reasoning as the sudo
    # probe in Setup::Escalation. Confirms it surfaces as the ordinary "no
    # public key" error, not a hang or a raw ssh-keygen crash.
    it 'refuses rather than hang when the only key found is passphrase-protected' do
      encrypted = File.join(@dir, 'encrypted')
      system('ssh-keygen', '-q', '-t', 'ed25519', '-N', 'a-passphrase', '-C', 'test@example',
             '-f', encrypted, out: File::NULL, err: File::NULL)
      File.delete("#{encrypted}.pub")

      expect { described_class.resolve(keys: [encrypted]) }
        .to raise_error(Odysseus::SetupError, /no public key/i)
    end

    it 'refuses when it can find nothing, rather than returning empty' do
      expect { described_class.resolve(keys: [File.join(@dir, 'nonexistent')]) }
        .to raise_error(Odysseus::SetupError, /no public key/i)
    end

    it 'names the paths it looked at, so the reader can fix the config' do
      missing = File.join(@dir, 'nonexistent')

      expect { described_class.resolve(keys: [missing]) }
        .to raise_error(Odysseus::SetupError, /#{Regexp.escape(missing)}/)
    end

    it 'expands a leading tilde, as ssh.keys entries are written' do
      expect { described_class.resolve(keys: ['~/definitely-not-a-key-abc123']) }
        .to raise_error(Odysseus::SetupError, /#{Regexp.escape(Dir.home)}/)
    end

    it 'returns one line per key, de-duplicated' do
      lines = described_class.resolve(keys: [private_key, private_key])

      expect(lines.size).to eq(1)
    end

    it 'strips trailing newlines, so a line can be appended safely' do
      lines = described_class.resolve(keys: [private_key])

      expect(lines.first).not_to end_with("\n")
    end
  end
end
