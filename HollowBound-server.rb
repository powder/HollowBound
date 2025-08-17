# backend_sqlite.rb
require "sinatra"
require "json"
require "sequel"
require "securerandom"
require "time"

require_relative "lib/point_crawl"
require_relative "lib/quest_generator"

set :bind, "0.0.0.0"
set :port, 4567

DB_PATH = ENV.fetch("RPG_DB", "rpg.db")
DB = Sequel.sqlite(DB_PATH)

# --- Schema bootstrap ---
DB.create_table?(:characters) do
  String  :id, primary_key: true
  Text    :json, null: false       # full snapshot blob
  String  :updated_at, null: false # ISO8601 string for quick compare
  index   :updated_at
end

DB.create_table?(:events) do
  String  :id, primary_key: true
  String  :character_id, null: false
  Text    :json, null: false
  String  :updated_at, null: false
  index   :character_id
  index   :updated_at
end

DB.create_table?(:character_quests) do
  String :character_id, primary_key: true
  Text   :quest_json, null: false
  String :current_node_id, null: false
  Text   :completed_nodes_json, null: false # JSON array of strings
  String :updated_at, null: false
end

CHARACTERS = DB[:characters]
EVENTS     = DB[:events]
QUESTS     = DB[:character_quests]

# ---- Quest Management ----
module QuestManager
  def self.get_current_quest(character_id)
    row = QUESTS.where(character_id: character_id).first
    return nil unless row

    quest = PointCrawl::Quest.from_h(JSON.parse(row[:quest_json]))
    {
      quest: quest,
      current_node_id: row[:current_node_id],
      completed_nodes: JSON.parse(row[:completed_nodes_json])
    }
  end

  def self.generate_new_quest(character_id)
    quest = PointCrawl::QuestGenerator.generate("quest_#{SecureRandom.hex(4)}")
    start_node_id = quest.start_node_id

    QUESTS.insert(
      character_id: character_id,
      quest_json: quest.to_h.to_json,
      current_node_id: start_node_id,
      completed_nodes_json: [].to_json,
      updated_at: Time.now.utc.iso8601
    )

    {
      quest: quest,
      current_node_id: start_node_id,
      completed_nodes: []
    }
  end

  def self.update_quest_location(character_id, old_node_id, new_node_id)
    row = QUESTS.where(character_id: character_id).first
    return unless row # Or handle error

    completed = JSON.parse(row[:completed_nodes_json])
    completed << old_node_id unless completed.include?(old_node_id)

    QUESTS.where(character_id: character_id).update(
      current_node_id: new_node_id,
      completed_nodes_json: completed.to_json,
      updated_at: Time.now.utc.iso8601
    )
  end
end

helpers do
  def json_body
    request.body.rewind
    s = request.body.read
    s.empty? ? {} : JSON.parse(s)
  rescue
    halt 400, { error: "invalid JSON" }.to_json
  end

  def now_iso
    Time.now.utc.iso8601
  end

  def iso(t)
    t.is_a?(String) ? t : t.to_s
  end

  def parse_iso(s)
    Time.parse(s) rescue Time.at(0)
  end

  def cors!
    headers["Access-Control-Allow-Origin"] = "*"
    headers["Access-Control-Allow-Methods"] = "GET,POST,PUT,OPTIONS"
    headers["Access-Control-Allow-Headers"] = "Content-Type"
  end

  def loot_table
    [
      { key:"iron_sword",    name:"Iron Sword",    effects:{ atk:3 } },
      { key:"wooden_shield", name:"Wooden Shield", effects:{ ac:2 } },
      { key:"mystic_ring",   name:"Mystic Ring",   effects:{ int:2 } },
      { key:"health_potion", name:"Health Potion", effects:{ heal:25 } }
    ]
  end
end

before do
  cors!
  content_type :json
end

options "*" do
  cors!
  200
end

# ---- Characters ----

# Fetch a character snapshot
get "/character/:id" do |id|
  row = CHARACTERS.where(id: id).first
  halt 404, { error: "not found" }.to_json unless row
  row[:json]
end

# Upsert a character snapshot with last write wins by updated_at
put "/character/:id" do |id|
  body = json_body
  incoming_updated = parse_iso(body["updated_at"] || now_iso)

  DB.transaction do
    row = CHARACTERS.where(id: id).for_update.first
    if row.nil?
      CHARACTERS.insert(id: id, json: body.to_json, updated_at: incoming_updated.iso8601)
    else
      current_updated = parse_iso(row[:updated_at])
      if incoming_updated > current_updated
        CHARACTERS.where(id: id).update(json: body.to_json, updated_at: incoming_updated.iso8601)
      end
    end
  end

  { ok: true }.to_json
end

# ---- Events ----

# Accept a batch of events
post "/events/batch" do
  data = json_body
  events = Array(data["events"])
  stored = 0

  DB.transaction do
    events.each do |ev|
      ev_id = ev["id"] || "ev_#{SecureRandom.hex(6)}"
      ev_updated = (ev["updated_at"] || now_iso).to_s
      raw = EVENTS.where(id: ev_id).for_update.first
      if raw.nil?
        EVENTS.insert(id: ev_id,
                      character_id: ev["character_id"] || "unknown",
                      json: ev.to_json,
                      updated_at: ev_updated)
        stored += 1
      else
        # If duplicate id arrives, keep the one with newer updated_at
        if parse_iso(ev_updated) > parse_iso(raw[:updated_at])
          EVENTS.where(id: ev_id).update(json: ev.to_json, updated_at: ev_updated)
          stored += 1
        end
      end
    end
  end

  { ok: true, count: stored }.to_json
end

# ---- Quests ----

# Get the character's current quest state.
# If they have no quest, a new one is generated.
get "/quests/current" do
  character_id = params["character_id"]
  halt 400, { error: "character_id is required" }.to_json unless character_id

  state = QuestManager.get_current_quest(character_id) || QuestManager.generate_new_quest(character_id)

  quest = state[:quest]
  current_node = quest.get_node(state[:current_node_id])

  connections = current_node.connections.map do |conn_id|
    node = quest.get_node(conn_id)
    { id: node.id, name: node.name }
  end

  {
    quest_name: quest.name,
    location: {
      id: current_node.id,
      name: current_node.name,
      description: current_node.description
    },
    connections: connections,
    completed: state[:current_node_id] == quest.end_node_id
  }.to_json
end

# Perform an action within a quest.
# Body: { character_id: "...", action: "...", ... }
# Returns: { description: "...", rewards: [...] }
post "/quests/action" do
  body = json_body
  character_id = body["character_id"]
  action = body["action"]
  halt 400, { error: "character_id and action are required" }.to_json unless character_id && action

  state = QuestManager.get_current_quest(character_id)
  halt 404, { error: "no active quest found" }.to_json unless state

  quest = state[:quest]
  current_node_id = state[:current_node_id]
  outcome = nil

  case action
  when "travel"
    destination_id = body["destination_id"]
    current_node = quest.get_node(current_node_id)
    halt 400, { error: "invalid destination" }.to_json unless current_node.connections.include?(destination_id)

    QuestManager.update_quest_location(character_id, current_node_id, destination_id)

    encounter = quest.travel_encounters.sample
    outcome = {
      log: "Traveling to #{quest.get_node(destination_id).name}... #{encounter.description}",
      rewards: encounter.rewards.map(&:to_h)
    }

  when "explore"
    current_node = quest.get_node(current_node_id)
    encounter = current_node.encounters.sample
    outcome = {
      log: "Exploring #{current_node.name}... #{encounter.description}",
      rewards: encounter.rewards.map(&:to_h)
    }

  else
    halt 400, { error: "unknown action" }.to_json
  end

  # TODO: Persist the outcome as an event
  outcome.to_json
end

# Clear a character's completed quest
post "/quests/complete" do
  body = json_body
  character_id = body["character_id"]
  halt 400, { error: "character_id is required" }.to_json unless character_id

  QUESTS.where(character_id: character_id).delete
  { ok: true }.to_json
end

# ---- Debug helpers ----

get "/debug/characters" do
  CHARACTERS.order(Sequel.desc(:updated_at)).all.map { |r| JSON.parse(r[:json]) }.to_json
end

get "/debug/events/:id" do |id|
  EVENTS.where(character_id: id).order(:updated_at).all.map { |r| JSON.parse(r[:json]) }.to_json
end
