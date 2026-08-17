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

    # Explicit rather than via keys:, so this can't be rescued by falling
    # through to deriving from the private key -- it isolates the stripping
    # done while validating a file's content, not stripping done elsewhere.
    it 'strips trailing newlines, so a line can be appended safely' do
      lines = described_class.resolve(keys: [private_key], explicit: [public_key])

      expect(lines.first).not_to end_with("\n")
    end

    # The failure mode this guards against: a private key is PEM, not an
    # authorized_keys line. Passed through unvalidated, it would land whole
    # -- headers, base64 body, footer -- on a remote host's authorized_keys.
    it 'refuses when --key points at a private key, rather than treating its content as a line' do
      expect { described_class.resolve(keys: [private_key], explicit: [private_key]) }
        .to raise_error(Odysseus::SetupError, /#{Regexp.escape(private_key)}/)
    end

    # One invalid --key path must not be silently dropped in favour of a
    # valid one given alongside it -- the operator asked for both, and
    # believing an unauthorised key is installed is worse than a refusal.
    it 'refuses when one of several --key paths is invalid, rather than silently dropping it' do
      other_valid = File.join(@dir, 'other.pub')
      File.write(other_valid, "ssh-ed25519 AAAAvalid valid@example\n")

      expect { described_class.resolve(keys: [], explicit: [other_valid, private_key]) }
        .to raise_error(Odysseus::SetupError, /#{Regexp.escape(private_key)}/)
    end

    it 'validates each key in a .pub containing several, yielding one line per key' do
      second_private = File.join(@dir, 'id_second')
      system('ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-C', 'second@example',
             '-f', second_private, out: File::NULL, err: File::NULL)
      second_line = File.read("#{second_private}.pub").strip
      File.write(public_key, "#{File.read(public_key).strip}\n#{second_line}\n")

      lines = described_class.resolve(keys: [private_key])

      expect(lines.size).to eq(2)
      expect(lines).to all(start_with('ssh-ed25519 '))
    end

    # An empty sibling must not read as "resolved to nothing" -- there is
    # still a usable key one step away, at the private key it sits beside.
    it 'derives when the .pub sibling is empty, rather than dropping a resolvable key' do
      File.write(public_key, '')

      lines = described_class.resolve(keys: [private_key])

      expect(lines.size).to eq(1)
      expect(lines.first).to start_with('ssh-ed25519 ')
    end

    it 'derives when the .pub sibling contains no valid key content' do
      File.write(public_key, "this is not a key\n")

      lines = described_class.resolve(keys: [private_key])

      expect(lines.size).to eq(1)
      expect(lines.first).to start_with('ssh-ed25519 ')
      expect(lines.first).not_to include('not a key')
    end

    # Guards the validation fix from over-correcting: a comment is free text,
    # not a second key field, and must survive even when it has spaces in it.
    it 'keeps a comment containing spaces intact' do
      File.write(public_key, "ssh-ed25519 AAAAcomment key with spaces in the comment\n")

      lines = described_class.resolve(keys: [private_key])

      expect(lines).to eq(['ssh-ed25519 AAAAcomment key with spaces in the comment'])
    end
  end
end
