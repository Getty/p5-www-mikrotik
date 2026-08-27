# WWW::MikroTik — Umsetzungsplan

Sehr einfacher Perl-Wrapper um die RouterOS-REST-API, nach dem Muster von
[`WWW::Hetzner`](../p5-www-hetzner/) — aber bewusst ohne dessen Maschinerie:
**eine Klasse**, kein Entity-Layer, keine IO-Rolle, kein CLI.

- **API-Doku:** https://help.mikrotik.com/docs/spaces/ROS/pages/47579162/REST+API
  — Digest mit allen Beispielen in `.claude/skills/perl-www-mikrotik/references/rest-api.md`
- **Base URL:** `https://<host>/rest` (www-ssl, Default) · `http://<host>/rest` ab RouterOS 7.9
- **Auth:** HTTP Basic mit Console-User
- **Besonderheiten:** alle Werte sind Strings · `.id` = `*<hex>` · PUT = add, POST = Kommando ·
  60-s-Timeout, keine Streaming-Kommandos

Board dazu: `karr board` (jede Phase ist ein Ticket).

---

## Phase 0 — Foundation ✅

- [x] `dist.ini` (`[@Author::GETTY]`, `name = WWW-MikroTik`)
- [x] `cpanfile`, `Changes`, `.gitignore`, `LICENSE`, `README.md`
- [x] `lib/WWW/MikroTik.pm` Stub + `t/00-load.t`
- [x] `.claude/` — Agenten, Rules, Skills (`perl-www-mikrotik` + Hardlinks), `briefing`
- [x] `git init`, karr-Board
- [ ] Erster Commit (macht der Maintainer)

## Phase 1 — Client-Klasse `WWW::MikroTik`

Eine Moo-Klasse, `namespace::clean`, `Log::Any` für Debug-Logging.

**Attribute** (alle `ro`, Types::Standard):

| Attribut | Typ | Default | Zweck |
|---|---|---|---|
| `host` | Str, required | — | Router-Adresse (IP oder Hostname) |
| `user` | Str | `'admin'` | Console-User |
| `password` | Str | `''` | Console-Passwort (RouterOS-Default: leer) |
| `scheme` | Enum[https,http] | `'https'` | `http` nur für Tests/Lab |
| `port` | Maybe[Int] | undef | nur setzen, wenn nicht Standardport |
| `verify_ssl` | Bool | `1` | `0` für selbstsignierte Lab-Router |
| `timeout` | Int | `60` | LWP-Timeout; RouterOS bricht selbst nach 60 s ab |
| `base_url` | lazy | `"$scheme://$host[:$port]/rest"` | Builder `_build_base_url` |
| `ua` | lazy | `LWP::UserAgent->new(...)` | **der Test-Seam** — alles mit `request($req)` → `HTTP::Response` |
| `_json` | lazy | `JSON::MaybeXS->new(canonical => 1, utf8 => 1)` | |

**Kern:** `request($method, $path, $body, %query)`

- [x] Pfad normalisieren: führenden `/` erzwingen, `.id`-Segmente (`*1A`) unverändert
      lassen (nicht URL-encoden), `base_url . $path`
- [x] `%query` → Query-String (`URI->query_form`); `.proplist` als Arrayref → `join ','`
- [x] Body (Hashref) → JSON, `Content-Type: application/json`
- [x] Basic Auth via `$req->authorization_basic($user, $password)`
- [x] Antwort: leerer Body → `undef`; sonst `decode_json`
- [x] Fehler (Status ≥ 400): JSON `{error,message,detail}` lesen, sonst Status-Line;
      `croak 'WWW::MikroTik: '.$status.' '.$message.(': '.$detail)` — kein Error-Objekt
- [x] `Log::Any`: `debug` für Request-Zeile und Body, `info` für `METHOD path -> status`

**HTTP-Verben** (je eine Zeile auf `request`):

- [x] `get($path, %query)` · `put($path, \%data)` · `patch($path, \%data)` ·
      `delete($path)` · `post($path, \%data)`

**RouterOS-Verben** (die eigentliche API für Nutzer):

- [x] `list($path, %filter)` → `get`
- [x] `add($path, %data)` → `put`, gibt den neuen Record zurück
- [x] `set($path, $id, %data)` → `patch("$path/$id")`
- [x] `remove($path, $id)` → `delete("$path/$id")`
- [x] `cmd($path, %args)` → `post`; Arrayref-Werte (z. B. `.proplist`) unverändert durchreichen
- [x] `print($path, proplist => \@, query => \@, %args)` → `cmd("$path/print", '.proplist' => …, '.query' => …)`

**Nicht bauen:** Boolean/Zahl-Konvertierung (RouterOS liefert und nimmt Strings —
`"true"`/`"false"` sind der Vertrag), Entity-Klassen, Retry, Pagination (gibt es nicht).

**POD** inline (`=attr`/`=method`, `# ABSTRACT:`), SYNOPSIS = das Beispiel aus dem
Skill `perl-www-mikrotik`.

## Phase 2 — Tests (ohne Router)

- [x] `t/lib/Test/WWW/MikroTik/MockUA.pm` — Moo-Klasse mit `request($http_request)`:
      Routen-Hash `"METHOD /rest/pfad" => Hashref | Arrayref | HTTP::Response | CODE`,
      zeichnet jeden Request auf (`requests`-Arrayref) für Assertions auf Methode, URL,
      Header, Body-Bytes
- [x] `t/10-request.t` — URL-Bau (Query, `.id` im Pfad, Port, Scheme), Basic-Auth-Header,
      Content-Type, Body-JSON kanonisch
- [x] `t/20-verbs.t` — jedes Verb → richtige Methode + Pfad; `add` ist PUT, `set` ist PATCH
- [x] `t/30-responses.t` — Listen/Objekt/leer; Fehler croaken mit Status, message, detail
      (Fixtures 1:1 aus `references/rest-api.md`)
- [x] `t/40-print.t` — `.proplist` String vs. Liste, `.query`-Stack unverändert
- [x] optional `t/90-live.t` — nur wenn `MIKROTIK_TEST_HOST` (+ `_USER`/`_PASSWORD`)
      gesetzt, sonst `skip_all`; **nur lesende Aufrufe** (`/system/resource/print`)

## Phase 3 — Release-Vorbereitung

- [ ] `Changes` unter `{{$NEXT}}` vollständig
- [x] `README.md` aus SYNOPSIS aktualisieren
- [ ] `dzil build` + `dzil test` sauber; `git status` leer (Git::GatherDir nimmt nur
      getrackte Dateien mit)
- [ ] `www-mikrotik-release-checker` laufen lassen
- [ ] Release **nur durch den Maintainer**

## Später / bewusst offen

- `bin/mikrotik.pl` (MooX::Cmd) — `mikrotik get /ip/address`, `add`, `set`, `remove`,
  `cmd` — nur wenn sich ein Bedarf zeigt
- `Net::Async::MikroTik` als Schwester-Dist: `request` überschreiben, Rest teilen —
  erst dann über eine IO-Rolle wie bei Hetzner nachdenken
- Helfer für die häufigsten Menüs (`/ip/address`, `/ip/firewall/*`, `/interface`) —
  nur als dünne Methoden, keine Entity-Klassen
