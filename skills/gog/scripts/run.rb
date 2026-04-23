#!/usr/bin/env ruby
# frozen_string_literal: true

require "open3"
require "shellwords"

# XDG_CONFIG_HOME and GOG_KEYRING_PASSWORD are injected by the executor
unless ENV["GOG_KEYRING_PASSWORD"]
  $stderr.puts "ERROR: No Google credentials configured for this user"
  exit 1
end

command = ARGV[0].to_s.strip
if command.empty?
  $stderr.puts "Usage: gog-tool.rb <gog-subcommand>"
  exit 1
end

parsed = Shellwords.shellsplit(command)

# Block destructive/outbound Gmail operations. These must go through the
# audited virtual tools (gmail_reply / gmail_new_thread) which derive
# recipients from the thread, enforce grounding, and persist a record.
BLOCKED_SUBCOMMANDS = [
  %w[gmail send],
  %w[gmail reply],
  %w[gmail forward],
  %w[gmail draft]
].freeze

BLOCKED_SUBCOMMANDS.each do |blocked|
  next unless parsed[0...blocked.size] == blocked
  $stderr.puts "ERROR: '#{blocked.join(' ')}' is disabled via the raw gog tool."
  $stderr.puts "       Use gmail_reply (for replies) or gmail_new_thread (for new outbound) instead."
  $stderr.puts "       Those virtual tools validate recipients, threading, and content grounding."
  exit 2
end

argv = ["/usr/local/bin/gog"] + parsed + ["--json", "--no-input"]
stdout, stderr, status = Open3.capture3(*argv)

$stdout.write(stdout)
$stderr.write(stderr)
exit(status.exitstatus || 1)
