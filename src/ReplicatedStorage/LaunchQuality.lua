--[=[
	LaunchQuality.lua
	Shared, PURE launch math: spherical aim → velocity vector, aim clamping,
	and GO-moment timing grades. The client renders previews with it and the
	server grades/builds with it, off the same synced clock — preview and
	verdict cannot drift.

	Launch ceremony (director's design):
	  Setup (sliders: height / theta / phi) → READY (both players) →
	  3·2·1·GO–SHOOT! → click LAUNCH at the GO instant.
	  Grading = |click − GO|: Perfect ≤ 0.12 s, Good ≤ 0.30 s, else Poor.
	  Tiers scale launch speed AND spin, hard-capped by LaunchBonusCap.

	The client submits ONLY (height, theta, phi, claimedTime) — never a raw
	vector. The server clamps every number and constructs the velocity itself.

	Headless-tested by tools/harness-runner (persistence mode test group).
]=]

local Constants = require(script.Parent:WaitForChild("Constants"))

local LaunchQuality = {}

-- ── GO-moment grading ─────────────────────────────────────────────────────────

-- Grade a press at `serverTime` against the GO instant (countdown end).
function LaunchQuality.gradeAtGo(serverTime: number, goTime: number): string
	local delta = math.abs(serverTime - goTime)
	if delta <= Constants.LaunchPerfectWindow then
		return "Perfect"
	elseif delta <= Constants.LaunchGoodWindow then
		return "Good"
	end
	return "Poor"
end

LaunchQuality.BONUS = {
	Perfect = Constants.LaunchBonusPerfect,
	Good = Constants.LaunchBonusGood,
	Poor = Constants.LaunchBonusPoor,
}

-- Multiplier applied to launch speed AND spin. Clamped to LaunchBonusCap as a
-- hard invariant — no quality tier may ever exceed the cap, whatever the
-- Constants say.
function LaunchQuality.multiplierFor(quality: string): number
	local bonus = LaunchQuality.BONUS[quality] or 0
	bonus = math.clamp(bonus, -Constants.LaunchBonusCap, Constants.LaunchBonusCap)
	return 1 + bonus
end

-- ── Spherical aim ─────────────────────────────────────────────────────────────
-- height: release height in studs (Bey teleports to this Y at launch)
-- theta:  elevation from vertical, degrees. 90 = flat horizontal launch,
--         smaller = steeper downward plunge (less horizontal carry).
-- phi:    azimuth, degrees, world XZ. 0 = +X, 90 = +Z (counter-clockwise).

function LaunchQuality.clampAim(aim)
	aim = type(aim) == "table" and aim or {}
	return {
		height = math.clamp(tonumber(aim.height) or Constants.LaunchHeightDefault,
			Constants.LaunchHeightMin, Constants.LaunchHeightMax),
		theta = math.clamp(tonumber(aim.theta) or Constants.LaunchThetaMax,
			Constants.LaunchThetaMin, Constants.LaunchThetaMax),
		phi = (tonumber(aim.phi) or 0) % 360,
	}
end

-- The launch velocity for a clamped aim at a given speed (server-fixed:
-- PrototypeLaunchSpeed × stadium scale × quality multiplier).
function LaunchQuality.aimToVector(aim, speed: number): Vector3
	local thetaRad = math.rad(aim.theta)
	local phiRad = math.rad(aim.phi)
	local horizontal = speed * math.sin(thetaRad)
	return Vector3.new(
		horizontal * math.cos(phiRad),
		-speed * math.cos(thetaRad), -- never upward: theta ≤ 90 from vertical
		horizontal * math.sin(phiRad)
	)
end

-- Seat default: flat, mid-height, aimed at the bowl centre.
-- side: -1 (spawns at -X, aims +X → phi 0) or +1 (spawns at +X, aims -X → phi 180)
function LaunchQuality.defaultAimFor(side: number)
	return {
		height = Constants.LaunchHeightDefault,
		theta = Constants.LaunchThetaMax,
		phi = (side or -1) < 0 and 0 or 180,
	}
end

return LaunchQuality
