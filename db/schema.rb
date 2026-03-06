# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_03_06_000755) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "vector"

  create_table "agent_principals", force: :cascade do |t|
    t.bigint "agent_id", null: false
    t.datetime "created_at", null: false
    t.text "credentials_json"
    t.string "display_name"
    t.jsonb "metadata", default: {}
    t.jsonb "permissions", default: {}
    t.string "role"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.bigint "workspace_id", null: false
    t.index ["agent_id"], name: "index_agent_principals_on_agent_id"
    t.index ["user_id"], name: "index_agent_principals_on_user_id"
    t.index ["workspace_id", "agent_id", "user_id"], name: "idx_agent_principals_unique", unique: true
    t.index ["workspace_id"], name: "index_agent_principals_on_workspace_id"
  end

  create_table "agent_tools", force: :cascade do |t|
    t.bigint "agent_id", null: false
    t.text "command_template", null: false
    t.datetime "created_at", null: false
    t.text "credentials_json"
    t.text "description", null: false
    t.boolean "enabled", default: true
    t.jsonb "input_schema", default: {}, null: false
    t.jsonb "metadata", default: {}
    t.string "name", null: false
    t.integer "timeout_seconds", default: 30
    t.datetime "updated_at", null: false
    t.string "working_directory"
    t.bigint "workspace_id", null: false
    t.index ["agent_id"], name: "index_agent_tools_on_agent_id"
    t.index ["workspace_id", "agent_id", "name"], name: "idx_agent_tools_unique", unique: true
    t.index ["workspace_id"], name: "index_agent_tools_on_workspace_id"
  end

  create_table "agents", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.jsonb "settings", default: {}
    t.text "system_prompt", null: false
    t.datetime "updated_at", null: false
    t.bigint "workspace_id", null: false
    t.index ["workspace_id"], name: "index_agents_on_workspace_id"
  end

  create_table "conversation_states", force: :cascade do |t|
    t.jsonb "active_goals", default: []
    t.bigint "conversation_id", null: false
    t.datetime "created_at", null: false
    t.bigint "extracted_through_message_id"
    t.jsonb "pinned_facts", default: []
    t.text "scratchpad", default: ""
    t.bigint "summarized_through_message_id"
    t.text "summary"
    t.jsonb "tool_log", default: []
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.bigint "workspace_id", null: false
    t.index ["conversation_id"], name: "index_conversation_states_on_conversation_id", unique: true
    t.index ["user_id"], name: "index_conversation_states_on_user_id"
    t.index ["workspace_id"], name: "index_conversation_states_on_workspace_id"
  end

  create_table "conversations", force: :cascade do |t|
    t.bigint "agent_id", null: false
    t.string "channel", null: false
    t.datetime "created_at", null: false
    t.string "external_thread_key"
    t.jsonb "metadata", default: {}
    t.string "status", default: "active", null: false
    t.string "tags", default: [], array: true
    t.string "title"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.bigint "workspace_id", null: false
    t.index ["agent_id"], name: "index_conversations_on_agent_id"
    t.index ["user_id"], name: "index_conversations_on_user_id"
    t.index ["workspace_id", "agent_id", "channel", "external_thread_key"], name: "idx_conversations_email_thread_lookup", unique: true, where: "((channel)::text = 'email'::text)"
    t.index ["workspace_id", "user_id", "agent_id", "channel", "external_thread_key"], name: "idx_conversations_non_email_lookup", unique: true, where: "((channel)::text <> 'email'::text)"
    t.index ["workspace_id"], name: "index_conversations_on_workspace_id"
  end

  create_table "invites", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.bigint "invited_by_id", null: false
    t.string "name"
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.bigint "workspace_id", null: false
    t.index ["invited_by_id"], name: "index_invites_on_invited_by_id"
    t.index ["user_id"], name: "index_invites_on_user_id"
    t.index ["workspace_id", "email"], name: "index_invites_on_workspace_id_and_email", unique: true
    t.index ["workspace_id"], name: "index_invites_on_workspace_id"
  end

  create_table "memory_items", force: :cascade do |t|
    t.string "category"
    t.text "content", null: false
    t.bigint "conversation_id"
    t.datetime "created_at", null: false
    t.vector "embedding", limit: 1536
    t.jsonb "metadata", default: {}
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.bigint "workspace_id", null: false
    t.index ["conversation_id"], name: "index_memory_items_on_conversation_id"
    t.index ["embedding"], name: "index_memory_items_on_embedding", opclass: :vector_cosine_ops, using: :hnsw
    t.index ["user_id"], name: "index_memory_items_on_user_id"
    t.index ["workspace_id", "user_id", "category"], name: "index_memory_items_on_workspace_id_and_user_id_and_category"
    t.index ["workspace_id"], name: "index_memory_items_on_workspace_id"
  end

  create_table "messages", force: :cascade do |t|
    t.text "content", null: false
    t.bigint "conversation_id", null: false
    t.datetime "created_at", null: false
    t.jsonb "metadata", default: {}
    t.string "role", null: false
    t.integer "token_count"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.bigint "workspace_id", null: false
    t.index ["conversation_id", "created_at"], name: "index_messages_on_conversation_id_and_created_at"
    t.index ["conversation_id"], name: "index_messages_on_conversation_id"
    t.index ["user_id"], name: "index_messages_on_user_id"
    t.index ["workspace_id"], name: "index_messages_on_workspace_id"
  end

  create_table "pairing_codes", force: :cascade do |t|
    t.bigint "agent_id", null: false
    t.string "code", null: false
    t.datetime "created_at", null: false
    t.bigint "created_by_id", null: false
    t.datetime "expires_at", null: false
    t.string "label"
    t.datetime "redeemed_at"
    t.bigint "redeemed_by_id"
    t.datetime "updated_at", null: false
    t.bigint "workspace_id", null: false
    t.index ["agent_id"], name: "index_pairing_codes_on_agent_id"
    t.index ["created_by_id"], name: "index_pairing_codes_on_created_by_id"
    t.index ["redeemed_by_id"], name: "index_pairing_codes_on_redeemed_by_id"
    t.index ["workspace_id", "code"], name: "index_pairing_codes_on_workspace_id_and_code", unique: true
    t.index ["workspace_id"], name: "index_pairing_codes_on_workspace_id"
  end

  create_table "scheduled_tasks", force: :cascade do |t|
    t.bigint "agent_id", null: false
    t.bigint "agent_tool_id"
    t.integer "consecutive_failures", default: 0, null: false
    t.bigint "conversation_id"
    t.datetime "created_at", null: false
    t.text "description", null: false
    t.boolean "enabled", default: true, null: false
    t.integer "interval_seconds"
    t.datetime "last_run_at"
    t.jsonb "metadata", default: {}
    t.datetime "next_run_at", null: false
    t.jsonb "tool_input", default: {}
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.bigint "workspace_id", null: false
    t.index ["agent_id"], name: "index_scheduled_tasks_on_agent_id"
    t.index ["agent_tool_id"], name: "index_scheduled_tasks_on_agent_tool_id"
    t.index ["conversation_id"], name: "index_scheduled_tasks_on_conversation_id"
    t.index ["enabled", "next_run_at"], name: "index_scheduled_tasks_on_enabled_and_next_run_at"
    t.index ["user_id"], name: "index_scheduled_tasks_on_user_id"
    t.index ["workspace_id", "agent_id"], name: "index_scheduled_tasks_on_workspace_id_and_agent_id"
    t.index ["workspace_id", "conversation_id"], name: "index_scheduled_tasks_on_workspace_id_and_conversation_id"
    t.index ["workspace_id"], name: "index_scheduled_tasks_on_workspace_id"
  end

  create_table "solid_queue_blocked_executions", force: :cascade do |t|
    t.string "concurrency_key", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.index ["concurrency_key", "priority", "job_id"], name: "index_solid_queue_blocked_executions_for_release"
    t.index ["expires_at", "concurrency_key"], name: "index_solid_queue_blocked_executions_for_maintenance"
    t.index ["job_id"], name: "index_solid_queue_blocked_executions_on_job_id", unique: true
  end

  create_table "solid_queue_claimed_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.bigint "process_id"
    t.index ["job_id"], name: "index_solid_queue_claimed_executions_on_job_id", unique: true
    t.index ["process_id", "job_id"], name: "index_solid_queue_claimed_executions_on_process_id_and_job_id"
  end

  create_table "solid_queue_failed_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "error"
    t.bigint "job_id", null: false
    t.index ["job_id"], name: "index_solid_queue_failed_executions_on_job_id", unique: true
  end

  create_table "solid_queue_jobs", force: :cascade do |t|
    t.string "active_job_id"
    t.text "arguments"
    t.string "class_name", null: false
    t.string "concurrency_key"
    t.datetime "created_at", null: false
    t.datetime "finished_at"
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.datetime "scheduled_at"
    t.datetime "updated_at", null: false
    t.index ["active_job_id"], name: "index_solid_queue_jobs_on_active_job_id"
    t.index ["class_name"], name: "index_solid_queue_jobs_on_class_name"
    t.index ["finished_at"], name: "index_solid_queue_jobs_on_finished_at"
    t.index ["queue_name", "finished_at"], name: "index_solid_queue_jobs_for_filtering"
    t.index ["scheduled_at", "finished_at"], name: "index_solid_queue_jobs_for_alerting"
  end

  create_table "solid_queue_pauses", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "queue_name", null: false
    t.index ["queue_name"], name: "index_solid_queue_pauses_on_queue_name", unique: true
  end

  create_table "solid_queue_processes", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "hostname"
    t.string "kind", null: false
    t.datetime "last_heartbeat_at", null: false
    t.text "metadata"
    t.string "name", null: false
    t.integer "pid", null: false
    t.bigint "supervisor_id"
    t.index ["last_heartbeat_at"], name: "index_solid_queue_processes_on_last_heartbeat_at"
    t.index ["name", "supervisor_id"], name: "index_solid_queue_processes_on_name_and_supervisor_id", unique: true
    t.index ["supervisor_id"], name: "index_solid_queue_processes_on_supervisor_id"
  end

  create_table "solid_queue_ready_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.index ["job_id"], name: "index_solid_queue_ready_executions_on_job_id", unique: true
    t.index ["priority", "job_id"], name: "index_solid_queue_poll_all"
    t.index ["queue_name", "priority", "job_id"], name: "index_solid_queue_poll_by_queue"
  end

  create_table "solid_queue_recurring_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.datetime "run_at", null: false
    t.string "task_key", null: false
    t.index ["job_id"], name: "index_solid_queue_recurring_executions_on_job_id", unique: true
    t.index ["task_key", "run_at"], name: "index_solid_queue_recurring_executions_on_task_key_and_run_at", unique: true
  end

  create_table "solid_queue_recurring_tasks", force: :cascade do |t|
    t.text "arguments"
    t.string "class_name"
    t.string "command", limit: 2048
    t.datetime "created_at", null: false
    t.text "description"
    t.string "key", null: false
    t.integer "priority", default: 0
    t.string "queue_name"
    t.string "schedule", null: false
    t.boolean "static", default: true, null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_solid_queue_recurring_tasks_on_key", unique: true
    t.index ["static"], name: "index_solid_queue_recurring_tasks_on_static"
  end

  create_table "solid_queue_scheduled_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.datetime "scheduled_at", null: false
    t.index ["job_id"], name: "index_solid_queue_scheduled_executions_on_job_id", unique: true
    t.index ["scheduled_at", "priority", "job_id"], name: "index_solid_queue_dispatch_all"
  end

  create_table "solid_queue_semaphores", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "key", null: false
    t.datetime "updated_at", null: false
    t.integer "value", default: 1, null: false
    t.index ["expires_at"], name: "index_solid_queue_semaphores_on_expires_at"
    t.index ["key", "value"], name: "index_solid_queue_semaphores_on_key_and_value"
    t.index ["key"], name: "index_solid_queue_semaphores_on_key", unique: true
  end

  create_table "tool_executions", force: :cascade do |t|
    t.bigint "agent_tool_id", null: false
    t.bigint "conversation_id"
    t.datetime "created_at", null: false
    t.integer "duration_ms"
    t.text "error"
    t.integer "exit_code"
    t.jsonb "input", default: {}
    t.text "output"
    t.boolean "timed_out", default: false
    t.string "tool_use_id"
    t.datetime "updated_at", null: false
    t.bigint "workspace_id", null: false
    t.index ["agent_tool_id"], name: "index_tool_executions_on_agent_tool_id"
    t.index ["conversation_id"], name: "index_tool_executions_on_conversation_id"
    t.index ["workspace_id"], name: "index_tool_executions_on_workspace_id"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email"
    t.jsonb "external_ids", default: {}
    t.string "name"
    t.datetime "updated_at", null: false
    t.bigint "workspace_id", null: false
    t.index ["workspace_id", "email"], name: "index_users_on_workspace_id_and_email", unique: true, where: "(email IS NOT NULL)"
    t.index ["workspace_id"], name: "index_users_on_workspace_id"
  end

  create_table "workspaces", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.jsonb "settings", default: {}
    t.string "slug", null: false
    t.datetime "updated_at", null: false
    t.index ["slug"], name: "index_workspaces_on_slug", unique: true
  end

  add_foreign_key "agent_principals", "agents"
  add_foreign_key "agent_principals", "users"
  add_foreign_key "agent_principals", "workspaces"
  add_foreign_key "agent_tools", "agents"
  add_foreign_key "agent_tools", "workspaces"
  add_foreign_key "agents", "workspaces"
  add_foreign_key "conversation_states", "conversations"
  add_foreign_key "conversation_states", "users"
  add_foreign_key "conversation_states", "workspaces"
  add_foreign_key "conversations", "agents"
  add_foreign_key "conversations", "users"
  add_foreign_key "conversations", "workspaces"
  add_foreign_key "invites", "users"
  add_foreign_key "invites", "users", column: "invited_by_id"
  add_foreign_key "invites", "workspaces"
  add_foreign_key "memory_items", "conversations"
  add_foreign_key "memory_items", "users"
  add_foreign_key "memory_items", "workspaces"
  add_foreign_key "messages", "conversations"
  add_foreign_key "messages", "users"
  add_foreign_key "messages", "workspaces"
  add_foreign_key "pairing_codes", "agents"
  add_foreign_key "pairing_codes", "users", column: "created_by_id"
  add_foreign_key "pairing_codes", "users", column: "redeemed_by_id"
  add_foreign_key "pairing_codes", "workspaces"
  add_foreign_key "scheduled_tasks", "agent_tools"
  add_foreign_key "scheduled_tasks", "agents"
  add_foreign_key "scheduled_tasks", "conversations"
  add_foreign_key "scheduled_tasks", "users"
  add_foreign_key "scheduled_tasks", "workspaces"
  add_foreign_key "solid_queue_blocked_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_claimed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_failed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_ready_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_recurring_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_scheduled_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "tool_executions", "agent_tools"
  add_foreign_key "tool_executions", "conversations"
  add_foreign_key "tool_executions", "workspaces"
  add_foreign_key "users", "workspaces"
end
