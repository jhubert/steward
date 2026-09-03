#!/usr/bin/env ruby
# frozen_string_literal: true

require "open3"
require "shellwords"

# BASECAMP_PROFILE is injected by the executor from the agent tool's
# credentials. It names the Basecamp CLI profile (a stored OAuth identity)
# that this agent acts as. Requiring it is deliberate: the CLI would
# otherwise fall back to whatever default identity happens to be configured
# on the host, which in a multi-agent, multi-principal install means an
# agent could silently post to Basecamp as somebody else.
profile = ENV["BASECAMP_PROFILE"].to_s.strip
if profile.empty?
  warn "ERROR: No Basecamp identity configured for this agent."
  warn "       Set BASECAMP_PROFILE in the tool's credentials to a profile"
  warn "       created with: basecamp profile create <name>"
  exit 1
end

command = ARGV[0].to_s.strip
if command.empty?
  warn "Usage: run.rb <basecamp-subcommand>"
  exit 1
end

parsed = Shellwords.shellsplit(command)

# Identity is injected, never chosen by the model. The CLI accepts -a/--account
# and --profile as overrides; letting the LLM pass either would defeat the
# per-agent isolation above and re-create the cross-principal access bug the
# gog skill hit with --account.
IDENTITY_FLAGS = %w[-a --account --profile].freeze
offending = parsed.find { |t| IDENTITY_FLAGS.include?(t) || t.start_with?("--account=", "--profile=") }
if offending
  warn "ERROR: '#{offending}' cannot be set here — your Basecamp identity is injected automatically."
  warn "       Remove the flag and retry; the correct account is already selected."
  exit 2
end

# Any of these as the action word mutates or destroys existing content.
DESTRUCTIVE_ACTIONS = %w[delete trash archive remove].freeze

# Whole command groups that administer the CLI, the host, or the Basecamp
# account itself rather than working with project content.
BLOCKED_COMMANDS = %w[
  webhooks accounts profile config setup migrate upgrade login logout tools
].freeze

# Specific writes that don't use a destructive verb but change access,
# membership, or visibility.
BLOCKED_PAIRS = [
  %w[people add],
  %w[recordings visibility]
].freeze

def refuse(message, hint)
  warn "ERROR: #{message}"
  warn "       #{hint}"
  exit 2
end

group = parsed[0]
action = parsed[1]

if BLOCKED_COMMANDS.include?(group)
  refuse(
    "'basecamp #{group}' is disabled for agents.",
    "This changes CLI, host, or Basecamp account configuration rather than project content. Ask Jeremy to run it directly."
  )
end

# auth is readable but not changeable — status is a useful diagnostic.
if group == "auth" && action != "status"
  refuse(
    "'basecamp auth #{action}' is disabled for agents.",
    "Only 'basecamp auth status' is allowed. Re-authentication is a human step."
  )
end

if DESTRUCTIVE_ACTIONS.include?(action)
  refuse(
    "'basecamp #{group} #{action}' is disabled for agents.",
    "Deleting, trashing, archiving, and removing are not reversible from here. Report what you would remove and let a human confirm."
  )
end

BLOCKED_PAIRS.each do |blocked|
  next unless parsed[0...blocked.size] == blocked
  refuse(
    "'basecamp #{blocked.join(' ')}' is disabled for agents.",
    "This changes who can see or belongs to something. Escalate to a human instead."
  )
end

# `-` tells the CLI to read content from stdin. The executor runs commands
# with no stdin attached, so a bare `-` cannot be satisfied here.
if parsed.include?("-")
  refuse(
    "Reading content from stdin ('-') is not supported by this tool.",
    "Pass the content inline as a quoted argument instead — literal newlines inside quotes are fine, since no shell is involved."
  )
end

# The services run with PATH=/home/deploy/.rubies/...:/usr/local/bin:/usr/bin:/bin,
# which excludes ~/.local/bin where the official installer puts the binary.
# Resolve it explicitly rather than relying on PATH.
BIN_CANDIDATES = [
  ENV["BASECAMP_BIN"],
  "/usr/local/bin/basecamp",
  File.join(Dir.home, ".local", "bin", "basecamp")
].compact.freeze

bin = BIN_CANDIDATES.find { |p| File.executable?(p) }
unless bin
  warn "ERROR: The 'basecamp' CLI was not found."
  warn "       Looked in: #{BIN_CANDIDATES.join(', ')}"
  warn "       Install it, or set BASECAMP_BIN in the tool's credentials."
  exit 1
end

# --json last so the model can't select a conflicting output mode by accident.
argv = [bin] + parsed + ["--json"]

stdout, stderr, status = Open3.capture3(*argv)

$stdout.write(stdout)
$stderr.write(stderr)
exit(status.exitstatus || 1)
