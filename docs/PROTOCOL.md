# Local protocol

Quoll exposes one Unix-domain socket. The socket path defaults to
`~/Library/Application Support/Quoll/quoll.sock`, is chmod-ed to `0600` right after `bind` (the data
directory itself is per-user),
and carries one JSON object per line in each direction.

## Request

```json
{
  "id": "42",
  "command": "search",
  "query": "ending:swift starts:Package",
  "limit": 100,
  "offset": 0,
  "sort": "name",
  "ascending": true
}
```

`id` is echoed in the reply and is optional. `command` is required.

## Commands

| Command | Fields | Effect |
| --- | --- | --- |
| `ping` | — | health check, replies `pong` |
| `search` | `query`, `limit`, `offset`, `sort`, `ascending` | run a query |
| `status` | — | catalog and service status |
| `scan` | `paths` | make `paths` the roots and rescan; empty `paths` rescans the current roots |
| `rebuild` | — | rescan the configured roots |
| `forget` | `path` | remove a path and its subtree |
| `open` | `path` | open with the default application |
| `reveal` | `path` | reveal in Finder |
| `export` | `query`, `format` | return JSON, CSV or TSV text |
| `show` | `query` (optional) | bring up the app's window, optionally with a query |
| `opened` | `paths` | count an open (feeds the `opened` sort) |
| `stop` | — | stop the service |

`scan` and `rebuild` reply immediately (`scan started`) and run in the
background; poll `status` (`lastScan`, counts) to see the result. A full scan
runs in a short-lived helper process, so the service's memory does not grow.

## Reply

```json
{
  "id": "42",
  "ok": true,
  "count": 2,
  "total": 2,
  "tookMS": 0.8,
  "results": [
    {
      "path": "/Users/you/src/Package.swift",
      "name": "Package.swift",
      "isDirectory": false,
      "size": 812,
      "modified": "2026-11-20T08:12:00Z",
      "created": "2026-11-01T10:00:00Z",
      "accessed": "2026-11-20T08:12:00Z",
      "fileExtension": "swift",
      "level": 4,
      "mount": "/"
    }
  ],
  "warnings": []
}
```

Errors:

```json
{
  "id": "42",
  "ok": false,
  "error": {
    "code": "unknown_command",
    "message": "unknown command 'frobnicate'"
  }
}
```

Codes: `bad_request`, `unknown_command`, `unavailable`.

## HTTP

Enable the server with `quoll serve --http --port 8484` or in `settings.json`:

```json
{
  "http": {
    "enabled": true,
    "port": 8484,
    "username": "",
    "password": "",
    "root": null
  }
}
```

### Endpoints

```
GET /search?q=<query>&limit=<n>&offset=<n>&sort=<key>&asc=<0|1>&json=1
GET /status
GET /export?q=<query>&format=json|csv|tsv
GET /<static path>
```

`/search` returns HTML by default and JSON when `json=1` or the client sends
`Accept: application/json`. `+` in `q` is treated as a space.

When `username` is non-empty, every request must carry HTTP Basic
authentication. An empty username disables the check.

## Limits

- Control request size: 1 MiB.
- Control read/write timeout: 10 seconds.
- HTTP request header size: 128 KiB.
- HTTP server handles one request per connection.
