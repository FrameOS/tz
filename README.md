# tz

Latest time zone data. For use with the [chrono](https://github.com/treeform/chrono) [nim](https://nim-lang.org/) library. Used internally by [FrameOS](https://github.com/FrameOS/frameos).

- https://tz.frameos.net/tzdata.json - contains both time zones and DST changes. Give this to `loadTzData`.

Please note that zone IDs are not guaranteed to be stable from one day to the next. Reload everything.

The files are generated from https://github.com/eggert/tz with a Github Action that ([allegedly](https://github.com/FrameOS/tz/actions/workflows/generate-timezones.yml)) runs 42 minutes past midnight UTC.

Also provided:

- https://tz.frameos.net/timezones.csv
- https://tz.frameos.net/dstchanges.csv
- https://tz.frameos.net/zone/Europe/Brussels.json - one zone (aliases included, e.g. `zone/Europe/Kiev.json`), same shape as `tzdata.json` with that zone as id 1 and only its transitions from last year through ten years ahead (~1.5 KB). For devices that cannot hold the whole file — the FrameOS ESP32 firmware. `zone/index.json` maps every name to its canonical zone.
