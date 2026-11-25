# OpenWispr Meet Names

Sends Google Meet participant names and the active speaker to the OpenWispr app (127.0.0.1:47891 only).

1. Open `chrome://extensions` and turn on Developer mode.
2. Click "Load unpacked".
3. Pick this `meet-names` folder. It is also inside the app bundle at `Contents/Resources/meet-names`; the Settings pane has a "Reveal extension folder" button.
4. Join a Meet call with OpenWispr running.

## How to tell it works

- Chrome DevTools console on the Meet tab (enable "Verbose" level) shows `[OpenWispr] roster n=…` lines every second.
- After you press Stop, the OpenWispr meeting view shows the Meet names.

Posts `{"v":1,"event":"roster"|"joined"|"left","meeting":"abc-defg-hij","participants":[{"name":"Rahul","speaking":true},{"name":"You","speaking":false,"self":true}]}` to `POST /meet`. You are sent as "You" with `"self": true` (the field is optional; the app only relabels mic lines when it sees it).

## Version 0.2.0

- `self: true` marks the local user's tile (the "(You)" row in the people list, or the self tile).
- Speaking detection now has three small detectors, OR-ed together: the known level indicator (`jsname="QgSmzd"` without the silent class), any empty leaf in the tile whose class or inline style changed in the last 1.5 s, and a tile flagged as the active speaker (`data-is-speaking` / `data-active-speaker`, a guess). These are checked against fixtures in `test.html` only, not against a live Meet call.
- While someone is speaking the roster is posted every second (it was every 5 s when the payload did not change).
- Reload the extension in `chrome://extensions` after updating the app.

## Tests

`npm i jsdom` somewhere on your `NODE_PATH`, then `node test.js` in this folder.
