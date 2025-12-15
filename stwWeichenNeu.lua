local redstone = component.proxy(component.list("redstone")())
local modem = component.proxy(component.list("modem")())
local eeprom = component.proxy(component.list("eeprom")())

local add = eeprom.getLabel()
local PORT = 1234
local uptime = computer.uptime

-- HARDWARE SIDES (Adjust these to match your wiring! aaaaaaaaaaaaaaaaaaaa)
local SIDE_COMMAND  = 1  -- Output to Weichen (e.g., East)
local SIDE_FEEDBACK = 0  -- Input from Weichen (e.g., West)

local zustaendigkeit = {}
local colorMap = {} 
local last_lage = {}
local next_poll = 0 -- Timer variable
local colorBits = { "white", "orange", "magenta", "lightBlue", "yellow", "lime", "pink", "gray", "lightGray", "cyan", "purple", "blue", "brown", "green", "red", "black" }

modem.open(PORT)

-- 1. Helper Functions
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

local function readWeichenlage(id)
  local idx = colorMap[tostring(id)]
  if not idx then return "+" end
  
  -- Read from Feedback Side
  local inputs = redstone.getBundledInput(SIDE_FEEDBACK) or {}
  local val = inputs[idx - 1] or 0
  
  -- If Signal is ON (>0) -> "-" (Abzweig), else "+" (Gerade)
  return (val > 0) and "-" or "+"
end

local function setRedstone(lage, id)
  local idx = colorMap[tostring(id)]
  if not idx then return end

  local colorIndex = idx - 1
  local level = (lage == "-") and 255 or 0

  local currentValues = redstone.getBundledOutput(SIDE_COMMAND) or {}
  for i=0,15 do currentValues[i] = currentValues[i] or 0 end -- Safe init
  currentValues[colorIndex] = level
  redstone.setBundledOutput(SIDE_COMMAND, currentValues)
end

-- 2. Startup Loop: GET RESPONSIBILITY
-- We use a loop that retries every 2 seconds if it doesn't get an answer.
local last_req_time = 0

while #zustaendigkeit == 0 do
  local now = uptime()
  
  -- If 2 seconds passed since last request, send again (RETRY LOGIC)
  if now - last_req_time > 2 then
    modem.broadcast(PORT, serialize({event = "zustaendigkeit_request", id = add}))
    last_req_time = now
  end

  -- Wait briefly (0.1s) for a response, then loop again
  local event, _, _, port, _, msg = computer.pullSignal(0.1)

  if event == "modem_message" and port == PORT then
    local data = unserialize(msg)
    if data then
      if data.event == "initial_startup" then
         last_req_time = 0 -- force immediate retry
      end

      -- ERROR FIX: Convert both IDs to string before comparing
      if tostring(data.id) == tostring(add) and data.event == "zustaendigkeit_response" then
        zustaendigkeit = unserialize(data.zustaendigkeit)
        colorMap = {}
        for i, MY_ID in ipairs(zustaendigkeit) do
          colorMap[tostring(MY_ID)] = i
          -- Initialize last known state from PHYSICAL HARDWARE
          last_lage[tostring(MY_ID)] = readWeichenlage(MY_ID)
        end
        modem.broadcast(PORT, serialize({event = "ack", id = add, zustaendigkeit = data.zustaendigkeit}))
      end
    end
  end
end

-- Report initial physical state to server
for _, MY_ID in ipairs(zustaendigkeit) do
    local current = readWeichenlage(MY_ID)
    -- Optional: Sync output to match input immediately?
    -- setRedstone(current, MY_ID) 
    modem.broadcast(PORT, serialize({event = "ack", id = MY_ID, lage = current}))
end

-- 3. Main Loop
next_poll = uptime() + 2

while true do
  local now = uptime()
  
  -- TIMER LOGIC: Calculate how long to sleep
  local time_left = next_poll - now
  if time_left < 0.1 then time_left = 0.1 end

  -- Wait for message OR timeout
  local event, _, _, port, _, msg = computer.pullSignal(time_left)
  
  -- Update time after waking up
  now = uptime()

  -- A. CHECK FEEDBACK (Every 2 seconds)
  if now >= next_poll then
    next_poll = now + 2
    for _, MY_ID in ipairs(zustaendigkeit) do
       local strID = tostring(MY_ID)
       local current = readWeichenlage(MY_ID)
       
       if last_lage[strID] ~= current then
          last_lage[strID] = current
          -- Detected manual change -> Tell Server
          modem.broadcast(PORT, serialize({event = "ack", id = MY_ID, lage = current}))
       end
    end
  end

  -- B. HANDLE MESSAGES
  if event == "modem_message" and port == PORT then
    local data = unserialize(msg)
    if data then
       local dataID = tostring(data.id)
       
       -- Server Restart
       if data.event == "initial_startup" then
          modem.broadcast(PORT, serialize({event = "zustaendigkeit_request", id = add}))
       end
       
       -- Switch Commands
       if colorMap[dataID] then
          if data.event == "umstellauftrag" then
             setRedstone(data.lage, dataID)
             -- Update memory immediately so the poll doesn't think it's a manual change
             last_lage[dataID] = data.lage 
             modem.broadcast(PORT, serialize({event = "ack", id = dataID, lage = data.lage}))
             
          elseif data.event == "request_lage" then
             local current = readWeichenlage(dataID)
             modem.broadcast(PORT, serialize({event = "ack", id = dataID, lage = current}))
          end
       end
    end
  end
end