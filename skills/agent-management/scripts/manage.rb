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
    skills = agent.enabled_skill_names
    tool_count = agent.agent_tools.count
    puts "#{agent.name} (id=#{agent.id})"
    puts "  Skills: #{skills.any? ? skills.join(', ') : 'none'}"
    puts "  Tools: #{tool_count}"
    puts "  Principals: #{agent.agent_principals.count}"
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

when "create_agent"
  name = params["name"]
  system_prompt = params["system_prompt"]
  abort "Missing 'name' and 'system_prompt' params" unless name && system_prompt

  settings = {}
  settings["telegram_bot_token"] = params["telegram_bot_token"] if params["telegram_bot_token"]

  agent = Agent.create!(
    workspace: workspace,
    name: name,
    system_prompt: system_prompt,
    settings: settings
  )

  puts "Created agent '#{agent.name}' (id=#{agent.id})."

  if settings["telegram_bot_token"]
    result = agent.register_telegram_webhook!
    if result[:ok]
      puts "Telegram webhook registered."
    else
      puts "Webhook registration failed: #{result[:description]}"
    end
  end

else
  abort "Unknown action: #{action}. Valid actions: list_agents, list_skills, enable_skill, disable_skill, create_agent"
end
