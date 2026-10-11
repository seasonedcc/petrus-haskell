"""The reference side of CustodyInteropSpec's revision-cell group.

    storage_revision.py PATH EXPRESSION

Creates the custody store at PATH, sets its revision cell to the SQL EXPRESSION (a tampered
store), and prints what load() makes of it: {"revision": n} or {"class": ..., "message": ...}.
"""

import json
import sys
from pathlib import Path

from petrus.agenticus.connection.storage import SqliteConnectionStorage


def main() -> None:
    path, expression = sys.argv[1:]
    storage = SqliteConnectionStorage(Path(path))
    storage._database.execute(f"UPDATE connection_custody SET revision = {expression} WHERE singleton = 1")
    try:
        result = {"revision": storage.load().revision}
    except Exception as error:
        result = {"class": type(error).__name__, "message": str(error)}
    finally:
        storage.close()
    sys.stdout.write(json.dumps(result) + "\n")


if __name__ == "__main__":
    main()
