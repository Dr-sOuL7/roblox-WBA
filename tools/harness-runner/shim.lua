--[=[
	shim.lua — minimal Roblox API shim for running the server simulation headless
	under the standalone Luau CLI (CI / local validation, never ships in the game).

	Provides exactly what the headless module chain touches:
	  Constants, MatchState, TickManager, CollisionClassifier, PhysicsController,
	  BeyController, SpinEvaluator, SimulationHarness

	Fidelity caveats (documented in README.md):
	  * Random is a xorshift32 PRNG, not Roblox's Random — batches are reproducible
	    within this runner but not numerically identical to a Studio run.
	  * Vector3 components are doubles here; Roblox stores float32. Distribution
	    statistics are valid; bit-exact parity with Studio is not the goal.
]=]

local warn = function(...)
	print("[WARN]", ...)
end

-- ── Vector3 ───────────────────────────────────────────────────────────────────

local Vector3 = {}
do
	local mt
	local function new(x, y, z)
		return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, mt)
	end

	local methods = {}
	function methods.Dot(a, b)
		return a.X * b.X + a.Y * b.Y + a.Z * b.Z
	end
	function methods.Lerp(a, b, alpha)
		return new(
			a.X + (b.X - a.X) * alpha,
			a.Y + (b.Y - a.Y) * alpha,
			a.Z + (b.Z - a.Z) * alpha
		)
	end
	function methods.Cross(a, b)
		return new(
			a.Y * b.Z - a.Z * b.Y,
			a.Z * b.X - a.X * b.Z,
			a.X * b.Y - a.Y * b.X
		)
	end

	mt = {
		__index = function(v, k)
			if k == "Magnitude" then
				return math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z)
			elseif k == "Unit" then
				local m = math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z)
				return new(v.X / m, v.Y / m, v.Z / m) -- zero vector → NaN components, same as Roblox
			end
			return methods[k]
		end,
		__add = function(a, b)
			return new(a.X + b.X, a.Y + b.Y, a.Z + b.Z)
		end,
		__sub = function(a, b)
			return new(a.X - b.X, a.Y - b.Y, a.Z - b.Z)
		end,
		__mul = function(a, b)
			if type(a) == "number" then
				return new(a * b.X, a * b.Y, a * b.Z)
			elseif type(b) == "number" then
				return new(a.X * b, a.Y * b, a.Z * b)
			end
			return new(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
		end,
		__div = function(a, b)
			if type(b) == "number" then
				return new(a.X / b, a.Y / b, a.Z / b)
			end
			return new(a.X / b.X, a.Y / b.Y, a.Z / b.Z)
		end,
		__unm = function(a)
			return new(-a.X, -a.Y, -a.Z)
		end,
		-- NaN components make v == v false, matching Roblox's NaN-guard idiom
		__eq = function(a, b)
			return a.X == b.X and a.Y == b.Y and a.Z == b.Z
		end,
		__tostring = function(v)
			return string.format("%g, %g, %g", v.X, v.Y, v.Z)
		end,
	}

	Vector3.new = new
	Vector3.zero = new(0, 0, 0)
	Vector3.one = new(1, 1, 1)
end

-- ── Random (xorshift32) ───────────────────────────────────────────────────────

local Random = {}
do
	local RandomImpl = {}
	RandomImpl.__index = RandomImpl

	local function nextU32(self)
		local x = self._state
		x = bit32.bxor(x, bit32.lshift(x, 13))
		x = bit32.bxor(x, bit32.rshift(x, 17))
		x = bit32.bxor(x, bit32.lshift(x, 5))
		self._state = x
		return x
	end

	function RandomImpl.NextNumber(self, min, max)
		local r = nextU32(self) / 4294967296
		if min == nil then
			return r
		end
		return min + r * (max - min)
	end

	function RandomImpl.NextInteger(self, min, max)
		return min + nextU32(self) % (max - min + 1)
	end

	function Random.new(seed)
		seed = math.floor(seed or os.clock() * 1e6) % 4294967296
		local state = bit32.bxor(seed, 0x9E3779B9)
		if state == 0 then
			state = 0x6C078965
		end
		local self = setmetatable({ _state = state }, RandomImpl)
		-- Warm-up rounds decorrelate sequential seeds
		for _ = 1, 4 do
			nextU32(self)
		end
		return self
	end
end

-- ── workspace / task / services ──────────────────────────────────────────────

local workspace = {
	GetServerTimeNow = function(_self)
		return os.clock()
	end,
	FindFirstChild = function(_self, _name)
		return nil
	end,
}

local task = {
	wait = function(_t) end,
	spawn = function(fn, ...)
		fn(...)
	end,
	delay = function(_t, fn, ...)
		fn(...)
	end,
}

-- ── Module registry: tokens stand in for Instances, require() resolves them ──

local __defs = {}   -- "Folder/Path/Name" -> loader function(script) -> module value
local __cache = {}
local __tokens = {}
local __folders = {}

-- Folder proxies resolve children as either modules (tokens) or sub-folders,
-- so nested paths like ServerScriptService/Persistence/ProfileLogic work.
local function getFolder(folderPath)
	if not __folders[folderPath] then
		__folders[folderPath] = {
			__folderPath = folderPath,
			WaitForChild = function(_self, childName, _timeout)
				local childKey = folderPath .. "/" .. childName
				if __tokens[childKey] then
					return __tokens[childKey]
				end
				if __folders[childKey] then
					return __folders[childKey]
				end
				error("Shim: no module or folder registered for " .. childKey)
			end,
			FindFirstChild = function(_self, childName)
				local childKey = folderPath .. "/" .. childName
				return __tokens[childKey] or __folders[childKey]
			end,
		}
		-- Materialize ancestors and give this folder a Parent
		local parentPath = string.match(folderPath, "^(.*)/")
		if parentPath then
			__folders[folderPath].Parent = getFolder(parentPath)
		end
	end
	return __folders[folderPath]
end

local function folderOf(key)
	return string.match(key, "^(.*)/")
end

local function __registerToken(key)
	getFolder(folderOf(key)) -- ensure the folder chain exists
	__tokens[key] = { __key = key, Parent = getFolder(folderOf(key)) }
end

local function require(token)
	local key = type(token) == "table" and token.__key or nil
	if not key then
		error("Shim require(): expected a module token, got " .. tostring(token))
	end
	if __cache[key] == nil then
		local loader = __defs[key] or error("Shim: module not registered: " .. key)
		local scriptObj = { Parent = getFolder(folderOf(key)) }
		__cache[key] = loader(scriptObj)
	end
	return __cache[key]
end

local __services = {
	ReplicatedStorage = getFolder("ReplicatedStorage"),
	RunService = {
		IsServer = function(_self)
			return true
		end,
		IsStudio = function(_self)
			return false
		end,
		Heartbeat = {
			Connect = function(_self, _fn)
				return { Disconnect = function() end }
			end,
		},
	},
}

local game = {
	GetService = function(_self, name)
		return __services[name] or error("Shim: no service " .. name)
	end,
}

-- Keep linters quiet about intentionally unused shim globals
local _ = { warn, Vector3, Random, workspace, task, game, require, __defs, __registerToken }
