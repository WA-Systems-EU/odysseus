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
  # Reported from a real deploy: `odysseus deploy --build` died with
  # "incompatible character encodings: UTF-8 and BINARY" while pushing. The
  # non-debug branch reads the pipe with IO#read_nonblock, which hands back
  # ASCII-8BIT; the accumulator starts as a UTF-8 literal but takes the
  # chunk's encoding on the first append, so any byte above 0x7F -- a
  # progress bar, a box-drawing character, an accented path -- reaches the
  # spinner's UTF-8 format string as binary and raises there, after the build
  # has already succeeded.
  describe 'streamed output that is not plain ASCII' do
    let(:ui) { described_class.new(debug: false) }

    # The pause is load-bearing, not padding. The reader loop polls the pipe
    # every 0.06s and exits as soon as the block is done and the buffer is
    # drained, so without it the block finishes first and nothing is ever
    # rendered -- which silently made an earlier version of these examples
    # pass for any input, including the input that crashes.
    def stream(line)
      output = StringIO.new
      original = $stdout
      $stdout = output
      begin
        ui.stream_steps(title: 'Building') do
          puts line
          $stdout.flush
          sleep 0.25
        end
      ensure
        $stdout = original
      end
      output.string
    end

    it 'survives a line containing non-ASCII bytes' do
      expect { stream('Pushing image ▓▓▓▓ 50%') }.not_to raise_error
    end

    it 'still shows the line it was given' do
      expect(stream('Pushing image ▓▓▓▓ 50%')).to include('Pushing image')
    end

    # A read boundary can fall inside a multi-byte character, so the bytes of
    # one character can arrive in two chunks. Scrubbing per chunk would eat it;
    # scrubbing a completed line cannot, since every byte of the line is there.
    it 'does not mangle a multi-byte character that spans a read' do
      expect(stream('Café built')).to include('Café')
    end

    it 'does not raise on genuinely invalid byte sequences' do
      expect { stream("broken \xC3\x28 output") }.not_to raise_error
    end
  end

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
