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

# Quest titles: simple strings with timestamps
DB.create_table?(:quest_titles) do
  primary_key :id
  String  :title, null: false
  String  :updated_at, null: false
  index   :updated_at
end

# Loot items: structured rewards
DB.create_table?(:loot_items) do
  primary_key :id
  String  :key, null: false, unique: true
  String  :name, null: false
  Text    :effects_json, null: false # JSON blob of effects
  String  :rarity, null: true
  String  :updated_at, null: false
  index   :key, unique: true
  index   :updated_at
end

# Enemies
DB.create_table?(:enemies) do
  primary_key :id
  String  :name, null: false, unique: true
  String  :updated_at, null: false
  index   :name, unique: true
end

# Enemy loot mapping with integer weight
DB.create_table?(:enemy_loot) do
  primary_key :id
  foreign_key :enemy_id, :enemies, null: false, on_delete: :cascade
  foreign_key :loot_id,  :loot_items, null: false, on_delete: :cascade
  Integer :weight, null: false, default: 1
  String  :updated_at, null: false
  index [:enemy_id, :loot_id], unique: true
end

DB.create_table?(:location_templates) do
  primary_key :id
  String :name, null: false
  String :description, null: false
  String :type, null: false, default: "generic" # :town, :dungeon, :ruin etc.
  String :updated_at, null: false
end

CHARACTERS      = DB[:characters]
EVENTS          = DB[:events]
ACTIVE_QUESTS   = DB[:character_quests]
QUEST_TITLES    = DB[:quest_titles]
LOOT_ITEMS      = DB[:loot_items]
ENEMIES         = DB[:enemies]
ENEMY_LOOT      = DB[:enemy_loot]
LOCATION_TEMPLATES = DB[:location_templates]

# ---- Quest Management ----
module QuestManager
  def self.get_current_quest(character_id)
    row = ACTIVE_QUESTS.where(character_id: character_id).first
    return nil unless row

    quest = PointCrawl::Quest.from_h(JSON.parse(row[:quest_json]))
    {
      quest: quest,
      current_node_id: row[:current_node_id],
      completed_nodes: JSON.parse(row[:completed_nodes_json])
    }
  end

  def self.generate_new_quest(character_id)
    # Fetch data for the generator
    locations = LOCATION_TEMPLATES.all
    enemies = ENEMIES.all
    titles = QUEST_TITLES.all

    # Generate the quest object
    quest = PointCrawl::QuestGenerator.generate(
      quest_id: "quest_#{SecureRandom.hex(4)}",
      locations: locations,
      enemies: enemies,
      titles: titles
    )
    return nil unless quest # Return nil if quest generation failed (e.g. no locations)

    start_node_id = quest.start_node_id

    ACTIVE_QUESTS.insert(
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
    row = ACTIVE_QUESTS.where(character_id: character_id).first
    return unless row # Or handle error

    completed = JSON.parse(row[:completed_nodes_json])
    completed << old_node_id unless completed.include?(old_node_id)

    ACTIVE_QUESTS.where(character_id: character_id).update(
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
    headers["Access-Control-Allow-Methods"] = "GET,POST,PUT,DELETE,OPTIONS"
    headers["Access-Control-Allow-Headers"] = "Content-Type"
  end

  def effects_json_from(obj)
    obj.is_a?(String) ? obj : JSON.dump(obj)
  end

  def row_to_loot(hash)
    {
      id: hash[:id],
      key: hash[:key],
      name: hash[:name],
      effects: JSON.parse(hash[:effects_json]),
      rarity: hash[:rarity]
    }
  end

  def weighted_roll(rows)
    total = rows.sum { |r| r[:weight].to_i }
    return nil if total <= 0
    pick = rand(1..total)
    acc = 0
    rows.each do |r|
      acc += r[:weight].to_i
      return r if pick <= acc
    end
    rows.last
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

# ---------------- Quest titles CRUD ----------------

# List all quest titles
get "/quests/titles" do
  QUEST_TITLES.order(:id).all.map { |r| { id: r[:id], title: r[:title], updated_at: r[:updated_at] } }.to_json
end

# Create quest title
post "/quests/titles" do
  b = json_body
  title = (b["title"] || "").strip
  halt 400, { error: "title required" }.to_json if title.empty?
  id = QUEST_TITLES.insert(title: title, updated_at: now_iso)
  { id: id, title: title }.to_json
end

# Read quest title
get "/quests/titles/:id" do |id|
  r = QUEST_TITLES.where(id: id.to_i).first
  halt 404, { error: "not found" }.to_json unless r
  { id: r[:id], title: r[:title], updated_at: r[:updated_at] }.to_json
end

# Update quest title
put "/quests/titles/:id" do |id|
  b = json_body
  title = (b["title"] || "").strip
  halt 400, { error: "title required" }.to_json if title.empty?
  cnt = QUEST_TITLES.where(id: id.to_i).update(title: title, updated_at: now_iso)
  halt 404, { error: "not found" }.to_json if cnt == 0
  { ok: true }.to_json
end

# Delete quest title
delete "/quests/titles/:id" do |id|
  cnt = QUEST_TITLES.where(id: id.to_i).delete
  halt 404, { error: "not found" }.to_json if cnt == 0
  { ok: true }.to_json
end

# ---------------- Loot CRUD ----------------

# List loot
get "/loot" do
  LOOT_ITEMS.order(:id).all.map { |r| row_to_loot(r) }.to_json
end

# Create loot
post "/loot" do
  b = json_body
  key = (b["key"] || "").strip
  name = (b["name"] || "").strip
  effects = b["effects"] || {}
  rarity = b["rarity"]
  halt 400, { error: "key and name required" }.to_json if key.empty? || name.empty?
  id = LOOT_ITEMS.insert(key: key, name: name, effects_json: effects_json_from(effects), rarity: rarity, updated_at: now_iso)
  row_to_loot(LOOT_ITEMS.where(id: id).first).to_json
end

# Read loot
get "/loot/:id" do |id|
  r = LOOT_ITEMS.where(id: id.to_i).first
  halt 404, { error: "not found" }.to_json unless r
  row_to_loot(r).to_json
end

# Update loot
put "/loot/:id" do |id|
  b = json_body
  updates = {}
  updates[:key] = b["key"].strip if b["key"]
  updates[:name] = b["name"].strip if b["name"]
  updates[:effects_json] = effects_json_from(b["effects"]) if b.key?("effects")
  updates[:rarity] = b["rarity"] if b.key?("rarity")
  updates[:updated_at] = now_iso
  cnt = LOOT_ITEMS.where(id: id.to_i).update(updates)
  halt 404, { error: "not found" }.to_json if cnt == 0
  row_to_loot(LOOT_ITEMS.where(id: id.to_i).first).to_json
end

# Delete loot
delete "/loot/:id" do |id|
  cnt = LOOT_ITEMS.where(id: id.to_i).delete
  halt 404, { error: "not found" }.to_json if cnt == 0
  { ok: true }.to_json
end

# ---------------- Enemies CRUD ----------------

# List enemies
get "/enemies" do
  ENEMIES.order(:id).all.map { |r| { id: r[:id], name: r[:name], updated_at: r[:updated_at] } }.to_json
end

# Create enemy
post "/enemies" do
  b = json_body
  name = (b["name"] || "").strip
  halt 400, { error: "name required" }.to_json if name.empty?
  id = ENEMIES.insert(name: name, updated_at: now_iso)
  { id: id, name: name }.to_json
end

# Read enemy
get "/enemies/:id" do |id|
  r = ENEMIES.where(id: id.to_i).first
  halt 404, { error: "not found" }.to_json unless r
  { id: r[:id], name: r[:name], updated_at: r[:updated_at] }.to_json
end

# Update enemy
put "/enemies/:id" do |id|
  b = json_body
  name = (b["name"] || "").strip
  halt 400, { error: "name required" }.to_json if name.empty?
  cnt = ENEMIES.where(id: id.to_i).update(name: name, updated_at: now_iso)
  halt 404, { error: "not found" }.to_json if cnt == 0
  { ok: true }.to_json
end

# Delete enemy
delete "/enemies/:id" do |id|
  cnt = ENEMIES.where(id: id.to_i).delete
  halt 404, { error: "not found" }.to_json if cnt == 0
  { ok: true }.to_json
end

# ---------------- Enemy loot mappings ----------------

# List an enemy's loot weights
get "/enemies/:id/loot" do |id|
  eid = id.to_i
  halt 404, { error: "enemy not found" }.to_json unless ENEMIES.where(id: eid).first
  rows = ENEMY_LOOT.where(enemy_id: eid).all
  payload = rows.map do |r|
    loot = LOOT_ITEMS.where(id: r[:loot_id]).first
    next nil unless loot
    { loot: row_to_loot(loot), weight: r[:weight] }
  end.compact
  payload.to_json
end

# Add a loot mapping to an enemy: { loot_id, weight }
post "/enemies/:id/loot" do |id|
  b = json_body
  eid = id.to_i
  loot_id = b["loot_id"].to_i
  weight = (b["weight"] || 1).to_i
  halt 404, { error: "enemy not found" }.to_json unless ENEMIES.where(id: eid).first
  halt 404, { error: "loot not found" }.to_json unless LOOT_ITEMS.where(id: loot_id).first
  ENEMY_LOOT.insert_conflict(target: [:enemy_id, :loot_id], update: { weight: weight, updated_at: now_iso })
           .insert(enemy_id: eid, loot_id: loot_id, weight: weight, updated_at: now_iso)
  { ok: true }.to_json
end

# Update a specific loot weight for an enemy
put "/enemies/:id/loot/:loot_id" do |id, loot_id|
  eid = id.to_i
  lid = loot_id.to_i
  b = json_body
  weight = (b["weight"] || 1).to_i
  cnt = ENEMY_LOOT.where(enemy_id: eid, loot_id: lid).update(weight: weight, updated_at: now_iso)
  halt 404, { error: "mapping not found" }.to_json if cnt == 0
  { ok: true }.to_json
end

# Remove a loot mapping
delete "/enemies/:id/loot/:loot_id" do |id, loot_id|
  cnt = ENEMY_LOOT.where(enemy_id: id.to_i, loot_id: loot_id.to_i).delete
  halt 404, { error: "mapping not found" }.to_json if cnt == 0
  { ok: true }.to_json
end

# ---------------- Location CRUD ----------------

# List locations
get "/api/locations" do
  LOCATION_TEMPLATES.order(:id).all.to_json
end

# Create location
post "/api/locations" do
  b = json_body
  name = (b["name"] || "").strip
  desc = (b["description"] || "").strip
  type = (b["type"] || "generic").strip
  halt 400, { error: "name and description required" }.to_json if name.empty? || desc.empty?

  id = LOCATION_TEMPLATES.insert(
    name: name,
    description: desc,
    type: type,
    updated_at: now_iso
  )
  LOCATION_TEMPLATES.where(id: id).first.to_json
end

# Read location
get "/api/locations/:id" do |id|
  loc = LOCATION_TEMPLATES.where(id: id.to_i).first
  halt 404, { error: "not found" }.to_json unless loc
  loc.to_json
end

# Update location
put "/api/locations/:id" do |id|
  b = json_body
  updates = { updated_at: now_iso }
  updates[:name] = b["name"].strip if b["name"]
  updates[:description] = b["description"].strip if b["description"]
  updates[:type] = b["type"].strip if b["type"]

  cnt = LOCATION_TEMPLATES.where(id: id.to_i).update(updates)
  halt 404, { error: "not found" }.to_json if cnt == 0
  LOCATION_TEMPLATES.where(id: id.to_i).first.to_json
end

# Delete location
delete "/api/locations/:id" do |id|
  cnt = LOCATION_TEMPLATES.where(id: id.to_i).delete
  halt 404, { error: "not found" }.to_json if cnt == 0
  { ok: true }.to_json
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
    encounter = current_node.encounters.sample # Assuming one encounter per node for now

    if encounter && encounter.enemy_id
      # Resolve combat encounter
      resolution_payload = { character: char, enemy_id: encounter.enemy_id }

      # Making a request to our own endpoint is a bit weird.
      # A better way would be to refactor the resolution logic into a shared module.
      # For now, we'll simulate the call.
      # This is a simplified version of the logic in /quests/resolve_encounter
      loot_rows = ENEMY_LOOT.where(enemy_id: encounter.enemy_id).all
      loot_item = nil
      if loot_rows.any?
        picked = weighted_roll(loot_rows)
        loot_item = LOOT_ITEMS.where(id: picked[:loot_id]).first if picked
      end
      xp_gain = rand(18..32)
      loot = loot_item ? [row_to_loot(loot_item)] : []
      rewards = [{type: :xp, value: xp_gain}] + loot.map{|l| {type: :loot, value: l}}

      outcome = {
        log: "#{encounter.description} You won, gaining #{xp_gain} XP.",
        rewards: rewards
      }
    else
      # Peaceful encounter
      outcome = {
        log: encounter ? encounter.description : "The area is peaceful.",
        rewards: []
      }
    end

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

# This endpoint is no longer called directly by the overlay, but is used
# by the point-crawl system to resolve encounters with enemies.
# Request body can include { enemy_id }
post "/quests/resolve_encounter" do
  payload = json_body
  char = payload["character"] || {}
  enemy_id = payload["enemy_id"]

  loot_rows =
    if enemy_id
      ENEMY_LOOT.where(enemy_id: enemy_id.to_i).all
    else
      []
    end

  loot_item = nil
  if loot_rows.any?
    picked = weighted_roll(loot_rows)
    if picked
      loot_item = LOOT_ITEMS.where(id: picked[:loot_id]).first
    end
  end

  # If no enemy mapping or empty table, roll 60% chance on any loot
  if loot_item.nil?
    all = LOOT_ITEMS.all
    loot_item = all.sample if rand < 0.6 && all.any?
  end

  xp_gain = rand(18..32)
  loot = loot_item ? [row_to_loot(loot_item)] : []

  outcome = { xp: xp_gain, loot: loot }

  EVENTS.insert(id: "ev_#{SecureRandom.hex(6)}",
                character_id: char["id"] || "unknown",
                json: {
                  id: "ev_#{SecureRandom.hex(4)}",
                  type: "event",
                  kind: "quest_result",
                  payload: outcome,
                  character_id: char["id"],
                  updated_at: now_iso,
                  version: 1
                }.to_json,
                updated_at: now_iso)

  outcome.to_json
end


# ---- Debug helpers ----

get "/debug/characters" do
  CHARACTERS.order(Sequel.desc(:updated_at)).all.map { |r| JSON.parse(r[:json]) }.to_json
end

get "/debug/events/:id" do |id|
  EVENTS.where(character_id: id).order(:updated_at).all.map { |r| JSON.parse(r[:json]) }.to_json
end
