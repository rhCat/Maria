-------------------------------- MODULE MariaSetup --------------------------------
\* Maria shared-node setup — the ordering contract between disk and process.
\* Version 1.0.0
\*
\* WHY THIS SPEC EXISTS. Bringing Maria up against a govd node failed with HTTP 401
\* while every artefact on disk was demonstrably correct: the chip served the gate's
\* skill, auth_verifier was "ed25519", the registry declared the agent's subject
\* byte-for-byte, clocks agreed, the signature and TTL verified. Hours went into
\* re-checking those artefacts because the thing that was wrong is not an artefact.
\*
\* govd reads its configuration ONCE, at process start, and serves from that
\* snapshot. So there are two distinct states — what is on DISK and what the serving
\* process LOADED — and every check we ran inspected the first while the 401 was
\* decided by the second. This module makes that distinction explicit, so the
\* precondition for a claim to authenticate can be stated and proved rather than
\* rediscovered.
\*
\* Check with the backbone skill: general:backbone / validate | tlc | tlaps.

EXTENDS Naturals, FiniteSets, TLAPS

CONSTANTS
    Subjects,        \* the set of possible agent subjects ("ed25519:<16 hex>")
    NoSubject,       \* the agent has no key yet
    NoVerifier       \* auth_verifier unset -> the bearer-secret default

ASSUME SubjectsAssumption ==
    /\ Subjects # {}
    /\ NoSubject \notin Subjects
    /\ NoVerifier # "ed25519"

VARIABLES
    chipHasGate,     \* does the served chip declare hermes:toolgate
    diskVerifier,    \* auth_verifier in govd.json ON DISK
    diskRegistry,    \* subjects declared in principals.json["principals"] ON DISK
    loadedVerifier,  \* the scheme the SERVING process registered at startup
    loadedRegistry,  \* the registry the SERVING process holds
    agentSubject     \* the subject the agent signs with, or NoSubject

vars == <<chipHasGate, diskVerifier, diskRegistry,
          loadedVerifier, loadedRegistry, agentSubject>>

Verifiers == {NoVerifier, "ed25519"}

TypeOK ==
    /\ chipHasGate    \in BOOLEAN
    /\ diskVerifier   \in Verifiers
    /\ diskRegistry   \subseteq Subjects
    /\ loadedVerifier \in Verifiers
    /\ loadedRegistry \subseteq Subjects
    /\ agentSubject   \in Subjects \cup {NoSubject}

\* ---------------------------------------------------------------------------
\* The precondition for a claim to AUTHENTICATE. Note every conjunct names a
\* LOADED value, never a disk value. That is the whole point.
\* ---------------------------------------------------------------------------
Authenticates ==
    /\ agentSubject # NoSubject
    /\ loadedVerifier = "ed25519"
    /\ agentSubject \in loadedRegistry

\* What every diagnostic we ran actually measured.
DiskCorrect ==
    /\ agentSubject # NoSubject
    /\ diskVerifier = "ed25519"
    /\ agentSubject \in diskRegistry

\* A claim is GOVERNED (reaches policy evaluation and is recorded) only after it
\* authenticates AND the chip declares the skill the gate claims against. An
\* unverified skill is a fail-closed deny, and a 401 is refused before any run
\* is recorded — which is why the ledger stays empty rather than showing rejects.
Governed == Authenticates /\ chipHasGate

Init ==
    /\ chipHasGate    = FALSE          \* a fresh node serves a chip without the gate skill
    /\ diskVerifier   = NoVerifier
    /\ diskRegistry   = {}
    /\ loadedVerifier = NoVerifier
    /\ loadedRegistry = {}
    /\ agentSubject   = NoSubject

\* --- operator actions on DISK -----------------------------------------------
FetchChip ==                                    \* chipfetch re-pull
    /\ chipHasGate' = TRUE
    /\ UNCHANGED <<diskVerifier, diskRegistry, loadedVerifier, loadedRegistry, agentSubject>>

SetVerifier ==                                  \* write auth_verifier to govd.json
    /\ diskVerifier' = "ed25519"
    /\ UNCHANGED <<chipHasGate, diskRegistry, loadedVerifier, loadedRegistry, agentSubject>>

MintKey(s) ==                                   \* openssl rand -hex 32, derive subject
    /\ s \in Subjects
    /\ agentSubject' = s
    /\ UNCHANGED <<chipHasGate, diskVerifier, diskRegistry, loadedVerifier, loadedRegistry>>

RegisterPrincipal ==                            \* add subject under the "principals" key
    /\ agentSubject # NoSubject
    /\ diskRegistry' = diskRegistry \cup {agentSubject}
    /\ UNCHANGED <<chipHasGate, diskVerifier, loadedVerifier, loadedRegistry, agentSubject>>

\* --- the only action that moves DISK state into the PROCESS ------------------
\* docker restart: serve() re-reads the config and calls install_builtin_verifier.
Reload ==
    /\ loadedVerifier' = diskVerifier
    /\ loadedRegistry' = diskRegistry
    /\ UNCHANGED <<chipHasGate, diskVerifier, diskRegistry, agentSubject>>

Next ==
    \/ FetchChip
    \/ SetVerifier
    \/ (\E s \in Subjects : MintKey(s))
    \/ RegisterPrincipal
    \/ Reload

Spec == Init /\ [][Next]_vars

\* ---------------------------------------------------------------------------
\* THEOREMS
\* ---------------------------------------------------------------------------

THEOREM TypeCorrect == Spec => []TypeOK
<1>1. Init => TypeOK
  BY DEF Init, TypeOK, Verifiers
<1>2. TypeOK /\ [Next]_vars => TypeOK'
  <2> SUFFICES ASSUME TypeOK, [Next]_vars PROVE TypeOK'
    OBVIOUS
  <2>1. CASE FetchChip
    BY <2>1 DEF TypeOK, FetchChip, vars
  <2>2. CASE SetVerifier
    BY <2>2 DEF TypeOK, SetVerifier, Verifiers, vars
  <2>3. CASE \E s \in Subjects : MintKey(s)
    BY <2>3 DEF TypeOK, MintKey, vars
  <2>4. CASE RegisterPrincipal
    BY <2>4 DEF TypeOK, RegisterPrincipal, vars
  <2>5. CASE Reload
    BY <2>5 DEF TypeOK, Reload, vars
  <2>6. CASE UNCHANGED vars
    BY <2>6 DEF TypeOK, vars
  <2>7. QED
    BY <2>1, <2>2, <2>3, <2>4, <2>5, <2>6 DEF Next
<1>3. QED
  BY <1>1, <1>2, PTL DEF Spec

\* Fail-closed: with no verifier registered in the SERVING process, nothing
\* authenticates — regardless of what the registry on disk declares. This is the
\* 401 we observed, and it is the correct behaviour, not a fault.
THEOREM FailClosed == TypeOK => (loadedVerifier # "ed25519" => ~Authenticates)
BY DEF TypeOK, Authenticates

\* An unregistered subject never authenticates, however well-formed its assertion.
THEOREM UnregisteredDenied ==
    TypeOK => (agentSubject \notin loadedRegistry => ~Authenticates)
BY DEF TypeOK, Authenticates

\* THE LOAD-BEARING ONE. Authentication depends only on LOADED state, so a
\* correct disk cannot by itself imply a working agent. Everything we verified
\* during the outage was DiskCorrect; none of it was evidence of Authenticates.
THEOREM DiskIsNotEnough ==
    TypeOK => (Authenticates => (loadedVerifier = "ed25519" /\ agentSubject \in loadedRegistry))
BY DEF TypeOK, Authenticates

\* ---------------------------------------------------------------------------
\* THE TRAP, as a property TLC must REFUTE.
\*
\* If this held, a correct disk would guarantee a working agent and the outage
\* would have been impossible. TLC finds a counterexample in three steps:
\*   SetVerifier, MintKey, RegisterPrincipal   (disk correct, never reloaded)
\* The counterexample IS the bug report. Keep this invariant in the .cfg so the
\* violation is reproduced on every run rather than remembered.
\* ---------------------------------------------------------------------------
DiskCorrectImpliesAuth == DiskCorrect => Authenticates

\* Reload is the only action that can establish the precondition, so ordering is
\* forced: reload AFTER both writes, or the process serves a stale snapshot.
\* (Checked by TLC; stated here as the operational rule the SOP encodes.)
ReloadEstablishes ==
    (DiskCorrect /\ loadedVerifier = diskVerifier /\ loadedRegistry = diskRegistry)
        => Authenticates

=============================================================================
