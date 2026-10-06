# WW2 Frontlines: Monetization Setup Guide (for the game owner)

The store is already built into the game. Until you paste real IDs into
`src/shared/Config/Monetization.luau`, nothing is for sale. Every pass and product starts with `id = 0`,
is hidden in the store, and its perk does nothing. This guide covers creating the items on Roblox,
wiring them in, testing them, and staying within Roblox policy.

## 1. What is for sale (and why it is not pay-to-win)

| Key | Type | Suggested price | What it gives |
|---|---|---|---|
| `VIP` | Game pass | R$ 349 | +25% XP, a gold name in the scoreboard and kill feed, a `[VIP]` chat tag, and the exclusive Brass weapon camo |
| `DoubleXP` | Game pass | R$ 499 | Permanent +100% XP |
| `CamoCollection` | Game pass | R$ 199 | 7 cosmetic weapon camos (first- and third-person) |
| `UniformPack` | Game pass | R$ 249 | 4 uniform color variants (Winter Smock, Splinter Smock, Desert Drill, Parade Dress) |
| `LoadoutPresets` | Game pass | R$ 99 | 8 saved loadout presets instead of 2 |
| `XPBoost1h` | Developer product | R$ 49 | +100% XP for 1 real-time hour (buying again adds time) |
| `XPBoost3h` | Developer product | R$ 119 | +100% XP for 3 real-time hours |
| `WeaponUnlock` | Developer product | R$ 79 | Early access to one weapon above your level. If bought without choosing a weapon, it becomes an Unlock Token you can spend later |
| `TipSmall` / `TipMedium` / `TipLarge` | Developer product | R$ 25 / 100 / 500 | A thank-you message and the Supporter tag. No gameplay effect |

Roblox Premium members also get +10% XP automatically. There is nothing to set up for this.

**Fairness rules built into the code:**
- No item changes damage, health, armor or weapon stats.
- Every weapon you can buy early also unlocks by playing, and it uses the same stats for everyone.
- There are no random or loot-box items.
- Uniform variants are clamped to the same brightness as each faction's standard uniform, so they
  never make a player harder to see.
- Only XP is multiplied. The in-match **Score** is never multiplied, so the scoreboard stays fair.

**XP formula:** `multiplier = 1 + 0.25 (VIP) + 1.0 (Double XP) + 1.0 (active boost) + 0.10 (Premium)`.
The bonuses add up rather than multiply, and the total is capped at **3.0**
(`MAX_XP_MULTIPLIER`). Some examples:
- VIP alone: x1.25
- Double XP + VIP: x2.25
- Double XP + VIP + boost: x3.0 (the cap)

## 2. Creating the items on the Creator Dashboard

First, publish the place (File, then Publish to Roblox). Then go to <https://create.roblox.com/dashboard/creations>
and open your experience.

**Game passes** (do this once for each of the 5 passes):
1. Go to **Monetization → Passes → Create a Pass**.
2. Upload an icon (512×512), and enter the name and description. You can copy them from `Monetization.luau`.
3. Click **Create Pass**, open the pass, go to **Sales**, turn on **Item for Sale**, and set the price.
4. Copy the **Pass ID**, which is the number in the URL or on the pass page.

**Developer products** (do this once for each of the 7 products):
1. Go to **Monetization → Developer Products → Create a Developer Product**.
2. Enter the name, description, icon and price, then save.
3. Copy the **Product ID**.

## 3. Pasting the IDs

Open `src/shared/Config/Monetization.luau` and replace each `id = 0` with the real number, for example:

```lua
VIP = {
    key = "VIP",
    id = 123456789,   -- <- your Pass ID
    ...
```

Then do the following:
- Keep the `price` fields in sync with the dashboard. They are only used for display (the store shows "R$ 349"). Roblox always charges the dashboard price.
- Rebuild and publish (`rojo build`, or sync with Rojo, then publish).
- You can switch items on one at a time. Any item still at `id = 0` stays hidden.

Do **not** set `MarketplaceService.ProcessReceipt` anywhere else. `MonetizationService` is the only
receipt handler, and Roblox allows just one per server.

## 4. How purchases are kept safe

- **Game passes:** ownership is checked when a player joins with `UserOwnsGamePassAsync`. Each check is
  wrapped in pcall, tried 3 times, and re-tried every 60 s if Roblox was down. Ownership is also
  updated immediately through `PromptGamePassPurchaseFinished`.
- **Developer products:** each grant is one atomic `UpdateAsync` on the DataStore
  `WW2Frontlines_Monetization_v1` (key `Player_<UserId>`). That single call:
  - checks whether the `PurchaseId` was already processed (so a retry is never granted twice), and
  - applies the grant and records the `PurchaseId` in the same write.

  `PurchaseGranted` is returned only after that write succeeds. In every other case the handler returns
  `NotProcessedYet`, including when:
  - the player has left,
  - their data is not loaded yet,
  - the product id is unknown, or
  - the DataStore failed.

  Roblox then retries the receipt later, for example when the player rejoins. Players are never
  charged for nothing.
- **Weapon unlock:** the client asks for a specific weapon. The server checks that the weapon exists,
  is above the player's level and is not already owned. It then saves that choice and opens the
  purchase prompt, and the receipt grants that weapon. If there is no valid pending choice, the player
  gets an Unlock Token instead.

## 5. Testing in Studio

- **With real IDs:** purchases made in Studio are test purchases. No Robux is charged, and the whole
  flow runs, including `ProcessReceipt`. To use real DataStores, enable
  *Game Settings → Security → Enable Studio Access to API Services*. Without that, the service falls
  back to an in-memory store that resets when you stop the test.
- **Without IDs:** set `Monetization.STUDIO_TEST_GRANTS = true`. Inside Studio this makes every pass
  count as owned, and "buying" a product grants it immediately through the same code path, using a
  simulated receipt. The flag does nothing on live servers. Set it back to `false` before you publish
  anyway.
- **What to check:**
  - Press **K** (or click **STORE** on the deploy screen) and try each tab.
  - Buy a boost and confirm the "XP x2" HUD badge and countdown appear.
  - Unlock a high-level weapon and confirm it shows up as selectable in the loadout.
  - Equip a camo and a uniform, then redeploy.
  - Save and load a loadout preset using **PRESETS** on the deploy screen.

## 6. Earnings, DevEx and Premium Payouts (overview)

- Robux spent on passes and products goes to the experience owner, minus Roblox's marketplace fee.
  You keep about 70%. Earnings appear under Creator Dashboard → Analytics → Monetization. Payments
  can be pending for a few days.
- **Developer Exchange (DevEx)** lets eligible creators (13+, verified email, minimum balance, good
  standing) convert earned Robux into real money. See <https://create.roblox.com/docs/production/earning-on-roblox/developer-exchange>.
- **Premium Payouts** are automatic. Roblox pays you based on how much time Premium subscribers spend
  in your experience. The +10% XP for Premium members encourages that engagement. You do not need to
  set anything up.
- **Suggested pricing:**
  - Impulse items (tips, 1 h boost, presets) stay under R$ 100.
  - Cosmetics sit at R$ 199–249.
  - The two XP passes are the premium tier.

  Roblox data shows that most revenue comes from small repeat purchases plus one or two "hero"
  passes. Revisit prices after a few weeks of analytics, using the dashboard's price-testing tools.

## 7. Roblox policy notes

- **Paid random items:** if you ever add paid random items, you must disclose the odds and follow the
  Paid Random Items policy. The game has none today, and keeping it that way is recommended.
- **Fair descriptions:** describe items accurately. Do not imply a gameplay advantage the item does
  not give.
- **Audience:** keep store text and icons age-appropriate for Roblox's all-ages audience. Do not use
  high-pressure language such as countdown "deals" or "buy or lose".
- **Purchase prompts:** use only the official `MarketplaceService` prompts, which this game does. Never
  ask players for passwords or for purchases outside Roblox.
- **Refunds:** Roblox handles refunds. Do not remove a pass perk from a player who owns the pass.
- **Changing an ID:** if you replace an item, keep the old one on sale or grant its perks some other
  way. Players who bought the old one must keep what they paid for.
