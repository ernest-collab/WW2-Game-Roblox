--[[
	Game modes. RoundService (server) implements the rules; UI reads ModeId from GameState.

	Conquest  : hold capture points. Each team has tickets; deaths cost 1 ticket and holding the
	            majority of points bleeds the enemy. Team at 0 tickets loses.
	Frontline : tug-of-war along an ordered chain of points (Order 1..N, Allies start at the low
	            end, Axis at the high end). Only the frontmost point of each side is capturable
	            (others are Locked). Capturing a point pushes the front. Win by capturing every
	            point, or by having more points / tickets when time runs out.
	TDM       : team deathmatch, first team to `scoreLimit` kills wins. Objectives are hidden.
]]

export type ModeDef = {
	id: string,
	name: string,
	description: string,
	timeLimit: number, -- seconds
	tickets: number?, -- starting tickets per team (Conquest/Frontline)
	scoreLimit: number?, -- TDM
	ticketBleedPerSecond: number?, -- per point advantage (Conquest)
	ticketsOnCapture: number?, -- Frontline: tickets restored to the capturing side
	usesObjectives: boolean,
	usesVehicles: boolean,
	captureTime: number, -- base seconds to capture a neutral point with one player
	captureRadiusScale: number,
	respawnTime: number,
}

local GameModes: { [string]: ModeDef } = {
	Conquest = {
		id = "Conquest",
		name = "Conquest",
		description = "Capture and hold the objectives to drain enemy reinforcements.",
		timeLimit = 20 * 60,
		tickets = 350,
		ticketBleedPerSecond = 0.35,
		usesObjectives = true,
		usesVehicles = true,
		captureTime = 12,
		captureRadiusScale = 1,
		respawnTime = 8,
	},
	Frontline = {
		id = "Frontline",
		name = "Frontline",
		description = "Push the front line. Seize the enemy's forward objective to advance.",
		timeLimit = 25 * 60,
		tickets = 250,
		ticketsOnCapture = 60,
		usesObjectives = true,
		usesVehicles = true,
		captureTime = 18,
		captureRadiusScale = 1.2,
		respawnTime = 10,
	},
	TDM = {
		id = "TDM",
		name = "Team Deathmatch",
		description = "Eliminate the enemy. First team to the kill limit wins.",
		timeLimit = 12 * 60,
		scoreLimit = 150,
		usesObjectives = false,
		usesVehicles = false,
		captureTime = 0,
		captureRadiusScale = 1,
		respawnTime = 5,
	},
}

local ORDER = { "Conquest", "Frontline", "TDM" }

return { byId = GameModes, order = ORDER }
