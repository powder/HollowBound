# backend_sqlite_crud.rb
require "sinatra"
require "json"
require "sequel"
require "securerandom"
require "time"

set :bind, "0.0.0.0"
set :port, 4567

DB_PATH = ENV.fetch("RPG_DB", "rpg.db")
DB = Sequel.sqlite(DB_PATH)

# ---------------- Schema ----------------
DB.create_table?(:characters) do
  String  :id, primary_key: true
  Text    :json, null: false
  String  :updated_at, null: false
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

CHARACTERS  = DB[:characters]
EVENTS      = DB[:events]
QUESTS      = DB[:quest_titles]
LOOT        = DB[:loot_items]
ENEMIES     = DB[:enemies]
ENEMY_LOOT  = DB[:enemy_loot]

# ---------------- Helpers ----------------
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

# ---------------- Characters ----------------

get "/character/:id" do |id|
  row = CHARACTERS.where(id: id).first
  halt 404, { error: "not found" }.to_json unless row
  row[:json]
end

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
  QUESTS.order(:id).all.map { |r| { id: r[:id], title: r[:title], updated_at: r[:updated_at] } }.to_json
end

# Create quest title
post "/quests/titles" do
  b = json_body
  title = (b["title"] || "").strip
  halt 400, { error: "title required" }.to_json if title.empty?
  id = QUESTS.insert(title: title, updated_at: now_iso)
  { id: id, title: title }.to_json
end

# Read quest title
get "/quests/titles/:id" do |id|
  r = QUESTS.where(id: id.to_i).first
  halt 404, { error: "not found" }.to_json unless r
  { id: r[:id], title: r[:title], updated_at: r[:updated_at] }.to_json
end

# Update quest title
put "/quests/titles/:id" do |id|
  b = json_body
  title = (b["title"] || "").strip
  halt 400, { error: "title required" }.to_json if title.empty?
  cnt = QUESTS.where(id: id.to_i).update(title: title, updated_at: now_iso)
  halt 404, { error: "not found" }.to_json if cnt == 0
  { ok: true }.to_json
end

# Delete quest title
delete "/quests/titles/:id" do |id|
  cnt = QUESTS.where(id: id.to_i).delete
  halt 404, { error: "not found" }.to_json if cnt == 0
  { ok: true }.to_json
end

# Existing title picker used by the overlay
get "/quests/current_title" do
  char_id = params["character_id"]
  row = QUESTS.order(Sequel.lit("RANDOM()")).first
  fallback = ["Goblin Troubles", "The Lost Amulet", "A Rumor of Riches", "Bandits on the Road", "Crypt of Forgotten Kings"].sample
  { title: row ? row[:title] : fallback, character_id: char_id }.to_json
end

# ---------------- Loot CRUD ----------------

# List loot
get "/loot" do
  LOOT.order(:id).all.map { |r| row_to_loot(r) }.to_json
end

# Create loot
post "/loot" do
  b = json_body
  key = (b["key"] || "").strip
  name = (b["name"] || "").strip
  effects = b["effects"] || {}
  rarity = b["rarity"]
  halt 400, { error: "key and name required" }.to_json if key.empty? || name.empty?
  id = LOOT.insert(key: key, name: name, effects_json: effects_json_from(effects), rarity: rarity, updated_at: now_iso)
  row_to_loot(LOOT.where(id: id).first).to_json
end

# Read loot
get "/loot/:id" do |id|
  r = LOOT.where(id: id.to_i).first
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
  cnt = LOOT.where(id: id.to_i).update(updates)
  halt 404, { error: "not found" }.to_json if cnt == 0
  row_to_loot(LOOT.where(id: id.to_i).first).to_json
end

# Delete loot
delete "/loot/:id" do |id|
  cnt = LOOT.where(id: id.to_i).delete
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
    loot = LOOT.where(id: r[:loot_id]).first
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
  halt 404, { error: "loot not found" }.to_json unless LOOT.where(id: loot_id).first
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

# ---------------- Quest resolution ----------------

# Request body can include { enemy_id }
post "/quests/resolve" do
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
      loot_item = LOOT.where(id: picked[:loot_id]).first
    end
  end

  # If no enemy mapping or empty table, roll 60% chance on any loot
  if loot_item.nil?
    all = LOOT.all
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

# ---------------- Debug ----------------

get "/debug/characters" do
  CHARACTERS.order(Sequel.desc(:updated_at)).all.map { |r| JSON.parse(r[:json]) }.to_json
end

get "/debug/events/:id" do |id|
  EVENTS.where(character_id: id).order(:updated_at).all.map { |r| JSON.parse(r[:json]) }.to_json
end
