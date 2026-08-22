# This files is copied from https://github.com/treeform/chrono/blob/master/tools/generate.nim
# Then set to run daily via Github Actions to keep the timezone data up to date

import algorithm, chrono, json, os, osproc, parsecsv, parseopt, sets, strutils, tables, times

const doc = """

Generate your own packed timezone file.

Generate all timezones in bin and json:

  generate all

Generate only the years you want:

  generate all --startYear:2010 --endYear:2030

Generate only the timezones you want

  generate all --includeOnly:"utc,America/Los_Angeles,America/New_York,America/Chicago,Europe/Dublin"

Generate only the json data files:

  generate json

All together:

  generate.nim json --startYear:2010 --endYear:2030 --includeOnly:"utc,America/Los_Angeles,America/New_York,America/Chicago,Europe/Dublin"
"""

var startYearTs = Calendar(year: 1970, month: 1, day: 1).ts
var endYearTs = Calendar(year: 2060, month: 1, day: 1).ts
var includeOnly: seq[string] = @[]

const timeZoneFiles = @[
  "africa",
  "antarctica",
  "asia",
  "australasia",
  "europe",
  "northamerica",
  "southamerica",
  # "pacificnew", # some legal thing
  "etcetera",     # UTC, GMT, fixed offsets, and POSIX compatibility zones
  "factory",      # valid tzdb placeholder kept for existing user selections
  # "backzone"    # pre-1970 detail; do not need it for post-1970 compatibility aliases
]

const aliasSourceFiles = @[
  "africa",
  "antarctica",
  "asia",
  "australasia",
  "europe",
  "northamerica",
  "southamerica",
  "etcetera",
  "backward"
]

proc runCommand(cmd: string) =
  echo "running: ", cmd
  let ret = execCmdEx(cmd)
  if ret.exitCode != 0:
    echo "Command failed:"
    echo ret.output
    quit()

proc catCommand(cmd: string): string =
  echo "running: ", cmd
  let ret = execCmdEx(cmd)
  if ret.exitCode != 0:
    echo "Command failed:"
    echo ret.output
    quit()
  return ret.output

proc fetchAndCompileTzDb() =
  if not dirExists("tz"):
    echo "It looks like you don't have https://github.com/eggert/tz checkedout"
    runCommand("git clone https://github.com/eggert/tz")
  else:
    runCommand("cd tz; git pull origin main")

  if not dirExists("tz/zic") or not dirExists("tz/zdump"):
    runCommand("cd tz; make")

  if dirExists("tz/zic_out"):
    removeDir("tz/zic_out")
  runCommand("cd tz; zic -d zic_out " & timeZoneFiles.join(" "))

proc dumpToCsvFiles() =
  if not dirExists("tzdata"):
    createDir("tzdata")
  let timezones = open("tzdata/timezones.csv", fmWrite)
  let dstChanges = open("tzdata/dstchanges.csv", fmWrite)

  var files = newSeq[string]()
  for file in walkDirRec("tz/zic_out/", {pcFile, pcLinkToFile}):
    files.add(file)
  files.sort(system.cmp)

  for tzId, file in files:
    timezones.write("\"" & $tzId & "\",\"" & "" & "\",\"" & file[11..^1] & "\"\n")
    var prevDstName = ""
    var prevOffset = 0
    # zdump can only do absolute paths
    let output = catCommand("tz/zdump -v -c 2060 " & getCurrentDir() & "/" & file)

    for rawLine in output.split("\L"):
      let line = rawLine.replace(getCurrentDir() & "/tz/zic_out/", "")
      if "NULL" in line or line.len == 0:
        continue
      let parts = line.splitWhitespace()
      if len(parts) < 16:
        continue
      let dstName = parts[13]
      let offset = parseInt(parts[15].split("=")[1])
      let date = parts[2..5].join(" ")
      let isDst = parseInt(parts[14].split("=")[1])
      if prevDstName == dstName and prevOffset == offset:
        continue
      var ts: Timestamp
      try:
        ts = parseTs("{month/n/3} {day} {hour/2}:{minute/2}:{second/2} {year}", date)
      except ValueError:
        echo "Failed to parse ", date
        continue
      let csvLine = "\"" & $tzId & "\",\"" & dstName & "\",\"" & $(int64(ts)) &
          "\",\"" & $offset & "\",\"" & $isDst & "\"\n"

      dstChanges.write(csvLine)

      prevDstName = dstName
      prevOffset = offset

  timezones.close()
  dstChanges.close()

proc dumpAliasFile(timeZoneNames: seq[string]) =
  let canonicalNames = timeZoneNames.toHashSet()
  var aliases = initTable[string, string]()

  for fileName in aliasSourceFiles:
    let path = "tz/" & fileName
    if not fileExists(path):
      continue
    for line in lines(path):
      let stripped = line.strip()
      if stripped.len == 0 or stripped.startsWith("#"):
        continue
      let parts = stripped.splitWhitespace()
      if parts.len >= 3 and parts[0] == "Link":
        let target = parts[1]
        let alias = parts[2]
        if target in canonicalNames and alias notin canonicalNames:
          aliases[alias] = target

  var aliasNames = newSeq[string]()
  for alias in aliases.keys:
    aliasNames.add(alias)
  aliasNames.sort(system.cmp)

  var data = newJObject()
  for alias in aliasNames:
    data[alias] = %aliases[alias]

  writeFile("timezone_aliases.json", $data)
  echo "written file timezone_aliases.json ", aliasNames.len, " aliases"

iterator readCvs*(fileName: string, readHeader = false): CsvRow =
  var p: CsvParser
  p.open(fileName)
  if readHeader:
    p.readHeaderRow()
  while p.readRow():
    yield p.row
  p.close()

type TimeZoneWithStr = object
  id: int
  name: string
type DstChangeWithStr = object
  tzId: int
  name: string
  start: float
  offset: int

# Per-zone slices for devices that cannot hold the whole tzdata.json (the
# FrameOS ESP32 firmware: frameos/src/lib/tz.nim, embedded/esp32/main/fos_tz.c).
# One file per zone AND per alias at zone/<Name>.json, the same
# {timezones, dstChanges} shape with that zone as id 1 and only its
# transitions from the start of last year through ten years ahead — about
# 1.5 KB for an EU zone. Served at https://tz.frameos.net/zone/<Name>.json.
const sliceYearsBack = 1
const sliceYearsAhead = 10

proc sliceFor(zone: TimeZoneWithStr, sliceName: string, changes: seq[DstChangeWithStr],
    fromTs, toTs: Timestamp): JsonNode =
  var kept = newSeq[DstChangeWithStr]()
  var head = -1
  for i, change in changes:
    if change.tzId != zone.id:
      continue
    if Timestamp(change.start) <= fromTs:
      head = i
    elif Timestamp(change.start) < toTs:
      if head >= 0:
        kept.add(changes[head])
        head = -1
      kept.add(change)
  if kept.len == 0 and head >= 0:
    kept.add(changes[head])
  var dsts = newJArray()
  for change in kept:
    dsts.add(%*{"tzId": 1, "name": change.name, "start": change.start, "offset": change.offset})
  %*{"timezones": [{"id": 1, "name": sliceName}], "dstChanges": dsts}

proc dumpZoneSlices(timeZones: seq[TimeZoneWithStr], changes: seq[DstChangeWithStr]) =
  let nowYear = Timestamp(epochTime()).calendar().year
  let fromTs = Calendar(year: nowYear - sliceYearsBack, month: 1, day: 1).ts
  let toTs = Calendar(year: nowYear + sliceYearsAhead, month: 1, day: 1).ts
  var aliases = initTable[string, string]()
  if fileExists("timezone_aliases.json"):
    for alias, target in parseJson(readFile("timezone_aliases.json")):
      if target.kind == JString:
        aliases[alias] = target.getStr()
  var byName = initTable[string, TimeZoneWithStr]()
  for zone in timeZones:
    byName[zone.name] = zone
  removeDir("zone")
  var written = 0
  var index = newJObject()
  proc writeSlice(name: string, zone: TimeZoneWithStr) =
    let path = "zone" / (name & ".json")
    createDir(path.parentDir)
    let slice = sliceFor(zone, name, changes, fromTs, toTs)
    writeFile(path, $slice)
    index[name] = %zone.name
    inc written
  for zone in timeZones:
    writeSlice(zone.name, zone)
  for alias, target in aliases:
    if byName.hasKey(target):
      writeSlice(alias, byName[target])
  writeFile("zone" / "index.json", $index)
  echo "written ", written, " per-zone slices under zone/"

proc csvToJson() =

  var timeZones = newSeq[TimeZoneWithStr]()
  var dstChangesAllowed = newSeq[DstChangeWithStr]()
  var zoneIds = newSeq[int]()

  block:
    for row in readCvs("tzdata/timezones.csv"):
      if includeOnly.len == 0 or row[2] in includeOnly:
        timeZones.add TimeZoneWithStr(
          id: parseInt(row[0]),
          name: row[2],
          )
        zoneIds.add(parseInt(row[0]))

    timeZones.sort do (x, y: TimeZoneWithStr) -> int:
      result = cmp(x.name, y.name)

    var timeZoneNames = newSeq[string]()
    for timeZone in timeZones:
      timeZoneNames.add(timeZone.name)
    dumpAliasFile(timeZoneNames)

  block:
    var prevDst = DstChangeWithStr()
    var dst = DstChangeWithStr()
    var zoneDsts = newSeq[DstChangeWithStr]()
    var dstChanges = newSeq[DstChangeWithStr]()

    proc dumpZone() =
      var startI = 0
      var endI = zoneDsts.len
      for i, innerDst in zoneDsts:
        if Timestamp(innerDst.start) < startYearTs:
          startI = i
        if Timestamp(innerDst.start) > endYearTs and endI > i:
          endI = i
      if startI > 0:
        dec startI
      for innerDst in zoneDsts[startI..<endI]:
        dstChanges.add(innerDst)

      zoneDsts = newSeq[DstChangeWithStr]()

    for row in readCvs("tzdata/dstchanges.csv"):
      dst = DstChangeWithStr(
        tzId: parseInt(row[0]),
        name: row[1],
        start: parseFloat(row[2]),
        offset: parseInt(row[3])
      )

      if prevDst.tzId != dst.tzId:
        dumpZone()

      zoneDsts.add(dst)
      prevDst = dst

    dumpZone()

    for dst in dstChanges:
      if dst.tzId in zoneIds:
        dstChangesAllowed.add(dst)

    echo "dst transitions: ", dstChangesAllowed.len

  let timeZonesJsonData = $(%*{
    "timezones": timeZones,
    "dstChanges": dstChangesAllowed
  })
  writeFile("tzdata.json", timeZonesJsonData)
  echo "written file tzdata.json ", timeZonesJsonData.len div 1024, "k"
  dumpZoneSlices(timeZones, dstChangesAllowed)

when isMainModule:
  var action = "all"
  for kind, key, val in getopt():
    if kind == cmdArgument:
      action = key
    if kind == cmdLongOption:
      case key
      of "startYear":
        startYearTs = Calendar(year: parseInt(val), month: 1, day: 1).ts
      of "endYear":
        endYearTs = Calendar(year: parseInt(val), month: 1, day: 1).ts
      of "includeOnly":
        includeOnly = val.split(",")
      else:
        quit("invalid option " & key)
    if kind == cmdShortOption:
      quit(doc)
  case action:
  of "help":
    quit(doc)
  of "all":
    fetchAndCompileTzDb()
    dumpToCsvFiles()
    csvToJson()
  of "fetch":
    fetchAndCompileTzDb()
  of "dump":
    dumpToCsvFiles()
  of "json":
    csvToJson()
  else:
    quit("invalid action " & action)
