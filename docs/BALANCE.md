# WW2 Frontlines balance

Owner: Balancing. Numbers live in `src/shared/Config/{Weapons,Vehicles,GameModes,Progression,Classes}.luau`;
the maths that checks them is `scripts/balance_report.py`. Rerun it after any numeric change:

```sh
python3 scripts/balance_report.py --check       # lists target violations, exit 1 if any
python3 scripts/balance_report.py --update-doc  # regenerates the tables at the bottom of this file
```

The script loads the real config modules through the Luau CLI (`$LUAU`, `luau` on PATH, `.tools/luau`
or `/tmp/claude-0/tools/luau`) with a small Roblox mock, so templates, merges and helper-built
values (vehicle `AP()/HE()` shells, MG blocks) are what the game sees. Its damage maths mirrors
`Util/Ballistics.luau` (falloff, hit zones, explosion curve), `CombatService` (pellets, `Explode`
uses the distance to the nearest body-part box) and `VehicleService.ApplyDamage` / shell resolution
(facings, angle factor, non-pen fractions, HE splash also hitting the struck vehicle). Keep them in
sync if a formula changes.

## Philosophy

* **Time-to-kill is the currency.** Every firearm is tuned by shots-to-kill (STK) x fire interval
  against 100 HP; recoil, spread and handling then decide how often a player achieves that TTK.
  TTK numbers in the tables assume every shot lands, which is the ceiling a good player reaches.
* **Categories own ranges.** SMGs win inside ~30 studs, ARs and LMGs at 25-65, semi-autos at
  50-150, bolt-actions and scopes beyond. Falloff curves, not damage, carve these out.
* **Nations are flavour, not power.** Every nation's best level-1 option in each category is within
  10 % TTK of every other nation's. Historical character (PPSh drum, MG42 rate, Lee-Enfield bolt,
  Garand clip) is expressed in magazine, rate, recoil and handling, never in raw lethality.
* **Unlocks are side-grades.** An unlock may not be more than 10 % faster to kill at every range
  than the level-1 weapon it competes with; it must give something up (range, magazine, ADS speed,
  reload, recoil, precision).
* **Headshots and positioning are rewarded, one-shots are rare.** Only bolt-action and scoped
  headshots, shotguns at point blank, tank shells and well-placed explosives kill in one hit.
* **Armor is about angles.** Tanks are killed from the side and rear; frontal fights are long.
  Infantry AT can always finish a tank, but needs 3-4 flanking hits, i.e. a squad or a resupply.

## Targets and how they are met

| Target | Result |
|---|---|
| SMG 220-330 ms at <= 25 studs | Level 1: 281-300 ms (4-5 STK); unlocks 257-327 ms |
| AR 250-360 ms | Level 1: 277-300 ms at 25-50 studs; unlocks 286-333 ms |
| LMG 240-380 ms, ADS >= 0.35 s, heavy move penalty | 255-360 ms; ADS 0.36-0.52 s; walk speed <= 0.93 (most 0.82-0.90) |
| Semi-auto 300-450 ms, 2-3 body, head + body kills | Level 1: 375-400 ms (46-49 dmg, 3 STK, head+body = 2); Gewehr 41 is the 2-shot variant at 200 rpm |
| Bolt-action: 1 head / 2 body <= 100 studs | Holds to 200+ studs; body TTK 1.03-1.30 s (bolt cycle), level-1 1.09-1.18 s |
| Scoped: no one-shot body at any range | Bolt scopes 95 dmg (2 body, 1 head everywhere); semi scopes 55 dmg x1.6 head (2 shots anywhere, never 1) |
| Shotguns: 1 shot <= 8 studs, 2 <= 15 | All shotguns: 1 at 8, 2 at 15, 3+ beyond 20 |
| Pistols 400-600 ms | 400-500 ms |
| Faction parity <= 10 % per category | 5-8 % spread in every category (see parity table) |
| Unlocks are side-grades | No unlock is > 10 % faster everywhere; a few TTK-equal unlocks trade recoil/precision/range (listed below) |
| Grenade lethal ~4-5 studs, damage radius ~12 | Frags: lethal 4.5-4.7, radius 12-13; level-10 "3-pack" grenades 4.0 / 11; F1 Limonka 5.3 / 14 |
| AT on a medium tank: 3 rear / 4 side / 6-8 front | Every launcher and thrown AT grenade: 6 / 4 / 3 on every 1900-2000 HP medium |
| Panzerfaust strong but short range | 700 vehicle dmg: 5 / 3 / 2-3 hits, 120-stud range, 150 studs/s, 1 + 2 reserve |
| Tank gun one-shots infantry on a direct hit, modest splash | Direct 220 (AP) / 300 (HE); HE lethal radius 3.7-5.3 studs, AP splash never kills |
| Medium vs medium AP: front 3-5 / side 2-3 / rear 1-2 | Every level-1 medium vs every level-1 medium: 3-4 / 3 / 2 |
| Heavy tanks need flanking | Heavy fronts (135-140) are not penetrated by any level-1 medium; their sides are |
| Light vehicles die to 2 AT rockets | All light vehicles <= 1100 HP: 2 side or rear hits (3-4 from the front) |
| Conquest 15-20 min (32 players) | Modelled 17.5 min (320 tickets, 0.2 bleed/s per point, 22 min cap) |
| Frontline 20-25 min | Modelled 22.2 min (160 tickets, +20 per capture, 25 min cap) |
| TDM limit in ~10 min (24 players) | Modelled 10.0 min (120 kills) |
| Level 10 in 2-3 h, level 30 in 25-35 h | 2.4 h and 29.1 h at a modelled 191 XP/min |
| First unlock in every class within 30-60 min | Level 5 (41 min): a new primary for every class in every nation |

### Modelling assumptions

* **Shotgun pellets:** the fraction of pellets landing is `min(1, 7 / (pi r^2))`, where `r` is
  the cone radius at that distance (pellet spread + ADS spread) and 7 studs^2 is the effective
  silhouette. Point-blank one-shots tolerate losing ~40 % of the pellets.
* **Tank duels:** frontal hits land 25 degrees off the normal, side hits 10, rear 0 (angle factor
  `1/cos^0.6`). Ricochets are ignored (they need >72 degrees).
* **Players per minute:** 0.70 kills, 20 % headshots, 0.35 assists, 3 captures + 1.5 neutralises
  per Conquest round, 15 XP/min of class actions (heals, resupplies, revives, repairs, spot
  assists), 50 % win rate, no XP boosts. That gives ~191 XP/min (~11.5k/h).
* **Rounds:** 0.70 deaths per player-minute, 12 % revived (refunding the ticket). Conquest: the
  losing side is one point behind 70 % of the time. Frontline: 0.3 captures per minute server-wide,
  35 % of them by the losing side. TDM: 1 kill per player-minute (smaller maps, 5 s respawn).

These assumptions decide the mode and progression numbers. Replace them with real telemetry
(kills, deaths, captures and XP per minute) as soon as playtests produce it, and retune with the script.

## Notable decisions

**Infantry**
* **Semi-autos: 3 shots, not 2.** The Garand used 50 damage, which is exactly 2 x 50 = 100, so it
  killed in 2 body shots at 200 ms (float-exact kill). Semi-autos now do 46-48 damage (3 body, or
  headshot + body) at 300-330 rpm, giving 375-400 ms. The M1 Carbine (38 dmg, 15 rounds) matches
  that TTK up close but falls to 4 STK past ~150 studs. The Gewehr 41 is the 2-shot side-grade
  (52 dmg, 2 body inside 60 studs at 200 rpm, worse falloff).
* **Scoped rifles never one-shot the body.** Bolt scopes went from 100 to 95 damage (Type 99:
  98). They keep a one-shot headshot at every range and a flatter falloff and a 0.28 zoom over
  iron-sight bolts. The level-14 semi-auto scopes (M1C, SVT-40 PU, G43 ZF4) dropped from 70 dmg
  at 240 rpm (2 body shots in 250 ms at any range) to 55 dmg x1.6 head at 150 rpm. They kill in
  2 hits of any kind in 400 ms, but never in one.
* **AT rifles are no longer one-shot snipers.** Infantry damage went from 160 (with a 1.0 limb
  multiplier, so one hit anywhere killed at any range) to 90 / x2.0 head / x0.8 limb, the same as
  a bolt-action. The semi-auto Type 97 and Solothurn dropped to 60 rpm. See the code issue below:
  they currently do no damage to armored vehicles.
* **Rates of fire were normalised per category.** Level-1 SMGs sit at 281-300 ms, ARs at
  277-300 ms and LMGs at 267-279 ms. Identity comes from magazines and handling. The PPSh keeps
  its 71-round drum at 21 dmg / 850 rpm. The MG42 trades per-round damage (22, 5 STK) for the
  highest rate (940 rpm) and a 75-round belt. The AVS-36, Charlton, FG42 and Breda PG are 3-shot
  guns at 400-420 rpm.
* **Shotguns:** the falloff now ends one-shots at about 12 studs (`8:1, 15:0.5, 30:0.18,
  50:0.05`). Pump guns cycle at 100-105 rpm and double barrels at 105-108 rpm (parity at 15
  studs). The Auto-5 fires at 160 rpm with less damage. The Ithaca has 5 shells against the
  M1897's 6 to make it a side-grade.
* **Pistols:** the 3-shot pistols (.45, Tokarev, P38, Webley) fire at 280-290 rpm. The 4-shot
  ones (Nambu, Beretta, MAB D, Hi-Power) fire at 420-450 rpm. The M712 is a 24-damage, 5-shot
  machine pistol at 600 rpm (400 ms) with a 20-round magazine and wild recoil.
* **Grenades:** frag radius went from 18 to 12 (the lethal radius was 6.8 studs, which killed
  whole squads). Impact grenades are smaller: OTO 10 / 130, SRCM 10 / 125, Gammon 12 / 170.
  Satchels shrank to an 18-stud radius / 220 damage, so the lethal radius dropped from 12 to 9.

**Vehicles**
* **Shell facing multipliers:** `PEN_FACING_MULT` changed from side 1.15 / rear 1.35 to side 1.25 /
  rear 1.7 (top 1.7). This makes rear shots 2-hit kills and rewards flanking more than raw gun
  size.
* **Level-1 medium tanks were normalised:** 1900-2000 HP, front armor 80-95, side 40-55, rear
  30-45, AP penetration 110-135 (beats every level-1 front even at 25 degrees) and 600-650
  damage. The Chi-Ha, M13/40, Char B1 and S35 had 65-80 penetration guns that could not hurt
  most enemy mediums from the front. They now differ only in reload (3.6-5.2 s), speed and HE.
  Light vehicles that historically outclassed these tanks stay out of scope; the arcade parity is
  intentional.
* **Emplaced AT guns** cannot flank, so every level-1 gun now has 110+ AP penetration (the
  French, Japanese and Italian 47 mm guns had 65-85 and could not hurt a medium from the front).
* **Heavies need flanking:** Churchill 140 front, KV-1 135, Tiger 140 (rear 80 to 60), Panther 140.
  The Churchill and KV-1 guns were raised to 110 penetration so they can fight mediums. The
  Tiger (160) and Panther (175) are the only guns that defeat heavy fronts.
* **Infantry AT:** bazooka 580, M9 570 (faster rocket and reload), PIAT 600 (slow, arcing),
  Panzerschreck 615, thrown RPG-40 / Type 3 600, RPG-43 630 (1 carried), Panzerfaust 700 and lunge
  mine 760 (both short range). Light vehicles were capped at 1100 HP so every launcher kills
  them in 2 side hits.

**Modes and progression**
* Conquest bleed went from 0.35 to 0.2 tickets/s per point: at 0.35 a one-point lead drained
  21 tickets a minute, twice the death rate, and decided rounds in about 14 min. Tickets went
  from 350 to 320 and the time cap from 20 to 22 min, so rounds end on tickets.
* Frontline: at 250 tickets with +60 per capture, tickets could never run out and every round
  went to the 25-minute cap. It now has 160 tickets and +20 per capture.
* TDM: the 150-kill limit is now 120.
* XP curve: `xpToNext = 1500 + 260 l + 24 l^2` (was `+ 320 l + 8 l^2`, which reached level 30 in
  19 h). Early levels are unchanged in feel, while the late curve is steeper.
* Unlocks: the first alternative primary for every class and nation now unlocks at level 5
  (41 min): bolt-actions (M1917, SMLE, M38, Lebel, G33/40, Type 38, M91), the first SMG unlocks
  (M3, Lanchester, PPS-43, MP28, Type 100 late, TZ-45) and one LMG per nation (M1919A6, Lewis,
  DS-39, Chauchat, MG42, Type 99). Before this the first unlock came after 87-129 min.

## Remaining concerns for playtests

1. **TTK assumes perfect accuracy.** Recoil and spread tables were not retuned. Watch the PPSh,
   the MG42 and the M2 Carbine, whose high rates may make real TTK fall faster than their peers'.
   Watch the AVS-36, FG42 and Charlton too, where 3-shot kills punish misses harder.
2. **Some unlocks are TTK-equal "upgrades"** that only give up things the script cannot see:
   SMLE (worse ADS spread), G33/40 (more recoil, shorter range), Arisaka Type 38 (less recoil,
   weaker long-range falloff), Type 99 LMG (more recoil) and M712 (hip spread, horizontal recoil).
   Check their kill share.
3. **Burst fire:** the Breda PG (`Burst`, 2 rounds) is modelled at its 420 rpm cycle. If
   WeaponController fires bursts faster than `rpm`, its TTK drops below 286 ms.
4. **Lupara / double barrels** reload after 2 shots (2.0-2.4 s). Their parity number is the
   15-stud follow-up shot only.
5. **Satchels and the C2 charge** still have 9-11-stud lethal radii. That is fine on a 5 s fuse
   and needed against tanks, but watch them as anti-infantry spam in buildings.
6. **Model inputs** (kills/min, captures/round, deaths/min) are estimates. Conquest length is very
   sensitive to how often one side holds more points, so check real round lengths.
7. **Lunge mine and Panzerfaust** kill a medium in 5 frontal hits, one below the 6-8 band. This
   is deliberate as the reward for 7 and 120-stud ranges.

## Code-level issues for other teams (not changed here)

* **AT rifles cannot damage armor (Combat/Vehicle).** `CombatService.processShot` passes
  `penetration = def.penetration` (a 0..1 cover factor, 1 for AT rifles) to
  `VehicleService.ApplyDamage`, which ignores values <= 1. The `vehicleDamage` (140) is then
  treated as small-arms damage, so every vehicle with `smallArmsMult = 0` (all tanks, light tanks
  and armored cars) takes nothing. Suggested fix: a separate `armorPenetration` weapon field
  (e.g. Boys 25, PTRD/PzB 30, Type 97 / S-18 35) passed as `opts.penetration`, leaving cover
  penetration untouched. Raising `penetration` itself would let AT rifles shoot through 60-stud
  walls (`thickness <= penetration * 2`).
* **HE splash double-dips (Vehicle).** `resolveShell` applies the shell damage and then
  `CombatService.Explode` with `splashVehicle`, which hits the struck tank again at full strength
  times `EXPLOSIVE_FACING_MULT` (rear 1.4). HE is still weaker than AP against armor, so this is
  only flagged. The script models it.
* **`PEN_FACING_MULT` also scales vehicle MG damage** on soft-skins (`opts.penetration > 1`),
  so the new rear 1.7 makes MG fire into the back of a jeep 26 % stronger than before. Accepted.
* **Float-exact kills:** kills happen at `Health <= 0`, so damage values that divide 100 exactly
  (25, 50) kill on the boundary. Avoid new exact divisors, or round damage in
  `damagePlayer`, if hit registration ever scales damage by non-exact factors (penetration 0.6).
* **Monetization:** weapon unlock levels moved (several level 8-12 items are now level 5). Check
  any price tiers derived from `unlockLevel` in `Config/Monetization.luau` (not owned here).

<!-- GENERATED BY scripts/balance_report.py --update-doc: do not edit below -->

## Infantry firearms

STK = shots to kill (body/head/limb), TTK in ms (body; head in brackets) from first shot, all hits. DPS = body damage x RPM at 10 studs; Sust = mag dump / (mag time + empty reload).

### SMG

| Weapon | Fac | Lvl | Dmg | RPM | Mag | ADS s | 10 STK b/h/l | 10 TTK | 25 STK b/h/l | 25 TTK | 50 STK b/h/l | 50 TTK | 100 STK b/h/l | 100 TTK | 200 STK b/h/l | 200 TTK | DPS | Dump | Sust |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| ThompsonM1A1 | US | 1 | 28 | 640 | 30 | 0.20 | 4/3/4 | 281 (188) | 4/3/4 | 281 (188) | 5/3/5 | 375 (188) | 6/4/7 | 469 (281) | 6/4/7 | 469 (281) | 299 | 840 | 150 |
| M3GreaseGun | US,FR | 5 | 28 | 560 | 30 | 0.18 | 4/3/4 | 321 (214) | 4/3/4 | 321 (214) | 5/3/5 | 429 (214) | 6/4/7 | 536 (321) | 6/4/7 | 536 (321) | 261 | 840 | 140 |
| ThompsonM1928 | US,UK | 16 | 28 | 700 | 50 | 0.24 | 4/3/4 | 257 (171) | 4/3/4 | 257 (171) | 5/3/5 | 343 (171) | 6/4/7 | 429 (257) | 6/4/7 | 429 (257) | 327 | 1400 | 173 |
| StenMkII | UK,FR | 1 | 25 | 600 | 32 | 0.20 | 4/3/5 | 300 (200) | 4/3/5 | 300 (200) | 5/4/6 | 400 (300) | 7/5/8 | 600 (400) | 7/5/8 | 600 (400) | 250 | 800 | 133 |
| Lanchester | UK | 5 | 25 | 600 | 50 | 0.24 | 4/3/5 | 300 (200) | 4/3/5 | 300 (200) | 5/4/6 | 400 (300) | 7/5/8 | 600 (400) | 7/5/8 | 600 (400) | 250 | 1250 | 151 |
| StenMkV | UK | 20 | 25 | 575 | 32 | 0.20 | 4/3/5 | 313 (209) | 4/3/5 | 313 (209) | 5/4/6 | 417 (313) | 7/5/8 | 626 (417) | 7/5/8 | 626 (417) | 240 | 800 | 130 |
| PPSh41 | USSR | 1 | 21 | 850 | 71 | 0.23 | 5/4/6 | 282 (212) | 5/4/6 | 282 (212) | 6/4/6 | 353 (212) | 8/5/9 | 494 (282) | 8/5/9 | 494 (282) | 298 | 1491 | 173 |
| PPS43 | USSR | 5 | 25 | 650 | 35 | 0.18 | 4/3/5 | 277 (185) | 4/3/5 | 277 (185) | 5/4/6 | 369 (277) | 7/5/8 | 554 (369) | 7/5/8 | 554 (369) | 271 | 875 | 145 |
| PPD40 | USSR | 18 | 22 | 800 | 71 | 0.22 | 5/4/6 | 300 (225) | 5/4/6 | 300 (225) | 6/4/6 | 375 (225) | 8/5/9 | 525 (300) | 8/5/9 | 525 (300) | 293 | 1562 | 175 |
| MAS38 | FR | 1 | 25 | 620 | 32 | 0.18 | 4/3/5 | 290 (194) | 4/3/5 | 290 (194) | 5/4/6 | 387 (290) | 7/5/8 | 581 (387) | 7/5/8 | 581 (387) | 258 | 800 | 136 |
| MP40 | DE,IT | 1 | 27 | 600 | 32 | 0.20 | 4/3/5 | 300 (200) | 4/3/5 | 300 (200) | 5/3/5 | 400 (200) | 6/4/7 | 500 (300) | 6/4/7 | 500 (300) | 270 | 864 | 144 |
| MP28 | DE | 5 | 26 | 620 | 32 | 0.22 | 4/3/5 | 290 (194) | 4/3/5 | 290 (194) | 5/3/5 | 387 (194) | 7/5/7 | 581 (387) | 7/5/7 | 581 (387) | 269 | 832 | 141 |
| MP35 | DE | 18 | 26 | 600 | 32 | 0.20 | 4/3/5 | 300 (200) | 4/3/5 | 300 (200) | 5/3/5 | 400 (200) | 7/5/7 | 600 (400) | 7/5/7 | 600 (400) | 260 | 832 | 139 |
| Type100 | JP | 1 | 26 | 600 | 30 | 0.20 | 4/3/5 | 300 (200) | 4/3/5 | 300 (200) | 5/3/5 | 400 (200) | 7/5/7 | 600 (400) | 7/5/7 | 600 (400) | 260 | 780 | 134 |
| Type100Late | JP | 5 | 24 | 800 | 30 | 0.23 | 5/3/5 | 300 (150) | 5/3/5 | 300 (150) | 5/4/6 | 300 (225) | 7/5/8 | 450 (300) | 7/5/8 | 450 (300) | 320 | 720 | 143 |
| BerettaM38A | IT | 1 | 26 | 600 | 30 | 0.22 | 4/3/5 | 300 (200) | 4/3/5 | 300 (200) | 5/3/5 | 400 (200) | 7/5/7 | 600 (400) | 7/5/7 | 600 (400) | 260 | 780 | 134 |
| TZ45 | IT | 5 | 25 | 550 | 40 | 0.18 | 4/3/5 | 327 (218) | 4/3/5 | 327 (218) | 5/4/6 | 436 (327) | 7/5/8 | 655 (436) | 7/5/8 | 655 (436) | 229 | 1000 | 140 |
| FNAB43 | IT | 18 | 26 | 560 | 40 | 0.20 | 4/3/5 | 321 (214) | 4/3/5 | 321 (214) | 5/3/5 | 429 (214) | 6/4/7 | 536 (321) | 6/4/7 | 536 (321) | 243 | 1040 | 147 |

### AssaultRifle

| Weapon | Fac | Lvl | Dmg | RPM | Mag | ADS s | 10 STK b/h/l | 10 TTK | 25 STK b/h/l | 25 TTK | 50 STK b/h/l | 50 TTK | 100 STK b/h/l | 100 TTK | 200 STK b/h/l | 200 TTK | DPS | Dump | Sust |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| M2Carbine | US,UK,FR | 1 | 28 | 650 | 30 | 0.22 | 4/3/4 | 277 (185) | 4/3/4 | 277 (185) | 4/3/4 | 277 (185) | 5/3/5 | 369 (185) | 6/4/6 | 462 (277) | 303 | 840 | 143 |
| StG44 | DE,IT,JP | 1 | 31 | 600 | 30 | 0.26 | 4/3/4 | 300 (200) | 4/3/4 | 300 (200) | 4/3/4 | 300 (200) | 4/3/4 | 300 (200) | 5/3/6 | 400 (200) | 310 | 930 | 152 |
| AVS36 | USSR | 1 | 40 | 420 | 15 | 0.30 | 3/2/3 | 286 (143) | 3/2/3 | 286 (143) | 3/2/3 | 286 (143) | 3/2/3 | 286 (143) | 4/2/4 | 429 (143) | 280 | 600 | 117 |
| FedorovAvtomat | USSR | 12 | 33 | 540 | 25 | 0.26 | 4/2/4 | 333 (111) | 4/2/4 | 333 (111) | 4/2/4 | 333 (111) | 4/3/4 | 333 (222) | 5/3/5 | 444 (222) | 297 | 825 | 140 |
| CharltonAR | UK | 12 | 40 | 400 | 10 | 0.30 | 3/2/3 | 300 (150) | 3/2/3 | 300 (150) | 3/2/3 | 300 (150) | 3/2/3 | 300 (150) | 3/2/4 | 300 (150) | 267 | 400 | 91 |
| BredaPG | IT | 10 | 36 | 420 | 20 | 0.26 | 3/2/4 | 286 (143) | 3/2/4 | 286 (143) | 3/2/4 | 286 (143) | 4/2/4 | 429 (143) | 4/3/5 | 429 (286) | 252 | 720 | 121 |
| FG42 | DE | 12 | 38 | 400 | 20 | 0.30 | 3/2/3 | 300 (150) | 3/2/3 | 300 (150) | 3/2/3 | 300 (150) | 3/2/4 | 300 (150) | 4/2/4 | 450 (150) | 253 | 760 | 125 |
| MKb42H | DE,JP | 22 | 31 | 540 | 30 | 0.28 | 4/3/4 | 333 (222) | 4/3/4 | 333 (222) | 4/3/4 | 333 (222) | 4/3/4 | 333 (222) | 5/3/6 | 444 (222) | 279 | 930 | 145 |

### MachineGun

| Weapon | Fac | Lvl | Dmg | RPM | Mag | ADS s | 10 STK b/h/l | 10 TTK | 25 STK b/h/l | 25 TTK | 50 STK b/h/l | 50 TTK | 100 STK b/h/l | 100 TTK | 200 STK b/h/l | 200 TTK | DPS | Dump | Sust |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| BAR | US,FR | 1 | 40 | 430 | 20 | 0.36 | 3/2/3 | 279 (140) | 3/2/3 | 279 (140) | 3/2/3 | 279 (140) | 3/2/3 | 279 (140) | 3/2/4 | 279 (140) | 287 | 800 | 131 |
| M1919A6 | US | 5 | 36 | 450 | 100 | 0.50 | 3/2/4 | 267 (133) | 3/2/4 | 267 (133) | 3/2/4 | 267 (133) | 3/2/4 | 267 (133) | 4/3/4 | 400 (267) | 270 | 3600 | 177 |
| JohnsonLMG | US | 22 | 36 | 460 | 25 | 0.38 | 3/2/4 | 261 (130) | 3/2/4 | 261 (130) | 3/2/4 | 261 (130) | 3/2/4 | 261 (130) | 4/3/4 | 391 (261) | 276 | 900 | 135 |
| Bren | UK | 1 | 38 | 440 | 30 | 0.38 | 3/2/3 | 273 (136) | 3/2/3 | 273 (136) | 3/2/3 | 273 (136) | 3/2/3 | 273 (136) | 4/3/4 | 409 (273) | 279 | 1140 | 148 |
| LewisGun | UK | 5 | 36 | 450 | 47 | 0.46 | 3/2/4 | 267 (133) | 3/2/4 | 267 (133) | 3/2/4 | 267 (133) | 3/2/4 | 267 (133) | 4/3/4 | 400 (267) | 270 | 1692 | 156 |
| VickersBerthier | UK | 22 | 36 | 460 | 30 | 0.42 | 3/2/4 | 261 (130) | 3/2/4 | 261 (130) | 3/2/4 | 261 (130) | 3/2/4 | 261 (130) | 4/3/4 | 391 (261) | 276 | 1080 | 144 |
| DP27 | USSR | 1 | 36 | 450 | 47 | 0.42 | 3/2/4 | 267 (133) | 3/2/4 | 267 (133) | 3/2/4 | 267 (133) | 3/2/4 | 267 (133) | 4/3/4 | 400 (267) | 270 | 1692 | 159 |
| DS39 | USSR | 5 | 30 | 700 | 100 | 0.52 | 4/3/4 | 257 (171) | 4/3/4 | 257 (171) | 4/3/4 | 257 (171) | 4/3/4 | 257 (171) | 4/3/5 | 257 (171) | 350 | 3000 | 193 |
| RPD44 | USSR | 22 | 31 | 650 | 100 | 0.36 | 4/3/4 | 277 (185) | 4/3/4 | 277 (185) | 4/3/4 | 277 (185) | 4/3/4 | 277 (185) | 4/3/5 | 277 (185) | 336 | 3100 | 204 |
| FM2429 | FR | 1 | 36 | 450 | 25 | 0.38 | 3/2/4 | 267 (133) | 3/2/4 | 267 (133) | 3/2/4 | 267 (133) | 3/2/4 | 267 (133) | 4/3/4 | 400 (267) | 270 | 900 | 134 |
| Chauchat | FR | 5 | 42 | 360 | 20 | 0.40 | 3/2/3 | 333 (167) | 3/2/3 | 333 (167) | 3/2/3 | 333 (167) | 3/2/3 | 333 (167) | 3/2/4 | 333 (167) | 252 | 840 | 125 |
| MG34 | DE | 1 | 33 | 650 | 50 | 0.42 | 4/3/4 | 277 (185) | 4/3/4 | 277 (185) | 4/3/4 | 277 (185) | 4/3/4 | 277 (185) | 4/3/4 | 277 (185) | 358 | 1650 | 165 |
| MG42 | DE,IT | 5 | 22 | 940 | 75 | 0.48 | 5/4/6 | 255 (191) | 5/4/6 | 255 (191) | 5/4/6 | 255 (191) | 5/4/6 | 255 (191) | 6/4/6 | 319 (191) | 345 | 1650 | 156 |
| MG15 | DE | 22 | 26 | 700 | 75 | 0.40 | 4/3/5 | 257 (171) | 4/3/5 | 257 (171) | 4/3/5 | 257 (171) | 4/3/5 | 257 (171) | 5/3/5 | 343 (171) | 303 | 1950 | 171 |
| Type96LMG | JP | 1 | 34 | 440 | 30 | 0.42 | 3/2/4 | 273 (136) | 3/2/4 | 273 (136) | 3/2/4 | 273 (136) | 3/2/4 | 273 (136) | 4/3/4 | 409 (273) | 249 | 1020 | 133 |
| Type99LMG | JP | 5 | 38 | 450 | 30 | 0.42 | 3/2/3 | 267 (133) | 3/2/3 | 267 (133) | 3/2/3 | 267 (133) | 3/2/3 | 267 (133) | 4/3/4 | 400 (267) | 285 | 1140 | 150 |
| Type11LMG | JP | 18 | 33 | 500 | 30 | 0.42 | 4/3/4 | 360 (240) | 4/3/4 | 360 (240) | 4/3/4 | 360 (240) | 4/3/4 | 360 (240) | 4/3/4 | 360 (240) | 275 | 990 | 105 |
| Breda30 | IT | 1 | 34 | 430 | 20 | 0.38 | 3/2/4 | 279 (140) | 3/2/4 | 279 (140) | 3/2/4 | 279 (140) | 3/2/4 | 279 (140) | 4/3/4 | 419 (279) | 244 | 680 | 117 |
| Breda37 | IT | 12 | 42 | 450 | 40 | 0.52 | 3/2/3 | 267 (133) | 3/2/3 | 267 (133) | 3/2/3 | 267 (133) | 3/2/3 | 267 (133) | 3/2/4 | 267 (133) | 315 | 1680 | 163 |

### SemiAuto

| Weapon | Fac | Lvl | Dmg | RPM | Mag | ADS s | 10 STK b/h/l | 10 TTK | 25 STK b/h/l | 25 TTK | 50 STK b/h/l | 50 TTK | 100 STK b/h/l | 100 TTK | 200 STK b/h/l | 200 TTK | DPS | Dump | Sust |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| M1Garand | US | 1 | 48 | 300 | 8 | 0.28 | 3/2/3 | 400 (200) | 3/2/3 | 400 (200) | 3/2/3 | 400 (200) | 3/2/3 | 400 (200) | 3/2/3 | 400 (200) | 240 | 384 | 101 |
| M1Carbine | US,UK,FR | 1 | 38 | 320 | 15 | 0.22 | 3/2/4 | 375 (188) | 3/2/4 | 375 (188) | 3/2/4 | 375 (188) | 3/2/4 | 375 (188) | 4/3/5 | 562 (375) | 203 | 570 | 109 |
| SVT40 | USSR | 1 | 48 | 300 | 10 | 0.28 | 3/2/3 | 400 (200) | 3/2/3 | 400 (200) | 3/2/3 | 400 (200) | 3/2/3 | 400 (200) | 3/2/3 | 400 (200) | 240 | 480 | 96 |
| MAS44 | FR | 1 | 48 | 300 | 10 | 0.28 | 3/2/3 | 400 (200) | 3/2/3 | 400 (200) | 3/2/3 | 400 (200) | 3/2/3 | 400 (200) | 3/2/3 | 400 (200) | 240 | 480 | 96 |
| Gewehr43 | DE | 1 | 48 | 300 | 10 | 0.28 | 3/2/3 | 400 (200) | 3/2/3 | 400 (200) | 3/2/3 | 400 (200) | 3/2/3 | 400 (200) | 3/2/3 | 400 (200) | 240 | 480 | 96 |
| Type5Rifle | JP | 1 | 49 | 300 | 10 | 0.28 | 3/2/3 | 400 (200) | 3/2/3 | 400 (200) | 3/2/3 | 400 (200) | 3/2/3 | 400 (200) | 3/2/3 | 400 (200) | 245 | 490 | 96 |
| Armaguerra39 | IT | 1 | 46 | 320 | 6 | 0.28 | 3/2/3 | 375 (188) | 3/2/3 | 375 (188) | 3/2/3 | 375 (188) | 3/2/3 | 375 (188) | 3/2/3 | 375 (188) | 245 | 276 | 78 |
| Gewehr41 | DE,IT | 10 | 52 | 200 | 10 | 0.32 | 2/2/3 | 300 (300) | 2/2/3 | 300 (300) | 2/2/3 | 300 (300) | 3/2/3 | 600 (300) | 3/2/4 | 600 (300) | 173 | 520 | 81 |
| M1941Johnson | US | 12 | 46 | 320 | 10 | 0.28 | 3/2/3 | 375 (188) | 3/2/3 | 375 (188) | 3/2/3 | 375 (188) | 3/2/3 | 375 (188) | 3/2/3 | 375 (188) | 245 | 460 | 94 |
| SVT38 | USSR | 14 | 46 | 330 | 10 | 0.31 | 3/2/3 | 364 (182) | 3/2/3 | 364 (182) | 3/2/3 | 364 (182) | 3/2/3 | 364 (182) | 3/2/3 | 364 (182) | 253 | 460 | 95 |

### BoltAction

| Weapon | Fac | Lvl | Dmg | RPM | Mag | ADS s | 10 STK b/h/l | 10 TTK | 25 STK b/h/l | 25 TTK | 50 STK b/h/l | 50 TTK | 100 STK b/h/l | 100 TTK | 200 STK b/h/l | 200 TTK | DPS | Dump | Sust |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| M1903 | US | 1 | 90 | 52 | 5 | 0.32 | 2/1/2 | 1154 (0) | 2/1/2 | 1154 (0) | 2/1/2 | 1154 (0) | 2/1/2 | 1154 (0) | 2/1/2 | 1154 (0) | 78 | 450 | 49 |
| M1917Enfield | US | 5 | 92 | 50 | 6 | 0.34 | 2/1/2 | 1200 (0) | 2/1/2 | 1200 (0) | 2/1/2 | 1200 (0) | 2/1/2 | 1200 (0) | 2/1/2 | 1200 (0) | 77 | 552 | 52 |
| LeeEnfieldNo4 | UK | 1 | 88 | 55 | 10 | 0.32 | 2/1/2 | 1091 (0) | 2/1/2 | 1091 (0) | 2/1/2 | 1091 (0) | 2/1/2 | 1091 (0) | 2/1/2 | 1091 (0) | 81 | 880 | 60 |
| SMLE | UK | 5 | 86 | 58 | 10 | 0.28 | 2/1/2 | 1034 (0) | 2/1/2 | 1034 (0) | 2/1/2 | 1034 (0) | 2/1/2 | 1034 (0) | 2/1/2 | 1034 (0) | 83 | 860 | 61 |
| MosinNagant | USSR | 1 | 94 | 51 | 5 | 0.32 | 2/1/2 | 1176 (0) | 2/1/2 | 1176 (0) | 2/1/2 | 1176 (0) | 2/1/2 | 1176 (0) | 2/1/2 | 1176 (0) | 80 | 470 | 51 |
| MosinM38 | USSR | 5 | 90 | 48 | 5 | 0.26 | 2/1/2 | 1250 (0) | 2/1/2 | 1250 (0) | 2/1/2 | 1250 (0) | 2/1/2 | 1250 (0) | 2/1/2 | 1250 (0) | 72 | 450 | 47 |
| MAS36 | FR | 1 | 90 | 52 | 5 | 0.30 | 2/1/2 | 1154 (0) | 2/1/2 | 1154 (0) | 2/1/2 | 1154 (0) | 2/1/2 | 1154 (0) | 2/1/2 | 1154 (0) | 78 | 450 | 49 |
| Lebel1886 | FR | 5 | 95 | 46 | 8 | 0.36 | 2/1/2 | 1304 (0) | 2/1/2 | 1304 (0) | 2/1/2 | 1304 (0) | 2/1/2 | 1304 (0) | 2/1/2 | 1304 (0) | 73 | 760 | 50 |
| Kar98k | DE | 1 | 90 | 52 | 5 | 0.32 | 2/1/2 | 1154 (0) | 2/1/2 | 1154 (0) | 2/1/2 | 1154 (0) | 2/1/2 | 1154 (0) | 2/1/2 | 1154 (0) | 78 | 450 | 49 |
| G3340 | DE,IT | 5 | 90 | 54 | 5 | 0.26 | 2/1/2 | 1111 (0) | 2/1/2 | 1111 (0) | 2/1/2 | 1111 (0) | 2/1/2 | 1111 (0) | 2/1/2 | 1111 (0) | 81 | 450 | 50 |
| ArisakaType99 | JP | 1 | 90 | 52 | 5 | 0.32 | 2/1/2 | 1154 (0) | 2/1/2 | 1154 (0) | 2/1/2 | 1154 (0) | 2/1/2 | 1154 (0) | 2/1/2 | 1154 (0) | 78 | 450 | 49 |
| ArisakaType38 | JP | 5 | 86 | 52 | 5 | 0.32 | 2/1/2 | 1154 (0) | 2/1/2 | 1154 (0) | 2/1/2 | 1154 (0) | 2/1/2 | 1154 (0) | 2/1/2 | 1154 (0) | 75 | 430 | 47 |
| CarcanoM9138 | IT | 1 | 88 | 54 | 6 | 0.29 | 2/1/2 | 1111 (0) | 2/1/2 | 1111 (0) | 2/1/2 | 1111 (0) | 2/1/2 | 1111 (0) | 2/1/2 | 1111 (0) | 79 | 528 | 57 |
| CarcanoM91 | IT | 5 | 92 | 52 | 6 | 0.36 | 2/1/2 | 1154 (0) | 2/1/2 | 1154 (0) | 2/1/2 | 1154 (0) | 2/1/2 | 1154 (0) | 2/1/2 | 1154 (0) | 80 | 552 | 58 |

### Sniper

| Weapon | Fac | Lvl | Dmg | RPM | Mag | ADS s | 10 STK b/h/l | 10 TTK | 25 STK b/h/l | 25 TTK | 50 STK b/h/l | 50 TTK | 100 STK b/h/l | 100 TTK | 200 STK b/h/l | 200 TTK | DPS | Dump | Sust |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| M1903A4 | US | 1 | 95 | 48 | 5 | 0.45 | 2/1/2 | 1250 (0) | 2/1/2 | 1250 (0) | 2/1/2 | 1250 (0) | 2/1/2 | 1250 (0) | 2/1/2 | 1250 (0) | 76 | 475 | 47 |
| M1C | US | 14 | 55 | 150 | 8 | 0.45 | 2/2/3 | 400 (400) | 2/2/3 | 400 (400) | 2/2/3 | 400 (400) | 2/2/3 | 400 (400) | 2/2/3 | 400 (400) | 138 | 440 | 79 |
| LeeEnfieldNo4T | UK | 1 | 95 | 52 | 10 | 0.45 | 2/1/2 | 1154 (0) | 2/1/2 | 1154 (0) | 2/1/2 | 1154 (0) | 2/1/2 | 1154 (0) | 2/1/2 | 1154 (0) | 82 | 950 | 62 |
| MosinPU | USSR | 1 | 95 | 48 | 5 | 0.45 | 2/1/2 | 1250 (0) | 2/1/2 | 1250 (0) | 2/1/2 | 1250 (0) | 2/1/2 | 1250 (0) | 2/1/2 | 1250 (0) | 76 | 475 | 47 |
| SVT40Sniper | USSR | 14 | 55 | 150 | 10 | 0.45 | 2/2/3 | 400 (400) | 2/2/3 | 400 (400) | 2/2/3 | 400 (400) | 2/2/3 | 400 (400) | 2/2/3 | 400 (400) | 138 | 550 | 76 |
| MAS36Scoped | FR | 1 | 95 | 50 | 5 | 0.42 | 2/1/2 | 1200 (0) | 2/1/2 | 1200 (0) | 2/1/2 | 1200 (0) | 2/1/2 | 1200 (0) | 2/1/2 | 1200 (0) | 79 | 475 | 48 |
| Kar98kZF39 | DE | 1 | 95 | 48 | 5 | 0.45 | 2/1/2 | 1250 (0) | 2/1/2 | 1250 (0) | 2/1/2 | 1250 (0) | 2/1/2 | 1250 (0) | 2/1/2 | 1250 (0) | 76 | 475 | 47 |
| Gewehr43ZF4 | DE | 14 | 55 | 150 | 10 | 0.45 | 2/2/3 | 400 (400) | 2/2/3 | 400 (400) | 2/2/3 | 400 (400) | 2/2/3 | 400 (400) | 2/2/3 | 400 (400) | 138 | 550 | 77 |
| Type97Sniper | JP | 1 | 95 | 50 | 5 | 0.45 | 2/1/2 | 1200 (0) | 2/1/2 | 1200 (0) | 2/1/2 | 1200 (0) | 2/1/2 | 1200 (0) | 2/1/2 | 1200 (0) | 79 | 475 | 48 |
| Type99Sniper | JP | 14 | 98 | 46 | 5 | 0.45 | 2/1/2 | 1304 (0) | 2/1/2 | 1304 (0) | 2/1/2 | 1304 (0) | 2/1/2 | 1304 (0) | 2/1/2 | 1304 (0) | 75 | 490 | 47 |
| CarcanoScoped | IT | 1 | 95 | 52 | 6 | 0.45 | 2/1/2 | 1154 (0) | 2/1/2 | 1154 (0) | 2/1/2 | 1154 (0) | 2/1/2 | 1154 (0) | 2/1/2 | 1154 (0) | 82 | 570 | 59 |

### Shotgun

| Weapon | Fac | Lvl | Dmg | RPM | Mag | ADS s | 10 STK b/h/l | 10 TTK | 25 STK b/h/l | 25 TTK | 50 STK b/h/l | 50 TTK | 100 STK b/h/l | 100 TTK | 200 STK b/h/l | 200 TTK | DPS | Dump | Sust |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| M1897Trench | US,UK | 1 | 19x9 | 100 | 6 | 0.26 | 1/1/1 | 0 (0) | 5/4/5 | 2400 (1800) | -/-/- | - (-) | -/-/- | - (-) | -/-/- | - (-) | 244 | 879 | 121 |
| Ithaca37 | US | 10 | 19x9 | 105 | 5 | 0.22 | 1/1/1 | 0 (0) | 4/3/4 | 1714 (1143) | -/-/- | - (-) | -/-/- | - (-) | -/-/- | - (-) | 257 | 733 | 123 |
| BrowningAuto5 | US,UK,FR,DE,IT | 18 | 16x9 | 160 | 5 | 0.26 | 1/1/1 | 0 (0) | 5/4/6 | 1500 (1125) | -/-/- | - (-) | -/-/- | - (-) | -/-/- | - (-) | 329 | 617 | 124 |
| TOZDouble | USSR | 1 | 21x9 | 105 | 2 | 0.26 | 1/1/1 | 0 (0) | 4/3/4 | 3443 (2871) | -/-/- | - (-) | -/-/- | - (-) | -/-/- | - (-) | 284 | 324 | 94 |
| RobustDouble | FR | 1 | 21x9 | 105 | 2 | 0.26 | 1/1/1 | 0 (0) | 4/3/4 | 3343 (2771) | -/-/- | - (-) | -/-/- | - (-) | -/-/- | - (-) | 284 | 324 | 97 |
| DrillingM30 | DE | 1 | 20x9 | 105 | 2 | 0.26 | 1/1/1 | 0 (0) | 4/3/4 | 3543 (2971) | -/-/- | - (-) | -/-/- | - (-) | -/-/- | - (-) | 270 | 309 | 87 |
| Lupara | IT,JP | 1 | 22x9 | 108 | 2 | 0.18 | 1/1/1 | 0 (0) | 11/9/12 | 12778 (10222) | -/-/- | - (-) | -/-/- | - (-) | -/-/- | - (-) | 267 | 297 | 95 |

### Pistol

| Weapon | Fac | Lvl | Dmg | RPM | Mag | ADS s | 10 STK b/h/l | 10 TTK | 25 STK b/h/l | 25 TTK | 50 STK b/h/l | 50 TTK | 100 STK b/h/l | 100 TTK | 200 STK b/h/l | 200 TTK | DPS | Dump | Sust |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| M1911 | US,FR | 1 | 40 | 290 | 7 | 0.16 | 3/2/3 | 414 (207) | 3/2/3 | 414 (207) | 4/2/4 | 621 (207) | 5/3/5 | 828 (414) | 5/3/5 | 828 (414) | 193 | 280 | 79 |
| SWVictory | US,UK | 10 | 45 | 260 | 6 | 0.16 | 3/2/3 | 462 (231) | 3/2/3 | 462 (231) | 3/2/4 | 462 (231) | 4/3/5 | 692 (462) | 4/3/5 | 692 (462) | 195 | 270 | 68 |
| WebleyMkIV | UK | 1 | 45 | 280 | 6 | 0.16 | 3/2/3 | 429 (214) | 3/2/3 | 429 (214) | 3/2/4 | 429 (214) | 4/3/5 | 643 (429) | 4/3/5 | 643 (429) | 210 | 270 | 77 |
| HiPower | UK,FR,DE | 16 | 30 | 420 | 13 | 0.16 | 4/3/4 | 429 (286) | 4/3/4 | 429 (286) | 5/3/5 | 571 (286) | 6/4/7 | 714 (429) | 6/4/7 | 714 (429) | 210 | 390 | 99 |
| TT33 | USSR | 1 | 34 | 290 | 8 | 0.16 | 3/2/4 | 414 (207) | 3/2/4 | 414 (207) | 4/3/5 | 621 (414) | 5/4/6 | 828 (621) | 5/4/6 | 828 (621) | 164 | 272 | 72 |
| NagantM1895 | USSR | 8 | 42 | 240 | 7 | 0.16 | 3/2/3 | 500 (250) | 3/2/3 | 500 (250) | 3/2/4 | 500 (250) | 4/3/5 | 750 (500) | 4/3/5 | 750 (500) | 168 | 294 | 57 |
| MABD | FR | 1 | 30 | 450 | 9 | 0.16 | 4/3/4 | 400 (267) | 4/3/4 | 400 (267) | 5/3/5 | 533 (267) | 6/4/7 | 667 (400) | 6/4/7 | 667 (400) | 225 | 270 | 82 |
| MAS1935A | FR | 8 | 32 | 420 | 8 | 0.16 | 4/2/4 | 429 (143) | 4/2/4 | 429 (143) | 4/3/5 | 429 (286) | 6/4/6 | 714 (429) | 6/4/6 | 714 (429) | 224 | 256 | 79 |
| P38 | DE,IT | 1 | 34 | 290 | 8 | 0.16 | 3/2/4 | 414 (207) | 3/2/4 | 414 (207) | 4/3/5 | 621 (414) | 5/4/6 | 828 (621) | 5/4/6 | 828 (621) | 164 | 272 | 72 |
| LugerP08 | DE | 8 | 34 | 280 | 8 | 0.16 | 3/2/4 | 429 (214) | 3/2/4 | 429 (214) | 4/3/5 | 643 (429) | 5/4/6 | 857 (643) | 5/4/6 | 857 (643) | 159 | 272 | 71 |
| MauserM712 | DE,IT | 24 | 24 | 600 | 20 | 0.16 | 5/3/5 | 400 (200) | 5/3/5 | 400 (200) | 6/4/6 | 500 (300) | 7/5/8 | 600 (400) | 7/5/8 | 600 (400) | 240 | 480 | 100 |
| NambuType14 | JP | 1 | 31 | 420 | 8 | 0.16 | 4/3/4 | 429 (286) | 4/3/4 | 429 (286) | 5/3/5 | 571 (286) | 6/4/6 | 714 (429) | 6/4/6 | 714 (429) | 217 | 248 | 76 |
| Type94Pistol | JP | 8 | 30 | 450 | 6 | 0.14 | 4/3/4 | 400 (267) | 4/3/4 | 400 (267) | 5/3/5 | 533 (267) | 6/4/7 | 667 (400) | 6/4/7 | 667 (400) | 225 | 180 | 67 |
| Type26Revolver | JP | 16 | 44 | 260 | 6 | 0.16 | 3/2/3 | 462 (231) | 3/2/3 | 462 (231) | 3/2/4 | 462 (231) | 4/3/5 | 692 (462) | 4/3/5 | 692 (462) | 191 | 264 | 70 |
| BerettaM1934 | IT | 1 | 31 | 440 | 7 | 0.16 | 4/3/4 | 409 (273) | 4/3/4 | 409 (273) | 5/3/5 | 545 (273) | 6/4/6 | 682 (409) | 6/4/6 | 682 (409) | 227 | 217 | 71 |
| GlisentiM1910 | IT | 8 | 28 | 420 | 7 | 0.16 | 4/3/4 | 429 (286) | 4/3/4 | 429 (286) | 5/3/5 | 571 (286) | 6/4/7 | 714 (429) | 6/4/7 | 714 (429) | 196 | 196 | 63 |

### AntiTank

| Weapon | Fac | Lvl | Dmg | RPM | Mag | ADS s | 10 STK b/h/l | 10 TTK | 25 STK b/h/l | 25 TTK | 50 STK b/h/l | 50 TTK | 100 STK b/h/l | 100 TTK | 200 STK b/h/l | 200 TTK | DPS | Dump | Sust |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| BoysATRifle | UK | 10 | 90 | 40 | 5 | 0.55 | 2/1/2 | 1500 (0) | 2/1/2 | 1500 (0) | 2/1/2 | 1500 (0) | 2/1/2 | 1500 (0) | 2/1/2 | 1500 (0) | 60 | 450 | 41 |
| PTRD41 | USSR | 10 | 90 | 30 | 1 | 0.55 | 2/1/2 | 2600 (0) | 2/1/2 | 2600 (0) | 2/1/2 | 2600 (0) | 2/1/2 | 2600 (0) | 2/1/2 | 2600 (0) | 45 | 90 | 20 |
| PzB39 | DE | 18 | 90 | 30 | 1 | 0.55 | 2/1/2 | 2000 (0) | 2/1/2 | 2000 (0) | 2/1/2 | 2000 (0) | 2/1/2 | 2000 (0) | 2/1/2 | 2000 (0) | 45 | 90 | 22 |
| Type97ATRifle | JP | 18 | 90 | 60 | 7 | 0.55 | 2/1/2 | 1000 (0) | 2/1/2 | 1000 (0) | 2/1/2 | 1000 (0) | 2/1/2 | 1000 (0) | 2/1/2 | 1000 (0) | 90 | 630 | 54 |
| SolothurnS18 | IT,DE | 12 | 90 | 60 | 10 | 0.55 | 2/1/2 | 1000 (0) | 2/1/2 | 1000 (0) | 2/1/2 | 1000 (0) | 2/1/2 | 1000 (0) | 2/1/2 | 1000 (0) | 90 | 900 | 61 |

## Faction parity (best level-1 option per category)

| Category | @studs | US | UK | USSR | FR | DE | JP | IT | spread |
|---|---|---|---|---|---|---|---|---|---|
| SMG | 25 | ThompsonM1A1 281 | StenMkII 300 | PPSh41 282 | MAS38 290 | MP40 300 | Type100 300 | BerettaM38A 300 | 7% |
| AssaultRifle | 50 | M2Carbine 277 | M2Carbine 277 | AVS36 286 | M2Carbine 277 | StG44 300 | StG44 300 | StG44 300 | 8% |
| MachineGun | 50 | BAR 279 | Bren 273 | DP27 267 | FM2429 267 | MG34 277 | Type96LMG 273 | Breda30 279 | 5% |
| SemiAuto | 50 | M1Carbine 375 | M1Carbine 375 | SVT40 400 | M1Carbine 375 | Gewehr43 400 | Type5Rifle 400 | Armaguerra39 375 | 7% |
| BoltAction | 100 | M1903 1154 | LeeEnfieldNo4 1091 | MosinNagant 1176 | MAS36 1154 | Kar98k 1154 | ArisakaType99 1154 | CarcanoM9138 1111 | 8% |
| Sniper | 200 | M1903A4 1250 | LeeEnfieldNo4T 1154 | MosinPU 1250 | MAS36Scoped 1200 | Kar98kZF39 1250 | Type97Sniper 1200 | CarcanoScoped 1154 | 8% |
| Shotgun | 15 | M1897Trench 600 | M1897Trench 600 | TOZDouble 571 | RobustDouble 571 | DrillingM30 571 | Lupara 556 | Lupara 556 | 8% |
| Pistol | 10 | M1911 414 | WebleyMkIV 429 | TT33 414 | MABD 400 | P38 414 | NambuType14 429 | BerettaM1934 409 | 7% |

### Unlock side-grade check

| Unlock | Lvl | vs (L1) | TTK ratio @10/25/50/100/200 | ADS | Mag | Verdict |
|---|---|---|---|---|---|---|
| Gewehr41 | 10 | Gewehr43 (DE) | 0.75/0.75/0.75/1.50/1.50 | 0.32 vs 0.28 | 10 vs 10 | side-grade |
| M1941Johnson | 12 | M1Carbine (US) | 1.00/1.00/1.00/1.00/0.67 | 0.28 vs 0.22 | 10 vs 15 | side-grade |
| SVT38 | 14 | SVT40 (USSR) | 0.91/0.91/0.91/0.91/0.91 | 0.31 vs 0.28 | 10 vs 10 | side-grade |
| M1917Enfield | 5 | M1903 (US) | 1.04/1.04/1.04/1.04/1.04 | 0.34 vs 0.32 | 6 vs 5 | side-grade |
| SMLE | 5 | LeeEnfieldNo4 (UK) | 0.95/0.95/0.95/0.95/0.95 | 0.28 vs 0.32 | 10 vs 10 | upgrade (<10%) |
| MosinM38 | 5 | MosinNagant (USSR) | 1.06/1.06/1.06/1.06/1.06 | 0.26 vs 0.32 | 5 vs 5 | side-grade |
| Lebel1886 | 5 | MAS36 (FR) | 1.13/1.13/1.13/1.13/1.13 | 0.36 vs 0.30 | 8 vs 5 | side-grade |
| G3340 | 5 | Kar98k (DE) | 0.96/0.96/0.96/0.96/0.96 | 0.26 vs 0.32 | 5 vs 5 | upgrade (<10%) |
| ArisakaType38 | 5 | ArisakaType99 (JP) | 1.00/1.00/1.00/1.00/1.00 | 0.32 vs 0.32 | 5 vs 5 | upgrade (<10%) |
| CarcanoM91 | 5 | CarcanoM9138 (IT) | 1.04/1.04/1.04/1.04/1.04 | 0.36 vs 0.29 | 6 vs 6 | side-grade |
| M1C | 14 | M1903A4 (US) | 0.32/0.32/0.32/0.32/0.32 | 0.45 vs 0.45 | 8 vs 5 | side-grade |
| SVT40Sniper | 14 | MosinPU (USSR) | 0.32/0.32/0.32/0.32/0.32 | 0.45 vs 0.45 | 10 vs 5 | side-grade |
| Gewehr43ZF4 | 14 | Kar98kZF39 (DE) | 0.32/0.32/0.32/0.32/0.32 | 0.45 vs 0.45 | 10 vs 5 | side-grade |
| Type99Sniper | 14 | Type97Sniper (JP) | 1.09/1.09/1.09/1.09/1.09 | 0.45 vs 0.45 | 5 vs 5 | side-grade |
| M3GreaseGun | 5 | ThompsonM1A1 (US) | 1.14/1.14/1.14/1.14/1.14 | 0.18 vs 0.20 | 30 vs 30 | side-grade |
| ThompsonM1928 | 16 | ThompsonM1A1 (US) | 0.91/0.91/0.91/0.91/0.91 | 0.24 vs 0.20 | 50 vs 30 | side-grade |
| Lanchester | 5 | StenMkII (UK) | 1.00/1.00/1.00/1.00/1.00 | 0.24 vs 0.20 | 50 vs 32 | side-grade |
| StenMkV | 20 | StenMkII (UK) | 1.04/1.04/1.04/1.04/1.04 | 0.20 vs 0.20 | 32 vs 32 | side-grade |
| PPS43 | 5 | PPSh41 (USSR) | 0.98/0.98/1.05/1.12/1.12 | 0.18 vs 0.23 | 35 vs 71 | side-grade |
| PPD40 | 18 | PPSh41 (USSR) | 1.06/1.06/1.06/1.06/1.06 | 0.22 vs 0.23 | 71 vs 71 | side-grade |
| MP28 | 5 | MP40 (DE) | 0.97/0.97/0.97/1.16/1.16 | 0.22 vs 0.20 | 32 vs 32 | side-grade |
| MP35 | 18 | MP40 (DE) | 1.00/1.00/1.00/1.20/1.20 | 0.20 vs 0.20 | 32 vs 32 | side-grade |
| Type100Late | 5 | Type100 (JP) | 1.00/1.00/0.75/0.75/0.75 | 0.23 vs 0.20 | 30 vs 30 | side-grade |
| TZ45 | 5 | MP40 (IT) | 1.09/1.09/1.09/1.31/1.31 | 0.18 vs 0.20 | 40 vs 32 | side-grade |
| FNAB43 | 18 | MP40 (IT) | 1.07/1.07/1.07/1.07/1.07 | 0.20 vs 0.20 | 40 vs 32 | side-grade |
| FedorovAvtomat | 12 | AVS36 (USSR) | 1.17/1.17/1.17/1.17/1.04 | 0.26 vs 0.30 | 25 vs 15 | side-grade |
| CharltonAR | 12 | M2Carbine (UK) | 1.08/1.08/1.08/0.81/0.65 | 0.30 vs 0.22 | 10 vs 30 | side-grade |
| BredaPG | 10 | StG44 (IT) | 0.95/0.95/0.95/1.43/1.07 | 0.26 vs 0.26 | 20 vs 30 | side-grade |
| FG42 | 12 | StG44 (DE) | 1.00/1.00/1.00/1.00/1.12 | 0.30 vs 0.26 | 20 vs 30 | side-grade |
| MKb42H | 22 | StG44 (DE) | 1.11/1.11/1.11/1.11/1.11 | 0.28 vs 0.26 | 30 vs 30 | side-grade |
| Ithaca37 | 10 | M1897Trench (US) | 1.00/0.71/-/-/- | 0.22 vs 0.26 | 5 vs 6 | side-grade |
| BrowningAuto5 | 18 | M1897Trench (US) | 1.00/0.62/-/-/- | 0.26 vs 0.26 | 5 vs 6 | side-grade |
| M1919A6 | 5 | BAR (US) | 0.96/0.96/0.96/0.96/1.43 | 0.50 vs 0.36 | 100 vs 20 | side-grade |
| JohnsonLMG | 22 | BAR (US) | 0.93/0.93/0.93/0.93/1.40 | 0.38 vs 0.36 | 25 vs 20 | side-grade |
| LewisGun | 5 | Bren (UK) | 0.98/0.98/0.98/0.98/0.98 | 0.46 vs 0.38 | 47 vs 30 | side-grade |
| VickersBerthier | 22 | Bren (UK) | 0.96/0.96/0.96/0.96/0.96 | 0.42 vs 0.38 | 30 vs 30 | side-grade |
| DS39 | 5 | DP27 (USSR) | 0.96/0.96/0.96/0.96/0.64 | 0.52 vs 0.42 | 100 vs 47 | side-grade |
| RPD44 | 22 | DP27 (USSR) | 1.04/1.04/1.04/1.04/0.69 | 0.36 vs 0.42 | 100 vs 47 | side-grade |
| Chauchat | 5 | FM2429 (FR) | 1.25/1.25/1.25/1.25/0.83 | 0.40 vs 0.38 | 20 vs 25 | side-grade |
| MG42 | 5 | MG34 (DE) | 0.92/0.92/0.92/0.92/1.15 | 0.48 vs 0.42 | 75 vs 50 | side-grade |
| MG15 | 22 | MG34 (DE) | 0.93/0.93/0.93/0.93/1.24 | 0.40 vs 0.42 | 75 vs 50 | side-grade |
| Type99LMG | 5 | Type96LMG (JP) | 0.98/0.98/0.98/0.98/0.98 | 0.42 vs 0.42 | 30 vs 30 | upgrade (<10%) |
| Type11LMG | 18 | Type96LMG (JP) | 1.32/1.32/1.32/1.32/0.88 | 0.42 vs 0.42 | 30 vs 30 | side-grade |
| Breda37 | 12 | Breda30 (IT) | 0.96/0.96/0.96/0.96/0.64 | 0.52 vs 0.38 | 40 vs 20 | side-grade |
| SWVictory | 10 | M1911 (US) | 1.12/1.12/0.74/0.84/0.84 | 0.16 vs 0.16 | 6 vs 7 | side-grade |
| HiPower | 16 | WebleyMkIV (UK) | 1.00/1.00/1.33/1.11/1.11 | 0.16 vs 0.16 | 13 vs 6 | side-grade |
| NagantM1895 | 8 | TT33 (USSR) | 1.21/1.21/0.81/0.91/0.91 | 0.16 vs 0.16 | 7 vs 8 | side-grade |
| MAS1935A | 8 | MABD (FR) | 1.07/1.07/0.80/1.07/1.07 | 0.16 vs 0.16 | 8 vs 9 | side-grade |
| LugerP08 | 8 | P38 (DE) | 1.04/1.04/1.04/1.04/1.04 | 0.16 vs 0.16 | 8 vs 8 | side-grade |
| MauserM712 | 24 | P38 (DE) | 0.97/0.97/0.81/0.73/0.73 | 0.16 vs 0.16 | 20 vs 8 | upgrade (<10%) |
| Type94Pistol | 8 | NambuType14 (JP) | 0.93/0.93/0.93/0.93/0.93 | 0.14 vs 0.16 | 6 vs 8 | side-grade |
| Type26Revolver | 16 | NambuType14 (JP) | 1.08/1.08/0.81/0.97/0.97 | 0.16 vs 0.16 | 6 vs 8 | side-grade |
| GlisentiM1910 | 8 | BerettaM1934 (IT) | 1.05/1.05/1.05/1.05/1.05 | 0.16 vs 0.16 | 7 vs 7 | side-grade |

## Explosives vs infantry

Distances are to the nearest body-part box (CombatService uses distanceToBox), i.e. roughly 1 stud less than to the torso centre. Lethal = >=100 dmg, wound = >=25 dmg.

| Item | Cat | Fac | Lvl | Radius | MaxDmg | Lethal r | 50 dmg r | 25 dmg r | Carried |
|---|---|---|---|---|---|---|---|---|---|
| Mk2 | Grenade | US | 1 | 12 | 150 | 4.5 | 7.2 | 9.1 | 2 |
| MillsBomb | Grenade | UK | 1 | 12 | 150 | 4.5 | 7.2 | 9.1 | 2 |
| RGD33 | Grenade | USSR | 1 | 13 | 145 | 4.7 | 7.7 | 9.8 | 2 |
| F1Grenade | Grenade | FR | 1 | 12.5 | 150 | 4.7 | 7.5 | 9.5 | 2 |
| M24 | Grenade | DE | 1 | 12 | 150 | 4.5 | 7.2 | 9.1 | 2 |
| Type97Grenade | Grenade | JP | 1 | 12 | 150 | 4.5 | 7.2 | 9.1 | 2 |
| OTOMod35 | Grenade | IT | 1 | 10 | 130 | 3.2 | 5.6 | 7.3 | 2 |
| M39Egg | Grenade | DE,IT | 10 | 11 | 145 | 4.0 | 6.5 | 8.3 | 3 |
| RG42 | Grenade | USSR | 10 | 11 | 145 | 4.0 | 6.5 | 8.3 | 3 |
| Gammon82 | Grenade | UK,US | 16 | 12 | 170 | 5.1 | 7.6 | 9.3 | 1 |
| Type99Grenade | Grenade | JP | 10 | 11 | 145 | 4.0 | 6.5 | 8.3 | 3 |
| SRCMMod35 | Grenade | IT | 10 | 10 | 125 | 3.0 | 5.5 | 7.2 | 3 |
| F1Limonka | Grenade | USSR | 18 | 14 | 150 | 5.3 | 8.4 | 10.6 | 2 |
| SatchelCharge | Explosive | ALL | 1 | 18 | 220 | 9.2 | 12.5 | 14.7 | 2 |
| GeballteLadung | Explosive | DE,IT | 8 | 17 | 210 | 8.5 | 11.7 | 13.8 | 2 |
| StickyBomb | Explosive | UK,FR | 8 | 14 | 200 | 6.7 | 9.4 | 11.3 | 1 |
| Type99Magnetic | Explosive | JP | 8 | 14 | 200 | 6.7 | 9.4 | 11.3 | 2 |
| C2Demolition | Explosive | US,USSR | 12 | 20 | 240 | 10.8 | 14.3 | 16.6 | 1 |
| M1A1Bazooka | AntiTank | US,FR | 1 | 9 | 130 | 2.9 | 5.1 | 6.6 | 1 |
| M9Bazooka | AntiTank | US,FR | 14 | 9 | 130 | 2.9 | 5.1 | 6.6 | 1 |
| PIAT | AntiTank | UK,FR | 1 | 9 | 130 | 2.9 | 5.1 | 6.6 | 1 |
| RPG40 | AntiTank | USSR | 1 | 8 | 120 | 2.3 | 4.3 | 5.7 | 2 |
| RPG43 | AntiTank | USSR | 18 | 8 | 110 | 2.0 | 4.1 | 5.6 | 1 |
| Panzerfaust | AntiTank | DE,IT | 1 | 9 | 130 | 2.9 | 5.1 | 6.6 | 1 |
| Panzerschreck | AntiTank | DE | 10 | 9 | 130 | 2.9 | 5.1 | 6.6 | 1 |
| Type3AT | AntiTank | JP | 1 | 8 | 120 | 2.3 | 4.3 | 5.7 | 2 |
| LungeMine | AntiTank | JP | 10 | 7 | 140 | 2.4 | 4.1 | 5.2 | 1 |

## Vehicles

### Infantry anti-tank: hits to kill (front/side/rear)

Direct hits; damage = vehicleDamage x EXPLOSIVE_FACING_MULT (front 0.6, side 1, rear 1.4).

| Vehicle | Class | HP | SatchelCharge (450) | GeballteLadung (380) | StickyBomb (500) | Type99Magnetic (520) | C2Demolition (550) | M1A1Bazooka (580) | M9Bazooka (570) | PIAT (600) | RPG40 (600) | RPG43 (630) | Panzerfaust (700) | Panzerschreck (615) | Type3AT (600) | LungeMine (760) |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| M4Sherman | Tank | 2000 | 8/5/4 | 9/6/4 | 7/4/3 | 7/4/3 | 7/4/3 | 6/4/3 | 6/4/3 | 6/4/3 | 6/4/3 | 6/4/3 | 5/3/3 | 6/4/3 | 6/4/3 | 5/3/2 |
| M5Stuart | Light | 1100 | 5/3/2 | 5/3/3 | 4/3/2 | 4/3/2 | 4/2/2 | 4/2/2 | 4/2/2 | 4/2/2 | 4/2/2 | 3/2/2 | 3/2/2 | 3/2/2 | 4/2/2 | 3/2/2 |
| M8Greyhound | Light | 1100 | 5/3/2 | 5/3/3 | 4/3/2 | 4/3/2 | 4/2/2 | 4/2/2 | 4/2/2 | 4/2/2 | 4/2/2 | 3/2/2 | 3/2/2 | 3/2/2 | 4/2/2 | 3/2/2 |
| Cromwell | Tank | 1900 | 8/5/4 | 9/5/4 | 7/4/3 | 7/4/3 | 6/4/3 | 6/4/3 | 6/4/3 | 6/4/3 | 6/4/3 | 6/4/3 | 5/3/2 | 6/4/3 | 6/4/3 | 5/3/2 |
| Churchill | Tank | 2600 | 10/6/5 | 12/7/5 | 9/6/4 | 9/5/4 | 8/5/4 | 8/5/4 | 8/5/4 | 8/5/4 | 8/5/4 | 7/5/3 | 7/4/3 | 8/5/4 | 8/5/4 | 6/4/3 |
| DaimlerAC | Light | 1100 | 5/3/2 | 5/3/3 | 4/3/2 | 4/3/2 | 4/2/2 | 4/2/2 | 4/2/2 | 4/2/2 | 4/2/2 | 3/2/2 | 3/2/2 | 3/2/2 | 4/2/2 | 3/2/2 |
| T34_85 | Tank | 2000 | 8/5/4 | 9/6/4 | 7/4/3 | 7/4/3 | 7/4/3 | 6/4/3 | 6/4/3 | 6/4/3 | 6/4/3 | 6/4/3 | 5/3/3 | 6/4/3 | 6/4/3 | 5/3/2 |
| KV1 | Tank | 2600 | 10/6/5 | 12/7/5 | 9/6/4 | 9/5/4 | 8/5/4 | 8/5/4 | 8/5/4 | 8/5/4 | 8/5/4 | 7/5/3 | 7/4/3 | 8/5/4 | 8/5/4 | 6/4/3 |
| BA64 | Light | 900 | 4/2/2 | 4/3/2 | 3/2/2 | 3/2/2 | 3/2/2 | 3/2/2 | 3/2/2 | 3/2/2 | 3/2/2 | 3/2/2 | 3/2/1 | 3/2/2 | 3/2/2 | 2/2/1 |
| CharB1 | Tank | 2000 | 8/5/4 | 9/6/4 | 7/4/3 | 7/4/3 | 7/4/3 | 6/4/3 | 6/4/3 | 6/4/3 | 6/4/3 | 6/4/3 | 5/3/3 | 6/4/3 | 6/4/3 | 5/3/2 |
| SomuaS35 | Tank | 1900 | 8/5/4 | 9/5/4 | 7/4/3 | 7/4/3 | 6/4/3 | 6/4/3 | 6/4/3 | 6/4/3 | 6/4/3 | 6/4/3 | 5/3/2 | 6/4/3 | 6/4/3 | 5/3/2 |
| Panhard178 | Light | 1100 | 5/3/2 | 5/3/3 | 4/3/2 | 4/3/2 | 4/2/2 | 4/2/2 | 4/2/2 | 4/2/2 | 4/2/2 | 3/2/2 | 3/2/2 | 3/2/2 | 4/2/2 | 3/2/2 |
| PanzerIV | Tank | 1900 | 8/5/4 | 9/5/4 | 7/4/3 | 7/4/3 | 6/4/3 | 6/4/3 | 6/4/3 | 6/4/3 | 6/4/3 | 6/4/3 | 5/3/2 | 6/4/3 | 6/4/3 | 5/3/2 |
| Panther | Tank | 2200 | 9/5/4 | 10/6/5 | 8/5/4 | 8/5/4 | 7/4/3 | 7/4/3 | 7/4/3 | 7/4/3 | 7/4/3 | 6/4/3 | 6/4/3 | 6/4/3 | 7/4/3 | 5/3/3 |
| TigerI | Tank | 2600 | 10/6/5 | 12/7/5 | 9/6/4 | 9/5/4 | 8/5/4 | 8/5/4 | 8/5/4 | 8/5/4 | 8/5/4 | 7/5/3 | 7/4/3 | 8/5/4 | 8/5/4 | 6/4/3 |
| SdKfz222 | Light | 1000 | 4/3/2 | 5/3/2 | 4/2/2 | 4/2/2 | 4/2/2 | 3/2/2 | 3/2/2 | 3/2/2 | 3/2/2 | 3/2/2 | 3/2/2 | 3/2/2 | 3/2/2 | 3/2/1 |
| ChiHa | Tank | 1900 | 8/5/4 | 9/5/4 | 7/4/3 | 7/4/3 | 6/4/3 | 6/4/3 | 6/4/3 | 6/4/3 | 6/4/3 | 6/4/3 | 5/3/2 | 6/4/3 | 6/4/3 | 5/3/2 |
| HaGo | Light | 1100 | 5/3/2 | 5/3/3 | 4/3/2 | 4/3/2 | 4/2/2 | 4/2/2 | 4/2/2 | 4/2/2 | 4/2/2 | 3/2/2 | 3/2/2 | 3/2/2 | 4/2/2 | 3/2/2 |
| M13_40 | Tank | 1900 | 8/5/4 | 9/5/4 | 7/4/3 | 7/4/3 | 6/4/3 | 6/4/3 | 6/4/3 | 6/4/3 | 6/4/3 | 6/4/3 | 5/3/2 | 6/4/3 | 6/4/3 | 5/3/2 |
| L6_40 | Light | 1100 | 5/3/2 | 5/3/3 | 4/3/2 | 4/3/2 | 4/2/2 | 4/2/2 | 4/2/2 | 4/2/2 | 4/2/2 | 3/2/2 | 3/2/2 | 3/2/2 | 4/2/2 | 3/2/2 |
| AB41 | Light | 1100 | 5/3/2 | 5/3/3 | 4/3/2 | 4/3/2 | 4/2/2 | 4/2/2 | 4/2/2 | 4/2/2 | 4/2/2 | 3/2/2 | 3/2/2 | 3/2/2 | 4/2/2 | 3/2/2 |

### Tank guns: AP shots to kill (front/side/rear) and time to kill (s, side)

Front shots assume 25 deg obliquity, side 10, rear 0. `n` marks a non-penetration (10 % damage).

| Shooter \ Target | pen/dmg/rl | M4Sherman | M5Stuart | M8Greyhound | Cromwell | Churchill | DaimlerAC | T34_85 | KV1 | BA64 | CharB1 | SomuaS35 | Panhard178 | PanzerIV | Panther | TigerI | SdKfz222 | ChiHa | HaGo | M13_40 | L6_40 | AB41 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| M4Sherman | 110/600/4.2 | 4/3/2 (8s) | 2/2/2 (4s) | 2/2/2 (4s) | 4/3/2 (8s) | 44n/4/3 (13s) | 2/2/2 (4s) | 4/3/2 (8s) | 44n/4/3 (13s) | 2/2/1 (4s) | 4/3/2 (8s) | 4/3/2 (8s) | 2/2/2 (4s) | 4/3/2 (8s) | 37n/3/3 (8s) | 44n/4/3 (13s) | 2/2/1 (4s) | 4/3/2 (8s) | 2/2/2 (4s) | 4/3/2 (8s) | 2/2/2 (4s) | 2/2/2 (4s) |
| M5Stuart | 60/330/2.4 | 61n/5/4 (10s) | 4/3/2 (5s) | 4/3/2 (5s) | 58n/5/4 (10s) | 79n/79n/5 (187s) | 4/3/2 (5s) | 61n/5/4 (10s) | 79n/79n/79n (187s) | 3/3/2 (5s) | 61n/5/4 (10s) | 58n/5/4 (10s) | 4/3/2 (5s) | 58n/5/4 (10s) | 67n/6/4 (12s) | 79n/79n/5 (187s) | 4/3/2 (5s) | 58n/5/4 (10s) | 4/3/2 (5s) | 58n/5/4 (10s) | 4/3/2 (5s) | 4/3/2 (5s) |
| M8Greyhound | 60/330/2.4 | 61n/5/4 (10s) | 4/3/2 (5s) | 4/3/2 (5s) | 58n/5/4 (10s) | 79n/79n/5 (187s) | 4/3/2 (5s) | 61n/5/4 (10s) | 79n/79n/79n (187s) | 3/3/2 (5s) | 61n/5/4 (10s) | 58n/5/4 (10s) | 4/3/2 (5s) | 58n/5/4 (10s) | 67n/6/4 (12s) | 79n/79n/5 (187s) | 4/3/2 (5s) | 58n/5/4 (10s) | 4/3/2 (5s) | 58n/5/4 (10s) | 4/3/2 (5s) | 4/3/2 (5s) |
| M1_57mm | 110/560/4 | 4/3/3 (8s) | 2/2/2 (4s) | 2/2/2 (4s) | 4/3/2 (8s) | 47n/4/3 (12s) | 2/2/2 (4s) | 4/3/3 (8s) | 47n/4/3 (12s) | 2/2/1 (4s) | 4/3/3 (8s) | 4/3/2 (8s) | 2/2/2 (4s) | 4/3/2 (8s) | 40n/4/3 (12s) | 47n/4/3 (12s) | 2/2/2 (4s) | 4/3/2 (8s) | 2/2/2 (4s) | 4/3/2 (8s) | 2/2/2 (4s) | 2/2/2 (4s) |
| Cromwell | 110/600/4 | 4/3/2 (8s) | 2/2/2 (4s) | 2/2/2 (4s) | 4/3/2 (8s) | 44n/4/3 (12s) | 2/2/2 (4s) | 4/3/2 (8s) | 44n/4/3 (12s) | 2/2/1 (4s) | 4/3/2 (8s) | 4/3/2 (8s) | 2/2/2 (4s) | 4/3/2 (8s) | 37n/3/3 (8s) | 44n/4/3 (12s) | 2/2/1 (4s) | 4/3/2 (8s) | 2/2/2 (4s) | 4/3/2 (8s) | 2/2/2 (4s) | 2/2/2 (4s) |
| Churchill | 110/600/4.6 | 4/3/2 (9s) | 2/2/2 (5s) | 2/2/2 (5s) | 4/3/2 (9s) | 44n/4/3 (14s) | 2/2/2 (5s) | 4/3/2 (9s) | 44n/4/3 (14s) | 2/2/1 (5s) | 4/3/2 (9s) | 4/3/2 (9s) | 2/2/2 (5s) | 4/3/2 (9s) | 37n/3/3 (9s) | 44n/4/3 (14s) | 2/2/1 (5s) | 4/3/2 (9s) | 2/2/2 (5s) | 4/3/2 (9s) | 2/2/2 (5s) | 2/2/2 (5s) |
| DaimlerAC | 70/340/2.5 | 59n/5/4 (10s) | 4/3/2 (5s) | 4/3/2 (5s) | 56n/5/4 (10s) | 77n/77n/5 (190s) | 4/3/2 (5s) | 59n/5/4 (10s) | 77n/77n/5 (190s) | 3/3/2 (5s) | 59n/5/4 (10s) | 56n/5/4 (10s) | 4/3/2 (5s) | 56n/5/4 (10s) | 65n/6/4 (12s) | 77n/77n/5 (190s) | 3/3/2 (5s) | 56n/5/4 (10s) | 4/3/2 (5s) | 56n/5/4 (10s) | 4/3/2 (5s) | 4/3/2 (5s) |
| QF6Pounder | 110/550/3.8 | 4/3/3 (8s) | 2/2/2 (4s) | 2/2/2 (4s) | 4/3/3 (8s) | 48n/4/3 (11s) | 2/2/2 (4s) | 4/3/3 (8s) | 48n/4/3 (11s) | 2/2/1 (4s) | 4/3/3 (8s) | 4/3/3 (8s) | 2/2/2 (4s) | 4/3/3 (8s) | 40n/4/3 (11s) | 48n/4/3 (11s) | 2/2/2 (4s) | 4/3/3 (8s) | 2/2/2 (4s) | 4/3/3 (8s) | 2/2/2 (4s) | 2/2/2 (4s) |
| T34_85 | 135/650/5.2 | 4/3/2 (10s) | 2/2/1 (5s) | 2/2/1 (5s) | 3/3/2 (10s) | 40n/4/3 (16s) | 2/2/1 (5s) | 4/3/2 (10s) | 40n/4/3 (16s) | 2/2/1 (5s) | 4/3/2 (10s) | 3/3/2 (10s) | 2/2/1 (5s) | 3/3/2 (10s) | 34n/3/2 (10s) | 40n/4/3 (16s) | 2/2/1 (5s) | 3/3/2 (10s) | 2/2/1 (5s) | 3/3/2 (10s) | 2/2/1 (5s) | 2/2/1 (5s) |
| KV1 | 110/600/5 | 4/3/2 (10s) | 2/2/2 (5s) | 2/2/2 (5s) | 4/3/2 (10s) | 44n/4/3 (15s) | 2/2/2 (5s) | 4/3/2 (10s) | 44n/4/3 (15s) | 2/2/1 (5s) | 4/3/2 (10s) | 4/3/2 (10s) | 2/2/2 (5s) | 4/3/2 (10s) | 37n/3/3 (10s) | 44n/4/3 (15s) | 2/2/1 (5s) | 4/3/2 (10s) | 2/2/2 (5s) | 4/3/2 (10s) | 2/2/2 (5s) | 2/2/2 (5s) |
| ZiS3 | 110/580/4.2 | 4/3/3 (8s) | 2/2/2 (4s) | 2/2/2 (4s) | 4/3/2 (8s) | 45n/4/3 (13s) | 2/2/2 (4s) | 4/3/3 (8s) | 45n/4/3 (13s) | 2/2/1 (4s) | 4/3/3 (8s) | 4/3/2 (8s) | 2/2/2 (4s) | 4/3/2 (8s) | 38n/4/3 (13s) | 45n/4/3 (13s) | 2/2/2 (4s) | 4/3/2 (8s) | 2/2/2 (4s) | 4/3/2 (8s) | 2/2/2 (4s) | 2/2/2 (4s) |
| CharB1 | 110/600/4.4 | 4/3/2 (9s) | 2/2/2 (4s) | 2/2/2 (4s) | 4/3/2 (9s) | 44n/4/3 (13s) | 2/2/2 (4s) | 4/3/2 (9s) | 44n/4/3 (13s) | 2/2/1 (4s) | 4/3/2 (9s) | 4/3/2 (9s) | 2/2/2 (4s) | 4/3/2 (9s) | 37n/3/3 (9s) | 44n/4/3 (13s) | 2/2/1 (4s) | 4/3/2 (9s) | 2/2/2 (4s) | 4/3/2 (9s) | 2/2/2 (4s) | 2/2/2 (4s) |
| SomuaS35 | 110/600/3.6 | 4/3/2 (7s) | 2/2/2 (4s) | 2/2/2 (4s) | 4/3/2 (7s) | 44n/4/3 (11s) | 2/2/2 (4s) | 4/3/2 (7s) | 44n/4/3 (11s) | 2/2/1 (4s) | 4/3/2 (7s) | 4/3/2 (7s) | 2/2/2 (4s) | 4/3/2 (7s) | 37n/3/3 (7s) | 44n/4/3 (11s) | 2/2/1 (4s) | 4/3/2 (7s) | 2/2/2 (4s) | 4/3/2 (7s) | 2/2/2 (4s) | 2/2/2 (4s) |
| Panhard178 | 50/170/3.8 | 118n/10/7 (8s) | 65n/6/4 (3s) | 7/6/4 (3s) | 112n/9/7 (8s) | 153n/153n/153n (165s) | 7/6/4 (3s) | 118n/118n/7 (126s) | 153n/153n/153n (165s) | 6/5/4 (2s) | 118n/118n/7 (126s) | 112n/9/7 (8s) | 7/6/4 (3s) | 112n/9/7 (8s) | 130n/130n/8 (139s) | 153n/153n/153n (165s) | 6/5/4 (2s) | 112n/9/7 (8s) | 7/6/4 (3s) | 112n/9/7 (8s) | 7/6/4 (3s) | 7/6/4 (3s) |
| Canon47 | 110/550/3.2 | 4/3/3 (6s) | 2/2/2 (3s) | 2/2/2 (3s) | 4/3/3 (6s) | 48n/4/3 (10s) | 2/2/2 (3s) | 4/3/3 (6s) | 48n/4/3 (10s) | 2/2/1 (3s) | 4/3/3 (6s) | 4/3/3 (6s) | 2/2/2 (3s) | 4/3/3 (6s) | 40n/4/3 (10s) | 48n/4/3 (10s) | 2/2/2 (3s) | 4/3/3 (6s) | 2/2/2 (3s) | 4/3/3 (6s) | 2/2/2 (3s) | 2/2/2 (3s) |
| PanzerIV | 125/600/4.8 | 4/3/2 (10s) | 2/2/2 (5s) | 2/2/2 (5s) | 4/3/2 (10s) | 44n/4/3 (14s) | 2/2/2 (5s) | 4/3/2 (10s) | 44n/4/3 (14s) | 2/2/1 (5s) | 4/3/2 (10s) | 4/3/2 (10s) | 2/2/2 (5s) | 4/3/2 (10s) | 37n/3/3 (10s) | 44n/4/3 (14s) | 2/2/1 (5s) | 4/3/2 (10s) | 2/2/2 (5s) | 4/3/2 (10s) | 2/2/2 (5s) | 2/2/2 (5s) |
| Panther | 175/620/5.6 | 4/3/2 (11s) | 2/2/2 (6s) | 2/2/2 (6s) | 4/3/2 (11s) | 5/4/3 (17s) | 2/2/2 (6s) | 4/3/2 (11s) | 5/4/3 (17s) | 2/2/1 (6s) | 4/3/2 (11s) | 4/3/2 (11s) | 2/2/2 (6s) | 4/3/2 (11s) | 4/3/3 (11s) | 5/4/3 (17s) | 2/2/1 (6s) | 4/3/2 (11s) | 2/2/2 (6s) | 4/3/2 (11s) | 2/2/2 (6s) | 2/2/2 (6s) |
| TigerI | 160/760/7 | 3/3/2 (14s) | 2/2/1 (7s) | 2/2/1 (7s) | 3/2/2 (7s) | 4/3/3 (14s) | 2/2/1 (7s) | 3/3/2 (14s) | 4/3/3 (14s) | 2/1/1 (0s) | 3/3/2 (14s) | 3/2/2 (7s) | 2/2/1 (7s) | 3/2/2 (7s) | 3/3/2 (14s) | 4/3/3 (14s) | 2/2/1 (7s) | 3/2/2 (7s) | 2/2/1 (7s) | 3/2/2 (7s) | 2/2/1 (7s) | 2/2/1 (7s) |
| SdKfz222 | 38/90/4.5 | 223n/223n/14 (143s) | 123n/10/8 (2s) | 13/10/8 (2s) | 212n/212n/13 (136s) | 289n/289n/289n (183s) | 13/10/8 (2s) | 223n/223n/223n (143s) | 289n/289n/289n (183s) | 10/8/6 (2s) | 223n/223n/223n (143s) | 212n/212n/13 (136s) | 13/10/8 (2s) | 212n/212n/13 (136s) | 245n/245n/245n (156s) | 289n/289n/289n (183s) | 12/9/7 (2s) | 212n/212n/13 (136s) | 13/10/8 (2s) | 212n/212n/13 (136s) | 13/10/8 (2s) | 13/10/8 (2s) |
| Pak40 | 130/620/4.6 | 4/3/2 (9s) | 2/2/2 (5s) | 2/2/2 (5s) | 4/3/2 (9s) | 42n/4/3 (14s) | 2/2/2 (5s) | 4/3/2 (9s) | 42n/4/3 (14s) | 2/2/1 (5s) | 4/3/2 (9s) | 4/3/2 (9s) | 2/2/2 (5s) | 4/3/2 (9s) | 36n/3/3 (9s) | 42n/4/3 (14s) | 2/2/1 (5s) | 4/3/2 (9s) | 2/2/2 (5s) | 4/3/2 (9s) | 2/2/2 (5s) | 2/2/2 (5s) |
| ChiHa | 110/600/4 | 4/3/2 (8s) | 2/2/2 (4s) | 2/2/2 (4s) | 4/3/2 (8s) | 44n/4/3 (12s) | 2/2/2 (4s) | 4/3/2 (8s) | 44n/4/3 (12s) | 2/2/1 (4s) | 4/3/2 (8s) | 4/3/2 (8s) | 2/2/2 (4s) | 4/3/2 (8s) | 37n/3/3 (8s) | 44n/4/3 (12s) | 2/2/1 (4s) | 4/3/2 (8s) | 2/2/2 (4s) | 4/3/2 (8s) | 2/2/2 (4s) | 2/2/2 (4s) |
| HaGo | 45/300/2.4 | 67n/67n/4 (158s) | 37n/3/3 (5s) | 4/3/3 (5s) | 64n/6/4 (12s) | 87n/87n/87n (206s) | 4/3/3 (5s) | 67n/67n/4 (158s) | 87n/87n/87n (206s) | 3/3/2 (5s) | 67n/67n/4 (158s) | 64n/6/4 (12s) | 4/3/3 (5s) | 64n/6/4 (12s) | 74n/74n/5 (175s) | 87n/87n/87n (206s) | 4/3/2 (5s) | 64n/6/4 (12s) | 4/3/3 (5s) | 64n/6/4 (12s) | 4/3/3 (5s) | 4/3/3 (5s) |
| Type1_47mm | 110/550/3.2 | 4/3/3 (6s) | 2/2/2 (3s) | 2/2/2 (3s) | 4/3/3 (6s) | 48n/4/3 (10s) | 2/2/2 (3s) | 4/3/3 (6s) | 48n/4/3 (10s) | 2/2/1 (3s) | 4/3/3 (6s) | 4/3/3 (6s) | 2/2/2 (3s) | 4/3/3 (6s) | 40n/4/3 (10s) | 48n/4/3 (10s) | 2/2/2 (3s) | 4/3/3 (6s) | 2/2/2 (3s) | 4/3/3 (6s) | 2/2/2 (3s) | 2/2/2 (3s) |
| M13_40 | 110/600/4 | 4/3/2 (8s) | 2/2/2 (4s) | 2/2/2 (4s) | 4/3/2 (8s) | 44n/4/3 (12s) | 2/2/2 (4s) | 4/3/2 (8s) | 44n/4/3 (12s) | 2/2/1 (4s) | 4/3/2 (8s) | 4/3/2 (8s) | 2/2/2 (4s) | 4/3/2 (8s) | 37n/3/3 (8s) | 44n/4/3 (12s) | 2/2/1 (4s) | 4/3/2 (8s) | 2/2/2 (4s) | 4/3/2 (8s) | 2/2/2 (4s) | 2/2/2 (4s) |
| L6_40 | 35/95/4 | 211n/211n/211n (152s) | 116n/10/7 (6s) | 12/10/7 (6s) | 200n/200n/12 (142s) | 274n/274n/274n (198s) | 12/10/7 (6s) | 211n/211n/211n (152s) | 274n/274n/274n (198s) | 10/8/6 (2s) | 211n/211n/211n (152s) | 200n/200n/12 (142s) | 12/10/7 (6s) | 200n/200n/12 (142s) | 232n/232n/232n (165s) | 274n/274n/274n (198s) | 11/9/7 (6s) | 200n/200n/12 (142s) | 12/10/7 (6s) | 200n/200n/12 (142s) | 116n/10/7 (6s) | 12/10/7 (6s) |
| AB41 | 35/95/4 | 211n/211n/211n (152s) | 116n/10/7 (6s) | 12/10/7 (6s) | 200n/200n/12 (142s) | 274n/274n/274n (198s) | 12/10/7 (6s) | 211n/211n/211n (152s) | 274n/274n/274n (198s) | 10/8/6 (2s) | 211n/211n/211n (152s) | 200n/200n/12 (142s) | 12/10/7 (6s) | 200n/200n/12 (142s) | 232n/232n/232n (165s) | 274n/274n/274n (198s) | 11/9/7 (6s) | 200n/200n/12 (142s) | 12/10/7 (6s) | 200n/200n/12 (142s) | 116n/10/7 (6s) | 12/10/7 (6s) |
| Cannone47_32 | 110/550/3 | 4/3/3 (6s) | 2/2/2 (3s) | 2/2/2 (3s) | 4/3/3 (6s) | 48n/4/3 (9s) | 2/2/2 (3s) | 4/3/3 (6s) | 48n/4/3 (9s) | 2/2/1 (3s) | 4/3/3 (6s) | 4/3/3 (6s) | 2/2/2 (3s) | 4/3/3 (6s) | 40n/4/3 (9s) | 48n/4/3 (9s) | 2/2/2 (3s) | 4/3/3 (6s) | 2/2/2 (3s) | 4/3/3 (6s) | 2/2/2 (3s) | 2/2/2 (3s) |

### Tank shells vs infantry

| Vehicle | Shell | Direct | Splash r | Splash max | Lethal r |
|---|---|---|---|---|---|
| M4Sherman | AP | 220 | 4.0 | 40 | 0.0 |
| M4Sherman | HE | 300 | 12.0 | 128 | 3.7 |
| M5Stuart | HE | 300 | 5.9 | 63 | 0.0 |
| M1_57mm | HE | 300 | 9.1 | 97 | 0.0 |
| DaimlerAC | HE | 300 | 6.4 | 68 | 0.0 |
| T34_85 | HE | 300 | 13.6 | 144 | 4.9 |
| KV1 | HE | 300 | 12.2 | 129 | 3.8 |
| SomuaS35 | HE | 300 | 7.5 | 80 | 0.0 |
| Panhard178 | AP | 70 | 2.5 | 25 | 0.0 |
| TigerI | HE | 300 | 14.1 | 150 | 5.3 |

## Class loadout coverage (level 1)

Number of level-1 choices per slot (primary/secondary/gadget1/gadget2).

| Class | US | UK | USSR | FR | DE | JP | IT |
|---|---|---|---|---|---|---|---|
| Rifleman | 3/1/1/2 | 2/1/1/2 | 2/1/1/2 | 3/2/1/2 | 2/1/1/2 | 2/1/1/2 | 2/2/1/2 |
| Assault | 3/1/1/1 | 3/1/1/1 | 3/1/1/1 | 4/2/1/1 | 3/1/1/1 | 3/1/1/1 | 4/2/1/1 |
| Support | 1/1/1/1 | 1/1/1/1 | 1/1/1/1 | 2/2/1/1 | 1/1/1/1 | 1/1/1/1 | 1/2/1/1 |
| Medic | 3/1/1/1 | 2/1/1/1 | 2/1/1/1 | 4/2/1/1 | 2/1/1/1 | 2/1/1/1 | 3/2/1/1 |
| Engineer | 3/1/1/2 | 3/1/1/2 | 3/1/1/2 | 4/2/2/2 | 3/1/1/2 | 3/1/1/2 | 4/2/1/2 |
| Recon | 2/1/1/2 | 2/1/1/2 | 2/1/1/2 | 2/2/1/2 | 2/1/1/2 | 2/1/1/2 | 2/2/1/2 |

## Game modes (modelled round length)

Model: 0.7 deaths/player/min, 12% revived; Conquest loser behind by 1.0 point(s) 70% of the time; Frontline 0.3 captures/min, loser makes 35%; TDM 1.0 kills/player/min, 12v12. Conquest/Frontline 16v16.

| Mode | Tickets / limit | Time cap | Drain (tickets/min) | Offset | Modelled length (min) | Target |
|---|---|---|---|---|---|---|
| Conquest | 320 | 22 | 9.9 | 8.4 | 17.5 | 15-20 |
| Frontline | 160 | 25 | 9.3 | 2.1 | 22.2 | 20-25 |
| TDM | 120 | 12 | 12.0 | 0.0 | 10.0 | 8-11 |

## Progression pacing

Modelled XP/min (Conquest, average player, no boosts): **191** (11487/h).

| Level | XP to next | Total XP | Hours |
|---|---|---|---|
| 2 | 1784 | 1500 | 0.13 |
| 3 | 2116 | 3284 | 0.29 |
| 4 | 2496 | 5400 | 0.47 |
| 5 | 2924 | 7896 | 0.69 |
| 6 | 3400 | 10820 | 0.94 |
| 8 | 4496 | 18144 | 1.58 |
| 10 | 5784 | 27756 | 2.42 |
| 12 | 7264 | 40040 | 3.49 |
| 14 | 8936 | 55380 | 4.82 |
| 16 | 10800 | 74160 | 6.46 |
| 18 | 12856 | 96764 | 8.42 |
| 20 | 15104 | 123576 | 10.76 |
| 22 | 17544 | 154980 | 13.49 |
| 24 | 20176 | 191360 | 16.66 |
| 30 | 29224 | 334196 | 29.09 |
| 40 | 48144 | 707616 | 61.60 |
| 50 | 0 | 1291836 | 112.46 |

### First unlock per class (minutes of play): primary weapon / any slot

| Class | US | UK | USSR | FR | DE | JP | IT |
|---|---|---|---|---|---|---|---|
| Rifleman | L5 41 / L5 41 | L5 41 / L5 41 | L5 41 / L5 41 | L5 41 / L5 41 | L5 41 / L5 41 | L5 41 / L5 41 | L5 41 / L5 41 |
| Assault | L5 41 / L5 41 | L5 41 / L5 41 | L5 41 / L5 41 | L5 41 / L5 41 | L5 41 / L5 41 | L5 41 / L5 41 | L5 41 / L5 41 |
| Support | L5 41 / L5 41 | L5 41 / L5 41 | L5 41 / L5 41 | L5 41 / L5 41 | L5 41 / L5 41 | L5 41 / L5 41 | L5 41 / L5 41 |
| Medic | L5 41 / L5 41 | L5 41 / L5 41 | L5 41 / L5 41 | L5 41 / L5 41 | L5 41 / L5 41 | L5 41 / L5 41 | L5 41 / L5 41 |
| Engineer | L5 41 / L5 41 | L5 41 / L5 41 | L5 41 / L5 41 | L5 41 / L5 41 | L5 41 / L5 41 | L5 41 / L5 41 | L5 41 / L5 41 |
| Recon | L5 41 / L5 41 | L5 41 / L5 41 | L5 41 / L5 41 | L5 41 / L5 41 | L5 41 / L5 41 | L5 41 / L5 41 | L5 41 / L5 41 |

### Unlock track (hours of play to reach each unlock level)

| Level | Hours | Unlocks (*vehicles* in italics) |
|---|---|---|
| 2 | 0.1 | *GMCTruck* (US), *OpelBlitz* (DE) |
| 3 | 0.3 | *M5Stuart* (US) |
| 4 | 0.5 | *SomuaS35* (FR), *AB41* (IT) |
| 5 | 0.7 | M1917Enfield (US), SMLE (UK), MosinM38 (USSR), Lebel1886 (FR), G3340 (DE,IT), ArisakaType38 (JP), CarcanoM91 (IT), M3GreaseGun (US,FR), Lanchester (UK), PPS43 (USSR), MP28 (DE), Type100Late (JP), TZ45 (IT), M1919A6 (US), LewisGun (UK), DS39 (USSR), Chauchat (FR), MG42 (DE,IT), Type99LMG (JP), *M8Greyhound* (US) |
| 8 | 1.6 | NagantM1895 (USSR), MAS1935A (FR), LugerP08 (DE), Type94Pistol (JP), GlisentiM1910 (IT), GeballteLadung (DE,IT), StickyBomb (UK,FR), Type99Magnetic (JP), *KV1* (USSR) |
| 10 | 2.4 | Gewehr41 (DE,IT), BredaPG (IT), Ithaca37 (US), SWVictory (US,UK), M39Egg (DE,IT), RG42 (USSR), Type99Grenade (JP), SRCMMod35 (IT), BoysATRifle (UK), PTRD41 (USSR), Panzerschreck (DE), LungeMine (JP), *Churchill* (UK) |
| 12 | 3.5 | M1941Johnson (US), FedorovAvtomat (USSR), CharltonAR (UK), FG42 (DE), Breda37 (IT), C2Demolition (US,USSR), SolothurnS18 (IT,DE), *Panther* (DE) |
| 14 | 4.8 | SVT38 (USSR), M1C (US), SVT40Sniper (USSR), Gewehr43ZF4 (DE), Type99Sniper (JP), M9Bazooka (US,FR) |
| 16 | 6.5 | ThompsonM1928 (US,UK), HiPower (UK,FR,DE), Type26Revolver (JP), Gammon82 (UK,US) |
| 18 | 8.4 | PPD40 (USSR), MP35 (DE), FNAB43 (IT), BrowningAuto5 (US,UK,FR,DE,IT), Type11LMG (JP), F1Limonka (USSR), RPG43 (USSR), PzB39 (DE), Type97ATRifle (JP), *TigerI* (DE) |
| 20 | 10.8 | StenMkV (UK) |
| 22 | 13.5 | MKb42H (DE,JP), JohnsonLMG (US), VickersBerthier (UK), RPD44 (USSR), MG15 (DE) |
| 24 | 16.7 | MauserM712 (DE,IT) |

## Target violations

None - every automated target is met.
