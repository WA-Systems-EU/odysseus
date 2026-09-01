require 'spec_helper'
require 'tmpdir'
require 'open3'

# Detecting an encrypted key matters because odysseus will never prompt for a
# passphrase -- non_interactive is deliberate on a deploy connection -- so the
# only useful thing it can do is say which key is locked and that ssh-agent is
# the answer. Without this the failure surfaces as "check your SSH keys",
# which is the one thing that is not wrong.
RSpec.describe Odysseus::SSHKey do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  def generate(type:, passphrase:, format: nil)
    path = File.join(@dir, "id_#{type}_#{passphrase.empty? ? 'plain' : 'locked'}#{format}")
    args = ['ssh-keygen', '-t', type, '-N', passphrase, '-f', path, '-q', '-C', 'spec']
    args += ['-b', '2048'] if type == 'rsa'
    args += ['-m', format.to_s.delete('_').upcase] if format
    _, err, status = Open3.capture3(*args)
    raise "ssh-keygen failed: #{err}" unless status.success?

    path
  end

  describe '.encrypted?' do
    # The OpenSSH container, which is what modern ssh-keygen writes by default.
    it 'is true for a passphrase-protected ed25519 key' do
      expect(described_class.encrypted?(generate(type: 'ed25519', passphrase: 'hunter2'))).to be true
    end

    it 'is false for an unencrypted ed25519 key' do
      expect(described_class.encrypted?(generate(type: 'ed25519', passphrase: ''))).to be false
    end

    it 'is true for a passphrase-protected RSA key' do
      expect(described_class.encrypted?(generate(type: 'rsa', passphrase: 'hunter2'))).to be true
    end

    it 'is false for an unencrypted RSA key' do
      expect(described_class.encrypted?(generate(type: 'rsa', passphrase: ''))).to be false
    end

    # Classic PEM announces it in a header instead, and old hosts still have
    # these lying around.
    it 'is true for a passphrase-protected PEM key' do
      path = generate(type: 'rsa', passphrase: 'hunter2', format: :pem)
      expect(described_class.encrypted?(path)).to be true
    end

    it 'is false for an unencrypted PEM key' do
      path = generate(type: 'rsa', passphrase: '', format: :pem)
      expect(described_class.encrypted?(path)).to be false
    end

    # Never the reason a deploy fails: a missing or unreadable key is a
    # different problem with a different message.
    it 'is false for a path that does not exist' do
      expect(described_class.encrypted?(File.join(@dir, 'nope'))).to be false
    end

    it 'is false for a file that is not a key at all' do
      path = File.join(@dir, 'garbage')
      File.write(path, "hello\n")
      expect(described_class.encrypted?(path)).to be false
    end

    it 'is false for a public key' do
      expect(described_class.encrypted?("#{generate(type: 'ed25519', passphrase: '')}.pub")).to be false
    end
  end
end
