# OpenWispr Meet Names

Sends Google Meet participant names and the active speaker to the OpenWispr app (127.0.0.1:47891 only).

1. Open `chrome://extensions` and turn on Developer mode.
2. Click "Load unpacked".
3. Pick this `meet-names` folder. It is also inside the app bundle at `Contents/Resources/meet-names`; the Settings pane has a "Reveal extension folder" button.
4. Join a Meet call with OpenWispr running.

## How to tell it works

- Chrome DevTools console on the Meet tab (enable "Verbose" level) shows `[OpenWispr] roster n=…` lines every second.
- After you press Stop, the OpenWispr meeting view shows the Meet names.

Posts `{"v":1,"event":"roster"|"joined"|"left","meeting":"abc-defg-hij","participants":[{"name":"Rahul","speaking":true}]}` to `POST /meet`. You are sent as "You".
