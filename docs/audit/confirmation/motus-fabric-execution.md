<!-- Dated record: confirmation audit at d869f62 (2026-10-12). Every finding is resolved or decided; see ../final.md. -->

# Confirmation audit: motus-fabric-execution

Repository: `petrus-haskell` main at `d869f62` (2026-10-12 10:20 -0300). The earlier audit was at `e47ce6b`.

Packages: petrus-activity, petrus-motus, petrus-motus-absurd, petrus-motus-zeromq, petrus-fabric, petrus-processes, petrus-execution, petrus-http-core, petrus-observation, petrus-observation-http, petrus-simulation. Also spec/fabric.md, spec/processes.md and their conformance checklists.

Method:
- I read the source and the fix commits, the CI test plan and logs of main run 38232074972 (`e861f5d`, the last main run that ran every suite after the ZeroMQ change), and the bench-gate logs of runs 38202655016 (`81bbdc5`, before the change) and 38255030541 (`d869f62`, after it).
- I did not build with cabal. I compiled two scratch reproductions with `ghc-9.10.3 -threaded` against the Homebrew libzmq 4.3.5. They are in `confirm-audit/motus-fabric-execution/repro/` and do not use the repository's code. Every process I started has been stopped. The repository is untouched.

Counts: **BLOCKER 0, MAJOR 1, MINOR 5.**

---

## 1. Earlier findings (FA-M-1 … FA-M-10)

| Finding | Status | Evidence |
|---|---|---|
| FA-M-1: exception naming seams | **Resolved** | `c5221a7`. One open hierarchy, `petrus-json/src/Petrus/Json/Python/Exception.hs:70-100` (`IsPythonException`, `SomePythonException`, `asPythonException`). `FabricError` (`petrus-fabric/src/Petrus/Fabric/Error.hs:51`), `AbsurdError`, the ZeroMQ errors and `ExecutionError` join it. Local custody calls `pythonException` (`petrus-motus/src/Petrus/Motus/Dispatch/Local.hs:699`), and that goes through `knownPythonException` → `asPythonException` (`petrus-motus/src/Petrus/Motus/PythonException.hs:137-150`). The closed `motusNames` list and `asPythonFailure`/`pythonActivityError` are gone. The new `WorkerRefusalSpec` runs in CI (shard 2 of run 38232074972: "a refused fabric.send or process.spawn is recorded as the reference Worker records it" ✔, and the reverse ✔). |
| FA-M-2: open `ActivityInvocation` | **Resolved** | `cb57de9`. `petrus-activity/src/Petrus/Activity.hs:37` exports the abstract type. `newtype ActivityInvocation` (:304) is built only by `activityInvocation` (:348) or `invocationFromJson`, with `HasField` readers (:327-340). |
| FA-M-3: bz2/xz/zstd archives refused | **Resolved** | `4a31bb5`. `Archive/Stream.hs` decodes all four codecs in tarfile's order, and the 3 GiB cap is gone. The remaining differences concern only error class and timing on corrupt input. They are documented (`petrus-execution/DIVERGENCES.md`, "Compressed archives") and checked live against the interpreter. |
| FA-M-4: direct thread-per-lane translation, `LaneSpawner` exported | **Not changed** (now documented) | `petrus-motus/src/Petrus/Motus/Worker.hs:66-67,595-599,657` is unchanged. It is documented in `petrus-motus/DIVERGENCES.md` item 20. See MINOR-4. |
| FA-M-5: Absurd int columns read as 0 | **Resolved** | `56c1564`. `petrus-motus-absurd/src/Petrus/Motus/Dispatch/Absurd.hs:1396` decodes with `Pg.decodeInt` and raises `DataError`. |
| FA-M-6: duplicated timestamptz codec | **Resolved** | `30c4118`. `petrus-postgres/src/Petrus/Postgres/Param.hs:251` (`timestamptzParam`) and `Value.hs:87` (`decodeTimestamptz`) are used by Fabric and Absurd. |
| FA-M-7: `DoorScoped` | **Resolved** | `53fcd12`. `DoorAnswer` is `DoorFired`/`DoorPrior` only (`petrus-fabric/src/Petrus/Fabric/Ingress.hs:31`). `engineDoor` refuses the scoped acknowledgement itself (DIVERGENCES row 4). |
| FA-M-8: silent ZAP thread, unowned announce | **Resolved, but the stop now depends on a cancel that can be lost** | `bc84d5c`. `Curve.hs:225-234` uses `asyncWithUnmask` + `link`, and stops with `cancel`. `Cli.hs:93` uses `withAsync (announce server)`. The later `zmq_poll` change makes that `cancel` unreliable: see MAJOR-1. |
| FA-M-9: `Number` Eq/Ord disagree on NaN | **Resolved in substance** | `f072f6d`. `Eq` is defined as `compare == EQ` (`petrus-activity/src/Petrus/Activity/Number.hs:37-38`), so the two are lawful together. Residual nit: `Show` is still Python repr (:92-93), not renamed as suggested. No severity. |
| FA-M-10: ad hoc spawn-worker protocol | **Mostly resolved** | `75d3850`. Refusals of `fabric.send` and `process.spawn` now go through real Local custody in both directions (`petrus-processes/test/Petrus/Processes/WorkerRefusalSpec.hs`). The successful P-079 demo path still uses the bespoke line protocol: see MINOR-5. |

---

## 2. Findings

### MAJOR-1: The `zmq_poll` wait under the threaded RTS can lose cancellation. `stopAuthenticator` (and with it a CURVE server's shutdown) can then hang forever. The change also does not meet the README design rule.

**Where**
- `packages/petrus-motus-zeromq/src/Petrus/Motus/Transport/ZeroMQ/Native.hsc:339-340`:
  ```haskell
  if rtsSupportsBoundThreads
    then pollFor s wanted (maybe (-1) (const ((remaining + 999) `div` 1000)) deadline)
  ```
- `Native.hsc:350-362`: `pollFor`, `foreign import capi interruptible "zmq.h zmq_poll"`.
- The change was introduced in `5a73d7a`, a commit titled "Bench reruns …". No test was added with it.

**What is wrong**
- An `interruptible` call is cancelled by the RTS sending the OS thread one signal (`pthread_kill`) when `throwTo` targets it. The signal interrupts the call only if it lands inside a blocking syscall.
- `zmq_poll` is not a single syscall. When it wakes for a mailbox *command* rather than for `POLLIN`, it processes the commands in user space and polls again. A signal that lands in that user-space window is lost, and the second `poll()` gets the remaining timeout.
- With a deadline, cancellation is then late, by up to the deadline: 100 ms on the server loop, the request timeout on the client.
- With **no deadline**, the call is `zmq_poll(…, -1)`. It never returns until a real message arrives, and the `throwTo` blocks until then.
- The earlier IO-manager wait capped every wait at 50 ms, so a missed wake could only delay. The new path dropped that bound.

**Where it bites: the ZAP authenticator**
- It waits with `Z.receiveFrames socket Nothing` (`Curve.hs:218`) and is stopped by `cancel` (`Curve.hs:233-234`).
- The server's cleanup (`Server.hs:201-204`) runs `Z.closeSocket socket` and then `stopAuthenticator` immediately.
- Closing the ROUTER ends its CURVE sessions. Each session holds an inproc ZAP pipe, so the ZAP socket receives a burst of pipe-termination commands at the exact moment the cancel signal is sent.

**Reproduction** (`repro/Burst.hs`)
- The program mirrors this sequence: a REP socket waited on exactly as `awaitEvent` does with no deadline, N inproc peers connected, then all peers closed, then `killThread` at once.
- On this machine (M4, GHC 9.10.3 `-threaded`, libzmq 4.3.5):

  | Configuration | Kills not delivered within 2 s | Output file |
  |---|---|---|
  | `-1`, 20 peers | 44 of 47 trials (stopped early) | `burst-infinite.txt` |
  | `-1`, 1 peer | 49 of 56 trials (stopped early) | `burst-1peer.txt` |
  | `-1`, no peers | 0 of 100 | `burst-nopeers.txt` |
  | 50 ms cap, 20 peers | 0 of 200 | `burst-capped.txt` |

- `repro/Repro.hs` shows the same with continuous peer churn.
- A stuck kill ends only when a real request reaches the socket. At server shutdown no request comes, so `serveForever`'s cleanup would block for ever, and `terminateContext` is never reached.
- The CI test that stops a CURVE server ("curve tcp allows approved key…", `TransportSpec.hs:389`) closes its clients *before* stopping the server, so it does not exercise this ordering.

**Why it matters**
- Outcome 5 and the README's standing rule.
- The README allows a low-level optimization only "behind a safe, total interface". This one keeps the interface but makes it unsafe: cancellation of a ZeroMQ wait is no longer guaranteed.
- The module header still promises the opposite (`Native.hsc:14-16`: "It still composes with `System.Timeout.timeout` and asynchronous exceptions, which interrupt the call").

**Design rule check**
- *A benchmark shows the clean version cannot keep up*: **met, on Linux only.**
  - CI bench-gate at `81bbdc5` (run 38202655016, job 114660170314), with the IO-manager wait: `zeromq/memory/claim-empty-100` 0.90× (FAIL), `custody-20` 0.98× (FAIL).
  - After the change: 1.11×/1.28× (run 38255030541) and 1.18–1.19×/1.27–1.36× (experiment runs 38206418285).
  - On macOS the clean version already won every row (1.14×–1.71×, `bench/RESULTS.md:100-113`).
- *In the lowest layer*: **met.** The change is in `Native.hsc`.
- *Behind a safe, total interface*: **not met** (above).
- *The measurement recorded beside it*: **not met.** The Linux figures that justify the change are not recorded anywhere in the repo. `RESULTS.md` records only the macOS figures, which show the change was *not* needed there, plus an unquantified sentence ("on the Linux CI runners that was enough to put a request round trip behind pyzmq's"). The code comment carries no figure either.

**Fix**
- Keep `zmq_poll` (it is what wins on Linux), but never wait unbounded. Pass `min 50 remainingMs` and use 50 ms when there is no deadline, as the old path's cap did. The reproduction's capped run shows this restores delivery (0/200 lost) at no measurable cost to a busy socket.
- Then correct the header comment to say exactly that: "interruptible, and bounded at 50 ms so a lost interrupt only delays".
- Add a test that stops a CURVE server while clients are still connected (and one that cancels a no-deadline receive during peer churn), under a hard timeout.
- Record the Linux before/after bench-gate figures, with their run IDs, in `bench/RESULTS.md` next to the macOS ones, and cite them in the `Native.hsc` header.

### MINOR-1: The ZeroMQ docs still describe the IO-manager wait. The non-threaded branch is dead and untested.

- `packages/petrus-motus-zeromq/README.md:60-64` still says "It waits on `ZMQ_FD` through the GHC IO manager … So a wait never blocks an OS thread".
- `DIVERGENCES.md:103-106` (item 9) still says the binding "waits through the GHC IO manager; README.md explains why".
- Both are now false for every built component. Each waiting socket holds an OS thread in a safe call.
- Every component that links the package is `-threaded`: the library's executable, test suite and benchmark (`petrus-motus-zeromq.cabal:72,100,119`), and nothing else in the repo depends on it. So the `threadWaitRead` branch (`Native.hsc:341-343`) is compiled but never run by any test or by CI.
- **Matters for:** outcome 5 (comments must match the code) and outcome 7 (untested code path).
- **Fix:** update both documents along with MAJOR-1's fix. Either drop the non-threaded branch (and require `-threaded`, documenting it), or add one non-threaded test target that exercises it.

### MINOR-2: The specs name "the Haskell port" where a language-neutral contract should name "an implementation"

- **Where:**
  - `spec/fabric.md:5-7` ("so that a second implementation (the Haskell port) can share…");
  - `spec/fabric.md:922-923` ("This port adopts it as the interoperable profile (**CONTRACT for this port**…)");
  - `spec/fabric.md:331,924`;
  - `spec/processes.md:12-14,65`;
  - both "1.1 Revisions" sections ("after the Haskell port ran every check").
- The substance is neutral. Python is cited only as provenance, and every rule is restated in implementation-free terms (for example §3.3's float spelling). But these sentences scope the contract to this repository's port. §11 makes the `fabric.send` profile a contract "for this port", where it should bind any conforming implementation.
- **Matters for:** outcome 4 (a language-neutral contract).
- **Fix:**
  - Reword to "a second implementation" and "this specification adopts … (**CONTRACT**; upstream: demo convention)".
  - Move port history out of the normative text, for example into the conformance checklists or a changelog.

### MINOR-3: `spec/` is not laid out like the upstream specs it sits beside

- Upstream `spec/README.md` indexes every document (§1a), defines one citation convention (`[ADR NNNN]`, `[DR <date> <slug>]`, §1b) and one marker convention (`**OPEN:**`, §1c).
- Here `spec/` has no index. The documents cite decision records as bare slugs in a bullet list (`spec/fabric.md:19-20`, `spec/processes.md:27-28`) instead of the bracketed inline form. They define their own marker set (CONTRACT/ACCIDENT/OPEN, `spec/fabric.md:34-45`) without relating it to upstream's.
- The root `README.md:34` is the only pointer to the directory.
- **Matters for:** outcome 4 ("written like the other spec documents").
- **Fix:**
  - Add `spec/README.md`, mirroring upstream's §1a–1c. It should list fabric.md, processes.md and the three conformance checklists, and state that CONTRACT/ACCIDENT extend upstream's `**OPEN:**` convention.
  - Cite decision records inline as `[DR 2026-07-20T1114Z process-fabric-is-an-inter-authority-protocol-plane]`.

### MINOR-4 (carried from FA-M-4): The sync bridge's lanes are a translation of Python's per-slot threads

- **Where:** `packages/petrus-motus/src/Petrus/Motus/Worker.hs:595-599` (`LaneSpawner`, `forkLane = void . forkIO`), `:603-636` (a `Chan` per lane), and `:657` (`lanes !! slot`, partial and guarded only by a comment).
- **What is wrong:**
  - A `forkIO` thread gives no OS-thread affinity, so the lane provides only mutual exclusion per slot, which an `MVar`/`Array` of providers gives directly.
  - `LaneSpawner` is exported only so a test can fake `Thread.start` failing.
  - DIVERGENCES item 20 now documents the choice, but it gives no reason to keep the lane design over the simpler one.
- **Matters for:** outcome 5.
- **Fix:**
  - Hold the providers in an `Array Int (MVar WorkerDispatch)`, built by the factory in order (or `forkOS` if real affinity is ever needed).
  - Drop `LaneSpawner`/`forkLane` from the API, and test a factory failure through the factory.

### MINOR-5 (residual of FA-M-10): Successful cross-language `process.spawn` at Engine level still bypasses Motus custody

- **Where:** `packages/petrus-processes/demo/Petrus/Processes/Demo.hs:424-470` (`--internal-spawn-worker`) and `test/interop/lifecycle_spawn_worker.py`. The P-079 demo configurations exchange invocations over a private line-JSON protocol, and the worker answers `{"ok"|"error", "ensure_calls"}`.
- **What is covered and what is not:**
  - Refusals go through real Local custody both ways (WorkerRefusalSpec).
  - Spawn outcomes are compared at the Activity level (InteropSpec P-079/P-080).
  - But no test has a parent Engine of one language collect a *successful* spawn executed by the other language's Worker through a real Dispatch. The same holds for a successful `fabric.send`.
- **Matters for:** outcome 4.
- **Fix:**
  - Drive `--spawn-worker-command` through a Local Dispatch file, the same way WorkerRefusalSpec does: the parent Engine dispatches and the other language's Worker runs `process.spawn`/`fabric.send`.
  - Then delete the bespoke protocol.

---

## 3. Outcome 4: where the contract lives, and whether the cross-language tests really run

**The contract**
- It lives in `spec/fabric.md` (Fabric protocol v1: values, canonical JSON, digests, the `impetus_fabric` DDL, operations, ingress, the §11 `fabric.send` profile, §12 error categories) and `spec/processes.md` (call payloads and envelopes, SpawnSpec, child identity, the `process.spawn` algorithm and outcome, the lineage registry, the provisioner port).
- The executable checklists are `spec/fabric-conformance.md` (108 checks) and `spec/processes-conformance.md` (80 checks).
- The content is language-neutral, with Python cited as provenance; the wording issues are MINOR-2 and MINOR-3.

**The tests, as run by CI**
- Main run 38232074972 at `e861f5d` includes the ZeroMQ change and every fix above:
  - shard 4: `petrus-fabric-test: passed (242 examples, 0 pending)`;
  - shard 2: `petrus-processes-test: passed (225 examples, 0 pending)`;
  - `scripts/check-pending` ran on both.
- The suites at HEAD have not changed since then. The README-only main run 38247811483 reused them by input hash.

**Both directions, as the logs show**
- **Conformance:** every F-/P- check runs under "Haskell port" and again under "Python reference". The Python side is the pinned reference, driven through `test/interop/conformance_driver.py` (`withPythonImpl`, `petrus-fabric/test/Petrus/Fabric/Conformance/Impl.hs:103-115`).
- **Messaging** (`both` runs each check as `[Python, then Haskell]` and `[Haskell, then Python]`, `Conformance/Setup.hs:136-156`):
  - F-102/F-103 submit/drain/acknowledge/receipt;
  - F-104 duplicates and conflicts;
  - F-105 discovery;
  - F-106 pruning;
  - F-108 a recipient History resumed by the other implementation;
  - F-107, the CV5 demo split four ways (Haskell orchestrator with a Python child, and with a Python parent; Python orchestrator with a Haskell child, and with a Haskell parent).
- **Call:**
  - P-038 result and error round trips, in both orders;
  - the lifecycle demo with a Haskell parent and Python child host, and a Python parent and Haskell child host.
- **Spawn:**
  - P-079 the same outcome JSON from either implementation, in both orders;
  - P-080 attempted in one and retried in the other, in both orders;
  - the demo with a Haskell parent Engine and a Python spawn worker, and the reverse, plus the mixed configuration;
  - refused send and spawn recorded identically through real Local custody, in both directions.

**Verdict:** outcome 4 **holds**. The spec should be reworded (MINOR-2/3), and Engine-level success paths should go through real custody (MINOR-5).

---

## 4. Verified as holding (fresh look)

- **Exception hierarchy** (FA-M-1 fix): open and extensible. Each port error declares its Python class once, and Inline, Local, Absurd and ZeroMQ custody, telemetry and `FailureText` all consult the same `asPythonException`.
- **Fabric DIVERGENCES row 2** now states accurately what each dispatcher records.
- **Spec consistency with the code:** spec/fabric.md §9 still matches the `DoorAnswer` change (a door answer of any other type is a `TypeError`, `spec/fabric.md:856,889`).
- **CI wiring:**
  - the test plan of run 38232074972 puts petrus-motus-zeromq (49), petrus-motus-absurd (127), petrus-processes (225), petrus-fabric (242), petrus-execution, petrus-http-core (108), petrus-observation(-http), petrus-simulation and petrus-activity on shards, all 0 pending;
  - the zeromq bench-gate rows are gated nightly and on full runs, and pass after the change.
- **ZeroMQ `pollFor` mechanics are otherwise correct:**
  - the `zmq_pollitem_t` layout through hsc2hs, the `long` timeout and the EINTR handling are right;
  - libzmq 4.3.5's `zmq_poll` uses `poll()` for these non-thread-safe socket types and returns −1/EINTR on an interrupted `poll()`. The no-peers reproduction confirms that an idle wait is cancelled (0/100 lost).
- **Execution's other low-level waits keep their measurements beside them.** The Gondolin sidecar's interruptible `poll()` is bounded by its tick (`Gondolin.hs:548-561`), and RESULTS.md records 0.141 → 0.033 ms per handshake. `posix_spawn` records 118 ms → about 1 ms. The bzip2 C shim is justified by a correctness defect in `bzlib`, documented in DIVERGENCES.
- **Archive decoding** (FA-M-3 fix): xz runs in lazy ST. bzip2 and zstd use `unsafePerformIO` plus `unsafeInterleaveIO` over a ForeignPtr'd decoder that each `restart` creates afresh, so state is advanced exactly once per thunk. This is acceptable, and it is confined to `Archive.Stream`.
- **Earlier verified items** spot-checked again and unchanged since `e47ce6b`: the Fabric canonical encoder, digest, SQL text, inbox drain; processes payloads and spawn order; and the observation and simulation HTTP routes.
