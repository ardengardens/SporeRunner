-- Spore Runner (LOVE2D edition)
-- A black-and-white pixel-art endless runner: a gothic little mushroom
-- jumps rocks under a twinkling starfield. Rendered at a low internal
-- resolution and scaled up with nearest-neighbor filtering, so every
-- shape -- mushroom, rocks, stars, and (mostly) the text -- reads chunky.
--
-- Optional: drop a blackletter/gothic .ttf font next to this file named
-- "gothic.ttf" and the title + big headings will use it automatically.
-- LOVE can't fetch fonts from the internet on its own, so without that
-- file the game falls back to the built-in pixel font everywhere.

local VW, VH = 300, 100          -- virtual (internal) resolution
local SCALE = 3                  -- window is VW*SCALE x VH*SCALE = 900x300
local groundY = VH - 22          -- the single ground line mushroom + rocks both sit on

local canvas
local pixelFont, pixelFontBig
local gothicFont                 -- only set if gothic.ttf is present next to main.lua

local state = {
  mode = "menu",                 -- "menu" | "playing" | "over"
  speed = 2.6,
  baseSpeed = 2.6,
  gravity = 0.34,
  score = 0,
  best = 0,
  frame = 0,
  nextObstacleIn = 40,
}

-- mushroom sprite grid: an 18x20 pixel-art grid, drawn as 1x1 rectangles
local MUSH_W, MUSH_H = 18, 20
local mush = {
  x = 26, y = 0, w = MUSH_W, h = MUSH_H,
  vy = 0, grounded = true, squash = 1,
}

local JUMP_V = -6.0

local obstacles = {}
local particles = {}
local clouds = {}
local stars = {}

-- 4x4 pixel-block cloud pattern (1 = filled block)
local CLOUD_PATTERN = {
  {0,0,0,1},
  {0,0,0,1},
  {0,0,0,0},
  {0,0,0,0},
}

-- palette --------------------------------------------------------------
local K   = {0.04, 0.04, 0.04, 1} -- ink / outline
local W   = {1,    1,    1,    1} -- white
local Wd  = {0.77, 0.77, 0.77, 1} -- cap shade
local T   = {0.85, 0.85, 0.85, 1} -- stem light
local Td  = {0.43, 0.43, 0.43, 1} -- stem shade
local ROCK_BASE   = {0.55, 0.22, 0.55, 1}
local ROCK_FACET  = {0.55, 0.95, 0.55, 1}
local ROCK_OUTLINE= {0.55, 0.95, 0.95, 1}

-- persistence ------------------------------------------------------------
local function loadBest()
  if love.filesystem.getInfo("best.txt") then
    state.best = tonumber(love.filesystem.read("best.txt")) or 0
  end
end

local function saveBest()
  love.filesystem.write("best.txt", tostring(math.floor(state.best)))
end

-- background setup --------------------------------------------------------
local function resetClouds()
  clouds = {}
  for i = 1, 5 do
    table.insert(clouds, {
      x = math.random(0, VW),
      y = math.random(6, 34),
      s = 0.6 + math.random() * 0.8,
      speed = 0.15 + math.random() * 0.2,
    })
  end
end

local function resetStars()
  stars = {}
  for i = 1, 70 do
    table.insert(stars, {
      x = math.random(0, VW),
      y = math.random(0, groundY - 6),
      size = (math.random() < 0.75) and 1 or 2,
      speed = 0.04 + math.random() * 0.08,
      phase = math.random() * math.pi * 2,
      twinkleSpeed = 0.03 + math.random() * 0.05,
    })
  end
end

-- mushroom pixel-art sprite (built once as a flat list of {x,y,color}) ----
local mushroomPixels = {}

local function addPixel(x, y, color)
  if x < 0 or y < 0 or x >= MUSH_W or y >= MUSH_H then return end
  table.insert(mushroomPixels, { x = x, y = y, color = color })
end

local function buildMushroomPixels()
  mushroomPixels = {}
  local cx = 9

  -- cap dome: rows 3..9, arched silhouette with black outline
  local capTop, capBottom = 3, 9
  for y = capTop, capBottom do
    local t = (y - capTop + 0.5) / (capBottom - capTop + 1)
    local halfW = math.floor(math.sin(t * math.pi / 2) * 8 + 0.5)
    for x = cx - halfW, cx + halfW do
      if x == cx - halfW or x == cx + halfW or y == capBottom then
        addPixel(x, y, K)
      else
        addPixel(x, y, ((x * 3 + y * 2) % 7 == 0) and Wd or W)
      end
    end
  end

  -- gothic crenellated rim hanging beneath the cap, like a crown
  for x = cx - 8, cx + 8 do
    if math.abs(x - cx) % 2 == 0 then
      addPixel(x, capBottom + 1, K)
    end
  end

  -- twin horn spikes curling off the top corners of the cap
  addPixel(cx - 8, capTop - 1, K); addPixel(cx - 9, capTop - 1, K)
  addPixel(cx - 9, capTop - 2, K)
  addPixel(cx + 8, capTop - 1, K); addPixel(cx + 9, capTop - 1, K)
  addPixel(cx + 9, capTop - 2, K)
  -- a single finial spike at the crown's peak
  addPixel(cx, capTop - 1, K)

  -- dark blotchy spots across the cap
  local spots = { {cx-4,6}, {cx+3,5}, {cx+5,8}, {cx-2,8}, {cx-6,7} }
  for _, s in ipairs(spots) do addPixel(s[1], s[2], K) end

  -- stem: rows 11..18, tapered, with an ink outline
  local stemTop, stemBottom = 11, 18
  for y = stemTop, stemBottom do
    local t = (y - stemTop) / (stemBottom - stemTop)
    local halfW = math.max(2, math.floor(3.4 - t * 1.2 + 0.5))
    for x = cx - halfW, cx + halfW do
      if x == cx - halfW or x == cx + halfW then
        addPixel(x, y, K)
      else
        addPixel(x, y, (y > stemTop + 4 and (x + y) % 4 == 0) and Td or T)
      end
    end
  end

  -- glowing eyes set into the stem, just below the cap
--  addPixel(cx-3, stemTop+1, K); addPixel(cx-3, stemTop+2, K); addPixel(cx-3, stemTop+2, W)
--  addPixel(cx+2, stemTop+1, K); addPixel(cx+2, stemTop+2, K); addPixel(cx+2, stemTop+2, W)

  -- thin root tendrils dripping from the base
  addPixel(cx-4, stemBottom+1, K)
  addPixel(cx+3, stemBottom+1, K)
  addPixel(cx,   stemBottom+1, K)
end

-- game flow ---------------------------------------------------------------
local function spawnSpores(x, y, n)
  for i = 1, n do
    table.insert(particles, {
      x = x + (math.random() - 0.5) * 6,
      y = y - 3,
      vx = (math.random() - 0.5) * 0.8,
      vy = -math.random() * 0.9 - 0.2,
      life = 18 + math.random() * 12,
      maxLife = 30,
    })
  end
end

local function spawnObstacle()
  local roll = math.random()
  if roll < 0.55 then
    local h = 8 + math.random() * 8
    table.insert(obstacles, { x = VW + 10, y = groundY, w = 9 + math.random() * 6, h = h, seed = math.random() * 1000 })
  elseif roll < 0.8 then
    local h = 14 + math.random() * 6
    table.insert(obstacles, { x = VW + 10, y = groundY, w = 8 + math.random() * 3, h = h, seed = math.random() * 1000 })
  else
    local h = 7 + math.random() * 5
    table.insert(obstacles, { x = VW + 10, y = groundY, w = 7, h = h, seed = math.random() * 1000 })
    table.insert(obstacles, { x = VW + 10 + 11, y = groundY, w = 7, h = h * 1.3, seed = math.random() * 1000 })
  end
end

local function resetGame()
  state.mode = "playing"
  state.speed = state.baseSpeed
  state.score = 0
  state.frame = 0
  state.nextObstacleIn = 40
  mush.y = groundY
  mush.vy = 0
  mush.grounded = true
  mush.squash = 1
  obstacles = {}
  particles = {}
end

local function jump()
  if state.mode ~= "playing" then
    resetGame()
    return
  end
  if mush.grounded then
    mush.vy = JUMP_V
    mush.grounded = false
    spawnSpores(mush.x + mush.w / 2, mush.y, 4)
  end
end

local function rectsOverlap(a, b)
  return a.x < b.x + b.w and a.x + a.w > b.x and a.y < b.y + b.h and a.y + a.h > b.y
end

local function gameOver()
  state.mode = "over"
  local s = math.floor(state.score)
  if s > state.best then
    state.best = s
    saveBest()
  end
end

-- love callbacks ------------------------------------------------------------
function love.load()
  love.window.setTitle("Spore Runner")
  love.graphics.setDefaultFilter("nearest", "nearest")
  canvas = love.graphics.newCanvas(VW, VH)
  canvas:setFilter("nearest", "nearest")

  pixelFont = love.graphics.newFont(8, "mono")
  pixelFont:setFilter("nearest", "nearest")
  pixelFontBig = love.graphics.newFont(14, "mono")
  pixelFontBig:setFilter("nearest", "nearest")

  -- optional real gothic font, if the user drops one next to this file
  if love.filesystem.getInfo("gothic.ttf") then
    local ok, f = pcall(love.graphics.newFont, "gothic.ttf", 20)
    if ok then gothicFont = f end
  end

  love.graphics.setFont(pixelFont)
  math.randomseed(os.time())

  mush.y = groundY
  buildMushroomPixels()
  loadBest()
  resetClouds()
  resetStars()
end

function love.keypressed(key)
  if key == "space" or key == "up" then
    jump()
  end
  if key == "escape" then
    love.event.quit()
  end
end

function love.mousepressed()
  jump()
end

function love.update(dt)
  local step = dt * 60
  if step > 3 then step = 3 end

  if state.mode == "playing" then
    for _, c in ipairs(clouds) do
      c.x = c.x - c.speed * step
      if c.x < -20 then
        c.x = VW + 20
        c.y = math.random(6, 34)
      end
    end
    for _, s in ipairs(stars) do
      s.x = s.x - s.speed * step
      if s.x < -4 then s.x = VW + 4 end
    end
  end

  if state.mode ~= "playing" then return end

  state.frame = state.frame + step
  state.score = state.score + state.speed * 0.05 * step
  state.speed = state.baseSpeed + math.min(3.2, state.score / 260)

  if not mush.grounded then
    mush.vy = mush.vy + state.gravity * step
    mush.y = mush.y + mush.vy * step
    if mush.y >= groundY then
      mush.y = groundY
      mush.vy = 0
      mush.grounded = true
      mush.squash = 1.25
      spawnSpores(mush.x + mush.w / 2, mush.y, 5)
    end
  end
  mush.squash = mush.squash + (1 - mush.squash) * 0.2 * step

  state.nextObstacleIn = state.nextObstacleIn - step
  if state.nextObstacleIn <= 0 then
    spawnObstacle()
    state.nextObstacleIn = math.max(24, 46 - state.score / 14) + math.random() * 22
  end

  for _, o in ipairs(obstacles) do
    o.x = o.x - state.speed * step
  end
  for i = #obstacles, 1, -1 do
    if obstacles[i].x + obstacles[i].w < -10 then
      table.remove(obstacles, i)
    end
  end

  local mushBox = { x = mush.x + 3, y = mush.y - mush.h + 2, w = mush.w - 6, h = mush.h - 2 }
  for _, o in ipairs(obstacles) do
    local obox = { x = o.x, y = o.y - o.h, w = o.w, h = o.h }
    if rectsOverlap(mushBox, obox) then
      gameOver()
      break
    end
  end

  for _, p in ipairs(particles) do
    p.x = p.x + p.vx * step
    p.y = p.y + p.vy * step
    p.vy = p.vy + 0.015 * step
    p.life = p.life - step
  end
  for i = #particles, 1, -1 do
    if particles[i].life <= 0 then
      table.remove(particles, i)
    end
  end
end

-- drawing --------------------------------------------------------------
local function drawStars()
  for _, s in ipairs(stars) do
    local twinkle = 0.5 + 0.5 * math.sin(state.frame * s.twinkleSpeed + s.phase)
    love.graphics.setColor(1, 1, 1, 0.25 + twinkle * 0.65)
    love.graphics.rectangle("fill", math.floor(s.x), math.floor(s.y), s.size, s.size)
  end
  love.graphics.setColor(1, 1, 1, 1)
end

 local function drawClouds()
  love.graphics.setColor(1, 1, 1, 0.5)
  for _, c in ipairs(clouds) do
    local bs = math.max(1, math.floor(2 * c.s))
    local gw, gh = #CLOUD_PATTERN[1], #CLOUD_PATTERN
    local ox = math.floor(c.x - (gw * bs) / 2)
    local oy = math.floor(c.y - (gh * bs) / 2)
    for row = 1, gh do
      for col = 1, gw do
        if CLOUD_PATTERN[row][col] == 1 then
          love.graphics.rectangle("fill", ox + (col - 1) * bs, oy + (row - 1) * bs, bs, bs)
        end
      end
    end
  end
  love.graphics.setColor(1, 1, 1, 1)
end

local function drawGround()
  love.graphics.setColor(0.08, 0.08, 0.08, 1)
  love.graphics.rectangle("fill", 0, groundY + 1, VW, VH - groundY - 1)
  love.graphics.setColor(0.85, 0.85, 0.85, 1)
  love.graphics.rectangle("fill", 0, groundY, VW, 1)

  love.graphics.setColor(1, 1, 1, 0.35)
  local off = math.floor(state.frame * state.speed) % 14
  local x = -off
  while x < VW do
    love.graphics.rectangle("fill", x, groundY + 3, 6, 1)
    x = x + 14
  end
  love.graphics.setColor(1, 1, 1, 1)
end

local function drawMushroom()
  love.graphics.push()
  love.graphics.translate(mush.x, mush.y)   -- anchor at feet (ground line)
  love.graphics.scale(1, mush.squash)
  love.graphics.translate(0, -MUSH_H)       -- shift up so sprite bottom lands on the anchor
  for _, p in ipairs(mushroomPixels) do
    love.graphics.setColor(p.color)
    love.graphics.rectangle("fill", p.x, p.y, 1, 1)
  end
  love.graphics.pop()
  love.graphics.setColor(1, 1, 1, 1)
end

local function drawObstacles()
  local RW, RH = 10, 8
  for _, o in ipairs(obstacles) do
    local colW = o.w / RW
    local rowH = o.h / RH
    for col = 0, RW - 1 do
      local t = col / (RW - 1)
      local jag = math.abs(math.sin(o.seed + t * 7 * 2.3)) * (RH * 0.4)
      local hgt = math.sin(t * math.pi) * (RH - jag) + jag * 0.3
      hgt = math.max(2, math.floor(hgt + 0.5))
      local topRow = RH - hgt
      for row = topRow, RH - 1 do
        local isEdge = (row == topRow) or (col == 0) or (col == RW - 1)
        local isFacet = (col < RW * 0.45) and (row < topRow + hgt * 0.55)
        local color = isEdge and ROCK_OUTLINE or (isFacet and ROCK_FACET or ROCK_BASE)
        love.graphics.setColor(color)
        love.graphics.rectangle("fill",
          o.x + col * colW, o.y - o.h + row * rowH,
          colW + 0.6, rowH + 0.6)
      end
    end
  end
  love.graphics.setColor(1, 1, 1, 1)
end

local function drawParticles()
  for _, p in ipairs(particles) do
    love.graphics.setColor(1, 1, 1, math.max(0, p.life / p.maxLife))
    love.graphics.rectangle("fill", math.floor(p.x), math.floor(p.y), 1, 1)
  end
  love.graphics.setColor(1, 1, 1, 1)
end

local function drawHud()
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.setFont(pixelFont)
  love.graphics.print(string.format("BEST %04d", state.best), 6, 4)
  love.graphics.print(string.format("SCORE %04d", math.floor(state.score)), VW - 90, 4)

  if state.mode == "menu" or state.mode == "over" then
    love.graphics.setFont(gothicFont or pixelFontBig)
    local heading = (state.mode == "menu") and "SPORE RUNNER" or "COMPOSTED"
    love.graphics.printf(heading, 0, VH / 2 - 20, VW, "center")

    love.graphics.setFont(pixelFont)
    local sub = (state.mode == "menu") and "SPACE to start" or "SPACE to retry"
    love.graphics.printf(sub, 0, VH / 2 + 2, VW, "center")
  end
end

function love.draw()
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0.02, 0.02, 0.02, 1)

  drawStars()
  drawClouds()
  drawGround()
  drawObstacles()
  drawMushroom()
  drawParticles()
  drawHud()

  love.graphics.setCanvas()
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.draw(canvas, 0, 0, 0, SCALE, SCALE)
end
