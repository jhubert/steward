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

ActiveRecord::Schema[8.1].define(version: 2026_02_12_092139) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

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
    t.jsonb "pinned_facts", default: []
    t.bigint "summarized_through_message_id"
    t.text "summary"
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
    t.index ["workspace_id", "user_id", "channel", "external_thread_key"], name: "idx_conversations_lookup", unique: true, where: "(external_thread_key IS NOT NULL)"
    t.index ["workspace_id"], name: "index_conversations_on_workspace_id"
  end

  create_table "memory_items", force: :cascade do |t|
    t.string "category"
    t.text "content", null: false
    t.bigint "conversation_id"
    t.datetime "created_at", null: false
    t.jsonb "metadata", default: {}
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.bigint "workspace_id", null: false
    t.index ["conversation_id"], name: "index_memory_items_on_conversation_id"
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

  add_foreign_key "agents", "workspaces"
  add_foreign_key "conversation_states", "conversations"
  add_foreign_key "conversation_states", "users"
  add_foreign_key "conversation_states", "workspaces"
  add_foreign_key "conversations", "agents"
  add_foreign_key "conversations", "users"
  add_foreign_key "conversations", "workspaces"
  add_foreign_key "memory_items", "conversations"
  add_foreign_key "memory_items", "users"
  add_foreign_key "memory_items", "workspaces"
  add_foreign_key "messages", "conversations"
  add_foreign_key "messages", "users"
  add_foreign_key "messages", "workspaces"
  add_foreign_key "users", "workspaces"
end
