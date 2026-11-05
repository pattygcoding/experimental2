# frozen_string_literal: true

namespace :test do
  desc "Run the pure-Ruby matching engine tests (no Rails boot, no database)"
  task :engine do
    root = File.expand_path("../..", __dir__)
    lib = File.join(root, "lib")
    files = Dir[File.join(root, "test", "lib", "**", "*_test.rb")].sort

    abort "test:engine found no engine tests under test/lib" if files.empty?

    # Load every engine test into one process. NB: minitest autorun interprets ARGV as a
    # filter, so the files must not be passed as arguments.
    loader = "Dir[File.join('test', 'lib', '**', '*_test.rb')].sort.each { |f| require File.expand_path(f) }"
    ruby "-I#{lib}", "-e", loader
  end
end
