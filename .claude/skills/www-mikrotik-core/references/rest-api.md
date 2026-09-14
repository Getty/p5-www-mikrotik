# RouterOS REST API — wire reference

Digest of https://help.mikrotik.com/docs/spaces/ROS/pages/47579162/REST+API
(RouterOS 7.1beta4+). Examples verbatim from the vendor page.

## Endpoint and auth

- URL: `https://<router>/rest/<path>` — `www-ssl` service, on by default.
  `http://<router>/rest/…` via the `www` service from 7.9 (testing only —
  credentials are readable on the wire).
- Auth: HTTP Basic with a console user (`curl -u admin:password`).
- JSON per ECMA-404 with one deviation: **all values are encoded as strings**,
  numbers and booleans included. Incoming numbers may be decimal, octal
  (leading `0`) or hex (`0x`); no exponent notation.

## Method mapping

| HTTP | console | notes |
|---|---|---|
| GET | print | list, or single record by `.id`/name |
| PUT | add | one record per request; returns the created record |
| PATCH | set | one record by `.id`; returns the full updated record |
| DELETE | remove | by `.id`; empty response on success |
| POST | any command | command word is the last path segment; params in body |

## GET

```
GET /rest/ip/address
[{".id":"*1","actual-interface":"ether2","address":"10.0.0.111/24","disabled":"false",
"dynamic":"false","interface":"ether2","invalid":"false","network":"10.0.0.0"},
{".id":"*2","actual-interface":"ether3","address":"10.0.0.109/24","disabled":"true",
"dynamic":"false","interface":"ether3","invalid":"false","network":"10.0.0.0"}]

GET /rest/ip/address/*1          → the single object
GET /rest/interface/ether1       → by name where the menu supports it
GET /rest/ip/address?network=10.155.101.0&dynamic=true      → filter (AND)
GET /rest/ip/address?.proplist=address,disabled             → field selection
[{"address":"10.0.0.111/24","disabled":"false"},{"address":"10.0.0.109/24","disabled":"true"}]
```

## PUT (add)

```
curl -k -u admin: -X PUT https://10.155.101.214/rest/ip/address \
  --data '{"address": "192.168.111.111", "interface": "dummy"}' \
  -H "content-type: application/json"
{".id":"*A","actual-interface":"dummy","address":"192.168.111.111/32","disabled":"false",
"dynamic":"false","interface":"dummy","invalid":"false","network":"192.168.111.111"}
```

## PATCH (set)

```
curl -k -u admin: -X PATCH https://10.155.101.214/rest/ip/address/*3 \
  --data '{"comment": "test"}' -H "content-type: application/json"
{".id":"*3","actual-interface":"dummy","address":"192.168.99.2/24","comment":"test",
"disabled":"false","dynamic":"false","interface":"dummy","invalid":"false","network":"192.168.99.0"}
```

## DELETE (remove)

```
curl -k -u admin: -X DELETE https://10.155.101.214/rest/ip/address/*9
                                  → success: empty body
                                  → 404 {"error":404,"message":"Not Found"}
```

## POST (commands)

Result shape mirrors the binary API: `!re` sentences → list of objects,
`!done` with data → one object, neither → `[]`.

```
POST /rest/system/resource/print
[{"architecture-name":"tile","board-name":"CCR1016-12S-1S+",
"build-time":"Dec/04/2020 14:19:51","cpu":"tilegx","cpu-count":"16",
"cpu-frequency":"1200","cpu-load":"1","free-hdd-space":"83439616",
"free-memory":"1503133696","platform":"MikroTik",
"total-hdd-space":"134217728","total-memory":"2046820352",
"uptime":"2d20h12m20s","version":"7.1beta4 (development)"}]

POST /rest/ping            {"address":"10.155.101.1","count":"4"}
[{"avg-rtt":"453us","host":"10.155.101.1","max-rtt":"453us","min-rtt":"453us","packet-loss":"0","received":"1","sent":"1","seq":"0","size":"56","time":"453us","ttl":"64"},
 {"avg-rtt":"417us","host":"10.155.101.1","max-rtt":"453us","min-rtt":"382us","packet-loss":"0","received":"2","sent":"2","seq":"1","size":"56","time":"382us","ttl":"64"},
 …]

POST /rest/password        {"old-password":"old","new-password":"N3w","confirm-new-password":"N3w"}
POST /rest/system/script/run          {".id":"*1"}
POST /rest/execute                    {"script":"/log/info test"}
POST /rest/export                     {"compact":"","file":"test.rsc"}
POST /rest/ip/firewall/nat/move       {".id":"*9",".id":"*C"}     (numbers → destination)
POST /rest/interface/lte/monitor      {"numbers":"0","once":""}
POST /rest/interface/wifi/monitor     {"numbers":"wifi1","once":""}
POST /rest/interface/lte/firmware-upgrade   {"number":"lte2"}
POST /rest/system/resource/print      {"oid":""}                  (SNMP OIDs)
POST /rest/tool/bandwidth-test        {"address":"10.155.101.1","duration":"2s"}
```

A flag parameter (`once`, `compact`, `oid`) is sent as an empty string.

### `.proplist`

Comma-separated string or list of strings; POST `print` only.

```
{".proplist":"name,type"}
{".proplist":["name","type"]}
```

### `.query`

List of query words, applied as a stack — same semantics as `?` words in the
binary API. `#|` OR, `#&` AND, `#!` NOT, applied to what is on the stack.

```
POST /rest/interface/print
{".query":["type=ether","type=vlan","#|!"]}       ≡  ?type=ether ?type=vlan ?#|!

POST /rest/ip/address/print
{".proplist":[".id","address","interface"],
 ".query":["network=192.168.111.111","dynamic=true","#|"]}
[{".id":"*8","address":"10.155.101.214/24","interface":"sfp12"},
 {".id":"*A","address":"192.168.111.111/32","interface":"dummy"}]
```

## Errors

HTTP status carries the verdict; body on ≥ 400:

```
{"error":<code>,"message":"<description>","detail":"<optional>"}
{"error":406,"message":"Not Acceptable","detail":"no such command or directory (remove)"}
{"detail":"Session closed","error":400,"message":"Bad Request"}   ← 60 s timeout hit
```

## Limits

- Request timeout **60 s**; a command that does not finish is cut off with the
  400 above. No continuous/streaming commands: `monitor` needs `once`, `ping`
  needs `count`, `bandwidth-test` needs `duration`.
- One record per PUT.
- Multi-row command output uses `.section` to group rows (see `bandwidth-test`).
