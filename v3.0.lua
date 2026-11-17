-- VBL 3.0 by Luna, volleyball legends helper for matcha

local PreviousRunId = 0
do
  local okG, prev = pcall(function() return _G.VBL_HELPER end)
  if okG and type(prev) == "table" then
    if type(prev.runId) == "number" then PreviousRunId = prev.runId end
    if type(prev.stop) == "function" then pcall(prev.stop) end
  end
end

local VERSION = "3.0"

-- loops check Running, stop() clears it
local Running = true
local Connections = {}

-- debug handle, filled in as functions get defined
local DebugHandle = {
  version = VERSION,
  runId = PreviousRunId + 1, -- bumps on every re-run
  started = tick(),
  running = true,
  connections = 0,
  buildOk = nil, -- nil until the tab is first opened
  buildError = nil,
  settingsPushed = false,
  settingsPushedFrame = nil,
  pushError = nil,
}
pcall(function() _G.VBL_HELPER = DebugHandle end)

local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local LocalPlayer = Players.LocalPlayer

local SETTINGS_FILE = "volleyball_legends_v3_settings.json"
local OFFSETS_CACHE = "volleyball_legends_v3_offsets.json"
local OFFSET_URLS = {
  "https://offsets.imtheo.lol/Offsets.json",
  "https://imtheo.lol/Offsets/Offsets.json",
}

-- internal timings, not in the menu
local AIR_FLOOR_MATERIAL = 1792
local LAND_DEBOUNCE = 0.08
local JUMP_KEY = 0x20
local PRE_JUMP_GRACE = 0.15
local FIGHT_DOT = 0.7
local FIGHT_FRAMES = 3
local USE_JUMP_FLAG = true
local CONTROLLER_SUPPORT = true
local JUMP_MIN_VELOCITY = 12
local CONTROLLER_PENDING_TIME = 0.12
local DIVE_KEYS = { 0xA2, 0x11 }
local DIVE_BLOCK_TIME = 1.0

local BALL_NAME_PATTERN = "CLIENT_BALL_"
local BALL_HITBOX_PART = "BoundingBox"
local BALL_HITBOX_INVISIBLE = true
local BALL_REAPPLY_INTERVAL = 0.25 -- live ball re-apply
local BALL_DIRTY_INTERVAL = 0.1 -- live ball, min gap after a change
local TEMPLATE_DIRTY_INTERVAL = 0.5 -- templates, min gap after a change
local TEMPLATE_REFRESH_INTERVAL = 5.0 -- templates, slow re-check
local BALL_PART_CLASSES = { Part = true, MeshPart = true, BasePart = true }

local DARK_AMBIENT = { 0.10, 0.10, 0.12 }
local DARK_OUTDOOR_AMBIENT = { 0.14, 0.14, 0.17 }

local F1_KEY = 0x70
local CREDIT = "VBL " .. VERSION .. " by Luna"

-- { key, default, min, max, integer }
local SCHEMA = {
  { "ball_transparency", 0.0, 0.0, 1.0 },
  { "hitbox", true },
  { "hitbox_size", 8.0, 1.0, 70.0 },
  { "hitbox_mode", 1, 0, 1, true }, -- 0 visible, 1 streamproof

  { "jump_assist", true },
  { "pre_jump", true },
  { "face_on_press", true },
  { "follow_camera_in_air", false },
  { "hold_duration", 999, 0, 999 },
  { "abort_when_fought", true },
  { "ignore_non_jump_air", true },

  { "eye_lines", false },
  { "eye_length", 60, 5, 500 },
  { "eye_thickness", 2, 1, 10 },
  { "eye_max_distance", 300, 50, 1000 },
  { "eye_enemies_only", true },

  { "dark_graphics", false },
  { "dark_brightness", 1.0, 0.0, 5.0 },
  { "dark_exposure", -0.6, -3.0, 3.0 },

}
local DEFAULT_EYE_COLOR = { 255, 60, 60 }

local SchemaByKey = {}
for _, e in ipairs(SCHEMA) do
  SchemaByKey[e[1]] = { default = e[2], min = e[3], max = e[4], int = e[5] == true, kind = type(e[2]) }
end

local Settings = {}
local function ResetSettingsTable(includeColor)
  for _, e in ipairs(SCHEMA) do Settings[e[1]] = e[2] end
  if includeColor or not Settings.eye_color then
    Settings.eye_color = { DEFAULT_EYE_COLOR[1], DEFAULT_EYE_COLOR[2], DEFAULT_EYE_COLOR[3] }
  end
end
ResetSettingsTable(true)

local function Clamp(v, lo, hi)
  if lo and v < lo then v = lo end
  if hi and v > hi then v = hi end
  return v
end

local function Coerce(key, v)
  local s = SchemaByKey[key]
  if not s then return nil end
  if s.kind == "boolean" then
    if type(v) == "boolean" then return v end
    if type(v) == "number" then return v ~= 0 end
    return nil
  elseif s.kind == "number" then
    v = tonumber(v)
    if not v or v ~= v then return nil end
    if s.int then v = math.floor(v + 0.5) end
    return Clamp(v, s.min, s.max)
  elseif s.kind == "string" then
    if type(v) == "string" and v ~= "" and #v < 200 then return v end
    return nil
  end
  return nil
end

local function CleanColor(t)
  if type(t) ~= "table" then return nil end
  local r, g, b = tonumber(t[1]), tonumber(t[2]), tonumber(t[3])
  if not (r and g and b) then return nil end
  return { math.floor(Clamp(r, 0, 255)), math.floor(Clamp(g, 0, 255)), math.floor(Clamp(b, 0, 255)) }
end

local Dirty = false
local DirtyTick = 0
local function MarkDirty()
  Dirty = true
  DirtyTick = tick()
end

local SETTINGS_FORMAT = 2 -- bump when the save layout changes

local function EncodeSettings()
  local out = { version = VERSION, settings_format = SETTINGS_FORMAT }
  for _, e in ipairs(SCHEMA) do out[e[1]] = Settings[e[1]] end
  out.eye_color = Settings.eye_color
  local ok, json = pcall(function() return HttpService:JSONEncode(out) end)
  if ok and type(json) == "string" then return json end
  return nil
end

-- every value goes through Coerce, junk is ignored
local function ApplySettingsData(data)
  if type(data) ~= "table" then return false end
  for _, e in ipairs(SCHEMA) do
    local v = Coerce(e[1], data[e[1]])
    if v ~= nil then Settings[e[1]] = v end
  end
  local c = CleanColor(data.eye_color)
  if c then Settings.eye_color = c end
  -- old 3.0 saves: 0 off / 1 visible / 2 streamproof
  if data.settings_format == nil and data.ball_resize ~= nil then
    local old = tonumber(data.hitbox_mode)
    if old == 0 then
      Settings.hitbox = false
    elseif old == 1 then
      Settings.hitbox, Settings.hitbox_mode = true, 0
    elseif old == 2 then
      Settings.hitbox, Settings.hitbox_mode = true, 1
    end
  end
  return true
end

local function SaveSettings()
  Dirty = false
  local json = EncodeSettings()
  if json then
    pcall(writefile, SETTINGS_FILE, json)
    return true
  end
  return false
end

local function LoadSettings()
  local okE, exists = pcall(isfile, SETTINGS_FILE)
  if not (okE and exists) then return false end
  local okR, raw = pcall(readfile, SETTINGS_FILE)
  if not (okR and type(raw) == "string" and raw ~= "") then return false end
  local okD, data = pcall(function() return HttpService:JSONDecode(raw) end)
  if not (okD and type(data) == "table") then return false end
  return ApplySettingsData(data)
end

pcall(LoadSettings)
DebugHandle.settings = Settings

local function Notify(msg, title, dur)
  pcall(notify, msg, title or "VBL", dur or 3)
end

local BuiltIn = {
  Camera = { Rotation = 192, Position = 228, FieldOfView = 296 },
  BasePart = { Primitive = 376, Transparency = 280 },
  Primitive = { Rotation = 176, Position = 212, AssemblyAngularVelocity = 236 },
  Humanoid = { FloorMaterial = 376, AutoRotate = 457, Jump = 464 },
  Lighting = { Brightness = 256, ExposureCompensation = 268, Ambient = 184, OutdoorAmbient = 232 },
}

local function ValidDump(d)
  return type(d) == "table"
    and type(d.Camera) == "table" and type(d.Camera.Rotation) == "number"
    and type(d.BasePart) == "table" and type(d.BasePart.Primitive) == "number"
    and type(d.Primitive) == "table" and type(d.Primitive.Rotation) == "number"
    and type(d.Humanoid) == "table" and type(d.Humanoid.FloorMaterial) == "number"
    and type(d.Humanoid.AutoRotate) == "number"
end

local function DecodeDump(src)
  if type(src) ~= "string" or src == "" then return nil end
  local ok, decoded = pcall(function() return HttpService:JSONDecode(src) end)
  if ok and type(decoded) == "table" and ValidDump(decoded.Offsets) then
    return decoded.Offsets
  end
  return nil
end

local function Pick(dump, group, key)
  local g = dump and dump[group]
  local v = type(g) == "table" and g[key]
  if type(v) == "number" then return v end
  return BuiltIn[group][key]
end

local function BuildOffsets(dump)
  return {
    CamRot = Pick(dump, "Camera", "Rotation"),
    Primitive = Pick(dump, "BasePart", "Primitive"),
    Transp = Pick(dump, "BasePart", "Transparency"),
    PrimRot = Pick(dump, "Primitive", "Rotation"),
    AngVel = Pick(dump, "Primitive", "AssemblyAngularVelocity"),
    Floor = Pick(dump, "Humanoid", "FloorMaterial"),
    AutoRotate = Pick(dump, "Humanoid", "AutoRotate"),
    Jump = Pick(dump, "Humanoid", "Jump"),
    LBright = Pick(dump, "Lighting", "Brightness"),
    LExposure = Pick(dump, "Lighting", "ExposureCompensation"),
    LAmbient = Pick(dump, "Lighting", "Ambient"),
    LOutdoor = Pick(dump, "Lighting", "OutdoorAmbient"),
  }
end

local function SameOffsets(a, b)
  for k, v in pairs(a) do if b[k] ~= v then return false end end
  return true
end

local O = BuildOffsets(nil)
local PendingOffsets = nil

do -- cache first, built-in otherwise
  local okF, exists = pcall(isfile, OFFSETS_CACHE)
  if okF and exists then
    local okR, raw = pcall(readfile, OFFSETS_CACHE)
    if okR then
      local d = DecodeDump(raw)
      if d then O = BuildOffsets(d) end
    end
  end
end

local AmIInAir, NotAirSince = false, nil
local Holding, UsedHold = false, false
local HoldHrp, HoldHumanoid = nil, nil
local TakeoffTick, TakeoffLook = 0, nil
local ChangedAutoRotate, OriginalAutoRotate = false, 1
local FightCount = 0
local JumpLook, JumpLookTick = nil, 0
local JumpKeyHeld = false
local PreJumpLook, PreJumpUntil, PreJumpHrp = nil, 0, nil
local GroundShiftlockSince = nil
local DiveUntil = 0
local JumpWindow = 0.4
local GroundLook = nil
local AirPendingSince = nil
local PrevY, PrevYTick = nil, 0
local AssistWasActive = false

local function AssistActive()
  return Settings.jump_assist
end

local function GetCameraLook(Camera)
  local base = Camera.Address + O.CamRot
  return Vector3.new(
    -memory_read("float", base + 8),
    -memory_read("float", base + 20),
    -memory_read("float", base + 32)
  )
end

local function GetVerticalSpeed(Hrp)
  local fromProp, fromDelta = nil, nil
  local okV, v = pcall(function() return Hrp.AssemblyLinearVelocity end)
  if okV and typeof(v) == "Vector3" and v.Y == v.Y then fromProp = v.Y end

  local okP, p = pcall(function() return Hrp.Position end)
  local now = tick()
  if okP and typeof(p) == "Vector3" and p.Y == p.Y then
    if PrevY and now - PrevYTick > 0.001 and now - PrevYTick < 0.2 then
      fromDelta = (p.Y - PrevY) / (now - PrevYTick)
    end
    PrevY, PrevYTick = p.Y, now
  end
  return fromProp, fromDelta
end

local function ReadJumpFlag(Humanoid)
  return memory_read("byte", Humanoid.Address + O.Jump) == 1
end

local function FaceCamera(Hrp, Look)
  local fx, fz = Look.X, Look.Z
  local len = math.sqrt(fx * fx + fz * fz)
  if len < 0.01 then return end
  fx, fz = fx / len, fz / len

  local Prim = memory_read("uintptr_t", Hrp.Address + O.Primitive)
  if not Prim or Prim == 0 then return end
  local Rot = Prim + O.PrimRot

  memory_write("float", Rot + 0, -fz)
  memory_write("float", Rot + 4, 0)
  memory_write("float", Rot + 8, -fx)
  memory_write("float", Rot + 12, 0)
  memory_write("float", Rot + 16, 1)
  memory_write("float", Rot + 20, 0)
  memory_write("float", Rot + 24, fx)
  memory_write("float", Rot + 28, 0)
  memory_write("float", Rot + 32, -fz)

  memory_write("float", Prim + O.AngVel, 0)
  memory_write("float", Prim + O.AngVel + 4, 0)
  memory_write("float", Prim + O.AngVel + 8, 0)
end

local function FacingDot(Hrp, Look)
  local Prim = memory_read("uintptr_t", Hrp.Address + O.Primitive)
  if not Prim or Prim == 0 then return 1 end
  local R = Prim + O.PrimRot
  local hx = -memory_read("float", R + 8)
  local hz = -memory_read("float", R + 32)
  local hl = math.sqrt(hx * hx + hz * hz)
  local cl = math.sqrt(Look.X * Look.X + Look.Z * Look.Z)
  if hl < 0.01 or cl < 0.01 then return 1 end
  return (hx * Look.X + hz * Look.Z) / (hl * cl)
end

local function RestoreAutoRotate(Value)
  if ChangedAutoRotate and HoldHumanoid then
    memory_write("byte", HoldHumanoid.Address + O.AutoRotate, Value or 1)
  end
  ChangedAutoRotate = false
end

local function ReleaseHold()
  Holding = false
  RestoreAutoRotate(OriginalAutoRotate)
end

local function IgnoreAir()
  AmIInAir = true
  Holding = false
  UsedHold = false
  JumpLook = nil
  PreJumpLook = nil
  AirPendingSince = nil
end

-- hand autorotate back to the game
local function ResetAssist()
  pcall(function()
    if ChangedAutoRotate then RestoreAutoRotate(OriginalAutoRotate) end
  end)
  AmIInAir, Holding, UsedHold = false, false, false
  NotAirSince, JumpLook, PreJumpLook, AirPendingSince = nil, nil, nil, nil
  ChangedAutoRotate = false
end

local function ApplyHold()
  if not AssistActive() then return end
  if tick() < DiveUntil then return end
  if not Holding then
    if PreJumpLook and PreJumpHrp and tick() < PreJumpUntil and PreJumpHrp.Parent then
      FaceCamera(PreJumpHrp, PreJumpLook)
    end
    return
  end
  if Settings.follow_camera_in_air or not TakeoffLook then return end
  if tick() - TakeoffTick >= Settings.hold_duration then return end
  if not HoldHrp or not HoldHrp.Parent then return end
  if HoldHumanoid and ChangedAutoRotate then
    memory_write("byte", HoldHumanoid.Address + O.AutoRotate, 0)
  end
  FaceCamera(HoldHrp, TakeoffLook)
end

local function IsShiftlockOn(Camera, Humanoid, Hrp)
  if memory_read("byte", Humanoid.Address + O.AutoRotate) ~= 0 then return false end
  return FacingDot(Hrp, GetCameraLook(Camera)) > 0.97
end

local function StartHold(Camera, Humanoid, Hrp)
  AmIInAir = true
  Holding = true
  UsedHold = true
  FightCount = 0
  HoldHrp = Hrp
  HoldHumanoid = Humanoid
  TakeoffTick = tick()
  if JumpLook and tick() - JumpLookTick < JumpWindow then
    TakeoffLook = JumpLook
  elseif GroundLook then
    TakeoffLook = GroundLook
  else
    TakeoffLook = GetCameraLook(Camera)
  end
  JumpLook = nil
  PreJumpLook = nil
  local ShiftlockWasOn = GroundShiftlockSince ~= nil and tick() - GroundShiftlockSince > 0.25
  OriginalAutoRotate = ShiftlockWasOn and 0 or 1
  memory_write("byte", Humanoid.Address + O.AutoRotate, 0)
  ChangedAutoRotate = true
  if not Settings.follow_camera_in_air then
    FaceCamera(Hrp, TakeoffLook)
  end
end

local function CharacterStep()
  if not AssistActive() then
    if AssistWasActive then
      AssistWasActive = false
      ResetAssist()
    end
    return
  end
  AssistWasActive = true

  local Camera = Workspace.CurrentCamera
  if not Camera then return end

  local FollowCam = Settings.follow_camera_in_air
  local HoldTime = Settings.hold_duration

  local Character = LocalPlayer.Character
  local Humanoid = Character and Character:FindFirstChild("Humanoid")
  local Hrp = Character and Character:FindFirstChild("HumanoidRootPart")

  if Humanoid and Hrp then
    local InAir = memory_read("int", Humanoid.Address + O.Floor) == AIR_FLOOR_MATERIAL
    local Active = isrbxactive()
    local SpaceDown = Active and iskeypressed(JUMP_KEY)
    local JumpFlag = USE_JUMP_FLAG and ReadJumpFlag(Humanoid)
    local JumpDown = SpaceDown or JumpFlag
    local vyProp, vyDelta = GetVerticalSpeed(Hrp)

    if Active then
      for _, k in ipairs(DIVE_KEYS) do
        if iskeypressed(k) then DiveUntil = tick() + DIVE_BLOCK_TIME break end
      end
    end
    local DiveActive = tick() < DiveUntil
    if DiveActive then
      PreJumpLook = nil
      JumpLook = nil
      if Holding then ReleaseHold() end
    end

    if not AmIInAir and not InAir then
      AirPendingSince = nil
      GroundLook = GetCameraLook(Camera)

      if Settings.pre_jump and JumpDown and not DiveActive then
        JumpLook = GroundLook
        JumpLookTick = tick()
        JumpWindow = 0.4

        if Settings.face_on_press and not JumpKeyHeld then
          local ShiftlockOn = GroundShiftlockSince ~= nil and tick() - GroundShiftlockSince > 0.25
          if not ShiftlockOn then
            PreJumpLook = JumpLook
            PreJumpUntil = tick() + PRE_JUMP_GRACE
            PreJumpHrp = Hrp
            FaceCamera(Hrp, PreJumpLook)
          end
        end
      end
      if IsShiftlockOn(Camera, Humanoid, Hrp) then
        GroundShiftlockSince = GroundShiftlockSince or tick()
      else
        GroundShiftlockSince = nil
      end
    end

    JumpKeyHeld = JumpDown

    if InAir then
      NotAirSince = nil

      if not AmIInAir then
        local JumpKeyRecent = JumpLook ~= nil and tick() - JumpLookTick < JumpWindow
        local VelocityJump = CONTROLLER_SUPPORT and (
          (vyProp ~= nil and vyProp > JUMP_MIN_VELOCITY) or
          (vyDelta ~= nil and vyDelta > JUMP_MIN_VELOCITY)
        )

        if DiveActive then
          IgnoreAir()
        elseif JumpKeyRecent or VelocityJump or not Settings.ignore_non_jump_air then
          AirPendingSince = nil
          StartHold(Camera, Humanoid, Hrp)
        elseif CONTROLLER_SUPPORT then
          AirPendingSince = AirPendingSince or tick()
          if tick() - AirPendingSince > CONTROLLER_PENDING_TIME then
            IgnoreAir()
          end
        else
          IgnoreAir()
        end
      end

      if Holding then
        if Settings.abort_when_fought and not FollowCam and TakeoffLook and tick() - TakeoffTick > 0.05 then
          if FacingDot(Hrp, TakeoffLook) < FIGHT_DOT then
            FightCount = FightCount + 1
          else
            FightCount = 0
          end
          if FightCount >= FIGHT_FRAMES then
            ReleaseHold()
          end
        end
      end

      if Holding then
        if FollowCam then
          FaceCamera(Hrp, GetCameraLook(Camera))
        elseif tick() - TakeoffTick < HoldTime then
          FaceCamera(Hrp, TakeoffLook)
        else
          RestoreAutoRotate()
        end
      end
    elseif AmIInAir then
      if Holding and tick() - TakeoffTick < PRE_JUMP_GRACE then
        if not FollowCam then FaceCamera(Hrp, TakeoffLook) end
      else
        NotAirSince = NotAirSince or tick()
        if tick() - NotAirSince >= LAND_DEBOUNCE then
          AmIInAir = false
          Holding = false
          NotAirSince = nil
          if UsedHold then
            RestoreAutoRotate(OriginalAutoRotate)
            GroundShiftlockSince = (OriginalAutoRotate == 0) and (tick() - 1) or nil
          end
          UsedHold = false
        elseif Holding and not FollowCam and tick() - TakeoffTick < HoldTime then
          FaceCamera(Hrp, TakeoffLook)
        end
      end
    end
  elseif AmIInAir then
    AmIInAir = false
    Holding = false
    UsedHold = false
    NotAirSince = nil
    ChangedAutoRotate = false
  end
end

local CurrentBall = nil
local LastFindTick = 0
local LastBallApplied, LastBallTick = nil, 0
local BallDirty = true
local BallTemplates = nil
local TemplatesDirty = true
local LastTemplateTick = -1e9
local BallsModified = false
local BallSnapshot = nil -- ball settings used by the last template pass

-- keyed by strings, instance handles can be a fresh wrapper on every read
-- model key T:<template> or L:<live name>, part id <name>#<n>
local BallMemory = {}
local TemplateNames = {} -- template name -> true
local SigToKeys = {} -- signature -> template keys
local LiveKeyCache = {} -- live ball name -> model key
local VOL_EPS = 1e-4
local INVISIBLE_T = 0.99 -- at or above = hidden part

-- applied = models fully at target, written = size writes
local function NewStats()
  return { applied = 0, written = 0, parts = 0, models = 0, hitboxParts = 0,
    transparencyWritten = 0, streamproofSkipped = 0, errors = 0, errorCount = 0 }
end

local function AddError(stats, msg)
  stats.errorCount = (stats.errorCount or 0) + 1
  stats.errors = stats.errorCount
  if stats.firstError == nil then stats.firstError = tostring(msg) end
end

local function AddStats(into, from)
  if type(from) ~= "table" then return into end
  for k, v in pairs(from) do
    if type(v) == "number" then into[k] = (into[k] or 0) + v end
  end
  if into.firstError == nil and type(from.firstError) == "string" then into.firstError = from.firstError end
  return into
end

local function FlagBallsDirty()
  BallDirty = true
  TemplatesDirty = true
end

local function IsLiveBallName(name)
  return string.find(tostring(name), BALL_NAME_PATTERN, 1, true) ~= nil
end

local function ReadSize(inst)
  local ok, s = pcall(function() return inst.Size end)
  if ok and typeof(s) == "Vector3" then return s end
  return nil
end

-- unreadable descendants are skipped
local function ScanModel(Model)
  local parts, counts = {}, {}
  for _, d in ipairs(Model:GetDescendants()) do
    local okC, cn = pcall(function() return d.ClassName end)
    if okC and BALL_PART_CLASSES[cn] then
      local okN, raw = pcall(function() return d.Name end)
      local n = okN and tostring(raw) or "unknown"
      local c = (counts[n] or 0) + 1
      counts[n] = c
      parts[#parts + 1] = { inst = d, pid = n .. "#" .. c, name = n, class = cn }
    end
  end
  return parts
end

-- mem offset, Transparency is read-only here
-- offset is checked against the property read before writing
local function WriteTransparency(inst, value)
  local okP, prop = pcall(function() return inst.Transparency end)
  if okP and type(prop) == "number" and math.abs(prop - value) < 1e-4 then
    return true, nil, false
  end
  local okA, addr = pcall(function() return inst.Address end)
  if okA and type(addr) == "number" and addr ~= 0 then
    local okR, cur = pcall(memory_read, "float", addr + O.Transp)
    local offsetOk = okR and type(cur) == "number" and cur == cur
      and (not (okP and type(prop) == "number") or math.abs(cur - prop) < 1e-3)
    if offsetOk then
      local okW = pcall(memory_write, "float", addr + O.Transp, value)
      if okW then return true, nil, true end
    end
  end
  local okF, errF = pcall(function() inst.Transparency = value end)
  if okF then return true, nil, true end
  return false, "transparency write failed (memory offset " .. tostring(O.Transp)
    .. " unusable, property: " .. tostring(errF) .. ")", false
end

-- fingerprint to match a live ball to its template
local function Signature(parts)
  local list = {}
  for i, p in ipairs(parts) do
    local mesh = ""
    if p.class == "MeshPart" then
      local ok, id = pcall(function() return p.inst.MeshId end)
      if ok and type(id) == "string" then mesh = id end
    end
    list[i] = p.pid .. ":" .. p.class .. ":" .. mesh
  end
  table.sort(list)
  return table.concat(list, "|")
end

-- picked once per model: BoundingBox, else an invisible part, else the largest
-- ties go to the lowest part id
local function DecideCollision(mem, parts)
  local best = nil
  for _, p in ipairs(parts) do
    if p.name == BALL_HITBOX_PART and (best == nil or p.pid < best) then best = p.pid end
  end
  if best then
    mem.collision, mem.collisionKind, mem.collisionIsBox = best, "box", true
    return
  end
  local function Largest(onlyInvisible)
    local pick, bestVol = nil, -1
    for _, p in ipairs(parts) do
      local s, t = mem.orig[p.pid], mem.transp[p.pid]
      if s and (not onlyInvisible or (t ~= nil and t >= INVISIBLE_T)) then
        local vol = s.X * s.Y * s.Z
        local tol = VOL_EPS * math.max(1, math.abs(bestVol))
        if pick == nil or vol > bestVol + tol or (math.abs(vol - bestVol) <= tol and p.pid < pick) then
          pick, bestVol = p.pid, vol
        end
      end
    end
    return pick
  end
  best = Largest(true)
  if best then
    mem.collision, mem.collisionKind, mem.collisionIsBox = best, "invisible", false
    return
  end
  best = Largest(false)
  mem.collision, mem.collisionKind, mem.collisionIsBox = best or false, best and "largest" or "none", false
end

local function Remember(key, parts, isTemplate)
  local mem = BallMemory[key]
  local fresh = false
  if not mem then
    mem = { orig = {}, transp = {}, transpTouched = {}, collision = nil, collisionKind = nil,
      collisionIsBox = false }
    BallMemory[key] = mem
    fresh = true
  end
  -- first-seen originals
  for _, p in ipairs(parts) do
    if mem.orig[p.pid] == nil then
      local s = ReadSize(p.inst)
      if s then mem.orig[p.pid] = s end
    end
    if mem.transp[p.pid] == nil then
      local ok, t = pcall(function() return p.inst.Transparency end)
      if ok and type(t) == "number" then mem.transp[p.pid] = t end
    end
  end
  if mem.collision == nil then DecideCollision(mem, parts) end
  if fresh and isTemplate then
    local sig = Signature(parts)
    local list = SigToKeys[sig]
    if not list then
      list = {}
      SigToKeys[sig] = list
    end
    list[#list + 1] = key
    table.sort(list)
  end
  return mem
end

-- live ball -> template key, cached per ball name
local function LiveBallKey(Model, parts)
  local name = tostring(Model.Name)
  local cached = LiveKeyCache[name]
  if cached then return cached end
  local key = nil
  if TemplateNames[name] then
    key = "T:" .. name
  else
    for _, d in ipairs(Model:GetDescendants()) do
      if d.ClassName == "Model" and TemplateNames[tostring(d.Name)] then
        key = "T:" .. tostring(d.Name)
        break
      end
    end
    if not key then
      local list = SigToKeys[Signature(parts)]
      if list and #list > 0 then key = list[1] end
    end
  end
  key = key or ("L:" .. name)
  if next(TemplateNames) ~= nil then LiveKeyCache[name] = key end
  return key
end

local function ModelKey(Model, parts, isTemplate)
  if isTemplate then return "T:" .. tostring(Model.Name) end
  return LiveBallKey(Model, parts)
end

-- 1 written, 0 already there, nil + err on failure
local function SetPartSize(inst, v3)
  local size = ReadSize(inst)
  if not size then return nil, "cannot read Size" end
  if math.abs(size.X - v3.X) > 0.01 or math.abs(size.Y - v3.Y) > 0.01 or math.abs(size.Z - v3.Z) > 0.01 then
    local ok, err = pcall(function() inst.Size = v3 end)
    if not ok then return nil, "Size write failed: " .. tostring(err) end
    return 1
  end
  return 0
end

local function SafeName(inst)
  local ok, n = pcall(function() return inst.Name end)
  return ok and tostring(n) or "unknown"
end

-- hitbox off: original size. visible: every part = hitbox size.
-- streamproof: original size, only the hidden collision part = hitbox size.
-- models with no hidden part get no hitbox in streamproof (streamproofSkipped)
local function SizeModel(Model, isTemplate)
  local stats = NewStats()
  local parts = ScanModel(Model)
  if #parts == 0 then return stats end
  local mem = Remember(ModelKey(Model, parts, isTemplate), parts, isTemplate)
  local label = (isTemplate and "template " or "live ball ") .. SafeName(Model)
  stats.models = 1

  local hs, bt = Settings.hitbox_size, Settings.ball_transparency
  local visibleMode = Settings.hitbox and Settings.hitbox_mode == 0
  local streamproof = Settings.hitbox and Settings.hitbox_mode == 1
  local hitV = Vector3.new(hs, hs, hs)

  local cpid = nil
  if visibleMode then
    cpid = mem.collision or nil
  elseif streamproof then
    if mem.collisionKind == "box" or mem.collisionKind == "invisible" then
      cpid = mem.collision
    else
      stats.streamproofSkipped = 1
    end
  end

  local allAtTarget = true
  for _, p in ipairs(parts) do
    local origT = mem.transp[p.pid]

    local size = visibleMode and hitV or mem.orig[p.pid]
    local transp = nil
    if origT ~= nil then
      local hidden = (BALL_HITBOX_INVISIBLE and p.name == BALL_HITBOX_PART) or origT >= INVISIBLE_T
      transp = hidden and 1 or bt
    end

    if cpid and p.pid == cpid then
      stats.hitboxParts = stats.hitboxParts + 1
      if streamproof then
        size = hitV
        if origT ~= nil then transp = 1 end
      end
    end

    stats.parts = stats.parts + 1
    if size == nil then
      allAtTarget = false
      AddError(stats, label .. " / " .. p.pid .. ": cannot read original Size")
    else
      local r, err = SetPartSize(p.inst, size)
      if r == nil then
        allAtTarget = false
        AddError(stats, label .. " / " .. p.pid .. ": " .. tostring(err))
      else
        stats.written = stats.written + r
      end
    end

    -- unreadable original = leave it alone
    if transp == nil then
      allAtTarget = false
      AddError(stats, label .. " / " .. p.pid .. ": cannot read original Transparency")
    else
      mem.transpTouched[p.pid] = true
      local okT, errT, wrote = WriteTransparency(p.inst, transp)
      if not okT then
        allAtTarget = false
        AddError(stats, label .. " / " .. p.pid .. ": " .. tostring(errT))
      elseif wrote then
        stats.transparencyWritten = stats.transparencyWritten + 1
      end
    end
  end

  if allAtTarget then stats.applied = 1 end
  BallsModified = true
  return stats
end

local function NewRestoreStats()
  return { restored = 0, modelsRestored = 0, models = 0, transparencyRestored = 0,
    streamproofSkipped = 0, errors = 0, errorCount = 0 }
end

local function RestoreModel(Model, isTemplate, stats)
  local parts = ScanModel(Model)
  if #parts == 0 then return end
  local mem = BallMemory[ModelKey(Model, parts, isTemplate)]
  if not mem then return end
  local label = (isTemplate and "template " or "live ball ") .. SafeName(Model)
  stats.models = stats.models + 1
  local allBack = true
  for _, p in ipairs(parts) do
    local orig = mem.orig[p.pid]
    if orig then
      local r, err = SetPartSize(p.inst, orig)
      if r == nil then
        allBack = false
        AddError(stats, label .. " / " .. p.pid .. ": " .. tostring(err))
      else
        stats.restored = stats.restored + r
      end
    end
    local t = mem.transp[p.pid]
    if mem.transpTouched[p.pid] and t ~= nil then
      local okT, errT, wrote = WriteTransparency(p.inst, t)
      if okT then
        if wrote then stats.transparencyRestored = stats.transparencyRestored + 1 end
      else
        allBack = false
        AddError(stats, label .. " / " .. p.pid .. ": " .. tostring(errT))
      end
    end
  end
  if allBack then stats.modelsRestored = stats.modelsRestored + 1 end
end

-- memory is kept, so applying again gives the same result
local function RestoreBalls(force)
  local stats = NewRestoreStats()
  if not BallsModified and not force then return stats end
  BallsModified = false
  if BallTemplates then
    local okL, list = pcall(function() return BallTemplates:GetChildren() end)
    if okL then
      for _, template in ipairs(list) do
        local okC, cn = pcall(function() return template.ClassName end)
        if okC and cn == "Model" then
          local okM, errM = pcall(RestoreModel, template, true, stats)
          if not okM then AddError(stats, "template " .. SafeName(template) .. ": " .. tostring(errM)) end
        end
      end
    else
      AddError(stats, "templates: " .. tostring(list))
    end
  end
  local okW, children = pcall(function() return Workspace:GetChildren() end)
  if okW then
    for _, child in ipairs(children) do
      if IsLiveBallName(SafeName(child)) then
        local okM, errM = pcall(RestoreModel, child, false, stats)
        if not okM then AddError(stats, "live ball " .. SafeName(child) .. ": " .. tostring(errM)) end
      end
    end
  else
    AddError(stats, "workspace: " .. tostring(children))
  end
  LastBallApplied = nil
  FlagBallsDirty()
  return stats
end

local function FindBall()
  LastFindTick = tick()
  CurrentBall = nil
  for _, Child in ipairs(Workspace:GetChildren()) do
    if IsLiveBallName(Child.Name) then
      CurrentBall = Child
      return
    end
  end
end

-- everything a ball pass reads, as one cheap string
local function BallSettingsKey()
  return tostring(Settings.hitbox) .. "|" .. tostring(Settings.hitbox_size) .. "|"
    .. tostring(Settings.hitbox_mode) .. "|" .. tostring(Settings.ball_transparency)
end

-- templates: after a change at most every 0.5 s, otherwise every 5 s
local function ApplyTemplates(force)
  local now = tick()
  local since = now - LastTemplateTick
  if not force and not ((TemplatesDirty and since >= TEMPLATE_DIRTY_INTERVAL) or since >= TEMPLATE_REFRESH_INTERVAL) then
    return nil
  end
  LastTemplateTick = now
  if not BallTemplates then
    local Assets = game:GetService("ReplicatedStorage"):FindFirstChild("Assets")
    BallTemplates = Assets and Assets:FindFirstChild("Ball")
  end
  if not BallTemplates then return nil end -- retried next interval
  TemplatesDirty = false
  BallSnapshot = BallSettingsKey()
  local stats = NewStats()
  local okL, list = pcall(function() return BallTemplates:GetChildren() end)
  if not okL then
    AddError(stats, "templates: " .. tostring(list))
    return stats
  end
  local models = {}
  for _, template in ipairs(list) do
    local okC, cn = pcall(function() return template.ClassName end)
    if okC and cn == "Model" then
      models[#models + 1] = template
      TemplateNames[SafeName(template)] = true
    end
  end
  for _, template in ipairs(models) do
    local ok, s = pcall(SizeModel, template, true)
    if ok then
      AddStats(stats, s)
    else
      AddError(stats, "template " .. SafeName(template) .. ": " .. tostring(s))
    end
  end
  return stats
end

-- live ball: new ball right away, otherwise throttled
local function ApplyBall(force)
  local stats = NewStats()
  if not Running then
    stats.active = false
    return stats
  end
  stats.active = true
  AddStats(stats, ApplyTemplates(force))
  local ball = CurrentBall
  if not ball then return stats end
  local now = tick()
  local since = now - LastBallTick
  if force or ball ~= LastBallApplied or since >= BALL_REAPPLY_INTERVAL
    or (BallDirty and since >= BALL_DIRTY_INTERVAL) then
    LastBallApplied = ball
    LastBallTick = now
    BallDirty = false
    local ok, s = pcall(SizeModel, ball, false)
    if ok then
      AddStats(stats, s)
      stats.liveBall = SafeName(ball)
    else
      AddError(stats, "live ball " .. SafeName(ball) .. ": " .. tostring(s))
    end
  end
  return stats
end

local function RequestBallApply()
  FlagBallsDirty()
  pcall(ApplyBall, false)
end

-- for tests
local function BallInfo()
  local out = {}
  for key, mem in pairs(BallMemory) do
    out[key] = { collision = mem.collision, kind = mem.collisionKind, isBoundingBox = mem.collisionIsBox }
  end
  return out
end

local function BallLoopStep()
  if not CurrentBall or CurrentBall.Parent ~= Workspace then
    CurrentBall = nil
    if tick() - LastFindTick >= 0.1 then pcall(FindBall) end
  end
  pcall(ApplyBall, false)
end

local EyeLines = {}

local function SafePosition(Inst)
  local ok, pos = pcall(function() return Inst.Position end)
  if ok and typeof(pos) == "Vector3" and pos.X == pos.X and pos.Y == pos.Y and pos.Z == pos.Z then
    return pos
  end
  return nil
end

local function GetCamData(Camera)
  local CamPos = Camera.Position
  if typeof(CamPos) ~= "Vector3" then return nil end
  local b = Camera.Address + O.CamRot
  local vp = Camera.ViewportSize
  return {
    pos = CamPos,
    rx = memory_read("float", b),
    ry = memory_read("float", b + 12), rz = memory_read("float", b + 24),
    ux = memory_read("float", b + 4), uy = memory_read("float", b + 16), uz = memory_read("float", b + 28),
    bx = memory_read("float", b + 8), by = memory_read("float", b + 20), bz = memory_read("float", b + 32),
    w = vp.X,
    h = vp.Y,
    focal = (vp.Y / 2) / math.tan(math.rad(Camera.FieldOfView) / 2),
  }
end

local function CamSpace(C, P)
  local rel = P - C.pos
  return rel.X * C.rx + rel.Y * C.ry + rel.Z * C.rz,
         rel.X * C.ux + rel.Y * C.uy + rel.Z * C.uz,
         -(rel.X * C.bx + rel.Y * C.by + rel.Z * C.bz)
end

local function ClampCoord(v)
  if v > 20000 then return 20000 end
  if v < -20000 then return -20000 end
  return v
end

local function ToScreen(C, x, y, d)
  return ClampCoord(C.w / 2 + x / d * C.focal), ClampCoord(C.h / 2 - y / d * C.focal)
end

local function ProjectSegment(C, A, B)
  local x1, y1, d1 = CamSpace(C, A)
  local x2, y2, d2 = CamSpace(C, B)
  local near = 0.1
  if d1 < near and d2 < near then return nil end
  if d1 < near then
    local t = (near - d1) / (d2 - d1)
    x1 = x1 + (x2 - x1) * t
    y1 = y1 + (y2 - y1) * t
    d1 = near
  elseif d2 < near then
    local t = (near - d2) / (d1 - d2)
    x2 = x2 + (x1 - x2) * t
    y2 = y2 + (y1 - y2) * t
    d2 = near
  end
  local sx1, sy1 = ToScreen(C, x1, y1, d1)
  local sx2, sy2 = ToScreen(C, x2, y2, d2)
  return sx1, sy1, sx2, sy2
end

local function GetLook(Part)
  local Prim = memory_read("uintptr_t", Part.Address + O.Primitive)
  if not Prim or Prim == 0 then return nil end
  local R = Prim + O.PrimRot
  local lx = -memory_read("float", R + 8)
  local ly = -memory_read("float", R + 20)
  local lz = -memory_read("float", R + 32)
  local m = math.sqrt(lx * lx + ly * ly + lz * lz)
  if m ~= m or m < 0.5 or m > 1.5 then return nil end
  return Vector3.new(lx / m, ly / m, lz / m)
end

local function IsEnemy(Player)
  if not Settings.eye_enemies_only then return true end
  local ok, same = pcall(function()
    local mine, theirs = LocalPlayer.Team, Player.Team
    return mine ~= nil and theirs ~= nil and mine == theirs
  end)
  return not (ok and same)
end

-- keyed by userid, not the player handle
local function PlayerKey(Player)
  local ok, id = pcall(function() return Player.UserId end)
  if ok and id ~= nil then return "U" .. tostring(id) end
  return "N" .. tostring(Player.Name)
end

local function GetEyeLine(key)
  local line = EyeLines[key]
  if not line then
    line = Drawing.new("Line")
    line.Transparency = 1
    line.ZIndex = 2
    line.Visible = false
    EyeLines[key] = line
  end
  return line
end

local function HideEyeLines()
  for _, line in pairs(EyeLines) do line.Visible = false end
end

local function RemoveAllEyeLines()
  for key, line in pairs(EyeLines) do
    pcall(function() line.Visible = false end)
    pcall(function() line:Remove() end)
    EyeLines[key] = nil
  end
end

local function EyeLinesStep()
  if not Running then return end
  if not Settings.eye_lines then
    HideEyeLines()
    return
  end
  local Camera = Workspace.CurrentCamera
  if not Camera then HideEyeLines() return end
  local C = GetCamData(Camera)
  if not C then HideEyeLines() return end

  local c = Settings.eye_color
  local color = Color3.fromRGB(c[1], c[2], c[3])
  local length = Settings.eye_length
  local maxDist = Settings.eye_max_distance
  local thickness = Settings.eye_thickness

  local seen, present = {}, {}
  for _, Player in ipairs(Players:GetPlayers()) do
    local pkey = PlayerKey(Player)
    present[pkey] = true
    if Player ~= LocalPlayer and IsEnemy(Player) then
      local Char = Player.Character
      local Head = Char and Char:FindFirstChild("Head")
      local Root = Char and Char:FindFirstChild("HumanoidRootPart")
      local Hum = Char and Char:FindFirstChild("Humanoid")
      if Head and Root and not (Hum and Hum.Health <= 0) then
        local HeadPos = SafePosition(Head)
        local Look = GetLook(Root)
        if HeadPos and Look and (HeadPos - C.pos).Magnitude <= maxDist then
          local x1, y1, x2, y2 = ProjectSegment(C, HeadPos, HeadPos + Look * length)
          if x1 then
            local line = GetEyeLine(pkey)
            line.From = Vector2.new(x1, y1)
            line.To = Vector2.new(x2, y2)
            line.Color = color
            line.Thickness = thickness
            line.Visible = true
            seen[pkey] = true
          end
        end
      end
    end
  end

  for key, line in pairs(EyeLines) do
    if not present[key] then
      pcall(function() line:Remove() end)
      EyeLines[key] = nil
    elseif not seen[key] then
      line.Visible = false
    end
  end
end

local LightingInst = nil
pcall(function() LightingInst = game:GetService("Lighting") end)

local DarkOrig = nil
local DarkOk = false

local function WriteColor(addr, c)
  memory_write("float", addr, c[1])
  memory_write("float", addr + 4, c[2])
  memory_write("float", addr + 8, c[3])
end

local function ReadColor(addr)
  return { memory_read("float", addr), memory_read("float", addr + 4), memory_read("float", addr + 8) }
end

local function RestoreDark()
  if not (LightingInst and DarkOrig) then return false end
  local a = LightingInst.Address
  memory_write("float", a + O.LBright, DarkOrig.b)
  memory_write("float", a + O.LExposure, DarkOrig.e)
  WriteColor(a + O.LAmbient, DarkOrig.am)
  WriteColor(a + O.LOutdoor, DarkOrig.oa)
  DarkOrig = nil
  return true
end

local function ApplyDark()
  if not LightingInst then return end
  local want = Running and Settings.dark_graphics

  if not want then
    RestoreDark()
    return
  end
  local a = LightingInst.Address

  if not DarkOk then
    local b = memory_read("float", a + O.LBright)
    DarkOk = (b == b and b >= 0 and b <= 50)
    if not DarkOk then return end
  end

  if not DarkOrig then
    DarkOrig = {
      b = memory_read("float", a + O.LBright),
      e = memory_read("float", a + O.LExposure),
      am = ReadColor(a + O.LAmbient),
      oa = ReadColor(a + O.LOutdoor),
    }
  end

  memory_write("float", a + O.LBright, Settings.dark_brightness)
  memory_write("float", a + O.LExposure, Settings.dark_exposure)
  WriteColor(a + O.LAmbient, DARK_AMBIENT)
  WriteColor(a + O.LOutdoor, DARK_OUTDOOR_AMBIENT)
end

local Loading = false -- no notifications while true
local UIRegistry = {} -- setting keys that have a widget
local built = false
local NotifyKeys = {
  hitbox = "Hitbox",
  eye_lines = "Eye Lines",
  dark_graphics = "Dark Graphics",
  jump_assist = "Jump Assist",
}
local LastNotify = {}
local function OnChanged(key, value)
  if key == "hitbox" or key == "hitbox_size" or key == "hitbox_mode"
    or key == "ball_transparency" then
    RequestBallApply()
  end
end

local function Set(key, raw)
  if not Running then return end -- late widget callbacks after stop
  local v = Coerce(key, raw)
  if v == nil then return end
  if Settings[key] == v then return end
  Settings[key] = v
  MarkDirty()
  pcall(OnChanged, key, v)

  local label = NotifyKeys[key]
  if label and not Loading and type(v) == "boolean" then
    local now = tick()
    if not LastNotify[key] or now - LastNotify[key] > 0.75 then
      LastNotify[key] = now
      Notify(label .. (v and " ON" or " OFF"), nil, 2)
    end
  end
end

local function ColorSetter(key)
  return function(...)
    local a = { ... }
    local r, g, b
    if type(a[1]) == "table" then
      local t = a[1]
      r, g, b = t.r or t.R or t[1], t.g or t.G or t[2], t.b or t.B or t[3]
    elseif typeof(a[1]) == "Color3" then
      r, g, b = a[1].R * 255, a[1].G * 255, a[1].B * 255
    else
      r, g, b = a[1], a[2], a[3]
    end
    r, g, b = tonumber(r), tonumber(g), tonumber(b)
    if not (r and g and b) then return end
    -- 0..1 pickers too (a 0..255 colour that low is black either way)
    if r <= 1 and g <= 1 and b <= 1 then
      r, g, b = r * 255, g * 255, b * 255
    end
    local c = CleanColor({ r, g, b })
    local old = Settings[key]
    if c and (c[1] ~= old[1] or c[2] ~= old[2] or c[3] ~= old[3]) then
      Settings[key] = c
      MarkDirty()
    end
  end
end

local function PushSettingsToUI()
  if not built then return end
  Loading = true
  for _, key in ipairs(UIRegistry) do
    pcall(UI.SetValue, key, Settings[key])
  end
  Loading = false
end

local function BallAction(fn, ...)
  local ok, stats = pcall(fn, ...)
  if ok and type(stats) == "table" then return stats end
  local stats2 = NewStats()
  AddError(stats2, (not ok) and tostring(stats) or "no stats returned")
  return stats2
end

local function ReapplySettings()
  FlagBallsDirty()
  pcall(FindBall)
  local stats = BallAction(ApplyBall, true)
  pcall(ApplyDark)
  PushSettingsToUI()
  return stats
end

local function ApplyBallSizeNow()
  FlagBallsDirty()
  pcall(FindBall)
  local stats = BallAction(ApplyBall, true)
  Notify("Ball settings applied", nil, 2)
  return stats
end

-- restore first, then force-apply the defaults (no throttle)
local function ResetToDefaults()
  Loading = true
  ResetSettingsTable(false) -- picker can't be set from code
  pcall(RestoreBalls, true)
  pcall(RestoreDark)
  FlagBallsDirty()
  pcall(FindBall)
  local stats = BallAction(ApplyBall, true)
  pcall(ApplyDark)
  MarkDirty()
  PushSettingsToUI()
  SaveSettings()
  Loading = false
  Notify("Settings reset to defaults", nil, 3)
  return true, stats
end

-- profiles live in vbl_profiles/<name>.json
-- the buttons and _G.VBL_HELPER call the same functions
local Profiles = { dir = "vbl_profiles", name = "default" }
pcall(makefolder, Profiles.dir)

Profiles.Sanitize = function(raw)
  local s = (string.gsub(tostring(raw or ""), "[^%w%-_]", ""))
  s = string.sub(s, 1, 32)
  if s == "" then return nil end
  return s
end

Profiles.Resolve = function(nameArg)
  local name = Profiles.Sanitize(nameArg ~= nil and nameArg or Profiles.name)
  if not name then
    local msg = "Enter a profile name (letters, digits, - or _)"
    Notify(msg, "Profiles", 3)
    return nil, msg
  end
  return name
end

Profiles.Path = function(name)
  return Profiles.dir .. "/" .. name .. ".json"
end

-- the menu list line uses this too
Profiles.List = function()
  local names = {}
  local ok, files = pcall(listfiles, Profiles.dir)
  if ok and type(files) == "table" then
    for _, f in ipairs(files) do
      local n = string.match(tostring(f), "([^/\\]+)%.json$")
      if n then names[#names + 1] = n end
    end
  end
  table.sort(names)
  return names
end

Profiles.ListText = function()
  local names = Profiles.List()
  if #names == 0 then return "none yet" end
  return table.concat(names, ", ")
end

Profiles.Save = function(nameArg)
  local name, err = Profiles.Resolve(nameArg)
  if not name then return nil, err end
  pcall(makefolder, Profiles.dir)
  local json = EncodeSettings()
  if not json then
    local msg = "Could not encode the settings"
    Notify(msg, "Profiles", 3)
    return nil, msg
  end
  local ok, werr = pcall(writefile, Profiles.Path(name), json)
  if not ok then
    local msg = "Could not save profile '" .. name .. "': " .. tostring(werr)
    Notify(msg, "Profiles", 3)
    return nil, msg
  end
  Notify("Saved '" .. name .. "'. Profiles: " .. Profiles.ListText(), "Profiles", 3)
  return true
end

Profiles.Load = function(nameArg)
  local name, err = Profiles.Resolve(nameArg)
  if not name then return nil, err end
  local path = Profiles.Path(name)
  local okE, exists = pcall(isfile, path)
  if not (okE and exists) then
    local msg = "Profile '" .. name .. "' not found. Profiles: " .. Profiles.ListText()
    Notify(msg, "Profiles", 3)
    return nil, msg
  end
  local okR, raw = pcall(readfile, path)
  local okD, data = false, nil
  if okR and type(raw) == "string" then
    okD, data = pcall(function() return HttpService:JSONDecode(raw) end)
  end
  if not (okD and type(data) == "table") then
    local msg = "Profile '" .. name .. "' is damaged and was not loaded"
    Notify(msg, "Profiles", 3)
    return nil, msg
  end
  Loading = true
  ApplySettingsData(data) -- same validation as the save file
  MarkDirty() -- main save follows the profile
  pcall(ReapplySettings)
  Loading = false
  Notify("Loaded profile '" .. name .. "'", "Profiles", 3)
  return true
end

Profiles.Delete = function(nameArg)
  local name, err = Profiles.Resolve(nameArg)
  if not name then return nil, err end
  local path = Profiles.Path(name)
  local okE, exists = pcall(isfile, path)
  if not (okE and exists) then
    local msg = "Profile '" .. name .. "' does not exist"
    Notify(msg, "Profiles", 3)
    return nil, msg
  end
  local ok, derr = pcall(delfile, path)
  if not ok then
    local msg = "Could not delete profile '" .. name .. "': " .. tostring(derr)
    Notify(msg, "Profiles", 3)
    return nil, msg
  end
  Notify("Deleted '" .. name .. "'. Profiles: " .. Profiles.ListText(), "Profiles", 3)
  return true
end

local framesAfterBuild = 0

local function BoolCb(key)
  return function(v)
    if type(v) ~= "boolean" and type(v) ~= "number" then
      local ok, g = pcall(UI.GetValue, key)
      if ok then v = g end
    end
    Set(key, v)
  end
end

local function NumCb(key)
  return function(v) Set(key, v) end
end

local function AddToggle(sec, key, label)
  UIRegistry[#UIRegistry + 1] = key
  sec:Toggle(key, label, Settings[key], BoolCb(key))
end

local function AddSliderInt(sec, key, label)
  local s = SchemaByKey[key]
  UIRegistry[#UIRegistry + 1] = key
  sec:SliderInt(key, label, s.min, s.max, math.floor(Settings[key] + 0.5), NumCb(key))
end

local function AddSliderFloat(sec, key, label, fmt)
  local s = SchemaByKey[key]
  UIRegistry[#UIRegistry + 1] = key
  sec:SliderFloat(key, label, s.min, s.max, Settings[key], fmt or "%.1f", NumCb(key))
end

local function BuildTab(tab)
  local info = tab:Section("Info", "Left")
  info:Text(CREDIT)
  info:Tip("Everything saves automatically.")

  local ball = tab:Section("Ball", "Left")
  AddToggle(ball, "hitbox", "Hitbox")
  AddSliderFloat(ball, "hitbox_size", "Hitbox Size", "%.1f")
  local hitboxModes = { "Visible", "Streamproof" }
  UIRegistry[#UIRegistry + 1] = "hitbox_mode"
  ball:Combo("hitbox_mode", "Hitbox Mode", hitboxModes, Settings.hitbox_mode, function(index, text)
    local n = tonumber(index) -- 0-based
    if n == nil and type(text) == "string" then
      for i, name in ipairs(hitboxModes) do
        if name == text then n = i - 1 end
      end
    end
    Set("hitbox_mode", n)
  end)
  AddSliderFloat(ball, "ball_transparency", "Ball Transparency", "%.2f")
  ball:Tip("Visible: ball grows to the hitbox size. Streamproof: ball stays normal size, hitbox is bigger.")

  local jump = tab:Section("Jump Assist", "Left")
  AddToggle(jump, "jump_assist", "Jump Assist")
  AddToggle(jump, "pre_jump", "Pre Jump")
  AddToggle(jump, "face_on_press", "Face Camera On Press")
  AddToggle(jump, "follow_camera_in_air", "Hold Facing After Jump (Follow Camera In Air)")
  AddSliderInt(jump, "hold_duration", "Hold Duration (seconds)")
  AddToggle(jump, "abort_when_fought", "Abort When Fought")
  AddToggle(jump, "ignore_non_jump_air", "Ignore Non-Jump Air")

  local vis = tab:Section("Visuals", "Right")
  AddToggle(vis, "eye_lines", "Eye Lines")
  vis:ColorPicker("eye_color", Settings.eye_color[1], Settings.eye_color[2], Settings.eye_color[3], 255, ColorSetter("eye_color"))
  AddSliderInt(vis, "eye_length", "Eye Line Length")
  AddSliderInt(vis, "eye_thickness", "Eye Line Thickness")
  AddSliderInt(vis, "eye_max_distance", "Eye Line Max Distance")
  AddToggle(vis, "eye_enemies_only", "Enemies Only")
  vis:Spacing()
  AddToggle(vis, "dark_graphics", "Dark Graphics")
  AddSliderFloat(vis, "dark_brightness", "Dark Brightness", "%.2f")
  AddSliderFloat(vis, "dark_exposure", "Dark Exposure", "%.2f")

  local prof = tab:Section("Profiles", "Right")
  prof:InputText("profile_name", "Profile Name", Profiles.name, function(v)
    if type(v) == "string" then Profiles.name = v end
  end)
  prof:Button("Save Profile", function() pcall(Profiles.Save) end)
  prof:Button("Load Profile", function() pcall(Profiles.Load) end)
  prof:Button("Delete Profile", function() pcall(Profiles.Delete) end)
  prof:Text("Saved profiles: " .. Profiles.ListText())
  prof:Tip("Everything saves automatically. Profiles are extra snapshots you can switch between.")

  local cfg = tab:Section("Settings", "Right")
  cfg:Button("Reset To Defaults", function() pcall(ResetToDefaults) end)
  cfg:Tip("Everything saves automatically.")
end

local TAB_NAME = "VBL"

DebugHandle.uiBuilt = function() return built == true end
pcall(function() _G.VBL_HELPER = DebugHandle end)

local tabFrames = 0
local pushAttempts = 0
local pushFinished = false

-- a re-run replaces the old tab
pcall(function() UI.RemoveTab(TAB_NAME) end)

pcall(function()
  UI.AddTab(TAB_NAME, function(tab)
    if not Running then return end
    tabFrames = tabFrames + 1
    if not built then
      built = true
      local ok, err = pcall(BuildTab, tab)
      DebugHandle.buildOk = ok
      DebugHandle.buildError = (not ok) and tostring(err) or nil
      if not ok then Notify("Menu build error: " .. tostring(err), nil, 6) end
      return
    end
    -- push saved values 2 frames after build, retry once
    if not pushFinished then
      if framesAfterBuild < 2 then framesAfterBuild = framesAfterBuild + 1 end
      if framesAfterBuild >= 2 then
        pushAttempts = pushAttempts + 1
        local ok, err = pcall(PushSettingsToUI)
        if ok then
          pushFinished = true
          DebugHandle.settingsPushed = true
          DebugHandle.settingsPushedFrame = tabFrames
          DebugHandle.pushError = nil
        else
          Loading = false -- don't stay muted after a failed push
          if pushAttempts >= 2 then
            pushFinished = true
            DebugHandle.pushError = tostring(err)
          end
        end
      end
    end
  end)
end)

local function Safe(fn) pcall(fn) end

-- full teardown, the next run calls this
local function Stop()
  if not Running then return false end
  Running = false
  DebugHandle.running = false
  for _, c in ipairs(Connections) do
    pcall(function() c:Disconnect() end)
  end
  Connections = {}
  DebugHandle.connections = 0
  if Dirty then pcall(SaveSettings) end -- next run loads these
  pcall(ResetAssist)
  pcall(RemoveAllEyeLines)
  pcall(RestoreDark)
  pcall(RestoreBalls, true)
  pcall(function() UI.RemoveTab(TAB_NAME) end)
  return true
end
DebugHandle.stop = Stop

local function Track(conn)
  if conn ~= nil then Connections[#Connections + 1] = conn end
  DebugHandle.connections = #Connections
end

pcall(function()
  Track(RunService.RenderStepped:Connect(function()
    if not Running then return end
    Safe(CharacterStep)
    Safe(EyeLinesStep)
    Safe(ApplyHold)
  end))
end)
pcall(function()
  Track(RunService.Stepped:Connect(function()
    if not Running then return end
    Safe(ApplyHold)
  end))
end)
pcall(function()
  Track(RunService.Heartbeat:Connect(function()
    if not Running then return end
    Safe(ApplyHold)
    Safe(EyeLinesStep)
  end))
end)

task.spawn(function() -- ball loop
  while Running do
    task.wait(0.1)
    if not Running then break end
    pcall(BallLoopStep)
  end
end)

task.spawn(function() -- dark graphics loop
  while Running do
    task.wait(0.25)
    if not Running then break end
    pcall(ApplyDark)
  end
end)

task.spawn(function() -- autosave + deferred offset swap
  while Running do
    task.wait(0.5)
    if not Running then break end

    if Dirty and tick() - DirtyTick > 0.6 then pcall(SaveSettings) end

    if PendingOffsets and not DarkOrig and not Holding and not AmIInAir and not ChangedAutoRotate then
      O = PendingOffsets
      PendingOffsets = nil
    end
  end
end)

task.spawn(function() -- settings watcher, catches changes that skipped Set or a lagging widget
  local uiLast = {}
  while Running do
    task.wait(0.25)
    if not Running then break end
    pcall(function()
      -- widget -> settings, only when a widget value actually moved
      if built then
        for _, key in ipairs(UIRegistry) do
          if key ~= "hitbox_mode" then -- combo has its own index callback
            local ok, g = pcall(UI.GetValue, key)
            if ok and g ~= nil then
              if uiLast[key] ~= nil and g ~= uiLast[key] then Set(key, g) end
              uiLast[key] = g
            end
          end
        end
      end
      -- settings -> ball, only if they differ from the last template pass
      if not TemplatesDirty and BallSettingsKey() ~= BallSnapshot then
        FlagBallsDirty()
      end
    end)
  end
end)

task.spawn(function() -- f1 fallback, tab may not be built yet
  local wasDown = false
  while Running do
    task.wait(0.03)
    if not Running then break end
    pcall(function()
      local down = isrbxactive() and iskeypressed(F1_KEY)
      if down and not wasDown then
        Set("hitbox", not Settings.hitbox)
        FlagBallsDirty()
        pcall(ApplyBall, true)
        if built then pcall(UI.SetValue, "hitbox", Settings.hitbox) end
      end
      wasDown = down
    end)
  end
end)

task.spawn(function() -- refresh offsets in the background
  for attempt = 1, 3 do
    for _, url in ipairs(OFFSET_URLS) do
      if not Running then return end
      local ok, body = pcall(httpget, url)
      if not Running then return end
      local dump = ok and DecodeDump(body) or nil
      if dump then
        pcall(writefile, OFFSETS_CACHE, HttpService:JSONEncode({ Offsets = dump }))
        local fresh = BuildOffsets(dump)
        if not SameOffsets(fresh, O) then PendingOffsets = fresh end
        return
      end
    end
    task.wait(1)
  end
end)


pcall(FindBall)
FlagBallsDirty()
pcall(ApplyBall, true)

local startMsg = "Loaded. Menu tab: " .. TAB_NAME .. ". F1 = Hitbox on/off."
Notify(startMsg, CREDIT, 5)

pcall(function()
  -- errors come back as nil, err
  local function Wrap(fn)
    return function(...)
      if type(fn) ~= "function" then return nil, "not available" end
      local r = table.pack(pcall(fn, ...))
      if r[1] then return table.unpack(r, 2, r.n) end
      return nil, r[2]
    end
  end
  DebugHandle.applyBalls = Wrap(ApplyBallSizeNow)
  DebugHandle.reapply = Wrap(ReapplySettings)
  DebugHandle.save = Wrap(SaveSettings)
  DebugHandle.load = Wrap(function()
    local ok = LoadSettings()
    if ok then ReapplySettings() end
    return ok
  end)
  DebugHandle.reset = Wrap(ResetToDefaults)
  DebugHandle.restoreBalls = Wrap(function() return RestoreBalls(true) end)
  DebugHandle.ballInfo = Wrap(BallInfo)
  DebugHandle.hitboxMode = function() -- mode, name, hitbox on
    local n = Settings.hitbox_mode
    local names = { [0] = "Visible", [1] = "Streamproof" }
    return n, names[n], Settings.hitbox == true
  end
  DebugHandle.profiles = Wrap(Profiles.List)
  -- same functions the profile buttons call
  DebugHandle.saveProfile = Wrap(Profiles.Save)
  DebugHandle.loadProfile = Wrap(Profiles.Load)
  DebugHandle.deleteProfile = Wrap(Profiles.Delete)
  DebugHandle.listProfiles = Wrap(Profiles.List)
  _G.VBL_HELPER = DebugHandle
end)
