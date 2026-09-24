# Guild Gear Browser Paper-Doll Layout

## Goal

Replace the circular gear arrangement in the saved guild gear browser with the slot arrangement shown in the user reference. Show 19 gear slots: eight vertical slots on each side and three weapon slots along the bottom. Leave the center open. Do not add the Ammo (0) slot.

## Layout

Use fixed paper-doll positions corresponding to the inventory slot IDs in the reference:

- Left, top to bottom: HEAD (1), NECK (2), SHOULDER (3), BACK (15), CHEST (5), SHIRT (4), TABARD (19), WRIST (9).
- Right, top to bottom: HANDS (10), WAIST (6), LEGS (7), FEET (8), FINGER_1 (11), FINGER_2 (12), TRINKET_1 (13), TRINKET_2 (14).
- Bottom, left to right: MAIN_HAND (16), OFF_HAND (17), RANGED (18).

Preserve the existing character list, saved identity, capture time, empty-slot treatment, item icons, and item tooltips. The central area remains empty; do not add a character model.

## Data and synchronization

Make the 19 slots canonical across local capture, snapshots, SavedVariables, stable gear tracking, and addon-message sync. Each added slot must use the same Blizzard-exposed in-game inventory APIs as the existing slots. Ammo remains excluded.

Complete snapshots must contain all 19 slots, including explicit empty values only when the permitted API confirms the slot is empty. Migrate schema version 1 records to schema version 2 by preserving their 16 known slot values, capture time, identity, and sequence, while marking them incomplete. Keep those records visible as incomplete: render the 16 known values, and show shirt, tabard, and ranged as unavailable rather than empty. They become complete only after an authoritative 19-slot baseline is received or captured.

Update the sync protocol version and snapshot shape for 19 slots. Do not accept an old 16-slot response as a complete baseline. A client that cannot provide a valid 19-slot baseline must leave the record incomplete rather than bypassing API restrictions or inventing values. Retain bounded, request-triggered repair behavior and existing throttling safeguards.

## Alternatives considered

1. **Adopt the 19-slot set throughout the addon (chosen).** Matches the supplied layout and lets every displayed slot have the same verified capture and cache meaning.
2. **Move only the existing 16 slots.** Leaves three visible slots without stored values and cannot match the supplied 8 + 8 + 3 layout.
3. **Add display-only placeholders for the missing slots.** Rejected because a placeholder could imply knowledge the addon does not have and would not synchronize correctly.

## Acceptance criteria

- The browser renders the requested fixed positions: eight left, eight right, and three bottom.
- Slot mapping matches the provided numbered diagram, with no circular placement and no Ammo slot.
- A selected record renders its saved item data and explicit empty slots in the corresponding positions.
- An incomplete migrated record remains visibly incomplete, with unknown slots distinguished from confirmed-empty slots.
- Local capture, pending-change tracking, snapshots, persistence, validation, and synchronization agree on the same 19 slot keys and inventory IDs.
- Old 16-slot data is never silently completed with fabricated empty values.
- No recurring guild-wide polling, extra retry path, or other increase in network behavior is introduced.

## Verification scope

Review the affected UI and data-flow tests and run the project’s existing test suite after implementation. Also inspect the final diff for slot-order, mapping, migration, and protocol-version consistency.
