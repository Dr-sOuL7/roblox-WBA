--[=[
	LaunchQuality.lua
	Shared, PURE timing-bar math: the client renders the bar with it and the
	server grades with it, off the same synced clock (GetServerTimeNow), so
	preview and verdict cannot drift.

	Bar model: triangle wave with period LaunchBarPeriod, sweeping 0 → 1 → 0.
	Centre (0.5) is the Perfect mark. Zones are distances from centre.

	Headless-tested by tools/harness-runner (persistence mode test group).
]=]

local Constants = require(script.Parent:WaitForChild("Constants"))

local LaunchQuality = {}

-- Bar position in [0, 1] at `serverTime`, for a bar that started at `epoch`.
function LaunchQuality.barPosition(serverTime: number, epoch: number): number
	local period = Constants.LaunchBarPeriod
	local t = (serverTime - epoch) % period
	local half = period / 2
	if t < half then
		return t / half
	end
	return 1 - ((t - half) / half)
end

-- Grade a press at `serverTime` against the bar. Pure timing only — window
-- rules (late launches) are the caller's policy.
function LaunchQuality.gradeAt(serverTime: number, epoch: number): string
	local distance = math.abs(LaunchQuality.barPosition(serverTime, epoch) - 0.5)
	if distance <= Constants.LaunchPerfectZone then
		return "Perfect"
	elseif distance <= Constants.LaunchGoodZone then
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

return LaunchQuality
