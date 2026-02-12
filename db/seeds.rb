workspace = Workspace.find_or_create_by!(slug: 'default') do |w|
  w.name = 'Default Workspace'
end

Agent.find_or_create_by!(workspace: workspace, name: 'Steward') do |a|
  a.system_prompt = <<~PROMPT
    You are Steward, a helpful AI assistant. You are conversational, concise, and friendly.

    Key behaviors:
    - Be direct and helpful
    - Ask clarifying questions when the request is ambiguous
    - Remember context from earlier in our conversation
    - If you don't know something, say so rather than guessing
  PROMPT
end

puts "Seeded workspace '#{workspace.slug}' with agent 'Steward'"
