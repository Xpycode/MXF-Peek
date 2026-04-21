# Audit Report JSON Schema

**Current version:** `1.0.0`
**Writer:** `AuditReportExporter.makeJSON(...)` (in `Services/ReportGenerator.swift`)
**Wire format:** JSON, UTF-8, pretty-printed, ISO 8601 dates, slashes not escaped

## Stability guarantees

| Within a major version | Across major versions |
|------------------------|-----------------------|
| Fields may be **added** | Fields may be renamed or removed |
| Nullability may **relax** (required → optional) | Nullability may tighten (optional → required) |
| Field types do NOT change | Field types may change |
| Downstream readers that ignore unknown keys will continue to work | Consumers must check `schema_version` |

**Bumping rule:** add a minor bump (`1.1.0`) when you introduce a new field. Bump major (`2.0.0`) when you rename or remove an existing one.

## Top-level shape

```json
{
  "schema_version": "1.0.0",
  "generated_at": "2026-04-20T13:45:00Z",
  "source_folder": "/Volumes/Avid/MediaFiles/MXF/1",
  "summary": { ... },
  "clips": [ ... ]
}
```

| Key | Type | Nullable | Description |
|-----|------|----------|-------------|
| `schema_version` | string | no | Semver of this schema. Match against this before parsing. |
| `generated_at` | string (ISO 8601 UTC) | no | Timestamp the report was written. |
| `source_folder` | string | **yes** | Absolute POSIX path the scan was rooted at. `null` only when the scan wasn't rooted at a folder (e.g. drag-and-dropped individual files — future v1.x). |
| `summary` | object | no | See below. |
| `clips` | array of objects | no | Zero-or-more clip records. See below. |

## `summary` object

```json
{
  "total_clips": 42,
  "total_files": 168,
  "ungroupable_clips": 1,
  "parse_error_files": 0,
  "total_bytes": 52428800000
}
```

| Key | Type | Nullable | Description |
|-----|------|----------|-------------|
| `total_clips` | int | no | `clips.length`. |
| `total_files` | int | no | Sum of `clips[].files.length`. |
| `ungroupable_clips` | int | no | Count of clips with `is_ungroupable = true`. |
| `parse_error_files` | int | no | Count of files where `parse_error != null`. |
| `total_bytes` | int | no | Sum of every file's `size` in bytes. |

## `clips[]` object

```json
{
  "material_package_uid": "urn:smpte:umid:060a2b34.01010105.01010f20.13000000.a1b2c3d4.e5f60708.a1b2c3d4.e5f60708",
  "display_name": "A001_C001_0101XY",
  "project_name": "My Feature",
  "tape_name": "A001",
  "video_track_count": 1,
  "audio_track_count": 4,
  "duration_frames": 1250,
  "edit_rate_num": 25,
  "edit_rate_den": 1,
  "duration_seconds": 50.0,
  "total_bytes": 1200000000,
  "is_ungroupable": false,
  "files": [ ... ]
}
```

| Key | Type | Nullable | Notes |
|-----|------|----------|-------|
| `material_package_uid` | string | **yes** | Shared UMID across the clip's files. `null` when `is_ungroupable = true`. Hex-encoded form as emitted by `mxf2raw`. |
| `display_name` | string | no | Clip name from Avid metadata when available, else the first file's basename (without `.mxf`). |
| `project_name` | string | **yes** | Avid project the clip belongs to, if `mxf2raw --avid` surfaced it. |
| `tape_name` | string | **yes** | Physical source tape name / master-clip identifier when present. |
| `video_track_count` | int | no | Sum over member files of their video tracks. Typical OP-Atom: `1`. |
| `audio_track_count` | int | no | Sum over member files of their audio tracks. Typical OP-Atom: `N` for a clip with N audio stems. |
| `duration_frames` | int | **yes** | Max duration across member files, in edit units. |
| `edit_rate_num` | int | **yes** | Edit-rate numerator. Pair with `edit_rate_den`. |
| `edit_rate_den` | int | **yes** | Edit-rate denominator. Pair with `edit_rate_num`. |
| `duration_seconds` | number | **yes** | Derived: `duration_frames * edit_rate_den / edit_rate_num`. Present only when both duration and edit rate parse. |
| `total_bytes` | int | no | Sum of member file sizes. |
| `is_ungroupable` | bool | no | `true` when the file(s) had no parseable `MaterialPackageUID`. Such clips have exactly one file. |
| `files` | array of objects | no | The underlying MXF files. See below. One entry when ungroupable. |

## `clips[].files[]` object

```json
{
  "url": "/Volumes/Avid/MediaFiles/MXF/1/A001_C001_0101XY01.mxf",
  "size": 300000000,
  "parse_error": null
}
```

| Key | Type | Nullable | Notes |
|-----|------|----------|-------|
| `url` | string | no | Absolute POSIX path. |
| `size` | int | no | File size in bytes. |
| `parse_error` | string | **yes** | Short reason string when `mxf2raw --info` failed on this file; `null` on success. |

## Versioning examples

**Minor bump (1.0.0 → 1.1.0):** add `codec` to `clips[]` — safe; old readers ignore.

**Major bump (1.0.0 → 2.0.0):** rename `material_package_uid` → `umid`, or change `duration_frames` from int to decimal string.

## Reader pattern

```python
import json, sys
doc = json.load(open(sys.argv[1]))
assert doc["schema_version"].startswith("1.")
for clip in doc["clips"]:
    if clip["is_ungroupable"]:
        continue
    print(clip["display_name"], clip["total_bytes"])
```

## CSV export format

The CSV variant carries the same data as the JSON report (same `schema_version`, same source data) but in a spreadsheet-friendly flat shape — one row per clip, no nested file list. Excel / Numbers / `csv` module friendly.

### File layout

```
# source_folder,<absolute path>
# generated_at,<ISO 8601 timestamp>
# schema_version,<same version string as JSON>
material_package_uid,display_name,project_name,tape_name,video_track_count,audio_track_count,duration_frames,edit_rate,duration_seconds,total_bytes,file_count,is_ungroupable,parse_error_count
<row 1>
<row 2>
…
```

### Metadata prefix rows (`# …`)

The first 1–3 rows (up to one per metadata field present) are **prefixed with `# `** as a 2-column convention: `# key,value`. These encode the report-level metadata that the JSON variant carries as `schema_version`, `generated_at`, `source_folder` at the top level.

**This violates strict RFC 4180** (which has no comment syntax). Consequences:

- **Numbers / Excel / LibreOffice Calc**: tolerate them as short data rows; visually obvious as metadata
- **Python `csv.reader`**: returns them as 2-element rows — filter with `if row and not row[0].startswith('#')` or similar
- **`awk -F,`**: same — skip lines matching `/^#/`
- **Anything expecting a perfectly-rectangular RFC 4180 file**: will complain about column-count mismatch between metadata rows (2 cols) and data rows (13 cols)

Rationale: adding a sidecar `.meta.json` felt like overkill for a human-readable export. If a real-world consumer can't cope with the prefix rows, add a `--bare` / `writeCSVBare(...)` variant that omits them.

### Column header

Line 4 (after the 3 metadata rows) is the authoritative column list. **Always parse from that line**, not from a hardcoded position — future schema bumps may add columns.

### Escaping

Fields are escaped per **RFC 4180**:

- If the value contains comma, double-quote, CR, or LF → the entire field is wrapped in double-quotes
- Internal double-quotes are doubled (`"` → `""`)
- Line endings are `\r\n` (CRLF), not `\n`, per RFC 4180

### Worked example — minimum-viable parse

Python:

```python
import csv

with open("audit-report.csv", newline="") as f:
    rows = [r for r in csv.reader(f) if not (r and r[0].startswith("#"))]
    header, *data = rows
    for row in data:
        clip = dict(zip(header, row))
        print(clip["display_name"], clip["project_name"], clip["total_bytes"])
```

Shell:

```bash
# Just the clip rows, one per line
grep -v '^#' audit-report.csv | tail -n +2
```

## See also

- Column definitions + CSV encoder: `Services/ReportGenerator.swift::AuditReportExporter.makeCSV`
- Internal model: `Clip` in `Services/P2CardParser.swift`
- Ingest: `MXFHeaderInfo` in `Services/BMXWrapper.swift`
