# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "lib" << "test"
  t.test_files = FileList["test/**/*_test.rb"]
  t.warning = false
end

desc "Send one of each signal to a real Argus (needs ARGUS_CONTRACT_DSN)"
task :contract do
  ruby "-Ilib test/contract/run.rb"
end

task default: :test
