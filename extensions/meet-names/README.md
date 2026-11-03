# OpenWispr Meet Names

Sends Google Meet participant names and the active speaker to the OpenWispr app (127.0.0.1:47891 only).

1. Open `chrome://extensions` and turn on Developer mode.
2. Click "Load unpacked".
3. Pick this `meet-names` folder.
4. Join a Meet call with OpenWispr running; names appear in the meeting transcript at Stop.

Posts `{"v":1,"event":"roster"|"joined"|"left","meeting":"abc-defg-hij","participants":[{"name":"Rahul","speaking":true}]}` to `POST /meet`.
