# openwispr CLI contract

Generated from `openwispr spec`. Every command prints `{ok, command, data, meta, error}` JSON.

```json
{
  "command" : "spec",
  "data" : {
    "commands" : [
      {
        "name" : "transcribe",
        "usage" : "transcribe <file> [--model M] [--lang L] [--format json]"
      },
      {
        "name" : "history list",
        "usage" : "history list [--limit N]"
      },
      {
        "name" : "history get",
        "usage" : "history get <id>"
      },
      {
        "name" : "history search",
        "usage" : "history search <query>"
      },
      {
        "name" : "meetings list",
        "usage" : "meetings list"
      },
      {
        "name" : "meetings get",
        "usage" : "meetings get <stamp>"
      },
      {
        "name" : "dictionary add",
        "usage" : "dictionary add <term> [--replace <text>]"
      },
      {
        "name" : "dictation start",
        "usage" : "dictation start"
      },
      {
        "name" : "dictation stop",
        "usage" : "dictation stop"
      },
      {
        "name" : "meeting start",
        "usage" : "meeting start"
      },
      {
        "name" : "meeting stop",
        "usage" : "meeting stop"
      },
      {
        "name" : "skill install",
        "usage" : "skill install"
      },
      {
        "name" : "spec",
        "usage" : "spec"
      },
      {
        "name" : "info",
        "usage" : "info"
      }
    ],
    "urlScheme" : [
      "openwispr:\/\/dictation\/start|stop",
      "openwispr:\/\/meeting\/start|stop",
      "openwispr:\/\/open\/<pane>",
      "openwispr:\/\/dictionary\/add?term=&replace="
    ]
  },
  "error" : null,
  "meta" : {
    "version" : "0.19.1"
  },
  "ok" : true
}
```
