-- Default input bindings. Controllers should read from here (and from SettingsController
-- overrides) instead of hard-coding keys. Gamepad equivalents in `gamepad`.
local Keybinds = {
	keyboard = {
		Fire = Enum.UserInputType.MouseButton1,
		Aim = Enum.UserInputType.MouseButton2,
		Reload = Enum.KeyCode.R,
		Sprint = Enum.KeyCode.LeftShift,
		Crouch = Enum.KeyCode.C,
		Prone = Enum.KeyCode.Z,
		Jump = Enum.KeyCode.Space,
		Primary = Enum.KeyCode.One,
		Secondary = Enum.KeyCode.Two,
		Gadget1 = Enum.KeyCode.Three,
		Gadget2 = Enum.KeyCode.Four,
		Melee = Enum.KeyCode.V,
		QuickGrenade = Enum.KeyCode.G,
		FireMode = Enum.KeyCode.B,
		Interact = Enum.KeyCode.E, -- enter vehicle, pick up, resupply
		Spot = Enum.KeyCode.Q,
		Scoreboard = Enum.KeyCode.Tab,
		BigMap = Enum.KeyCode.M,
		Deploy = Enum.KeyCode.Return,
		Settings = Enum.KeyCode.P,
		ChangeLoadout = Enum.KeyCode.L,
		-- vehicles
		VehicleExit = Enum.KeyCode.F,
		VehicleSwitchSeat = Enum.KeyCode.X,
		VehicleZoom = Enum.UserInputType.MouseButton2,
		VehicleFire = Enum.UserInputType.MouseButton1,
		VehicleAltFire = Enum.KeyCode.Space,
		VehicleFreeLook = Enum.KeyCode.LeftAlt,
	},
	gamepad = {
		Fire = Enum.KeyCode.ButtonR2,
		Aim = Enum.KeyCode.ButtonL2,
		Reload = Enum.KeyCode.ButtonX,
		Sprint = Enum.KeyCode.ButtonL3,
		Crouch = Enum.KeyCode.ButtonB,
		Jump = Enum.KeyCode.ButtonA,
		SwitchWeapon = Enum.KeyCode.ButtonY,
		QuickGrenade = Enum.KeyCode.ButtonR1,
		Gadget = Enum.KeyCode.ButtonL1,
		Melee = Enum.KeyCode.ButtonR3,
		Interact = Enum.KeyCode.DPadUp,
		Scoreboard = Enum.KeyCode.ButtonSelect,
		VehicleExit = Enum.KeyCode.DPadDown,
	},
}

return Keybinds
