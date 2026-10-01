# Local Alt and Guild Profession Visibility Design

**Status:** Draft for written review
**Date:** 2026-10-01

This specification extends the profession recipe browser design dated 2026-09-30. It supersedes that design where it limits results to current guild members or hides all results when the roster is unconfirmed. Other existing recipe browser behavior remains in scope unless stated here.

## Goal

Show saved profession recipes for the viewer’s own characters and current guild members, while excluding unrelated characters. A character logged into this local GuildGearMemory database is one of the viewer’s local characters, even when that character is outside the guild.

## Agreed behavior

1. When a character logs into this local database, record its GUID as locally owned. This records ownership only; it does not capture profession data.
2. Saving a personal profession snapshot still requires the user to open that profession and click Save Snapshot. A local character with no saved profession snapshot is omitted from the recipe browser.
3. Guild-member profession data continues to use the manual profession-link flow: a member shares a trade-skill link in guild chat; the viewer opens it and clicks Save Snapshot. Capture must verify current guild membership as the existing flow requires.
4. The browser includes a saved character when its GUID is locally owned or the current, confirmed guild roster includes it. Other out-of-guild characters are hidden.
5. The browser shows each crafter’s character name and realm without an ownership or guild-status badge. Preserve the existing cached/last-known status and capture-date behavior so saved data is not presented as live knowledge.
6. Saved local-character snapshots remain visible when the current guild roster is unconfirmed. Guild-member records are withheld until roster membership is confirmed.
7. After a successful, complete roster check confirms that a non-local character has left the guild, remove that character’s saved gear and profession data from this local database, along with derived index entries. Keep the data when roster membership is unavailable, incomplete, or ambiguous. A locally owned character is retained even if it is no longer in the guild.
8. Automatic profession snapshot exchange through addon messages is future scope. This change adds no such exchange and never synchronizes data between characters unrelated by local account or current guild.

## Ownership and storage model

The example database already separates character identity, guild activity, local ownership, and the recipe index. The revised model keeps those concepts independent:

- Add a GUID-keyed local ownership set, named localCharacterGUIDs. A true value means that character has logged into this local database. The set is local SavedVariables state, not a network claim.
- Keep professionCharacters entries and localCharacterIDByGUID as the identity registry used by recipe-index references. The active field continues to mean current guild membership only; it does not mean local ownership.
- Keep canonical identity and profession snapshots under professions[characterKey]. Snapshot source describes how a snapshot was captured, not who owns the character. Do not infer local ownership from a player-source snapshot, a name match, or a guild link.
- Keep professionRecipeIndex[professionID][recipeID] entries compact. Each crafters array contains local character IDs. Resolve those IDs through professionCharacters, then include the owner only when its GUID is in localCharacterGUIDs or in the confirmed current guild roster.
- Rebuild or reconcile the derived recipe index so it includes eligible local characters outside the guild as well as confirmed current guild members. A recipe known by multiple eligible characters has one row and all corresponding local IDs in crafters.

On login, record the character GUID even if it has no profession snapshot yet. The browser still omits that character until Save Snapshot creates a valid profession snapshot. The catalog may show local characters while guild membership is unconfirmed, but must not attribute non-local cached records to current guild members until confirmation.

## Guild membership and data removal

The roster refresh remains the source of truth for current guild membership. A roster error, incomplete roster, ambiguous identity, or pending refresh is not evidence that a character left.

After a successful complete roster result:

- Mark characters present in the roster as current guild members.
- For characters absent from the roster, preserve records whose GUID is in localCharacterGUIDs.
- For absent, non-local characters, purge saved gear, profession snapshots, character registry entries, and all derived recipe-index references from this local database.
- Rebuild derived indexes only after the confirmed membership result is valid; do not partially delete records on a failed reconciliation.

Deletion is local to this SavedVariables database. It does not send a deletion message to another player’s addon.

## Capture and display boundaries

- The login path records local ownership only; it does not call profession APIs or save recipes.
- Save Snapshot remains the only profession capture trigger for the current character or an explicitly opened guild profession link.
- Opening the recipe browser, selecting a profession, searching, or changing tabs reads saved data only. These actions do not request a roster refresh, inspect a profession, or send addon messages.
- Use only the permitted in-game APIs and SavedVariables. Do not acquire data from process memory, packets, screen extraction, or external tools.
- Retain explicit cached, incomplete, unavailable, and no-snapshot states. If membership or ownership cannot be established, do not attribute a non-local record to the viewer’s current guild.

## Database compatibility

The example database currently has a character-keyed localCharacters set and a schema-versioned SavedVariables table. Add localCharacterGUIDs as the stable ownership allowlist. During migration, seed it only when a legacy local-character key resolves to a matching stored identity with a valid GUID. If a legacy marker cannot be resolved safely, leave the cached record unclassified until that character next logs into the local database; do not guess from name or realm alone. Preserve unrelated gear and profession records during migration.

Increment the schema and derived-index versions as needed. The migration and index rebuild must be bounded, deterministic, and safe to retry. It must not transmit data.

## Acceptance criteria

- Logging into a character records its GUID as locally owned without creating a profession snapshot.
- A local character with no saved profession snapshot is absent from recipe-owner rows.
- A local out-of-guild character with a saved snapshot appears, including while guild membership is unconfirmed.
- A non-local character appears only after a saved snapshot exists and current guild membership is confirmed.
- Other guild members’ out-of-guild alts are not shown merely because their guildmate has a saved snapshot.
- Crafters are rendered as name and realm without ownership or guild-status badges; existing cached dates remain visible.
- Recipe rows deduplicate by recipe ID and resolve every crafter ID to a valid, eligible character identity.
- An incomplete or failed roster check does not delete cached data and does not expose non-local characters as current guild members.
- A successful complete roster check deletes both gear and profession data for absent non-local characters and removes all derived references.
- A locally owned character’s data survives guild departure.
- Manual Save Snapshot remains the capture trigger. The browser adds no live capture, periodic traffic, or addon-message synchronization.
- Existing recipe-browser search, sorting, localization, cached-data labeling, and malformed-data safeguards remain intact.

## Out of scope

- Automatic profession capture on login or profession-window open.
- Automatic addon-message exchange of profession snapshots, including future guild-only exchange; this requires a separate design.
- Showing out-of-guild alts of other guild members.
- New ways to infer account ownership from character names or professions.
- New professions or changes to recipe search and sorting behavior.
