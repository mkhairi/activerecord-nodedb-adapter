require "spec_helper"

RSpec.describe "gem packaging" do
  # spec.files is built from the working tree. Fail if it ships a file
  # git ignores, such as local scratch under docs/bugs/.
  it "packages no git-ignored file" do
    root = File.expand_path("..", __dir__)
    # The gemspec's Dir[] globs resolve against the current directory.
    files = Dir.chdir(root) { Gem::Specification.load("activerecord-nodedb-adapter.gemspec").files }
    ignored = IO.popen(["git", "-C", root, "check-ignore", "--stdin"], "r+") do |io|
      io.puts(files)
      io.close_write
      io.read
    end

    expect(ignored.split("\n")).to be_empty
  end
end
