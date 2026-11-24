# World Notification Mover

Move the "World refresh in N Seconds" notification on WoW Forever to wherever you like.

## Install
Download the latest zip from Releases (or CurseForge) and extract the `WorldNotificationMover` folder into `World of Warcraft\_forever_\Interface\AddOns`.

## Use it
1. Type `/wnm` (or open Options > AddOns > World Notification Mover).
2. Click **Move notification**. A box appears: the real notification's size if it's showing, otherwise a sample.
3. Drag the box, then click **Lock** (or right-click the box).

The notification is the game's `ShardTransferImminentFrame` (from Blizzard_SocialToast, loaded on demand). The addon grabs it as soon as it exists and keeps it at your spot every time it shows. If a future client renames it, the addon falls back to finding it by its text.

## If a game update renames it
`/wnm text <words>` changes the text the backup search looks for (default "world refresh"). `/wnm status` shows what was found.

## Commands
`/wnm`, `/wnm move`, `/wnm lock`, `/wnm reset`, `/wnm find`, `/wnm text <words>`, `/wnm status`

Settings are account-wide (`WorldNotificationMoverDB`).

## License
MIT, see `LICENSE.txt`.
