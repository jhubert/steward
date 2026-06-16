# Idempotent setup for Jennifer's approval gate.
#
# Configures Jennifer to require human approval for outbound email tools and
# routes approval prompts to Jeremy on Telegram. Safe to re-run — reports what
# (if anything) it changed, and flags readiness gaps without trying to fix them
# unilaterally.
#
# Usage:
#   RAILS_ENV=production bin/rails runner script/setup_jennifer_approval.rb

APPROVAL_TOOLS    = %w[send_email gmail_reply gmail_new_thread].freeze
AGENT_NAME_HINTS  = ["Jennifer Lawson", "Jennifer"].freeze
APPROVER_EMAIL    = "jhubert@gmail.com"

def status(label, ok, detail = nil)
  prefix = ok ? "✓" : "✗"
  puts "#{prefix} #{label}#{detail ? " — #{detail}" : ''}"
end

def change(label)
  puts "+ #{label}"
end

def warn(label)
  puts "⚠ #{label}"
end

# --- Locate agent + approver ---

jennifer = AGENT_NAME_HINTS.lazy.map { |n| Agent.unscoped.find_by(name: n) }.find(&:itself)
abort "✗ Could not find Jennifer agent (tried: #{AGENT_NAME_HINTS.join(', ')})" unless jennifer

jeremy = User.unscoped.find_by_email_address(APPROVER_EMAIL) ||
         User.unscoped.find_by(email: APPROVER_EMAIL)
abort "✗ Could not find approver user (email: #{APPROVER_EMAIL})" unless jeremy

puts "Agent:    #{jennifer.name} (id=#{jennifer.id}, workspace=#{jennifer.workspace.slug})"
puts "Approver: #{jeremy.name} (id=#{jeremy.id}, workspace=#{jeremy.workspace.slug})"
puts

settings = (jennifer.settings || {}).dup
mutated  = false

# --- 1. approval_required_tools (set-union: never strip tools you added manually) ---

current_tools = Array(settings["approval_required_tools"]).map(&:to_s)
desired_tools = (current_tools + APPROVAL_TOOLS).uniq
added = desired_tools - current_tools

if added.empty?
  status "approval_required_tools includes all of #{APPROVAL_TOOLS.join(', ')}", true
else
  change "adding to approval_required_tools: #{added.join(', ')}"
  settings["approval_required_tools"] = desired_tools
  mutated = true
end

# --- 2. approval_approver_user_id (don't silently overwrite a different user) ---

current_approver_id = settings["approval_approver_user_id"]
if current_approver_id.nil?
  change "setting approval_approver_user_id = #{jeremy.id} (#{jeremy.name})"
  settings["approval_approver_user_id"] = jeremy.id
  mutated = true
elsif current_approver_id == jeremy.id
  status "approval_approver_user_id already set to Jeremy", true
else
  other = User.unscoped.find_by(id: current_approver_id)
  warn  "approval_approver_user_id is set to user #{current_approver_id} (#{other&.name || 'unknown'}), not Jeremy. " \
        "Not changing — clear the setting first if you want this script to set it."
end

# --- Save (only if anything actually changed) ---

if mutated
  jennifer.update!(settings: settings)
  puts "✓ saved"
else
  puts "✓ no settings changes needed"
end

puts
puts "--- Readiness checks (no changes made) ---"
puts

# 3. Does the approver have a Telegram conversation with Jennifer?
#    Without one, Approvals::TelegramPrompt has nowhere to deliver the ping.
conv = Conversation.unscoped
                   .where(agent_id: jennifer.id, user_id: jeremy.id, channel: "telegram")
                   .order(updated_at: :desc)
                   .first
if conv
  status "Jeremy has a Telegram conversation with Jennifer", true,
         "conv=#{conv.id}, chat=#{conv.external_thread_key}"
else
  status "Jeremy has a Telegram conversation with Jennifer", false,
         "approval prompts will NOT be delivered until he sends Jennifer a message on Telegram"
end

# 4. Is Jeremy a principal? Not required for approvals, but relevant — only
#    principals can be looked up via the existing principal-mode plumbing.
if jennifer.principal?(jeremy)
  status "Jeremy is a principal of Jennifer", true
else
  warn "Jeremy is NOT a principal of Jennifer. The approval flow still works " \
       "(it routes by user_id, not by principal status), but he can't talk to " \
       "her on Telegram without being added/paired first."
end

# 5. email_handle: send_email aborts before the approval gate when this is unset.
if jennifer.email_handle.present?
  status "email_handle is set", true, jennifer.email_handle
else
  warn "email_handle is NOT set. send_email will reject any call BEFORE the " \
       "approval gate fires. Restore it (e.g. \"jennifer.lawson\") if you want " \
       "outbound email working. Set gog_email too for Gmail; leave it for Postmark."
end

puts
puts "Done."
