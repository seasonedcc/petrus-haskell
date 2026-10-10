"""The reference's half of the PostgreSQL History interop suite.

Run from upstream/petrus with the pinned environment (psycopg from the
``postgres`` extra). The first argument is a libpq connection string to the
scratch database the Haskell suite also uses, so every command exercises the
shared table, rows, payloads, and transaction semantics.

Subcommands (DSN first):
  ddl                          print the reference's DDL statements as JSON
  ensure                       ensure_schema on an autocommit connection
  drop                         DROP SCHEMA IF EXISTS impetus CASCADE
  catalog                      print the impetus schema's catalog as JSON
  payloads                     print json.dumps(encode_record(r), allow_nan=False)
                               for every_record_category(), one per line
  write-every INSTANCE         extend every_record_category() in one batch
  verify-every INSTANCE        load; records equal every_record_category()
  rows INSTANCE                print the instance's rows as JSON
  records INSTANCE             print [encode_record(r)] of the loaded records
  count INSTANCE               print the loaded record count
  stale INSTANCE               open (load the count), print "ready", then for
                               every stdin line "append I" try to append
                               every_record_category()[I] and print "ok" or
                               "error <Type>: <message>"
  joined INSTANCE              join mode: open, print "ready"; stdin lines
                               "append I", "notify CHANNEL PAYLOAD", "commit",
                               "rollback"; each answers "ok"
  listen CHANNEL               LISTEN on an autocommit connection, print
                               "ready"; each stdin line "drain SECONDS" prints
                               the [channel, payload] pairs received within
                               SECONDS as JSON
"""

from __future__ import annotations

import json
import os
import sys

sys.path.insert(0, os.getcwd())

import psycopg  # noqa: E402

from petrus.impetus.history.codec import encode_record  # noqa: E402
from petrus.impetus.history_store import postgres as pg_store  # noqa: E402
from petrus.impetus.history_store.postgres import PostgresHistoryStore, ensure_schema  # noqa: E402
from tests.petrus.impetus.history_store.test_persistence import every_record_category  # noqa: E402


def _out(value) -> None:
    print(json.dumps(value), flush=True)


def _catalog(connection) -> dict:
    columns = connection.execute(
        "SELECT table_name, column_name, ordinal_position, data_type, is_nullable, column_default"
        " FROM information_schema.columns WHERE table_schema = 'impetus'"
        " ORDER BY table_name, ordinal_position"
    ).fetchall()
    indexes = connection.execute(
        "SELECT indexname, indexdef FROM pg_indexes WHERE schemaname = 'impetus' ORDER BY indexname"
    ).fetchall()
    constraints = connection.execute(
        "SELECT c.conname, c.contype::text, pg_get_constraintdef(c.oid)"
        " FROM pg_constraint c JOIN pg_namespace n ON n.oid = c.connamespace"
        " WHERE n.nspname = 'impetus' ORDER BY c.conname"
    ).fetchall()
    sequences = connection.execute(
        "SELECT sequence_name, data_type, start_value, increment FROM information_schema.sequences"
        " WHERE sequence_schema = 'impetus' ORDER BY sequence_name"
    ).fetchall()
    return {
        "columns": [list(row) for row in columns],
        "indexes": [list(row) for row in indexes],
        "constraints": [list(row) for row in constraints],
        "sequences": [list(row) for row in sequences],
    }


def _rows(connection, instance: str) -> list:
    rows = connection.execute(
        "SELECT event_id, net_instance_id, record_type, occurrence, payload::text"
        " FROM impetus.semantic_events WHERE net_instance_id = %s ORDER BY sequence",
        (instance,),
    ).fetchall()
    return [list(row) for row in rows]


def _interactive(store: PostgresHistoryStore, connection) -> None:
    records = every_record_category()
    _out("ready")
    for line in sys.stdin:
        words = line.split()
        if not words:
            continue
        try:
            if words[0] == "append":
                store.append(records[int(words[1])])
            elif words[0] == "notify":
                connection.execute("SELECT pg_notify(%s, %s)", (words[1], words[2]))
            elif words[0] == "commit":
                connection.commit()
            elif words[0] == "rollback":
                connection.rollback()
            elif words[0] == "count":
                _out(len(store))
                continue
            else:
                raise SystemExit(f"unknown line {line!r}")
            _out("ok")
        except (ValueError, RuntimeError) as error:
            _out(f"error {type(error).__name__}: {error}")


def main(dsn: str, command: str, arguments: list[str]) -> None:
    if command == "ddl":
        _out(list(pg_store._DDL))
    elif command == "payloads":
        for record in every_record_category():
            print(json.dumps(encode_record(record), allow_nan=False), flush=True)
    elif command == "joined":
        (instance,) = arguments
        with psycopg.connect(dsn, autocommit=False) as connection:
            _interactive(PostgresHistoryStore(connection, instance), connection)
    else:
        with psycopg.connect(dsn, autocommit=True) as connection:
            if command == "ensure":
                ensure_schema(connection)
            elif command == "drop":
                connection.execute("DROP SCHEMA IF EXISTS impetus CASCADE")
            elif command == "catalog":
                _out(_catalog(connection))
            elif command == "write-every":
                (instance,) = arguments
                PostgresHistoryStore(connection, instance).extend(every_record_category())
            elif command == "verify-every":
                (instance,) = arguments
                loaded = PostgresHistoryStore(connection, instance).records
                assert loaded == tuple(every_record_category()), "records differ"
            elif command == "rows":
                (instance,) = arguments
                _out(_rows(connection, instance))
            elif command == "records":
                (instance,) = arguments
                _out([encode_record(r) for r in PostgresHistoryStore(connection, instance).records])
            elif command == "count":
                (instance,) = arguments
                _out(len(PostgresHistoryStore(connection, instance)))
            elif command == "listen":
                (channel,) = arguments
                connection.execute(f"LISTEN {channel}")
                _out("ready")
                for line in sys.stdin:
                    words = line.split()
                    if words and words[0] == "drain":
                        seconds = float(words[1])
                        _out([[n.channel, n.payload] for n in connection.notifies(timeout=seconds)])
            elif command == "stale":
                (instance,) = arguments
                _interactive(PostgresHistoryStore(connection, instance), connection)
            else:
                raise SystemExit(f"unknown command {command!r}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], sys.argv[3:])
