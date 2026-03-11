#!/usr/bin/env ruby
# frozen_string_literal: true

# Agent management script — runs via `bin/rails runner` context from Tools::Executor.
# Usage: ruby scripts/manage.rb <action> [json_params]

require "json"

action = ARGV[0]
raw_params = ARGV[1]

params = if raw_params && raw_params != "params" && !raw_params.empty?
  begin
    JSON.parse(raw_params)
  rescue JSON::ParserError
    {}
  end
else
  {}
end

workspace = Workspace.find_by!(slug: "default")
Current.workspace = workspace

case action
when "list_agents"
  agents = Agent.all.order(:name)
  agents.each do |agent|
    next if agent.name == "Steward" # Don't list yourself

    email = agent.email_handle ? "#{agent.email_handle}@withstuart.com" : nil
    principals = agent.agent_principals.includes(:user).map { |ap| ap.display_name || ap.user.name }
    bio = agent.settings&.dig("bio")

    puts "#{agent.name}"
    puts "  Email: #{email}" if email
    puts "  Bio: #{bio}" if bio
    if principals.any?
      puts "  Currently works for: #{principals.join(', ')}"
    else
      puts "  Currently unassigned — available for new work"
    end
    puts ""
  end

when "list_skills"
  registry = Skills::Registry.instance
  registry.all.sort_by(&:name).each do |skill|
    tool_names = skill.tool_definitions.map { |d| d[:name] }
    puts "#{skill.name}: #{skill.description}"
    puts "  Tools: #{tool_names.any? ? tool_names.join(', ') : 'none (prompt-only)'}"
    puts ""
  end

when "enable_skill"
  agent_name = params["agent"]
  skill_name = params["skill"]
  abort "Missing 'agent' and 'skill' params" unless agent_name && skill_name

  agent = Agent.find_by!(name: agent_name)
  agent.enable_skill!(skill_name)
  puts "Enabled skill '#{skill_name}' for #{agent_name}."
  puts "Tools created: #{Skills::Registry.instance.find(skill_name).tool_definitions.map { |d| d[:name] }.join(', ')}"

when "disable_skill"
  agent_name = params["agent"]
  skill_name = params["skill"]
  abort "Missing 'agent' and 'skill' params" unless agent_name && skill_name

  agent = Agent.find_by!(name: agent_name)
  agent.disable_skill!(skill_name)
  puts "Disabled skill '#{skill_name}' for #{agent_name}."

when "connect_user"
  agent_name = params["agent"]
  email = params["email"]
  abort "Missing 'agent' and 'email' params" unless agent_name && email

  agent = Agent.find_by!(name: agent_name)
  user = User.find_by_email_address(email)
  abort "No user found with email '#{email}'. They need to be invited first." unless user

  existing = agent.agent_principals.find_by(user: user)
  if existing
    puts "#{user.name || email} is already connected to #{agent_name}."
  else
    agent.agent_principals.create!(
      workspace: workspace,
      user: user,
      display_name: params["display_name"] || user.name,
      role: params["role"] || "user"
    )
    puts "Connected #{user.name || email} as principal of #{agent_name}."
  end

when "create_agent"
  name = params["name"]
  system_prompt = params["system_prompt"]
  abort "Missing 'name' and 'system_prompt' params" unless name && system_prompt

  # Auto-generate email handle from name (e.g. "Maya Sutton" -> "maya.sutton")
  email_handle = name.downcase.gsub(/[^a-z\s]/, "").strip.gsub(/\s+/, ".")

  settings = {
    "email_handle" => email_handle,
    "model" => "claude-sonnet-4-6",
    "token_budgets" => { "response" => 8192 },
    "extraction_model" => "claude-haiku-4-5-20251001",
    "summarization_model" => "claude-haiku-4-5-20251001"
  }
  settings["telegram_bot_token"] = params["telegram_bot_token"] if params["telegram_bot_token"]

  agent = Agent.create!(
    workspace: workspace,
    name: name,
    system_prompt: system_prompt,
    settings: settings
  )

  puts "Created agent '#{agent.name}' (id=#{agent.id})."
  puts "Email: #{email_handle}@withstuart.com"

  if settings["telegram_bot_token"]
    result = agent.register_telegram_webhook!
    if result[:ok]
      puts "Telegram webhook registered."
    else
      puts "Webhook registration failed: #{result[:description]}"
    end
  end

when "setup_agent"
  # All-in-one: create agent, connect user as principal, send intro email.
  # Params: name, system_prompt, email, display_name (optional), role (optional)
  name = params["name"]
  system_prompt = params["system_prompt"]
  email = params["email"]
  abort "Missing required params: 'name', 'system_prompt', 'email'" unless name && system_prompt && email

  # 1. Create the agent with email handle and default settings
  email_handle = name.downcase.gsub(/[^a-z\s]/, "").strip.gsub(/\s+/, ".")

  settings = {
    "email_handle" => email_handle,
    "model" => "claude-sonnet-4-6",
    "token_budgets" => { "response" => 8192 },
    "extraction_model" => "claude-haiku-4-5-20251001",
    "summarization_model" => "claude-haiku-4-5-20251001"
  }

  agent = Agent.create!(
    workspace: workspace,
    name: name,
    system_prompt: system_prompt,
    settings: settings
  )
  puts "Created agent '#{agent.name}' (id=#{agent.id})"
  puts "Email: #{email_handle}@withstuart.com"

  # 2. Find or create the user and connect as principal
  user = User.find_by_email_address(email)
  abort "No user found with email '#{email}'. They need to be invited first." unless user

  display_name = params["display_name"] || user.name
  role = params["role"] || "owner"

  agent.agent_principals.create!(
    workspace: workspace,
    user: user,
    display_name: display_name,
    role: role
  )
  puts "Connected #{display_name} as #{role} of #{agent.name}"

  # 3. Send intro email from the new agent
  # Uses a system_instruction message that the LLM sees once to generate a
  # personalized intro, then ProcessMessageJob deletes it after delivery.
  # The conversation history starts clean with just the assistant's intro.
  email_conv = Conversation.find_or_start(
    user: user,
    agent: agent,
    channel: "email",
    external_thread_key: email
  )
  email_conv.update!(metadata: (email_conv.metadata || {}).merge(
    "email_subject" => "Hi from #{agent.name}"
  ))

  intro_msg = email_conv.messages.create!(
    workspace: workspace,
    user: user,
    role: "user",
    content: "Introduce yourself to #{display_name}. Tell them who you are, " \
             "what you can help with, and ask what's most urgent. Keep it concise. " \
             "Do not use any tools — just write your message directly.",
    metadata: { "system_instruction" => true }
  )

  ProcessMessageJob.perform_later(intro_msg.id)
  puts "Intro email queued — #{agent.name} will email #{email} shortly."
  puts "Done! Agent is fully set up and reaching out."

else
  abort "Unknown action: #{action}. Valid actions: list_agents, list_skills, enable_skill, disable_skill, create_agent, connect_user, setup_agent"
end
