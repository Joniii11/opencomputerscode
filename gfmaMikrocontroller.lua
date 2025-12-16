local redstone = component.proxy(component.list("redstone")())
local modem = component.proxy(component.list("modem")())
local eeprom = component.proxy(component.list("eeprom")())

local add = eeprom.getLabel()
local PORT = 1234
local uptime = computer.uptime

-- HARDWARE SIDES MAPPING
-- We map the specific Side ID to a "Quarter Index" (0, 1, 2, 3)
-- This helps us calculate which block of 16 IDs to use.
-- Side IDs: 2=North, 3=South, 4=West, 5=East (Standard OC absolute sides)
local SIDE_OFFSETS = {
  [2] = 0, -- North: IDs 1-16
  [3] = 1, -- South: IDs 17-32
  [4] = 2, -- West:  IDs 33-48
  [5] = 3  -- East:  IDs 49-64
}

local zustaendigkeit = {} -- Stores the 64 IDs
local state_cache = {}    -- Stores the last known state to prevent spam

modem.open(PORT)

-- HELPER FUNCTIONS
local function serialize(tbl)
  local function ser(val)
    if type(val) == "number" then return tostring(val)
    elseif type(val) == "boolean" then return val and "true" or "false"
    elseif type(val) == "string" then return string.format("%q", val)
    elseif type(val) == "table" then
      local items = {}
      for k, v in pairs(val) do items[#items + 1] = "[" .. ser(k) .. "]=" .. ser(v) end
      return "{" .. table.concat(items, ",") .. "}"
    else return "nil" end
  end
  return ser(tbl)
end

local function unserialize(str)
  local f = load("return " .. str)
  if f then return f() end
  return nil
end

-- Process a single signal change
local function handleRedstoneEvent(side, value, color)
  -- 1. Check if the side is one we monitor
  local offset = SIDE_OFFSETS[side]
  if not offset then return end

  -- 2. Check if color is provided (Bundled cables provide color, simple redstone does not)
  if color == nil then return end 

  -- 3. Calculate the Array Index for 'zustaendigkeit'
  -- Formula: (SideOffset * 16) + Color + 1
  -- Example: Side 2 (Offset 0), Color 0 (White) -> Index 1
  local array_index = (offset * 16) + color + 1
  local track_id = zustaendigkeit[array_index]

  if track_id then
    local is_occupied = (value > 0)

    -- 4. Check Cache (Only send if state ACTUALLY changed)
    if state_cache[array_index] ~= is_occupied then
      state_cache[array_index] = is_occupied
      
      -- Send Update
      modem.broadcast(PORT, serialize({
        event = "gfma_update", 
        id = track_id, 
        occupied = is_occupied
      }))
      
      -- BEEP! (1000Hz, 0.1s)
      computer.beep(1000, 0.1)
    end
  end
end

-- Full Scan (Used on startup only)
local function scanAll()
  for side, offset in pairs(SIDE_OFFSETS) do
    local inputs = redstone.getBundledInput(side) or {}
    for color = 0, 15 do
      local val = inputs[color] or 0
      handleRedstoneEvent(side, val, color)
    end
  end
end

local function handle_zustaendigkeit_response(data)
  zustaendigkeit = unserialize(data.zustaendigkeit) or {}
  state_cache = {} 
  scanAll() -- Force sync
  modem.broadcast(PORT, serialize({event = "ack", id = add, zustaendigkeit = data.zustaendigkeit}))
end

-- STARTUP LOOP
local last_req_time = 0

while #zustaendigkeit == 0 do
  local now = uptime()
  
  if now - last_req_time > 2 then
    modem.broadcast(PORT, serialize({
      event = "zustaendigkeit_request", 
      id = add,
    }))
    last_req_time = now
  end

  local event, _, _, port, _, msg = computer.pullSignal(0.1)

  if event == "modem_message" and port == PORT then
    local data = unserialize(msg)
    if data then
      if data.event == "initial_startup" then last_req_time = 0 end
      if tostring(data.id) == tostring(add) and data.event == "zustaendigkeit_response" then
          handle_zustaendigkeit_response(data)
      end
    end
  end
end

-- MAIN EVENT LOOP
while true do
  -- Wait indefinitely for a signal
  local event_data = {computer.pullSignal()}
  local event_type = event_data[1]

  if event_type == "redstone_changed" then
    -- address, side, oldValue, newValue, color
    local side = event_data[3]
    local newValue = event_data[5]
    local color = event_data[6]
    
    handleRedstoneEvent(side, newValue, color)

  elseif event_type == "modem_message" then
    -- _, localAddr, remoteAddr, port, distance, message
    local port = event_data[4]
    local msg = event_data[6]

    if port == PORT then
      local data = unserialize(msg)
      if data then
         if data.event == "initial_startup" then
            modem.broadcast(PORT, serialize({event = "zustaendigkeit_request", id = add}))
         elseif data.event == "zustaendigkeit_response" and tostring(data.id) == tostring(add) then
            handle_zustaendigkeit_response(data)
         elseif data.event == "request_status" then
            scanAll()
         end
      end
    end
  end
end