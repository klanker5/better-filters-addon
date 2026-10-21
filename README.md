# Better Filters

A World of Warcraft (Retail) addon that adds clean, flat filter panels next to the **Premade Groups** (Group Finder) window. There are panels for finding **Dungeon** and **Raid** groups, and separate panels for filtering the **applicants to your own listing**. It also adds instant sign-up, a sign-up note box, per-player notes with chat alerts, spec icons, a keystone button, and a tidier layout for groups you have applied to.

> Interface version: `120005` · Addon version: `0.8.0` · Saved variables: `BetterFiltersDB`

---

## Table of contents

- [Features at a glance](#features-at-a-glance)
- [Installation](#installation)
- [How the filters work](#how-the-filters-work)
- [Dungeons panel](#dungeons-panel)
- [Raids panel](#raids-panel)
- [Applicant filters (your own listing)](#applicant-filters-your-own-listing)
- [Notes](#notes)
- [Applied-group display](#applied-group-display)
- [Slash commands](#slash-commands)
- [Saved data and upgrading from Simple Group Filter](#saved-data-and-upgrading-from-simple-group-filter)
- [Limitations](#limitations)
- [Troubleshooting](#troubleshooting)
- [Project layout](#project-layout)
- [Contributing](#contributing)

---

## Features at a glance

**Both categories**
- Panel shows only in the matching Group Finder category (Dungeons panel for Dungeons, Raids panel for Raids).
- **Filter enabled** master switch.
- **Instant sign up**: click a listing and you sign up straight away (hold Shift, Ctrl or Alt to only select it). On by default, can be switched off.
- **Playstyle** filter (Learning, Relaxed, Competitive, Carry Offered) with three states per button.
- **Sign-up note box**: type the note you send when signing up, right in the panel (it sits under Instant sign up).
- **Notes**: right-click a group or player to add a good or bad note, with chat alerts when noted players join your group.
- **Applicant filters** for your own listing, with a separate panel for dungeons and for raids.
- Works next to **Raider.IO**: its side panel moves to the right of ours.
- Flat, ElvUI-style look that matches Blizzard's Group Finder.

**Dungeons**
- Leader Mythic+ score range slider.
- Key level range slider.
- **Fit my party**: only show groups that have room for the roles you already bring.
- Group composition: Has Tank, Has Healer, Has Bloodlust class.
- Quick dungeon buttons, sorted alphabetically with readable abbreviations.
- **Spec icons** in place of Blizzard's class-coloured role icons.
- **Keystone button**: shows your key and opens the listing page for it.

**Raids**
- Difficulty buttons (Normal, Heroic, Mythic).
- Range sliders for the number of tanks, healers and DPS in a group.
- Raid tabs with abbreviations and artwork; selecting a raid filters to it.
- Per-boss filters: still alive or already killed.
- Role counts shown on raid listings you have applied to.
- On raid listings: how many players of **your class** and of **your tier token group** are in the group.

---

## Installation

1. Download this repository (green **Code** button, then **Download ZIP**) or clone it.
2. Make sure the folder is named exactly **`BetterFilters`** and contains `BetterFilters.toc` and `BetterFilters.lua`.
3. Copy the folder to your AddOns directory:
   - Windows: `C:\Program Files (x86)\World of Warcraft\_retail_\Interface\AddOns\`
   - macOS: `/Applications/World of Warcraft/_retail_/Interface/AddOns/`
4. Start the game, or type `/reload` if it is already running.
5. Make sure **Better Filters** is ticked in the AddOns list on the character-select screen.
6. Open the Group Finder (default key `I`), go to **Premade Groups**, pick **Dungeons** or **Raids**, and the panel appears to the right of the window.

If the game says the addon is out of date, tick **Load out of date AddOns** on the AddOns screen.

---

## How the filters work

Most buttons cycle through **three states** with each click:

| Click | State | Colour | Meaning |
| --- | --- | --- | --- |
| Start | Empty | Grey | No preference |
| 1st | Include | Green | Group **must** match |
| 2nd | Exclude | Red | Group **must not** match |
| 3rd | Back to empty | Grey | No preference |

This applies to Playstyle, Has Tank / Has Healer / Bloodlust, and the dungeon buttons. Boss buttons use the same cycle with their own meaning (see [Raids panel](#raids-panel)).

Filters apply on top of whatever search Blizzard's own box has returned. Changing a filter refreshes the list immediately, and the result count updates accordingly.

---

## Dungeons panel

### Top section
- **Filter enabled**: turns all filtering on or off without losing your settings.
- **Notes**: opens the notes list (the button turns green while that list is open). See [Notes](#notes).
- **Fit my party**: reads your current group and hides groups that already have the roles you bring. A tank in your party hides groups with a tank, and so on for healers and DPS.
- **Instant sign up**: see above.
- **Sign-up note box**: shown under Instant sign up while it is on. What you type is sent as your note when you sign up. When Instant sign up is off the box goes back to Blizzard's sign-up dialog and the row disappears.

### Playstyle
Buttons for each playstyle the game uses. Excluded playstyles read "No ...".

| Blizzard label | Name used by the game's data |
| --- | --- |
| Learning | Learning |
| Fun (Relaxed) | Relaxed |
| Fun (Serious) | Competitive |
| Expert | Carry Offered |

### Group composition
Three tri-state buttons:
- **Tank**: require or exclude a tank in the group.
- **Healer**: require or exclude a healer.
- **Bloodlust**: require or exclude at least one class that can provide Bloodlust or Heroism.

### Sliders
- **Leader score**: two handles set a minimum and maximum Mythic+ rating for the group leader. Leave the bottom handle at the bottom for "no lower limit" and the top handle at the top for "no upper limit".
- **Key level**: the same two-handle slider for key level. The panel also shows the matching range text so it can be used with Blizzard's own search syntax.

### Dungeon buttons
- One button per dungeon, sorted alphabetically.
- Abbreviations are the first letter of each word (for example *Den of Nalorak* is DON), with hand-set overrides for a few names such as Void Scar Arena (VSA).
- Same three-state cycle: include, exclude, reset.

### Keystone button
The button at the bottom of the panel shows the keystone your character holds, for example `+12 BV`, using the same short dungeon names as the dungeon icons. Click it to open the Group Finder on the Dungeons **Start a Group** page. You then pick the dungeon, a playstyle and a title and press **List Group** yourself.

> The game does not let addons fill in a listing title or press List Group, so a one-click listing is not possible.

### Spec icons
Dungeon listings show each member's **spec icon** instead of the class-coloured tank/healer/DPS icons, ordered tanks, healers, then DPS, with small grey dots for open slots. If the game does not expose a member's class or spec, that listing keeps Blizzard's default icons.

---

## Raids panel

The raid panel keeps **Filter enabled**, **Notes**, **Instant sign up** and **Playstyle** from the dungeon panel and adds:

### Difficulty
Normal, Heroic and Mythic buttons with the same three-state cycle.

### Group role counts
Three range sliders set the minimum and maximum number of **tanks**, **healers** and **DPS** in a group.

### Raid tabs and bosses
- A tab per raid in the current tier that the Group Finder lists, shown with an abbreviation and the raid's artwork. Click a tab to show only that raid, click it again to show all raids.
- With a raid selected, each of its bosses gets a button:
  - first click: **green**, the boss is still alive (group has not killed it)
  - second click: **red**, the boss is already killed
  - third click: reset
- **Clear** resets all boss filters.

Boss names and the raid list come from the in-game Encounter Journal, so they update with the game.

### Class and tier counts on listings
Under the tank/healer/DPS numbers of a raid listing, two counts show how many players in that raid share **your class** and **your tier set token group** (Woven, Cured, Cast/Tier or Forged, by armour type).

---

## Applicant filters (your own listing)

When you list your own group and open the applicant list, a **Better Filters** panel appears next to the window (the dungeon version for dungeon listings, the raid version for raid listings). It hides applicants who do not match; **nobody is declined**, and hidden applicants come back when you loosen a filter. A "Showing X / Y" counter shows how many are visible. Dungeon and raid filters are saved separately.

How groups of applicants are treated: a party that applies together is **hidden if any member matches something you exclude**, and **shown if any member matches something you include**.

### Dungeon listings
| Filter | What it does |
| --- | --- |
| Filter enabled | Master switch for this panel. |
| Role | Tank / Healer / DPS buttons, with the usual include / exclude cycle. |
| Fit my group | Only shows applicants for the roles your group is missing (1 tank, 1 healer, 3 DPS counted from your current group, you included). Updates when your group changes. |
| Item level | Two-handle slider, 250 to 350. Bottom means no lower limit, top means no upper limit. |
| Dungeon rating | Two-handle slider on the applicant's overall Mythic+ rating, 0 to 4200. |
| Bloodlust class | Only bloodlust classes (green) or none of them (red). |
| Hide bad notes | Hides applicants you have a bad note on. |
| Only good notes | Only shows applicants you have a good note on. |
| Class | One icon per class, four per row, with include (gold ring) / exclude (red ring and cross) / reset. **Clear** resets them. |

### Raid listings
The same panel without Fit my group and Dungeon rating, plus a **Missing buffs** button on the Class row:
- **Missing buffs** clears the class filters, then selects every class that brings a raid buff nobody in your group (you included) brings yet.
- The **cogwheel** next to it opens a popup where you choose which raid buffs you care about. All are selected by default; the choice is saved.

| Class | Buff |
| --- | --- |
| Mage | Arcane Intellect |
| Warrior | Battle Shout |
| Priest | Power Word: Fortitude |
| Druid | Mark of the Wild |
| Shaman | Skyfury |
| Evoker | Blessing of the Bronze |
| Monk | Mystic Touch |
| Demon Hunter | Chaos Brand |
| Hunter | Hunter's Mark |
| Paladin | Devotion Aura |
| Rogue | Atrophic Poison |
| Warlock | Curses |

The list lives in `RAID_BUFFS` in `BetterFilters.lua` if the game changes it.

---

## Notes

Attach a short note to any player, or to a group leader, from the Group Finder.

- **Add a note**: right-click a group listing (the note attaches to its leader) or a player in a group, then choose the add-note entry.
- **Good or bad**: notes are Good (green) or Bad (red), each with free text.
- **Tooltips**: hovering a listing or player shows the note on one line, coloured by type.
- **Notes panel**: the **Notes** button opens a list of every stored note where you can review and delete them. A toggle at the top of the panel enables or disables chat alerts.
- **Chat alerts**: when a player you have a note on joins your group, a chat message shows their name and note. Alerts fire for both good and bad notes.

Notes are stored per `Name-Realm`, so the same player is matched wherever you meet them.

---

## Applied-group display

When you have applied to a group, Blizzard hides the group's composition and shows a pending label, timer and cancel button. Better Filters keeps the comp visible:

- **Dungeons**: the spec icons stay on the row, on the playstyle line, ending at the cancel button. The word "Pending" is hidden; the timer and cancel button are raised slightly.
- **Raids**: the role counts (tank, healer, DPS) are shown on the playstyle line in the same position, with the timer and cancel button raised the same way.

Because the game may stop exposing member data once you apply, the addon remembers a group's comp from the last time it drew that row **before** you applied and shows that. If you applied before the row was drawn, Blizzard's default display is used.

---

## Slash commands

| Command | What it does |
| --- | --- |
| `/bf debug` | Prints what listing data the game exposes for the first listings (useful for bug reports). |
| `/bf spec` | Prints the raw member data and spec-icon lookup for the first listings and any applied rows. |
| `/bf app` | Prints what the game exposes for your applicants and how the applicant filter reads them. |

`/sgf` still works as an alias for the old name.

---

## Saved data and upgrading from Simple Group Filter

Better Filters was previously called **Simple Group Filter**. Settings and notes are stored in `BetterFiltersDB`. On first load, if no `BetterFiltersDB` exists, the addon copies everything from the old `SimpleGroupFilterDB`, so your settings and notes carry over.

To upgrade:
1. Delete the old `SimpleGroupFilter` folder from `Interface/AddOns`.
2. Install the `BetterFilters` folder.
3. Log in once with the old saved-variables file still in place.

---

## Limitations

These come from restrictions Blizzard places on addons, not choices in this addon:

- **No keyword filter.** Group titles and descriptions are protected values that addons cannot read, so filtering by text in the listing title is not possible.
- **No group-leader item level.** The game does not expose item levels in the search results.
- **No one-click listing.** An addon cannot type a listing title or press List Group, so the keystone button only opens the listing page.
- **Hidden applicants are not declined.** Declining and inviting need a real click from you.
- **The Blizzard search box cannot be filled by an addon.** Writing to it is blocked as a protected action, and so is the clipboard.
- **Some listing data can be hidden by the game** in certain situations. Where that happens the addon leaves Blizzard's own display alone rather than guessing.
- Positions of the timer, cancel button and role icons on applied rows depend on Blizzard's row layout and may need adjusting after a game patch.

---

## Troubleshooting

- **Panel does not appear**: check the addon is enabled, then `/reload`. The panel only shows in the Dungeons and Raids categories of Premade Groups.
- **A Lua error appears**: install a Lua error display such as BugSack/BugGrabber, or enable `/console scriptErrors 1`, and include the message in your bug report.
- **Spec icons do not show**: run `/bf spec` and include the output in an issue.
- **Applicant filters do nothing**: open your applicant list with a filter set, run `/bf app` and include the output in an issue.
- **Raider.IO's panel overlaps ours**: it is moved to the right of whichever Better Filters panel is showing; reload the UI if it was loaded after us.
- **A filter seems to have no effect**: check **Filter enabled** is on, and that the group list was refreshed after changing the setting.
- **Notes are missing after the rename**: log in once with the old `SimpleGroupFilterDB` still present so it can be copied.

---

## Project layout

```
BetterFilters/
├── BetterFilters.toc    # addon manifest (interface version, saved variables)
├── BetterFilters.lua    # the whole addon
└── README.md
```

`BetterFilters.lua` is organised in sections: defaults, helpers, filtering logic (dungeons and raids), list refresh and instant sign-up hooks, the shared flat UI widgets, spec icons, raid class and tier counts, notes, the dungeon and raid panels, the keystone button, the applicant filter panels, Raider.IO support, debug commands, and startup.

---

## Contributing

Issues and pull requests are welcome. When reporting a bug, please include:
- the game version and addon version,
- the exact Lua error text if there is one,
- a screenshot if it is a layout problem,
- the output of `/bf debug` or `/bf spec` where relevant.

The addon is written in plain Lua with no external libraries, so there is no build step: edit `BetterFilters.lua`, `/reload` in game and test.

---

## License

Add a license of your choice here (for example MIT) before publishing.