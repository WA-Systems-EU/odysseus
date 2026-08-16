# spec/odysseus/cli/ui_spec.rb

require 'spec_helper'
require 'odysseus/cli/ui'
require 'stringio'

RSpec.describe Odysseus::CLI::UI do
  describe Odysseus::CLI::RedactingIO do
    let(:io) { StringIO.new }
    let(:upcaser) { lambda(&:upcase) }
    let(:redacting_io) { described_class.new(io, upcaser) }

    it 'passes written text through the redactor' do
      redacting_io.write('secret')

      expect(io.string).to eq('SECRET')
    end

    it 'passes each puts argument through the redactor' do
      redacting_io.puts('one', 'two')

      expect(io.string).to eq("ONE\nTWO\n")
    end

    it 'writes a bare newline for puts with no arguments' do
      redacting_io.puts

      expect(io.string).to eq("\n")
    end

    it 'passes printed text through the redactor' do
      redacting_io.print('shh')

      expect(io.string).to eq('SHH')
    end

    it 'delegates unknown methods to the wrapped io' do
      expect(redacting_io.tty?).to be(false)
    end
  end

  # In debug mode output flows through the redactor rather than the spinner
  # renderer, which is the seam where secrets could leak into a terminal or CI
  # log. The orchestrators print the docker commands they run.
  describe 'redaction of streamed output' do
    let(:ui) { described_class.new(debug: true) }

    def streamed(line)
      output = StringIO.new
      original = $stdout
      $stdout = output
      begin
        ui.stream_steps(title: 'Deploying') { puts line }
      ensure
        $stdout = original
      end
      output.string
    end

    it 'redacts a master key passed as a docker env flag' do
      expect(streamed('docker run -e RAILS_MASTER_KEY=abc123 myapp')).to include('[REDACTED]')
      expect(streamed('docker run -e RAILS_MASTER_KEY=abc123 myapp')).not_to include('abc123')
    end

    it 'redacts assignments of secret-looking names' do
      expect(streamed('DATABASE_PASSWORD=hunter2')).not_to include('hunter2')
    end

    it 'redacts a --password flag' do
      expect(streamed('docker login --password hunter2 registry.example.com'))
        .not_to include('hunter2')
    end

    it 'leaves ordinary output alone' do
      expect(streamed('Deploy complete for myapp')).to include('Deploy complete for myapp')
    end
  end

  # Everything this UI writes goes to stdout, and the one place that cannot is
  # `logs`: its own diagnostics would land in the stream a `> app.log` is
  # capturing. `io` is how those three lines opt out — a default rather than a
  # second set of methods, so every other caller is unchanged.
  describe 'the stream a message is written to' do
    let(:ui) { described_class.new(debug: true) }
    let(:elsewhere) { StringIO.new }

    def to_stdout
      output = StringIO.new
      original = $stdout
      $stdout = output
      begin
        yield
      ensure
        $stdout = original
      end
      output.string
    end

    %i[error warn step].each do |method|
      it "##{method} writes to stdout by default" do
        expect(to_stdout { ui.public_send(method, 'a message') }).to include('a message')
        expect(elsewhere.string).to be_empty
      end

      it "##{method} writes to the io it was given instead" do
        expect(to_stdout { ui.public_send(method, 'a message', io: elsewhere) }).to be_empty
        expect(elsewhere.string).to include('a message')
      end
    end

    # The header the interactive sessions print opts out the same way: the
    # terminal they hand over writes its own output to stdout, and a line about
    # which container that is does not belong in it.
    it '#header writes to stdout by default and to the io it was given instead' do
      expect(to_stdout { ui.header('A Title') }).to include('A Title')
      expect(elsewhere.string).to be_empty

      expect(to_stdout { ui.header('A Title', io: elsewhere) }).to be_empty
      expect(elsewhere.string).to include('A Title')
    end

    it '#info writes to stdout by default and to the io it was given instead' do
      expect(to_stdout { ui.info('Label', 'value') }).to include('Label: value')
      expect(elsewhere.string).to be_empty

      expect(to_stdout { ui.info('Label', 'value', io: elsewhere) }).to be_empty
      expect(elsewhere.string).to include('Label: value')
    end

    it '#blank writes to stdout by default and to the io it was given instead' do
      expect(to_stdout { ui.blank }).to eq("\n")
      expect(elsewhere.string).to be_empty

      expect(to_stdout { ui.blank(io: elsewhere) }).to be_empty
      expect(elsewhere.string).to eq("\n")
    end
  end

  describe 'step numbering' do
    let(:ui) { described_class.new(debug: true) }

    def captured
      output = StringIO.new
      original = $stdout
      $stdout = output
      begin
        yield
      ensure
        $stdout = original
      end
      output.string
    end

    it 'numbers steps in sequence' do
      out = captured do
        ui.spin_step('first') { nil }
        ui.spin_step('second') { nil }
      end

      expect(out).to match(/1.*first/m)
      expect(out).to match(/2.*second/m)
    end

    it 'restarts numbering at each header' do
      out = captured do
        ui.spin_step('first') { nil }
        ui.header('New Section')
        ui.spin_step('back to one') { nil }
      end

      expect(out.lines.grep(/back to one/).join).to include('1')
    end

    it 'returns the value the step block produced' do
      result = captured { @value = ui.spin_step('work') { :done } }

      expect(@value).to eq(:done)
      expect(result).to include('work')
    end
  end
end
