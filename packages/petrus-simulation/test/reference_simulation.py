"""The upstream simulation HTTP server, for byte-level comparisons.

Usage: python -I reference_simulation.py MODE

MODE is one of:

- ``real``: ``tests.simulation_support.build_scenario()`` served with the
  real ``simulate``;
- ``failing``: the same build, with ``simulate`` replaced by one that raises
  ``ValueError("secret")`` (an unexpected producer failure).

Prints the bound port, serves until stdin closes, then shuts down.
"""

import sys
import threading
import warnings

sys.path.insert(0, ".")  # run from upstream/petrus: its ``tests`` package

from tests.simulation_support import build_scenario  # noqa: E402
import petrus.simulation_http as simulation_http  # noqa: E402
from petrus.simulation_http import create_simulation_server  # noqa: E402

ORIGIN = "http://localhost:5173"


def failing(*args, **kwargs):
    raise ValueError("secret")


def main() -> None:
    mode = sys.argv[1]
    # CEL filter and completion evaluation failures are warnings upstream.
    warnings.simplefilter("ignore")
    if mode == "failing":
        simulation_http.simulate = failing
    built, _ = build_scenario()
    server = create_simulation_server(built, "127.0.0.1", 0, allowed_origin=ORIGIN)
    thread = threading.Thread(target=server.serve_forever)
    thread.start()
    print(server.server_port, flush=True)
    sys.stdin.read()
    server.shutdown()
    server.server_close()
    thread.join()


if __name__ == "__main__":
    main()
