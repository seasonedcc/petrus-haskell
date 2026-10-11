# hamsterdan-e2e: divergences from the Python twins

The Haskell replay (`Hamsterdan.E2E.Replay`) and carried agent
(`Hamsterdan.E2E.Agents`) are twins of `python/replay_python.py` and
`python/host_seams.py`. On every tape the reference records they report
the same steps, calls and mismatches (tier B and the carried-agent tests
compare them), and `python/raise_check.py` checks that recorded failures
raise alike. The seams the Haskell host offers them are listed in
`../hamsterdan-host/DIVERGENCES.md` ("The end-to-end seams").

The differences are confined to tapes the reference never writes:

1. **A tape member of the wrong type is refused.** The Python twins index
   records (`record["attempt"]`) and pass the value on, so a missing member
   raises `KeyError` but a mistyped one travels until something uses it.
   The Haskell twins read each member as the type the replay needs
   (`Hamsterdan.E2E.Tape.field`) and throw a `TapeError` naming the member
   when it is missing or mistyped, at the same point the reference reads
   it: when the runner is built for the call keys, within the step for a
   step's members (so the step fails, as an exception in the reference's
   step does). Why: a typed read with a loud failure, instead of the
   defaults (`""`, `0`, `[]`) the accessors once fell back to, which could
   turn a damaged tape into a silently different replay.
2. **A recorded `failure_class` must be one the Haskell type knows.** The
   reference passes `GitHubBoundaryError(failure_class=...)` any string
   (the parameter is a `Literal` that Python does not check); the Haskell
   error holds a `FailureClass`, so another spelling is refused as a
   `TapeError`. The recorder only writes the five classes.
3. **A tape line holding a lone surrogate escape is refused at load.**
   `tape.read` uses `json.loads`, which accepts `"\ud800"`; `readTape`
   uses `pythonLoads`, which refuses it. The recorder writes decoded HTTP
   bodies and agent results, which come from UTF-8 and so hold no lone
   surrogates.
