require "spec_helper"
require "timeout"

RSpec.describe "NodeDB::Graph.silence_libpq_noise" do
  it "returns the block's value" do
    expect(NodeDB::Graph.silence_libpq_noise { :ok }).to eq(:ok)
  end

  it "does not deadlock when the block writes more than the pipe capacity" do
    Timeout.timeout(10) do
      NodeDB::Graph.silence_libpq_noise { $stderr.write("x" * 200_000) }
    end
  end

  it "restores the original stderr after the block" do
    before_fd = $stderr.fileno
    NodeDB::Graph.silence_libpq_noise {}
    expect($stderr.fileno).to eq(before_fd)
    # and stderr still works:
    expect { warn "" }.not_to raise_error
  end

  it "survives concurrent invocations without detaching stderr" do
    threads = 8.times.map do
      Thread.new do
        NodeDB::Graph.silence_libpq_noise { $stderr.write("noise\n") }
      end
    end
    threads.each(&:join)
    expect { warn "" }.not_to raise_error
  end

  it "re-raises the block's exception" do
    expect {
      NodeDB::Graph.silence_libpq_noise { raise ArgumentError, "boom" }
    }.to raise_error(ArgumentError, "boom")
  end
end
