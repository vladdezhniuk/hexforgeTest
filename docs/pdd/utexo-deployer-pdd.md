# Product Design Document (PDD) — UTEXO Smart Contract Deployment Library

**Document type:** Product Design Document for the product capability *UTEXO Smart Contract Deployment Library* (product working name: **UTEXO Deployer**).
**Status:** Reviewed PDD from a product-design run. Material product decisions are stated below as decisions; everything that remains open is collected in §28.
**Scope of this run:** product intent, product boundary, operator-visible behaviour, semantics, states and non-goals. This document deliberately contains no implementation stories, execution slices, PR-level tasks, package layout, Go APIs, database schemas or code-level architecture. Where a mechanism matters it is stated as a product requirement (what must be true), never as a design of code.

---

## 1. Document Conventions: Claim Provenance and Statement Status

Claims in this document are typed, because the design step had **no access to live repositories**. Nothing in this document is presented as verified against a live repository checkout.

| Marker | Meaning |
| --- | --- |
| **[decision]** | A product decision made by this design run (or agreed before it started) and binding for the product scope below. |
| **[source snapshot]** | A statement about contract/script behaviour derived from the checked-in source-orientation snapshot of `bridge-smart-contracts` at revision `dcb9d395c109d16d7afd2e5c96464f947d303953` (branch `dev`) and/or `usdt0-smart-contracts` at revision `872548276f48cd8e71a8c1c626654a3691243aec` (branch `dev`), inspected 2026-09-30. These statements describe the *snapshot*, not a live checkout; the live repositories at those revisions remain the authority on current implementation behaviour. |
| **[diagram intent]** | Developer-provided target operational intent from the deployment sequence diagram. Strong domain input; it may describe a desired flow that is ahead of, or different from, the snapshot. |
| **[operator input]** | A value or fact that must be supplied or confirmed by an operator/stakeholder because no accepted source confirms it. |
| **[deferred]** | A capability deliberately outside the current release, named as deferred and explicitly not architecturally excluded. |
| **[open]** | A product question that is not resolvable from the supplied material; collected in §28. |

Source-attribution rule used throughout: every code-level claim is attributed to a repository name **and** a revision. Any statement that cannot be attributed is either marked as product decision, diagram intent, operator input, or is not stated as fact.

### 1.1 Decisions in force (register)

These decisions were taken before/at the start of this design and are not re-opened by this document:

1. **Go-native boundary** [decision] — Go owns transaction construction, broadcast, signing, state and UX; Foundry remains the compiler and the source of artifacts; `forge verify` is a helper. Both extremes are rejected: a thin wrapper that runs the existing `forge script` deploy scripts, and a full Solidity toolchain implemented in Go. Detailed in §5.
2. **Bridge deployment profiles** [decision] — the product fixes **both** profiles: implementation+proxy (matching current `DeployAll` semantics) and a single-transaction Bridge as the diagram depicts; addresses always come from actual nonce/receipt evidence, never from ordinal position in the diagram; the first release uses the proxy profile; the `n+2` vs `n+3` divergence is closed by the profile model rather than by silently choosing one source. Detailed in §10.
3. **First EVM release scope** [decision] — Arbitrum core + Arbitrum `UtexoLZAdapter` + Ethereum `UtexoSourceEntrypoint`; TRON later. Both "Arbitrum core only" and "everything including TRON at once" are rejected. Detailed in §6, §7, §8.
4. **Operator surface** [decision] — exactly one non-interactive CLI with the commands `plan` / `preflight` / `apply` / `status` / `resume`, machine-readable output, and confirmation for irreversible actions. Interactive CLI/TUI as the main surface, and "CLI and TUI at once", are rejected. Detailed in §11.
5. **Signer modes** [decision] — a local key (keystore/env) is mandatory in the first release, plus a signer abstraction so an external signer can be added later. KMS/HSM/hardware wallet as a first-release requirement, and "external signers only", are rejected. Detailed in §14.
6. **Explorer/source verification** [decision] — mandatory for Arbitrum and Ethereum, modelled as a separate `VERIFIED` state; a verification failure does not block READY but is always visible. Both "blocks READY" and "optional, report-only" are rejected. Detailed in §22.
7. **Actions through `MultisigProxy`** [decision] — the product prepares proposals and tracks their state; execution is a separate command performed once the federation signatures exist. Full automation of create + wait for timelock + execute inside `apply`, and "report a manual checklist without preparing proposal data", are both rejected. Detailed in §21.
8. **TRON in the first TRON release** [decision] — Go orchestrates a pinned TronBox toolchain, while the product owns validation, state, resume and UX. Detailed in §8.
9. **Product location** [decision] — a new Go module in this repository (the repository is otherwise empty; there is no other place in the project for it).
10. **Statement status** [decision] — this PDD separates "from the source snapshot" from "verified in a live repository"; all code-level behaviour is presented as derived from the source snapshot, because the design steps had no repository access.

---

## 2. User and Problem

### 2.1 Who the users are

- **Deployment operator / release engineer** — the primary user. Performs the deployment of a UTEXO contract-suite release onto the supported chains, on a schedule or on demand, and is accountable for the result.
- **Reviewer / second operator** — inspects the plan before it is executed and inspects the result manifest afterwards. May be the same person at a different time, but the product must not assume so.
- **Federation and enclave governance participants** — not users of the deployment product. They consume prepared governance proposals and provide approvals through their own governance process. The product never handles their keys.
- **Consumers of the result** — release/audit stakeholders who need to know which build is deployed where, and whether the deployed system matches the intended configuration.

### 2.2 The problem

Today a release of the supported contract suite is deployed through manual, hand-driven orchestration, where the operator carries values and decisions in their head and between tools. The concrete costs, as recorded in the product intent:

- remembering the deployment order across many contracts and three chains;
- copying addresses produced by one step into the next step;
- manually translating the outputs of one step into the inputs of later steps;
- repeatedly editing environment files for each run;
- remembering which values are immutable after deployment and which are mutable configuration;
- remembering which actions take effect immediately and which are governance/timelock follow-ups;
- reconstructing what happened after a partial failure;
- manually determining what already succeeded before continuing;
- repeating a long post-deployment checklist by hand.

The snapshot shows why this is costly: the deployment spans multiple contracts with constructor-time address dependencies, deployer-nonce-dependent address prediction, plugin deployment, ownership handoff and post-deployment configuration, plus a cross-chain continuation (LayerZero adapter, source entrypoints) and a governance continuation (routes and trusted entrypoints registered later through federation governance) [source snapshot].

The scale of the problem is not "one command is long". It is that the deployment is **multi-step, multi-chain, multi-repository, expensive, irreversible, and long-lived** (a deployment can legitimately sit in a pending-governance state for a timelock period), while the current tooling keeps no authoritative, resumable, secret-free record of what has already happened.

### 2.3 What is wrong with the current reality

- The full production flow is encoded in a script whose correct execution depends on exact deployer nonce/order [source snapshot], which makes address prediction fragile and makes partial failure expensive.
- Routes are not registered by the full-deployment script; federation governance performs route setup later [source snapshot]. A deployment is therefore rarely "finished" when the deploy transactions are mined.
- The same product concern is spread over two repositories and two toolchains (Foundry for EVM, TronBox for TRON) [source snapshot], so "the deployment" is not a single artefact.
- Configuration is split between environment files, script arguments and implicit deployer state, mixing real intent, network data, derived addresses and secrets [source snapshot: existence and shape of `.env.deploy`-style configuration; no value is reproduced here].

The product must remove the manual orchestration work while keeping the operator in control of real decisions.

---

## 3. Product Goal

**Goal.** Provide a Go library and an operator-facing product surface that turn a declared deployment intent into a validated, planned, dependency-aware, safely resumable, verifiable deployment of the supported UTEXO contract suite across the supported chains — and that never claims completion it has not verified.

The product-level pipeline the product must deliver (this is a product abstraction, not an architecture):

- deployment intent + configuration
- validate (preflight)
- show the plan
- execute dependency-aware deployment
- persist safe, secret-free deployment state
- resume safely if interrupted
- prepare and track governance/timelock work
- verify the resulting system against the desired configuration
- emit a machine-readable and human-readable deployment result

### 3.1 Observable success criteria

The product is successful when an operator can state that:

1. no address produced by an earlier step was ever copied by hand;
2. a run interrupted at any point can be diagnosed and resumed, and a resumed run can never deploy a duplicate contract or duplicate proposal;
3. a deployment is attributable to the exact contracts it used (repository, revision, compiled artifact identity) and to the account that performed it;
4. the operator can see, at any moment, which steps are done, which are blocked, which are waiting on a timelock or on federation action, and what remains;
5. the deployment is reported READY only when the desired configuration matches on-chain state on every required chain — never merely because transactions were mined;
6. no secret ever appears in product output, persisted state, manifests, or terminal history.

### 3.2 What the goal does not include

The goal does not include becoming a general deployment platform, a wallet, a governance key manager, a testing framework, or a monitoring product. It does not include inventing behaviour for chains or flows for which no accepted source material exists. See §26 and §27.

---

## 4. Product Boundary

### 4.1 Inside the boundary

- Turning a declared deployment intent into a validated plan for the supported flows (§6) and the supported networks (§7).
- Preflight validation before anything is broadcast (§17).
- Building, signing and broadcasting transactions for the supported chains, and owning the signing/account semantics (§5, §14).
- Dependency propagation: derived values flow from step to step automatically (§18).
- Authoritative, secret-free deployment state; safe resume; idempotency (§19, §20).
- Direct configuration steps that must happen while the deployer still owns the contracts, and initiation of two-step ownership handover (§21).
- Preparing `MultisigProxy` bootstrap governance proposals, tracking their state, and executing them as a separate action once the federation has signed and the timelock has elapsed (§21).
- Verification of the resulting system against the desired configuration, including readiness semantics (§22).
- Explorer/source verification as a required, separately-tracked state for Arbitrum and Ethereum, performed through a helper toolchain (§5, §22).
- Emitting the deployment result manifest (§20).
- A reusable library surface that is usable independently of the CLI, plus the single operator CLI (§11).

### 4.2 Outside the boundary

- Handling federation or enclave governance private keys of any kind, holding them, deriving them, or simulating authority the product does not have.
- Producing federation approvals. Those happen in the federation's own process; the product consumes their result (a proposable/executable state) and never forges it.
- Compiling Solidity or implementing a Solidity toolchain in Go (§5).
- Reserving, migrating or repairing already-deployed production state ("automatic migration of deployed production state" is an explicit non-goal, §27).
- Automatic deployment to a mainnet network without explicit operator intent.
- Contract testing, contract correctness proof, or replacing the contract repositories' own test suites.
- Arbitrary third-party contract deployments, wallets, dashboards, IDEs, or key management.
- Any TRON behaviour that is not grounded in the source snapshot or in a decision recorded here.

### 4.3 Prepare / perform / report distinction

For every action the product is expected to exist near, the product declares exactly one of three modes. This distinction is a product requirement, and the plan must label each step with its mode:

- **Perform** — the product constructs, signs and broadcasts the action itself (deployment transactions, direct configuration while the deployer is owner, ownership-transfer initiation, proposal creation, proposal execution, verification submission).
- **Prepare** — the product computes and materialises everything needed for an action whose authority it does not hold, and then tracks the action's state (federation-signed bootstrap proposals; any action whose execution depends on approvals collected outside the product).
- **Report** — the product only observes and reports a fact it cannot influence (who signed a proposal, whether an external party shipped something, whether a route pair is expected to be enabled by a later organisational decision).

A product that only reports what should be manual is not acceptable; a product that performs actions it has no authority for is not acceptable either.

### 4.4 Library and operator surface are both required

- The library is a required product surface: other automation and the product's own tests must be able to reach every product semantic through it.
- An operator-facing surface is also required; an SDK-only product is rejected [decision].
- The two surfaces must not diverge in semantics: the CLI is a rendering and confirmation surface over the same product semantics, and the library must remain usable with no CLI present [decision].

---

## 5. Go-Native Boundary

"Go-native" is resolved here explicitly. The question the product answers is: *which of the deployment product's responsibilities are owned by Go, which remain with Foundry, and which are delegated to a helper tool?*

The six items below are each answered with exactly one owner: **Go**, **Foundry**, or **helper**.

| # | Responsibility | Owner | What that means at product level |
| --- | --- | --- | --- |
| 1 | Transaction construction and broadcast | **Go** | The product itself determines nonce, chain, calldata, fee/resource parameters and the transaction envelope, and broadcasts through the configured RPC endpoints. It does not ask another tool to construct or send its transactions. |
| 2 | Signing | **Go** | The product performs signing through the configured signer source, with a signer abstraction that keeps the semantics (who signs, what is shown before signing, what is redacted, what is never persisted) stable if an external signer is added later (§14). |
| 3 | ABI / bytecode / artifact consumption | **Go** | The product consumes the compiled artifacts (interface description, creation code, artifact identity) produced by the build step; calldata construction and result decoding are the product's own responsibility. |
| 4 | Compilation / build tooling | **Foundry** | Foundry remains the compiler and the source of the artifacts for EVM. The product does not implement, embed or replace a Solidity toolchain. |
| 5 | Contract verification (explorer/source) | **helper** | Verification is performed by invoking `forge verify` (or an equivalent explorer verification path) as a helper. The product owns the verification *state machine* (submitted, verified, failed, not submitted), the requirement that it is mandatory for Arbitrum and Ethereum, and the visibility of failure — but it does not re-implement source verification. |
| 6 | Interaction with Foundry | **helper, artifact-consuming** | Foundry is invoked for compilation (as the build step) and for verification (as a helper). The product never uses the existing deploy scripts as its execution engine: no deployment step is delegated to a `forge script` run. Artifact availability is what the product needs from Foundry; running the deployment is Go's job. |

### 5.1 Rejected extremes

- **Rejected: thin wrapper around the existing deploy scripts** [decision]. Running the current ordered scripts would leave the product unable to own state, resume, idempotency, dependency propagation, confirmation semantics and cross-repository identity — i.e. exactly the parts that are currently error-prone. A wrapper would also place the fragile nonce-ordered flow outside the product's control.
- **Rejected: full Solidity toolchain in Go** [decision]. There is no product reason to re-implement compilation. Foundry already produces authoritative artifacts; duplicating it would add risk and divergence with no product gain.

### 5.2 Consequences the product must respect

- **Two stages, one product.** The product has an explicit "obtain artifacts" stage (for EVM: Foundry compilation of the pinned revisions of both repositories) and an "execute" stage (Go builds and broadcasts). The plan shows which repositories/revisions/artifacts it will execute, and the deployment identity pins them (§13).
- **Execution does not require a compiler, but it does require the identity.** Because the product consumes artifacts rather than source, it must be able to state, before broadcasting, which artifact identity each step will use; a plan whose artifact identity cannot be resolved is a blocking preflight failure.
- **Verification is a helper, not a blocker.** Because verification is delegated and can fail for reasons outside the deployment (explorer availability, API compatibility), its failure is a visible state, not a READY blocker (§22).
- **Toolchain difference is a family difference, not a semantic difference.** For TRON the compilation/deployment tooling is the pinned TronBox toolchain, which Go orchestrates (§8); the product's own semantics (identity, plan, preflight, state, resume, UX, verification) stay the same. The Go-native boundary therefore describes the EVM execution path; the corresponding TRON path is Go *orchestrating* an accepted toolchain while still owning everything around it.

---

## 6. Supported Deployment Flows

The flows that exist in the current material are: full production deployment, step-by-step deployment scripts, `MinimalBridge` deployment, Bridge implementation upgrades, post-deployment governance/configuration, and post-deployment verification/checks. Existence is not a reason for inclusion [decision].

### 6.1 Flows in the first release

- **F1 — Full production deployment of the Arbitrum core suite** using the **proxy profile** (§10): core contracts (CommissionManager, RouteRegistry, Bridge implementation plus canonical Bridge proxy, verifier/settlement plugins, `MultisigProxy`), initial outflow configuration, conditional oracle configuration, and initiation of two-step ownership handover. Step classes follow the diagram's phases: deploy, direct configuration while the deployer is owner, then ownership-transfer initiation [diagram intent].
- **F2 — Arbitrum `UtexoLZAdapter` deployment** with its EID↔OFT routing inputs [source snapshot], leaving trusted-entrypoint registration to the governance flow (F4).
- **F3 — Ethereum `UtexoSourceEntrypoint` deployment** with token, source-chain OFT, destination EID (Arbitrum), adapter address as `bytes32`, and initial owner [source snapshot].
- **F4 — Bootstrap governance work through `MultisigProxy`**: preparation and tracking of the proposal set (ownership acceptances, adapter pointer, Bridge adapter pointer, commission defaults, route-specific commissions where required, one proposal per directional route, trusted entrypoints for the Ethereum and TRON EIDs, additional enclave signer sets and additional outflow buckets where required), plus execution as a separate action once federation signatures exist and the timelock has elapsed [diagram intent, decision].
- **F5 — Post-deployment verification and readiness evaluation** against the desired configuration, per §22.
- **F6 — Explorer/source verification state** for the Arbitrum and Ethereum artifacts, performed via the helper path, with `VERIFIED` as a separate state [decision].
- **F7 — Proxy profile as the default and first-release Bridge profile** [decision] (§10).

### 6.2 Flows staged later

- **F8 — `MinimalBridge` deployment flow** [deferred]. The flow model treats a "flow" as a named set of steps with declared inputs/outputs; adding this flow later requires no change to product concepts. It is not part of the first release because it does not contribute to the end-to-end result the first release must deliver.
- **F9 — Step-by-step operator-driven flow** [deferred]. `plan`, `status` and per-step execution visibility already let an operator inspect and stage work; a first-class interactive step-by-step surface is deferred and must not become the only surface if reintroduced (§11).
- **F10 — Bridge implementation upgrade flow** [deferred]. The proxy profile makes the canonical address stable, which is the prerequisite any upgrade capability needs; upgrades additionally require their own plan/verification semantics (comparing the desired configuration of the new implementation, authorization, and storage-compatibility concerns that the product can only *report*). No dead end: the product is not allowed to assume that the implementation address is canonical anywhere.
- **F11 — TRON entrypoint deployment execution** [deferred], sequenced after EVM reaches an end-to-end result (§8).
- **F12 — Additional EVM source chains** beyond the explicit network list in §7 [deferred]; adding one is a product decision with its own capability record.

### 6.3 Flow inclusion criteria

A flow belongs to a release when **all** of the following hold: it is required for the operator problem the release claims to solve; it ends in an evaluated readiness result rather than a partial state; and its absence would leave the release unable to produce a working end-to-end outcome. Flows that exist but fail these criteria are staged, and staging must not create a dead end: for every deferred flow, §28 states what would be needed to add it and what first-release assumption keeps the door open.

---

## 7. EVM-First Scope

EVM is the first supported chain family, and within it the first release target is deliberately narrow.

### 7.1 The explicit network list

The supported networks are exactly these four named targets, each with its own network record (RPC, expected chain identity, verification provider capability, LayerZero endpoint/EID, oracle/feed capability, confirmation policy, fee policy):

| Network target | Expected chain id | Role in the first release |
| --- | --- | --- |
| Arbitrum One (mainnet profile) | 42161 | Arbitrum core suite + `UtexoLZAdapter` |
| Arbitrum Sepolia (testnet profile) | 421614 | Arbitrum core suite + `UtexoLZAdapter` |
| Ethereum mainnet (mainnet profile) | 1 | `UtexoSourceEntrypoint` |
| Ethereum Sepolia (testnet profile) | 11155111 | `UtexoSourceEntrypoint` |

Notes on this list:

- The expected chain id is part of the network record and is validated at preflight against the chain identity the RPC endpoint reports; the product never proceeds on an unvalidated assumption about which chain it is talking to. The numeric values above are operator/maintainer-supplied network data, not a claim verified in a live repository.
- The list is closed. **"All EVM networks" is not an accepted formulation, and a rule that "selects" networks without naming them is not accepted** [decision]. A network that is not in the list is not deployable; adding one is a product decision (§25), not a configuration value.
- Networks are grouped into two **network profiles** (mainnet, testnet) so that the plan, identity and readiness evaluation are always explicit about which set of chains a deployment covers. A deployment never mixes profiles: a plan that would deploy to a mainnet chain and a testnet chain in one deployment is a configuration error.

### 7.2 The product does not assume uniform EVM behaviour

Per-network capability records exist precisely because the following differ between EVM networks and must be declared, not assumed:

- **Verification**: which explorer/verification provider applies, whether it is available at all, and which contract forms can be verified. A network without a supported verification provider is represented as an explicit `NOT_SUPPORTED` verification capability for that network — never as a silent success and never as a reason to block the deployment (§22).
- **LayerZero identity**: endpoint, local EID, remote EIDs, and the OFT address pair per route. Mainnet identifiers visible in the snapshot (Ethereum EID `30101`, Arbitrum destination EID `30110`, TRON legacy EID `30420`) are mainnet values; testnet identifiers differ and must come from the network record, not from a uniform formula [source snapshot, diagram intent].
- **Oracle / native commission quoting capability**: whether the sequencer uptime feed, the ETH-USD bounds and the ETH-USD feed configuration are available and applicable for that network. The conditional oracle configuration of the core flow is enabled only where the capability record says so; an operator may also explicitly disable it [diagram intent].
- **RPC behaviour**: endpoint availability, rate limits, archive requirements for the reads the product performs, and the absence of silent failover (a failover must be declared per network, §19 case 3).
- **Confirmation and fee policy**: how many confirmations the product requires before treating a step as confirmed, and how fees are determined. These are per-network policy, not one global number.

Consequence: the product's readiness evaluation is a per-chain, per-contract evaluation. "The desired configuration matches on-chain state on every required chain" (§22) is evaluated with each chain's own capability record.

---

## 8. EVM-First and TRON-Second Sequencing

### 8.1 Sequencing rule

**EVM must reach a complete end-to-end outcome before TRON execution is implemented** [decision]. "Complete end-to-end" means: deployed on Arbitrum and Ethereum, governance work prepared and executed or visibly pending, and readiness evaluated by the definition in §22. TRON-specific execution is staged after that, without changing any product concept introduced by the EVM path.

### 8.2 The TRON operating model

For the first TRON release, **Go orchestrates a pinned TronBox toolchain while owning validation, state, resume and UX** [decision]. Rejected alternatives: implementing native Go TRON deployment in the first TRON release, and leaving TRON out entirely (which would make the product's completion invariant unachievable for the TRON route pair).

The accepted toolchain constraints from the snapshot are treated as inputs the product pins and validates, not as values it invents: TronBox 4.7.1, solc 0.8.20, `viaIR: true`, `evmVersion: paris` because the TVM does not implement `PUSH0`, Node.js >= 18, and deployment through the TronBox migration command [source snapshot]. The TRON deployment takes token, OFT, destination EID (Arbitrum), the Arbitrum adapter as `bytes32`, and the initial owner [source snapshot], mirroring the EVM entrypoint's semantics.

What Go owns despite orchestrating TronBox: identity (repository revision + artifact identity + network record + profile), the plan and its confirmation, preflight validation of every TRON-specific input, the deployment state and resume point, the readiness evaluation, and the operator UX. What Go does not own: the TRON compiler toolchain itself.

### 8.3 TRON questions resolved as product requirements (not assumed)

- **Address representation and conversion.** TRON addresses appear in base58 form and in hex form, whereas the Arbitrum adapter stores a trusted source entrypoint as `bytes32` (an EVM-style 32-byte word). The product owns an explicit, validated conversion in both directions: it must accept one canonical operator-facing form, display both forms in the plan and manifest, refuse ambiguous or conflicting input, and verify the value by reading the on-chain registration back where the contract allows it. The exact encoding used inside the adapter's `bytes32` trusted-entrypoint slot (and whether the business chain id is a separate field of the same registration) must be confirmed against the adapter contract before TRON trust registration executes — this is recorded as **[open]** in §28, because the snapshot does not settle it.
- **Signer and secrets for TRON.** TRON account/key representation and account derivation differ from EVM, and the accepted toolchain consumes its own account configuration. Product requirement: the same signer abstraction and the same rules apply — the operator supplies TRON credentials explicitly for the run, secrets are never persisted, never echoed, never placed in configuration files or command-line arguments, the signing account is displayed and matched against the deployment identity before signing, and the TRON deployment account is a separate authority from federation/enclave governance keys (§14).
- **Resource and fee semantics.** TRON operation depends on account activation, bandwidth and energy, and TRX balance for energy; "out of energy" is a distinct failure class from EVM out-of-gas. Product requirements: preflight validates that the deployment account exists/is usable and that resources (energy/bandwidth/TRX) are sufficient for the planned deployment and configuration transactions, with a stated margin; the plan displays expected resource consumption; a mid-run resource shortfall is reported as a blocked step with a concrete funding instruction, never as a retry loop.
- **Confirmation semantics.** Block production and the notion of "confirmed" differ from EVM. The product applies its per-network confirmation policy (a property of the network record) and does not mirror EVM confirmation counts or EVM receipt handling onto TRON.
- **Verification and readiness for TRON.** TRON source verification is a different capability from the Arbitrum/Ethereum explorer path. The product must model it as its own capability record, and while it is unsupported it must report the explicit unsupported/not-submitted state for TRON contracts rather than a false `VERIFIED`. Readiness for TRON follows §22, evaluated on TRON's own on-chain state.
- **Coupling of Arbitrum adapter trust registration to the TRON entrypoint deployment.** The adapter's trusted-entrypoint registration for the TRON EID can only be meaningful once the TRON entrypoint exists and its address is known [diagram intent]. Product requirement: the TRON entrypoint deployment produces the inputs of the adapter trust proposal (entrypoint address converted to the adapter's expected form, the TRON EID, and the TRON business chain id as an operator input), and the plan sequences it that way rather than pre-registering an unknown address. TRON therefore cannot be "usable for traffic" before the Arbitrum-side trust registration is executed.
- **No invented TRON behaviour.** Anything about TRON not covered by the snapshot or by a decision in this document is not stated. The business chain id `728126428` given by the diagram is **[operator input]**: it was not found in the inspected snapshot, so the product requires it as configuration (validated and echoed in the manifest) and never hardcodes it.

---

## 9. Cross-Repository Deployment Scope (Core Bridge + USDT0/LZ Contracts)

A complete target deployment is not contained in one repository [source snapshot]. This is a first-class product fact, not an implementation detail.

### 9.1 The two source repositories

- **Core bridge repository** — Arbitrum/core: Bridge implementation and the canonical proxy, `CommissionManager`, `RouteRegistry`, verifier/settlement plugins, `MultisigProxy`, ownership/governance semantics (branch `dev`) [source snapshot].
- **USDT0 / LayerZero repository** — the real `UtexoLZAdapter`, the EVM source entrypoint, and the TRON material (contracts, migrations, toolchain configuration, tests; branch `dev`) [source snapshot].

### 9.2 Contract units the product reasons about

- **Arbitrum core units**: `CommissionManager`, `RouteRegistry`, Bridge (implementation and canonical proxy are distinct units), `RGBVerifier`, `RgbSettlementModule`, `NullVerifier`, `RgbOutboundSettlementModule`, `RgbPoolSettlementModule`, `NullSettlementModule`, `MultisigProxy`.
- **Arbitrum LayerZero unit**: `UtexoLZAdapter` (per-EID OFT routes and trusted source entrypoints).
- **Ethereum unit**: `UtexoSourceEntrypoint` (non-upgradeable).
- **TRON unit**: `UtexoSourceEntrypoint` (TRON deployment path).

Listed units come from the snapshot and the developer diagram [source snapshot, diagram intent]. The product treats this as a bounded, named inventory per flow: a flow declares which units it deploys, and a unit that is not declared is not touched.

### 9.3 Consequences for the product

- **Two revisions, one identity.** A deployment records the revision of *both* repositories plus the artifact identity of every contract unit it uses. A deployment attributable to only one revision is not attributable at all.
- **Two toolchains, one semantic model.** Foundry artifacts for EVM and TronBox-produced artifacts for TRON are both inputs to the same identity/plan/state model (§5, §8).
- **Derived cross-repository values.** The Arbitrum adapter address is produced on Arbitrum and consumed on other chains (as a `bytes32`), so cross-repository and cross-chain dependency propagation is a normal case the product must handle natively (§18).
- **No assumption of a single deployment script boundary.** The product preserves required outcomes and invariants (order where it matters, wiring to the canonical Bridge address, ownership and governance handoffs, verification), not the file/script boundaries of the current repositories [decision].

---

## 10. Developer Sequence-Diagram Intent and Resolved Conflicts

The developer sequence diagram is developer-provided target-operational intent. It is accepted as strong input about the intended operator flow, and it is explicitly **not** treated as a statement about current code behaviour where it differs from the snapshot. Its conflicts are resolved below, each with a named decision; none is silently reconciled.

### 10.1 Diagram intent adopted as product intent

- An explicit preflight phase (configuration, secrets, RPCs, chain ids, balances, addresses, signer thresholds, LayerZero EIDs and OFT peers) before any broadcast [diagram intent].
- Phased execution: core deployment → direct configuration while the deployer is still owner → initiation of two-step ownership handover → LayerZero adapter deployment → Ethereum entrypoint deployment → TRON entrypoint deployment → bootstrap governance proposals → wait for the timelock → execution → final verification [diagram intent].
- Post-deployment configuration that must happen before ownership moves (outflow limits, global limits, and — when native commission quoting is enabled — sequencer uptime feed, ETH-USD price bounds and feed) [diagram intent].
- Routes and trusted entrypoints are configured **through governance**, not by the deployment account [diagram intent; consistent with the snapshot statement that routes are registered later by federation governance].
- A strong completion invariant: **deployment is complete when the desired configuration matches the on-chain state on all required chains** [diagram intent]. Adopted as the product's definition of READY (§22).
- The step classes implied by the diagram (deploy / direct-config / ownership-initiation / proposal-preparation / proposal-execution / verification) are distinct and must never be collapsed [decision].

### 10.2 Conflict 1 — Bridge deployment shape: `CREATE(n + 2)` / one transaction vs implementation+proxy

**The conflict.** The diagram shows a single Bridge deployment transaction (A3) and states that the Bridge address is predicted as `CREATE(n + 2)` after CommissionManager and RouteRegistry. The snapshot's `DeployAll.s.sol` instead deploys CommissionManager at `n`, RouteRegistry at `n+1`, the Bridge *implementation* at `n+2`, and the canonical `BridgeProxy` at `n+3`, and wires `CommissionManager` and `RouteRegistry` to the canonical Bridge proxy address rather than to the implementation [source snapshot].

**Resolution** [decision]:

1. **Both profiles are named and supported.**
   - **Profile `proxy` (implementation + proxy)** — matches the current `DeployAll` semantics: a Bridge implementation is deployed and a proxy is deployed and treated as the canonical Bridge; the consumers that must hold the canonical address are wired to the proxy address; the implementation address is a separate, non-canonical output.
   - **Profile `single-tx` (Bridge deployed in one transaction)** — the shape the diagram depicts; supported as a named profile so that a future refactor of the suite needs no product rework and so that the diagram is not silently discarded.
2. **The first release uses profile `proxy`** [decision]. It matches current code, and it is the profile under which the canonical address is stable (a property later upgrade capability needs, §6.2/F10).
3. **Addresses always come from actual nonce/receipt evidence, never from ordinal position in the diagram** [decision]. Where the current flow predicts a canonical address from the deployer nonce, the product treats the prediction as a checkable expectation: it validates the prediction against the deployment receipt(s), and if the predicted address does not match the receipt-derived address, the deployment fails loudly instead of continuing with the expected address or with the produced one.
4. **The divergence is closed by the profile, not by choosing one source.** The profile determines the expected canonical-address derivation, is part of the deployment identity, is displayed in the plan, and is checked at resume: a resume attempt under a different profile from the recorded one is refused. There is no silent "n+2 or n+3, whichever works".
5. **The residual question is recorded, not hidden.** Whether the diagram describes a planned simplification of the contract suite (to be implemented) or should itself be corrected is **[open]** (§28). Its product impact is zero for the first release because both profiles are names the product understands, and the first-release choice is stated explicitly.

### 10.3 Conflict 2 — TRON business chain id

The diagram states `Tron business chain ID = 728126428` and `Tron LayerZero EID = 30420` [diagram intent]. The snapshot supports `30420` as the TRON EID example/legacy route, but the business chain id `728126428` was **not found** in the inspected snapshot [source snapshot]. **Resolution** [decision]: business chain ids are operator-supplied configuration values, validated at preflight, displayed in the plan, and echoed into the manifest; they are never hardcoded and never presented as a verified fact. This includes the business chain ids used in the route pairs the diagram lists (Arbitrum↔RGB, Ethereum↔RGB, TRON↔RGB). Because the TRON business chain id participates in the Arbitrum adapter's trusted-entrypoint registration, a wrong value becomes a visible misconfiguration rather than a silent one. Confirming `728126428` against an accepted source remains **[open]** (§28) with no design impact (it is an input).

### 10.4 Conflict 3 — Scope crosses two repositories

The diagram spans Arbitrum, Ethereum and TRON, and the material behind it spans `bridge-smart-contracts` and `usdt0-smart-contracts` plus a TRON TronBox flow [source snapshot]. **Resolution**: §9 — deployment identity, plan, propagation and readiness are multi-repository and multi-toolchain by design; the product never assumes one contract repository.

### 10.5 Other diagram facts the product adopts as inputs

- The adapter deployment takes the LayerZero endpoint, token, Bridge address, `MultisigProxy`, and arrays of EIDs and local OFTs, and stores per-EID OFT routes (`oftByEid` entries for the Ethereum and TRON EIDs) plus trusted source entrypoints [source snapshot, diagram intent].
- The Ethereum entrypoint deployment takes the Ethereum token, the Ethereum OFT, destination EID `30110`, the Arbitrum adapter as `bytes32`, and the initial owner [source snapshot].
- The bootstrap governance set includes ownership acceptances for the three core governance-owned contracts, an adapter-pointer update, the Bridge's `setLZAdapter`, global commission defaults, optional route-specific commissions, optional additional enclave signer sets, optional additional outflow buckets, one proposal per directional route, and trusted-entrypoint registrations for the Ethereum and TRON EIDs [diagram intent].
- Proposal execution follows a timelock wait, and route proposals route through the Bridge's registry when executed [diagram intent]. The exact observable proposal lifecycle states must come from the `MultisigProxy` contract before implementation ([open], §28).

---

## 11. Operator UX

### 11.1 Operator surface

**Decision** [decision]: the product's operator surface in the first release is **exactly one non-interactive CLI** with five commands:

| Command | Purpose (product level) |
| --- | --- |
| `plan` | Compute and display the deployment plan for a declared intent — read-only, nothing broadcast; shows steps, classes, dependencies, origins of inputs, addresses that will be produced and reused, and which steps require confirmation. |
| `preflight` | Validate everything that can be validated before any broadcast (§17) — read-only against chains, no secrets echoed, blocking failures distinguished from warnings. |
| `apply` | Execute the plan: perform the steps, gate the irreversible ones behind explicit confirmation, persist state, stop cleanly on failure/blocking conditions. |
| `status` | Report the authoritative current state of a deployment: completed steps, blocked steps, pending governance/timelock, verification states, readiness evaluation, drift since deployment. |
| `resume` | Continue an existing deployment from its safe resume point after identity, configuration and on-chain corroboration checks. |

Properties of the surface:

- **Non-interactive by design**: configuration is declared, not prompted for. The single permitted interaction is the confirmation gate for irreversible actions (below).
- **Machine-readable output** for every command, alongside human-readable rendering [decision]. Both renderings carry the same facts; the machine-readable form is the input to audit and automation, and must be stable enough to diff between runs.
- **Confirmation on the irreversible** [decision]: explicit confirmation is required before broadcasting any irreversible transaction, before initiating ownership handover, before creating a governance proposal, before executing a proposal, before submitting explorer verification (public, even though not irreversible), and for anything on a mainnet network. The confirmation names the operation, the chain, the target contract unit, the effect, the irreversibility, and the cost estimate.
- **The library remains usable without the CLI** [decision]: no product semantic may exist only inside the CLI.

**Rejected** [decision]: an interactive CLI or TUI as the *primary* surface (it makes runs hard to reproduce, hard to automate, and weaker for audit, and it invites the operator to answer prompts rather than declare intent), and "both CLI and TUI in the first release" (two surfaces before there is a need). A read-oriented TUI remains conceivable later as a view over `status` [deferred], but never as the only surface.

### 11.2 What the operator must be able to see

Every item below is a UX requirement, mapping directly to the operational state the product must expose:

1. **Selected chain/network** — per step, including the human-readable network name, the expected chain identity, and the network profile (mainnet/testnet).
2. **Source revision / artifact identity** — both source repositories with their revisions, and the compiled artifact identity of each contract unit the plan will execute.
3. **Deployment profile** — flow, Bridge profile (`proxy` / `single-tx`), network profile, product configuration version.
4. **Required and missing inputs** — each expected input with its status (supplied / missing / defaulted) and its classification (required / optional / conditionally required, with the condition stated).
5. **Preflight validation failures** — each failure with the object it concerns (input, chain, contract unit, signer, dependency), whether it blocks execution, and what would resolve it.
6. **Planned steps and dependencies** — ordered steps with stable identifiers, their class, what each depends on, and which steps are gated behind governance/timelock.
7. **Addresses that will be reused by later steps** — each produced address with the steps that consume it, and the canonical Bridge address clearly distinguished from the Bridge implementation address.
8. **Transaction status and confirmations** — per step: submitted hash(es), confirmation depth against the network policy, and any replacement/cancellation event (§19).
9. **Already-completed steps** and the **safe resume point** — explicitly, with the evidence that a step is considered complete.
10. **Post-deployment actions still required** — including actions the product prepares but does not execute.
11. **Governance/timelock actions that cannot complete immediately** — proposals prepared, waiting for signatures, waiting for the timelock, executable, executed; with timelock timing where the contract makes it observable.
12. **Verification status** — the explorer/source verification state per contract unit, and the readiness evaluation summary (§22).
13. **Final deployed addresses and metadata** — the result manifest rendering: chain, contract unit, role (canonical/implementation/proxy/adapter/entrypoint/registry/multisig/plugin), address, transaction hashes, artifact identity, verification status, and the non-secret configuration actually used.

### 11.3 Secrets in UX

**Requirement**: secrets must never be casually echoed into logs, manifests, or terminal history [decision, §5 of the product intent]. Consequently:

- secret *presence* may be shown (e.g. that a keystore for a named account reference was loaded, and which account address will sign), secret *values* never are;
- the CLI must not accept secrets as positional command-line arguments, because those land in shell history and process listings;
- error paths, debug output, RPC dumps and generated evidence are subject to the same redaction rule as normal output;
- the product must not write secrets into any output artefact at all (§14, §20).

---

## 12. Configuration Semantics

### 12.1 What a deployment configuration is

A **deployment configuration** is an explicit statement of deployment intent for one deployment: which flow, which network profile and which networks from the closed list, which Bridge profile, which operator-supplied parameters, which source revisions and artifact sets, which external references to secrets (never the secrets), and which confirmation policy applies. It is the *intent document*; it is not a mirror of the current environment files.

The current `DeployAll` flow consumes a large set of environment variables, some required, some optional, and some conditionally required [source snapshot]. **Decision** [decision]: a one-to-one translation of `.env.deploy` into a larger configuration of any kind is **not** the accepted product model. The reason is structural, not stylistic: that file mixes (a) genuine operator intent, (b) network data, (c) per-run values, (d) values that are really *outputs* of earlier steps, and (e) secrets. A mechanical translation would preserve exactly the manual shuffling the product exists to remove, and would make the product's identity/resume semantics impossible to enforce. Additionally, conditional requirement (for example, oracle-related parameters that only apply when native commission quoting is enabled) cannot be expressed honestly by a flat uniform set.

Instead: values that are genuine operator intent become declared configuration with explicit classification; values that the product can derive are removed from the input surface entirely and become derived values (§18); secrets become references resolved only at run time (§14).

### 12.2 Answers to the configuration questions

- **What constitutes a deployment configuration**: flow, network profile, the networks involved, Bridge profile, the operator-supplied parameters of that flow, the source revisions and artifact sets to execute, the external inputs the flow genuinely needs (for example token and OFT addresses, EIDs, governance signer sets and thresholds, oracle parameters when enabled, route pairs), secret references, and the confirmation policy. It also carries a product configuration version so a schema change is explicit rather than accidental.
- **How network-specific values are represented**: by named **network records**, one per supported network, containing the expected chain identity, the RPC endpoint reference, verification capability, LayerZero endpoint/EID and local OFT, oracle/feed capability, confirmation policy, fee/resource policy, and monitoring/explorer reference. Network values are never shared implicitly across networks; there is no "EVM defaults" record.
- **How required / optional / conditional fields are communicated**: every field is explicitly classified in the configuration, and a conditional field states its condition. A conditional field that the selected flow/profile *requires* but that is not supplied (or not explicitly disabled, where disabling is a legitimate operator choice) is a blocking preflight failure — never a silent default.
- **How outputs of earlier steps become inputs of later steps**: automatically. The operator supplies only the genuinely external inputs; every address or value produced by a step is resolved from the deployment state (planned value first, then the receipt/on-chain value once the producing step is confirmed), referenced by name in later steps, and shown in the plan with its provenance. Manual copying of produced values is not a supported path (§18).
- **How configuration is validated before broadcasting**: by preflight (§17) — shape and completeness, network resolution and chain-identity match against the RPC, artifact availability and identity match, address form validity, signer availability and account match, balance/resource sufficiency, EID/OFT presence and pairing, dependency closure, and redaction of rendered output. Nothing is broadcast on a failing preflight.
- **How defaults are represented and sourced**: only where a safe, documented default exists, and only for values that do not change what is deployed, by whom, on which chain, or with which artefact. Defaults are visible in the plan and labelled as defaults. There is deliberately **no default** for: the flow, the network profile, the networks, the Bridge profile, the signer/account, the source revisions/artifacts, or the ownership/governance target. A default never silently changes a deployment mode, network, signer, artifact, or profile [decision, §24].
- **How secrets are separated from ordinary configuration**: configuration contains secret *references* only (for example "account reference resolved from a keystore location", "password supplied through a named environment reference"). A configuration file must be shareable and auditable as-is, without redaction. Secret values are resolved by the signer source at run time and exist only in memory for the duration of the run (§14).
- **How a deployment is reproduced or audited later without persisting secrets**: by the deployment identity, the recorded plan, the recorded non-secret configuration, the artifact identities, and the recorded transaction evidence (§13, §20). "Reproduce" for a blockchain deployment means *re-derivable and re-verifiable*: the manifest is sufficient for a third party to locate every deployed contract, reconstruct the exact build identity, and verify the resulting configuration on-chain — while the secrets needed to actually re-run must be re-supplied by the operator and are never stored.
- **How configuration changes affect resume semantics**: any change to a field that participates in the deployment identity (flow, profile, networks, operator-supplied parameters, source revisions, artefact identity, ownership/governance target, deployment account) **invalidates resume**: `resume` refuses, shows a field-level diff between the recorded and supplied configuration, and requires either reverting the change or an explicit decision to treat the change as a new deployment. Changes that are not part of the identity (for example an additional redundant RPC endpoint, or increased confirmation depth) are allowed and recorded; changes that *weaken* a safety property (reduced confirmation depth, reduced required confirmations, disabling verification) are treated as identity-relevant changes and must be explicit and recorded. Changing a secret source is allowed only if the resulting signing account matches the recorded deployment account.

---

## 13. Artifact and Source Identity

A deployment must be attributable to the exact contract code and artefacts it used. **Identity is the mechanism that makes resume safe**: a resume that could silently pick up a different build is the single most dangerous failure mode of a deployment product.

### 13.1 Required identity

The product-level identity of a deployment must include, at minimum:

- **source repository** — the specific repository each artefact came from; both repositories are recorded whenever a deployment spans them;
- **source revision / commit** — per repository, always both when both are involved;
- **chain/network** — per step, from the closed network list;
- **compiled artefact identity** — per contract unit per chain: at least the contract unit identity, the compiler configuration that produced it, and a stable content identity for the compiled artefact (the concrete hash algorithm and storage medium are deliberately **not** prescribed at product level; the requirement is a stable, comparable identity);
- **deployment profile/version** — flow, Bridge profile, network profile, and the product configuration version;
- **resulting contract addresses** — with role labels (canonical Bridge vs implementation, proxy, adapter, entrypoint, registry, multisig, plugin module);
- **transaction hashes** — per step, with the step identity, class and chain, including any replacement hashes;
- **deployment status** — per step and overall (§19, §22);
- **verification status** — per contract unit (§22);
- **governance state** — which proposals were prepared, created, and executed, and which remain pending (§21);
- **accounting identity** — the signer account address that performed the deployment (an address, never a key), and the deployer nonce history relevant to the steps;
- **secret-free intent identity** — a stable identity over the configuration as supplied (secret references included, secret values excluded).

### 13.2 The derived deployment identity and its enforcement

- A **deployment id** is derived from the deployment identity (flow, profile, networks, intent identity, artefact identity set, deployment account). Every `plan`, `preflight`, `apply`, `status` and `resume` invocation compares the supplied identity against the recorded one.
- **Accidental resume with a different build must be impossible** [decision]: before any broadcast, the product compares source revisions and artefact identities; on mismatch it refuses, reports the difference, and only proceeds if the operator explicitly decides to start a new deployment — a decision that is itself recorded, with its reason, in the manifest.
- Identity is also what makes audit possible: a third party can take the manifest, rebuild the recorded revisions, and compare artefact identities and deployed code identity.

### 13.3 Storage is not prescribed, properties are

**Decision**: the PDD does not prescribe an artefact-storage technology. It prescribes properties that any storage must satisfy:

- **durable across process death** — a transaction hash that has been broadcast must be recoverable after a crash, so that the product can always reconcile instead of re-broadcasting;
- **secret-free** — never contains secret material, in any field, at any point;
- **shareable** — a deployment record can be handed to a reviewer without redaction;
- **versioned** — the record states the product configuration version that produced it, so a later product version can interpret (or explicitly migrate) an older record;
- **authoritative** — the recorded state is the product's single source of truth for "what has already been done", and is always corroborated with on-chain evidence before a step is treated as satisfied.

---

## 14. Signer and Secrets Semantics

### 14.1 Signer modes

**Decision** [decision]: the first release requires a **local key** — loaded from a keystore or from the environment — and additionally defines a **signer abstraction** so that an external signer can be supported later without changing product semantics. Rejected: requiring KMS/HSM/hardware-wallet support in the first release; and supporting only external signers.

Product requirements for signing:

- **Chain identity before signing**: every signature is preceded by a confirmed, displayed chain identity (network record, chain identity as reported by the RPC, human-readable network name) and by the specific operation being signed. Signing is only performed after the product has re-validated that the RPC endpoint really is the intended chain. **No silent fallback to a different network or signer, ever** [decision].
- **Account match**: before signing, the signing account address is compared with the deployment identity's account. A mismatch aborts before broadcast. A changed deployer account invalidates resume.
- **What is signed is what was planned**: the product signs only calldata it constructed (or, in the governance-proposal case, proposal payloads it prepared and displayed). It never signs opaque payloads produced by another actor without showing and recording what they do.
- **Confirmation UX for signing**: the irreversible-action confirmation (§11.1) is the operator's last opportunity to stop; the product shows the operation, the chain, the target contract unit, the effect and the cost estimate.

### 14.2 Secret sourcing, redaction, and non-persistence

- **Sourcing**: secrets are supplied by an explicit secret source chosen by the operator (keystore + its password source, or an environment-supplied key reference). The configuration contains references, never values. Secrets must not be passable as command-line arguments, because that would place them in shell history and process listings.
- **Redaction**: secrets never appear in logs (including verbose/debug logging), in plans, in machine-readable output, in manifests, in persisted state, in error messages, in RPC request/response dumps, or in history captured by the terminal [decision]. Secret *presence* and the resulting account address may be shown. Redaction is verified as part of output rendering and as a preflight check.
- **No persistence**: the product never writes secret material anywhere, including any "reproduce this later" convenience file. A run's secret exists in memory for the duration of the process. If an operator needs to re-run a deployment later, they re-supply the secret.
- **Chain/account mismatch**: handled as above; additionally, the product validates that the deployment account has the authority the plan assumes for a step (for example, being the current owner where a configuration transaction requires it) by reading on-chain state before acting.

### 14.3 Separation of deployment authority from governance authority

**Decision** [decision]: the deployer key is an authority to deploy, to perform direct configuration while the deployer is owner, to initiate ownership handover, and to create/execute proposals *as a submitting account*. It is a **different authority** from the federation and enclave governance keys.

- The product never holds, requests, derives, or handles federation/enclave private keys, and never simulates federation approvals. Test scripts that simulate signatures locally do not make federation key handling a product responsibility [source snapshot: test scripts simulate signatures locally].
- Federation approvals are produced by the federation's own process. The product consumes their effect: a proposal becomes executable, and the product executes it (or waits visibly).
- Governance-related inputs the product does accept as configuration are *public* parameters: signer sets, thresholds, timelock parameters, governance target addresses — not keys.

---

## 15. Deployment Plan Semantics

The plan is the product's contract with the operator: a deterministic, inspectable, ordered description of what will be done, produced before anything is broadcast.

### 15.1 Plan contents (per step)

- a stable step identifier and an ordering;
- the **step class**: deploy / direct configuration / ownership-transfer initiation / artefact or governance-proposal preparation / governance execution / TRON-orchestrated deployment / verification;
- the target chain and network record, and the target contract unit;
- the **mode** from §4.3 (perform / prepare / report);
- whether the step is reversible or **irreversible**, and therefore whether it requires explicit confirmation;
- the step's inputs, each marked as operator-supplied or derived from a named output of an earlier step;
- the named outputs the step produces;
- the dependencies it requires to be confirmed first;
- any governance/timelock involvement and the condition under which it may execute;
- a cost/resource estimate in the chain's own terms;
- the post-condition that must hold on-chain for the step to be considered complete (this is what makes skipping and resume safe).

### 15.2 Plan properties

- **Deterministic and stable**: the same intent and identity produce the same plan, with the same step identifiers and order, so that plans can be diffed and reviewed. Any change of identity or configuration invalidates a previously confirmed plan.
- **Separation of preview and execution**: `plan` and `preflight` never mutate chain state; `apply` executes exactly the confirmed plan. Drift between the confirmed plan and the supplied configuration at execution time stops execution.
- **No collapse of step classes**: deploying a contract, configuring it while the deployer is owner, initiating two-step ownership handover, preparing a governance proposal, executing that proposal after a timelock, and verifying the result are different classes with different state, confirmation and failure semantics. The plan never presents them as one step.
- **Gate visibility**: the plan shows which steps are executable now, which are gated behind a timelock, and which are gated behind federation activity — so the operator sees the deployment's long-run shape before starting it.
- **Explicit exclusion list**: the plan lists what the product will *not* do for this deployment (federation signing, production state migration, anything outside §4.1).

---

## 16. Dependency Propagation

**Requirement**: outputs of earlier steps become inputs of later steps automatically and traceably. The operator's job is to declare intent plus the genuinely external inputs; carrying values between steps is the product's job.

- Each step declares its named outputs and its declared post-condition.
- Later steps reference named outputs, not copied literals. Values are resolved from the plan first and from the actual on-chain result once the producing step is confirmed; a receipt-derived value always wins over a predicted or planned value.
- Predicted addresses (as the current flow's nonce-based prediction does [source snapshot]) exist only as expectations: a step that consumes a predicted address either waits for the producing step's receipt to validate the prediction, or is explicitly marked in the plan as consuming a prediction, in which case the prediction is validated at the earliest possible moment.
- **Canonical vs implementation distinction**: the product models the canonical Bridge address and the Bridge implementation address as *different* named outputs, because consumers must be wired to the canonical address rather than the implementation [source snapshot]. Wiring the wrong one must be impossible by construction and visible in the plan.
- **Cross-chain propagation**: an address produced on one chain (for example the Arbitrum adapter) is consumed on another chain as a `bytes32`; the product owns the representation conversion and validates it in both directions, including reading the value back where the contract permits (§8.3 for TRON).
- **Cross-family propagation**: the entrypoint addresses produced on Ethereum and on TRON are consumed by the Arbitrum adapter's trusted-entrypoint registration, which is why that registration is necessarily a later governance step rather than part of adapter deployment [diagram intent].
- **External inputs are validated, not derived**: values such as source tokens and OFTs are not produced by this deployment; they are operator inputs that preflight validates for existence and interoperability as far as the chain allows, and that the manifest records as externally supplied.
- **Never a manual paste**: an unresolvable dependency is a blocking condition (a preflight failure, or a blocked step if only discovered later). The product never asks the operator to paste a value a step was supposed to produce.
- **Provenance is recorded**: for every derived value, the manifest records which step produced it and from which transaction/receipt it was taken.

---

## 17. Preflight Validation

Preflight is the fail-fast gate before any broadcast. It is read-only with respect to chain state, writes nothing containing secrets, and produces a per-check, blocking-vs-warning result.

**Check groups:**

1. **Configuration and identity** — configuration completeness and shape; classification satisfied for required/optional/conditional fields (conditional fields either satisfied or explicitly disabled); flow and profile valid; no leftover environment-file semantics being relied on implicitly.
2. **Sources and artefacts** — both repository revisions declared; artefact set present for every contract unit the flow needs; artefact identities resolvable and consistent with the declared revisions; parameter shape of deployments (parameter count/order/types against the artefact interface) so a changed build surfaces as a validation failure rather than as a broken transaction.
3. **Chains and networks** — every network resolves to a network record; the RPC endpoint is reachable; the chain identity reported by the RPC matches the network record's expected identity; the network's capability record is present (verification capability or an explicit unsupported state, LayerZero endpoint/EID, oracle/feed capability, confirmation and fee/resource policy).
4. **Signer** — the signer is available; the signing account matches the deployment identity; the account's authority matches what the plan assumes (for example current ownership where a configuration step requires it, read on-chain); account resource sufficiency (balance for EVM; account usability plus energy/bandwidth/TRX for TRON) against the estimated total cost with a stated margin.
5. **Dependencies** — full dependency closure is computable: every derived input has a producer earlier in the plan; no cycles; already-satisfied steps are identified rather than re-planned.
6. **Cross-chain and cross-family consistency** — EID↔business-chain-id mapping; token/OFT pairing per route; address representation valid for each consumer (including `bytes32` forms for the adapter); route pairs well-formed (distinct source/destination chain ids, enabled flag, verifier and settlement module resolvable); owner/initial-owner values consistent with the governance target.
7. **Governance** — the `MultisigProxy` target and the federation/enclave signer sets and thresholds are validated as *inputs* (shape, counts, non-emptiness, threshold sanity); timelock parameter sanity; the plan is checked to ensure it never attempts to execute a proposal before the timelock has elapsed.
8. **Safety and redaction** — rendered output passes the redaction check; no secret has entered the plan, the record, or the machine-readable output; the confirmation policy is satisfied for every irreversible step in the plan.
9. **Concurrency/no-drift expectations** — the deployment account is not in use by another process or actor in a way that conflicts with the nonces the plan needs (§19 case 12).

**Outcome semantics**: each check reports pass / warning / fail with the object it concerns and what would resolve it. Any failing check blocks execution. Warnings are visible and recorded in the manifest. An inability to *perform* a check is treated as a failure, not as a pass — "unknown" is never "fine" (§24).

---

## 18. Execution State

### 18.1 Per-step state

At minimum, the product must represent and persist, per step:

- `planned` — in the confirmed plan, not started;
- `blocked` — a precondition is unmet (dependency, configuration, resources, chain identity, identity mismatch, competing account use);
- `awaiting_confirmation` — irreversible step, waiting for the operator's explicit confirmation;
- `submitting` — being signed/broadcast;
- `submitted` — a transaction hash is recorded durably;
- `confirming` — mined, confirmation depth accruing against the network's confirmation policy;
- `confirmed` — confirmation policy satisfied and the step's post-condition verified on-chain;
- `already_satisfied` — the step's post-condition already held before this run; recorded with the evidence used to determine that;
- `failed` — a definitive negative outcome (revert with a definitive reason, or an effect that cannot satisfy the intent);
- `unknown_outcome` — the product cannot determine whether the transaction took effect (for example an RPC outage after broadcast); requires reconciliation and blocks progress until resolved.

Governance steps additionally carry lifecycle state: proposal **prepared**, **created** (transaction recorded), **waiting for signatures** where the governance design requires on-chain collection, **timelock pending**, **executable**, **executed** — with the caveat that the exact set of observable states must be taken from the `MultisigProxy` contract before implementation ([open], §28). The product must be able to display timelock elapsed/remaining wherever the contract exposes it, and must not infer it purely from configuration.

### 18.2 Overall deployment state

The product's overall state for a deployment is one of: `planned` → `executing` → one of `partial`, `awaiting_governance`, `not_ready`, `ready`, `failed`, `aborted`, per §24 — always accompanied by the readiness evaluation of §22.

### 18.3 State rules

- **Durability before waiting** [decision]: the transaction hash and the fact of broadcast are recorded before the product waits for a receipt. A crash must never lose the knowledge that a transaction exists.
- **Evidence, not recollection**: a step is never treated as complete because the plan or the operator says it was done; it is treated as complete because the recorded transaction is confirmed and/or because the on-chain post-condition holds. Inference is allowed only where marked as inference, and is displayed as such.
- **Keyed by deployment identity**: state is per deployment id; operations supplied with a different identity are refused (§13).
- **Secret-free**: state contains no secrets, and is shareable.
- **Sufficient for a later operator**: state plus the plan and the manifest must let a different operator understand exactly where the deployment stands and what the safe next action is — including after a timelock of arbitrary duration.

---

## 19. Retries, Resume, and Idempotency

**Model** [decision]: the product's resume model is *identity-checked reconciliation*, not "run it again". Before any re-broadcast, the product answers, from on-chain state, the question "is this step's desired effect already present?" — by address and code identity for deployments, by ownership/configuration reads for configuration steps, by proposal existence/execution for governance steps. Only when the effect is provably absent does the product broadcast again. Re-running without that proof is explicitly not accepted as the model.

Explicit behaviour per case:

1. **Partial execution** — state shows per-step results; `status` names completed steps, the first incomplete step and the safe resume point; `resume` continues from there and re-validates already-complete steps against chain state before skipping them.
2. **Process crash** — no knowledge of broadcasts is lost (hashes are durable before waiting); on restart the product reconciles local state against chain state using the recorded hashes first, then on-chain reads; it never re-broadcasts blindly.
3. **RPC failure** — bounded retry with backoff per the network record; an RPC failure alone never marks a step failed; if the outcome cannot be determined the step becomes `unknown_outcome` and blocks further progress until reconciled; if a transaction hash was already recorded, the product re-queries that hash instead of sending a new transaction; RPC failover must be configured explicitly per network and never silently moves the deployment to a different network.
4. **Transaction replacement / repricing** — the product detects that a submitted nonce was mined with a different hash. If the replacement carries the same intent (same target and same calldata semantics as the recorded step), the product adopts it and records both hashes and their replacement relation. If it carries a different intent, this means another actor used the account: the deployment **stops** for operator review, because the deployment account's exclusivity has been violated. A cancellation replacement leaves the step not executed, and this must be reportable.
5. **Transaction mined but not recorded locally** — on reconciliation the product inspects the deployment account's recent activity and matches transactions to planned steps by nonce and effect; a discovered matching transaction is adopted into state with its hash, explicitly marked as *adopted from on-chain evidence* in the manifest, together with the fact that its provenance was inferred. Where matching is ambiguous, the deployment halts for operator decision rather than guessing. For deployment steps, an equivalent check is: does a contract matching the expected artefact identity exist at the expected address?
6. **Rerunning the same deployment command** — `apply` on an already-started deployment behaves as `resume`: identity check, reconciliation, continuation from the safe point. It never re-broadcasts a confirmed step. On a fully executed deployment it only re-evaluates status/readiness and reports, mutating nothing.
7. **Already-deployed contracts** — if a contract already exists at the expected address with a matching artefact identity and the step's post-condition holds, the step is `already_satisfied`, recorded with the evidence. It is not redeployed. If the address is occupied by *different* code, this is a wrong-target/foreign-state error: the deployment stops; the product does not overwrite, adopt silently, or guess.
8. **Changed input configuration between attempts** — any change to an identity-bearing field refuses resume and shows a field-level diff (§12); the operator must revert it or explicitly start a new deployment (recorded, with reason). Changes that are not identity-bearing are allowed, recorded, and do not invalidate completed steps.
9. **Changed contract source/artefacts between attempts** — identity mismatch refuses resume and reports the artefact-identity difference (a recompiled artefact with a different identity is a different build even if a revision string looks the same). The product never deploys a mixture of artefacts from two builds.
10. **Wrong chain/network** — blocked at preflight, and re-checked immediately before each signing/broadcast at execution time; a mismatch aborts before anything is signed. There is no automatic switching of networks and no fallback to a default network.
11. **Insufficient deployer balance** — blocked at preflight with the estimated total cost and the shortfall (native gas for EVM; account usability plus energy/bandwidth/TRX for TRON). A shortfall discovered mid-run becomes a blocked step with a concrete funding instruction for a named account on a named chain; never an automatic retry loop that burns resources.
12. **Nonce drift / concurrent use of the deployer account** — three distinct outcomes: (a) the expected nonce is already consumed → reconciliation path as in case 5; (b) a lower nonce is pending from another actor → the deployment stops rather than competing, because its own transaction could be superseded or its intent replaced; (c) the account has unrelated pending activity → reported as a blocking condition if it affects the nonces the plan needs, as a warning otherwise. The product states to the operator that a deployment requires exclusive use of the deployment account for its duration.
13. **Post-deploy governance actions pending for a timelock** — this is not a failure: the deployment enters `awaiting_governance`, which is a distinct, visible state (§21). `status` shows the pending proposals, since when, and (where the contract exposes it) when they become executable. Execution is a separate action once signatures exist and the timelock has elapsed. A deployment is never reported READY while required governance actions remain unexecuted.

**Idempotency definition** [decision]: re-running the same intent with the same identity against a partially complete deployment converges to the same end state, never produces duplicate contract deployments or duplicate governance proposals, and never re-applies a configuration step whose effect is already on-chain. This is achievable only because every step declares a post-condition that can be read from the chain, and because state is always corroborated with chain evidence before a step is skipped.

---

## 20. Result Manifest and Audit Needs

### 20.1 The manifest

The product must emit a deployment result manifest, primarily machine-readable with a human-readable rendering of the same facts.

Required contents:

- the deployment id and the full identity block (§13): both source repositories with revisions, artefact identity set, flow, Bridge profile, network profile, product configuration version, deployment account address;
- per chain and per step: step identity, class, mode, target contract unit, transaction hash(es) including replacement/cancellation relations, confirmation evidence, the provenance of each input, and the named outputs the step produced;
- the resulting addresses with role labels (canonical Bridge vs implementation, proxy, adapter, entrypoint, registry, multisig, plugin modules), each with the step and transaction that produced it, or an explicit statement that it was an external input;
- the non-secret configuration actually used (with secret references, never secret values);
- verification status per contract unit, with the check performed and the observed result;
- the readiness evaluation with its per-check results and observed-vs-expected values;
- the outstanding governance/timelock items and any outstanding manual actions;
- warnings raised during the run, and any operator decisions recorded during the run (for example an explicit acceptance of a changed configuration as a new deployment);
- the product version/configuration version that produced the manifest.

### 20.2 Audit needs

- A third party must be able to take the manifest and (a) confirm every recorded address on chain, (b) reconstruct the exact build identity, (c) see which account performed which step and why, (d) distinguish facts observed directly from facts inferred.
- Every recorded fact carries its **evidence source**: receipt, chain read, or inference. Inference is always labelled.
- The manifest is **secret-free and shareable** by construction (redaction is a preflight-checked property, §17).
- The manifest is **re-generatable**: producing it twice without changes yields the same semantic content, so diffs are meaningful.
- The manifest is **comparable over time**: comparing a manifest against a later `status` must reveal drift (ownership moved afterwards, configuration changed, routes altered). Post-deployment drift reporting is a product-level need, not a monitoring product (§25).

---

## 21. Post-Deploy and Governance State

### 21.1 Three kinds of post-deployment work

1. **Performed directly by the product** while the deployer is still the owner: initial outflow limits on the Bridge, global outflow limits, and — when native commission quoting is enabled — the sequencer uptime feed, the ETH-USD price bounds and the ETH-USD feed [diagram intent]. These are ordinary irreversible transactions of the deployment, subject to confirmation.
2. **Prepared and tracked as governance proposals** through `MultisigProxy`, then **executed by a separate product action** after the federation signatures exist and the timelock has elapsed: accepting ownership of the three governance-owned core contracts, updating the adapter pointer, setting the Bridge's LayerZero adapter, setting global commission defaults, optional route-specific commissions, optional additional enclave signer sets, optional additional outflow buckets, one proposal per directional route, and the trusted-entrypoint registrations for the Ethereum and TRON EIDs [diagram intent, decision].
3. **Merely reported**: whatever the product cannot perform or prepare — federation signing itself, and any organisational or external action outside the contract suite.

### 21.2 The decision and its rejected alternatives

**Decision** [decision]: the product *prepares* proposals and *tracks* their state; execution is a **separate command** issued when the federation signatures are available; **pending governance is a distinct, visible state** that prevents READY.

Rejected: automating create + wait + execute inside `apply` (it would make a single long-running process straddle a timelock of arbitrary duration, hide who acted when, and couple the deployment run to federation timing); and merely reporting a manual checklist without preparing proposal data (it would leave the manual work the product exists to remove).

### 21.3 Semantics the product must implement

- **Two-step ownership handover** [source snapshot]: initiating the transfer is a deployer step; accepting it is a governance step executed through `MultisigProxy`. The intermediate state — owner is still the deployer, pending owner is the multisig — is an expected, legitimate, *displayed* state, not a failure. READY is impossible in that state, because the desired configuration does not yet hold.
- **Proposal data is derived, not transcribed**: the proposal set is computed from the desired configuration (routes from the configured route pairs, trusted entrypoints from the deployed entrypoints, adapter pointers from the deployed adapter). Adding a route or an entrypoint is a configuration change that produces additional proposals — no manual proposal authoring.
- **Proposal lifecycle visibility**: prepared → created → waiting for signatures → timelock pending → executable → executed, with timings where the contract exposes them. The product must not infer executability from configured timelock numbers alone.
- **Expected effect per proposal**: each prepared proposal carries the state change it is supposed to produce, and verification after execution checks that effect (§22). A proposal is not "done" because its execution transaction was mined, but because its effect is observable.
- **Route registration**: performed through federation governance after the base deployment, matching both the snapshot statement and the diagram [source snapshot, diagram intent]. Route pairs are configuration inputs; the chain ids used in them are operator-supplied (§10.3).
- **Trusted entrypoints**: registered per source EID with the entrypoint address in the adapter's expected form and the associated business chain id. Because the entrypoint addresses are produced by later deployments, these are necessarily late governance steps; and because the TRON address form must be confirmed against the adapter, the TRON registration carries an explicit open item (§8.3, §28).
- **Governance does not block other work**: while proposals wait, the product can still report status, evaluate readiness of what is done, and verify completed parts; it simply must not claim READY.
- **No simulated governance**: the product never bypasses the multisig or the timelock, never uses a deployer shortcut to perform an action that the target configuration requires to be governance-controlled.

---

## 22. Verification and Readiness States

### 22.1 Definition of READY

**READY means: the desired configuration matches the on-chain state on every required chain** [decision, adopting the diagram's completion invariant]. It does **not** mean "the deployment transactions were mined", and it does not mean "the workflow reached the end".

### 22.2 Distinct states that must never be collapsed

The product reports these separately, each with per-chain, per-contract evidence:

- **Contracts deployed** — each contract unit exists at its recorded address on its chain, with code identity matching the recorded artefact identity.
- **Transactions confirmed** — each step's transaction(s) satisfy the network's confirmation policy.
- **Ownership transfer initiated** — a pending owner is set while the deployer is still the owner.
- **Ownership accepted** — the governance target is the owner and no pending owner remains.
- **Oracle/config wiring complete** — outflow limits, global limits, and the conditional oracle configuration are set to the intended values (or explicitly disabled).
- **Route configuration complete** — every intended directional route has the intended enabled state, verifier and settlement module.
- **Explorer/source verification complete** — the verification state per contract unit (§22.3).
- **Invariants checked** — Bridge dependencies; the LayerZero adapter pointer; the wiring of `CommissionManager` and `RouteRegistry` to the canonical Bridge address rather than the implementation; signer sets and thresholds; outflow buckets; commission and oracle configuration; adapter per-EID OFT routes; trusted entrypoints; EID↔business-chain-id mappings.
- **Smoke checks passed** — the product's read-only consistency checks plus any minimally invasive probe the suite supports. First-release behaviour: smoke checks are non-destructive by default; a value-moving probe is not assumed ([open], §28).
- **Governance/timelock work still pending** — explicit, with the pending items listed.
- **Usable for traffic** — the aggregate judgement that everything required for the system to accept traffic holds (configuration complete, ownership accepted by the governance target, routes enabled and wired to live modules, entrypoints trusted by the adapter). For a cross-chain deployment, "usable for traffic" requires this on every required chain, because a chain that is not trusted by the adapter cannot route.

**READY = usable for traffic, with the verification state attached as a separate, visible reporting dimension.** There is deliberately **no single `success`** state [decision].

### 22.3 Explorer/source verification

**Decision** [decision]: explorer/source verification is **mandatory for Arbitrum and Ethereum deployments**, is modelled as a separate state per contract unit — `VERIFIED` / `PENDING` / `FAILED` / `NOT_SUBMITTED`, plus an explicit unsupported state for networks without a verification capability — and **its failure does not block READY**, but is always visible to the operator (in `status`, in the plan's follow-ups, and in the manifest).

Rejected: blocking READY on verification (verification depends on external services and on API compatibility, and a verification outage must not make a correctly deployed system "not ready"), and making verification optional/report-only-manual (it is a required part of the product's output for the chains where it applies).

Verification is performed through the helper path defined in §5: the product owns the state machine, the requirement and the reporting; the helper performs the submission. Verification status must record, per contract unit: the check performed, the target (proxy and/or implementation — see §28), the observed result, and the timestamp of the observation.

### 22.4 Unknown is never ready

If a required check cannot be performed (RPC cannot read ownership, contract read fails, artefact identity cannot be resolved), the product reports the check as unknown and the deployment as not ready — never as ready with a gap. Readiness evaluation is performed against on-chain state, not against the local record; the local record is what the product reconciles against.

### 22.5 Drift after completion

If a later evaluation shows the on-chain configuration no longer matches the desired configuration recorded for the deployment, readiness returns to not-ready with an explicit drift report naming the changed items observed-vs-desired. Drift detection is part of readiness reporting, not a separate monitoring product (§26).

---

## 23. Safety Behavior

Product requirements for safety, each traceable to a concrete behaviour:

- **Fail-fast validation before broadcast where possible** — preflight (§17) plus a chain-identity re-check immediately before each signing/broadcast.
- **No secret leakage** — the redaction and non-persistence rules of §14, enforced on every output path including errors, verbose logs and generated evidence.
- **Clear chain identity before signing** — the operator sees and the product confirms the network, its chain identity as reported by the RPC, and the operation before any signature.
- **Exact transaction/result provenance** — every recorded fact carries its source (receipt, chain read, inference) (§20.2).
- **Partial-failure visibility** — a run that stops reports exactly what completed, what was not attempted, and what is blocked.
- **Resume without accidental duplicate deployment** — identity check plus on-chain corroboration before skipping or re-broadcasting (§19).
- **Explicit handling of pending governance steps** — never silently folded into "done", never hidden behind a "workflow finished" message (§21).
- **Safe dry-run / plan preview** — `plan` and `preflight` are the dry-run surfaces, read-only and safe to run repeatedly.
- **Confirmation before materially dangerous operations** — broadcast of irreversible transactions, initiation of ownership handover, proposal creation, proposal execution, verification submission, and anything on a mainnet network (§11.1).
- **No silent fallback** — to a different network, a different signer, a different artefact, or a different deployment mode. Each of these is a hard error, never a substitution [decision].
- **No claiming completion when required verification is incomplete** — READY semantics (§22.4).
- **Mainnet discipline** — mainnet networks are first-class but never entered implicitly: no mainnet deployment without explicit operator intent, and no default that points at a mainnet network [decision].
- **No sign-what-you-did-not-build** — the product signs only calldata or proposal payloads it constructed and displayed, and records what was signed.
- **No governance shortcuts** — the product never uses deployer authority to perform an action that the desired configuration requires to be governance-controlled.
- **Exclusivity of the deployment account** — the product states the requirement and detects violations (§19 case 12).
- **No destructive cleanup** — the product never attempts to "undo" on-chain operations; where a mistake is conceivable, the answer is validation before broadcast and explicit operator decision after.

---

## 24. Failure and Incomplete States

Terminal-ish states of a deployment, with their meaning, evidence and operator obligations:

| State | Meaning | What the operator sees |
| --- | --- | --- |
| `FAILED` | A step produced a definitive negative outcome; the deployment cannot continue without intervention. | Which step, which chain, the evidence, and whether any on-chain effect was produced. |
| `BLOCKED` | A precondition is unmet (unresolved dependency, insufficient funds/resources, wrong chain identity, configuration change, identity mismatch, competing account use, failing preflight check). No effect was produced for the blocked step. | The blocking condition, the step it blocks, and a concrete action list. |
| `PARTIAL` / `INCOMPLETE` | Some steps confirmed; the rest not attempted or blocked. | The safe resume point, the completed steps with their evidence, and what remains. |
| `AWAITING_GOVERNANCE` | All product-executable steps confirmed; proposals created and waiting for federation signatures and/or the timelock. Explicitly not READY. | The pending proposals, since when, and when they become executable where observable. |
| `NOT_READY` | Everything executed, but the desired configuration does not (yet) match on-chain state, or a required check could not be completed. | The per-check readiness report, including unknown checks. |
| `READY` | Desired configuration matches on-chain state on every required chain (§22), with verification state attached separately. | The full readiness report plus verification status. |
| `ABORTED` | The operator explicitly aborted the run. | What was done, what was not, and that nothing was rolled back. |

**Rules:**

- The product never reports READY with a required step unconfirmed, a required check failed, or a required check unknown.
- The product never reports FAILED when the outcome is genuinely unknown; that case is `unknown_outcome — reconciliation required` (§18.1).
- Every failure/incomplete state carries an action list and the evidence that produced the state, so a different operator can resume days later, after a timelock, or after a product upgrade.
- Incomplete states must be resumable across product upgrades: a recorded deployment made by an older product version remains interpretable, or is explicitly migrated with operator visibility (§25).
- **No hidden rollback**: blockchain operations are irreversible; the product's answer to risk is pre-broadcast validation, and its answer to an unavoidable error is a truthful report plus explicit operator decisions.

---

## 25. Maintenance and Evolution

The contract suite will change; the product must absorb change deliberately.

- **New revisions** — a new revision of either repository is adopted deliberately: identity (§13) records both, so a new build forces a fresh plan; mid-deployment, a new build refuses resume and reports the artefact-identity difference. Adopting a new build mid-deployment is an explicit, recorded operator decision to start a new deployment.
- **New contract units or steps in a flow** — flows are named sets of steps with declared inputs, outputs and post-conditions; a flow gaining a step, or a new contract unit appearing, is expressed by declaring the step and its wiring, and dependency propagation, plan rendering, execution state and verification continue to work unchanged. The product must not encode a fixed contract inventory as a product rule.
- **New chain family** — TRON is the first such case: product semantics (identity, plan, preflight, state, resume, UX, verification, readiness) stay identical while a family-specific executor and the family's network/capability records are added (§8). This separation is the reason adding a family is an evolution rather than a redesign.
- **New EVM network** — adding a network means adding a network record and a capability record (verification, LayerZero endpoint/EID, oracle/feed capability, confirmation and fee policy), together with the operator-supplied external values. It is a product decision, never enabled by a "supports all EVM" switch (§7).
- **Governance changes** — when `MultisigProxy` governance semantics change, the product's governance step class and lifecycle states must be re-derived from the contract, not assumed; because proposals are generated from the desired configuration, new route/entrypoint requirements become new proposals without manual authoring (§21).
- **Product configuration versioning** — the configuration version is part of identity, so a schema change is explicit; recorded deployments must remain interpretable or be explicitly migrated.
- **Manifest longevity** — manifests remain verifiable documents; readiness can be re-evaluated against an older manifest, reporting drift rather than silently accepting it (§22.5).
- **Retirement** — if a flow is retired (for example `MinimalBridge`), the product reports it as unsupported rather than partially working. Retiring a flow must not leave an existing recorded deployment unverifiable.
- **Deferred flows stay reachable** — every deferred capability in §28 has a stated path back in, so the first release's narrow scope does not create a dead end.

---

## 26. Explicit Non-Goals

The following are **not** part of this product, and expanding into any of them requires explicit product justification in a future revision of this document rather than silent inclusion [decision]:

1. A generic deployment platform for arbitrary third-party smart contracts.
2. A smart-contract IDE.
3. A wallet product.
4. A federation key-management product.
5. A general-purpose blockchain operations dashboard.
6. A replacement for contract testing.
7. A replacement for Solidity/Foundry compilation, without an actual product reason.
8. Automatic migration of deployed production state.
9. Automatic mainnet deployment without explicit operator intent.
10. Fabricated TRON support based on assumptions.

Additionally, the following are out of boundary as a direct consequence of the decisions above (not new prohibitions, but the product must not drift into them): holding or managing governance keys; producing federation approvals; acting as a signer service for other systems; being a chain indexer or uptime monitor (drift *reporting* for a deployment's own configuration is in scope, continuous monitoring is not); re-implementing source verification; re-implementing a Solidity or TRON compiler; deploying contracts outside the declared inventory of a supported flow; supporting arbitrary EVM networks without an explicit product decision.

The product is specifically about reliable deployment and lifecycle setup of the supported UTEXO contract suites.

---

## 27. Product Question Register

The product intent posed fourteen questions. Each is resolved here or is explicitly open in §28.

1. **What must "Go-native" mean for deployment execution vs compilation/artefact generation?** Resolved in §5: Go owns transaction construction and broadcast, signing, artefact consumption, state, resume and UX; Foundry remains the compiler and the source of artefacts; verification and Foundry invocation are helper paths; running the existing deploy scripts as the execution engine is rejected.
2. **What operator UX is desired for the first release?** Resolved in §11: one non-interactive CLI with `plan` / `preflight` / `apply` / `status` / `resume`, machine-readable output, confirmation for irreversible actions; interactive CLI/TUI as the primary surface rejected; SDK-only rejected; the library remains usable without the CLI.
3. **Which EVM deployment flows are required in the first release?** Resolved in §6: F1–F7 — proxy-profile core deployment, Arbitrum adapter, Ethereum entrypoint, bootstrap governance preparation/tracking/execution, verification and readiness evaluation, verification state; `MinimalBridge`, step-by-step and implementation upgrades staged.
4. **Which EVM networks are first-class targets?** Resolved in §7: Arbitrum One, Arbitrum Sepolia, Ethereum mainnet, Ethereum Sepolia, each with its own network record and capability record; "all EVM networks" and unnamed network-selection rules rejected.
5. **Is explorer/source verification mandatory or optional?** Resolved in §22.3: mandatory for Arbitrum and Ethereum deployments, separate per-contract state, failure visible but not blocking READY.
6. **Which signer modes are required initially?** Resolved in §14: a local key (keystore/env) is required, plus a signer abstraction for external signers later; KMS/HSM/hardware-wallet as first-release requirements rejected.
7. **Which post-deploy governance steps should the tool automate, prepare, or merely report?** Resolved in §21: direct configuration while the deployer is owner is performed; governance actions are prepared and tracked and executed by a separate command once signatures exist; federation signing itself is merely reported.
8. **What is the desired behaviour around route registration and timelocked actions?** Resolved in §21: routes and trusted entrypoints are configured through federation governance after the base deployment (matching both the snapshot and the diagram); timelocked work produces a distinct pending-governance state that blocks READY; execution is never inside `apply`.
9. **What deployment state must be persisted for audit and resume?** Resolved in §13 and §20: the full identity, per-step state with evidence and provenance, the plan, the non-secret configuration, transaction evidence including replacements, verification and readiness results, and pending governance items; storage technology not prescribed, properties required; secret-free.
10. **Where will the Go product live: a new repository or an existing implementation repository?** Resolved in §1.1 (item 9): a new Go module in this repository; the repository is otherwise empty and no other place exists in the project.
11. **Does the developer sequence diagram represent the intended target flow where it differs from current scripts (especially Bridge address prediction / implementation+proxy)?** Resolved in §10: the diagram is adopted as target intent for the flow's phases, governance-driven route/entrypoint configuration, and the completion invariant; the Bridge shape divergence is closed by supporting both named profiles with the first release on the proxy profile and with all addresses taken from actual nonce/receipt evidence. Whether the diagram describes a planned refactor or needs correction remains open in §28 with no first-release impact.
12. **Should the first EVM release include only Arbitrum core, or also the Arbitrum `UtexoLZAdapter` and Ethereum `UtexoSourceEntrypoint`?** Resolved in §6/§7: core + adapter + Ethereum entrypoint, because a core-only release delivers no working end-to-end result; "everything including TRON at once" is rejected as well, with TRON sequenced after the EVM result (§8).
13. **For TRON, must deployment execution itself be native Go, or may Go orchestrate the pinned TronBox toolchain while owning validation/state/resume/UX?** Resolved in §8: Go orchestrates the pinned TronBox toolchain while owning validation, state, resume and UX; native Go TRON deployment is not a first-TRON-release requirement.
14. **Are upgrades part of the first product scope or a later capability?** Resolved in §6.2/F10 and §28: later. The proxy profile gives the stable canonical address that an upgrade capability needs, and the product never assumes the implementation address is canonical anywhere, so the deferral creates no dead end.

---

## 28. Unresolved Product Decisions and Deferred Capabilities

### 28.1 Open product decisions

Each item below is explicitly open. None blocks the first release, and each states its impact.

1. **Is the diagram's single-transaction Bridge a planned simplification or a diagram error?** [open] The diagram's `CREATE(n + 2)` / one-Bridge-transaction shape conflicts with the snapshot's implementation-plus-proxy flow (`n+2` implementation, `n+3` canonical proxy) [source snapshot]. Product impact: none for the first release, because both profiles are named, supported and part of identity, and the first release uses the proxy profile; the residual question is organisational (correct the diagram or plan a suite refactor) and must be answered by contract/release stakeholders before the `single-tx` profile would ever be selected.
2. **Confirmation of the TRON business chain id `728126428`** [open] — not found in the inspected snapshot; treated as operator-supplied configuration, validated at preflight and echoed in the manifest. Impact: none on design (it is an input); needs confirmation from an accepted source before TRON trust registration is executed.
3. **Encoding of a TRON address inside the adapter's `bytes32` trusted-entrypoint slot, and whether the business chain id is a separate field of the same registration** [open] — must be confirmed against the adapter contract before TRON trust registration executes. Impact: contained; the product already requires explicit bidirectional conversion with read-back validation (§8.3); what remains is which encoding is authoritative.
4. **`MultisigProxy` governance lifecycle detail** [open] — the exact observable proposal states, the timelock semantics (relationship between the configured timelock duration and the minimum), whether federation approvals are collected off-chain before proposal creation or on-chain afterwards, and whether cancellation/expiry exists. Product requirement in the meantime: represent and display whatever the contract makes observable, and never infer executability from configuration alone.
5. **Which oracle configuration applies to which network, and which feed addresses are valid per network** [open] — the product defines the conditional behaviour (conditional field, explicit enablement/disablement, per-network capability record, preflight validation), not the values. Impact: none; values are operator inputs.
6. **What constitutes a passing smoke check for the suite** [open] — first-release behaviour: smoke checks are read-only non-destructive checks by default, and a value-moving probe is not assumed. Needs contract-suite input to define anything more.
7. **Testnet network values** [open] — the EIDs, LayerZero endpoints, OFT addresses, chain identities and verification providers for the Sepolia-profile networks must be supplied per network record; the product's requirement is that they are declared and validated, and it does not assume parity with mainnet identifiers.
8. **Explorer verification coverage of the proxy profile** [open] — whether verification must cover both the proxy and the implementation for each contract unit, and how a failure on one of them is reported. Related: whether the helper path (`forge verify` or an explorer-API equivalent) is usable for both Arbitrum and Ethereum in the operator's environment. Impact: contained; verification does not block READY either way.
9. **Whether a non-interactive confirmation-acknowledgement mode is needed for automation** [open] — proposed shape: an explicit opt-in that is recorded in the manifest as an acknowledged confirmation policy, never a default. Needs product approval before it exists.
10. **Whether TRON readiness depends on the Arbitrum-side trust registration having executed** [open] — the product's working answer is yes (the entrypoint is not usable for traffic until the adapter trusts it), which must be confirmed with the contract owners, since it affects when the TRON part of a deployment can be reported as usable for traffic.
11. **Whether the `prepare_governance`-style long-lived sequence needs additional operator-visible stages** beyond create/wait/execute — needs the governance lifecycle detail of item 4.

### 28.2 Deferred capabilities (named as deferred, no dead end)

- **`MinimalBridge` deployment flow** [deferred] — excluded from the first release; addable later as another named flow with its own declared steps, inputs, outputs and post-conditions. No first-release assumption prevents it: the product models Bridge profiles as named variants rather than assuming a single Bridge shape.
- **Step-by-step operator-driven flow** [deferred] — `plan`, `status` and per-step execution state already expose the steps; a first-class interactive step-by-step flow is deferred and must not become the only product surface if introduced. The first release's step model (stable step identities, per-step state, post-conditions) is what such a flow would need.
- **Bridge implementation upgrade flow** [deferred] — the proxy profile keeps the canonical address stable, which is the prerequisite; an upgrade capability would additionally need its own plan and verification semantics (fresh desired-configuration comparison, authorisation, and storage-compatibility concerns the product can at most report). The product must never treat the implementation address as canonical, so the deferral creates no dead end.
- **TRON execution** [deferred until after the EVM end-to-end result] — the family executor, TRON network record and TRON capability records are the additions; the product semantics are already defined (§8) so TRON does not require redefining identity, plan, state, resume, verification or UX.
- **Additional EVM source chains** beyond §7's list [deferred] — added as network records plus a product decision, each with its own verification/oracle/RPC capability declaration.
- **External signers (KMS/HSM/hardware wallet)** [deferred] — reachable behind the signer abstraction without changing product semantics (§14).
- **Read-oriented TUI over `status`** [deferred] — only ever a secondary surface, and only if a real operator need appears; it can never replace the non-interactive CLI or the library (§11).

---

## Appendix A — Deployment Step Inventory Adopted from the Developer Diagram

This appendix lists the steps the diagram describes, mapped to the product's step classes, so that the plan model in §15 can be checked against the intended flow. Identifiers are the diagram's; the product assigns its own stable step identities at plan time.

| Diagram step | Product step class | Notes / decisions |
| --- | --- | --- |
| Preflight (configuration, secrets, RPCs, chain ids, balances, addresses, signer thresholds, EIDs, OFT peers) | preflight | §17. |
| A1 CommissionManager | deploy | Consumer of the predicted/canonical Bridge address; the canonical address is a distinct named output (§16). |
| A2 RouteRegistry | deploy | Same wiring rule to the canonical Bridge address [source snapshot]. |
| A3 Bridge | deploy | Profile-dependent: proxy profile deploys implementation + proxy; `single-tx` profile deploys one contract. Diagram's `CREATE(n + 2)` is not adopted as a fact; addresses come from receipts (§10.2). |
| A4–A9 verifiers and settlement modules | deploy | Plugin units; order and dependency of each on the RouteRegistry (and, for some, on other modules) is preserved. |
| A10 MultisigProxy | deploy | Governance target; consumes Bridge, CommissionManager, guardian, enclave and federation sets, thresholds and timelock parameters. |
| A11–A12 outflow limits | direct configuration | Performed while the deployer is owner; irreversible and confirmed. |
| A13–A15 oracle configuration | direct configuration | Conditional on native commission quoting being enabled for the network (§7.2, §12.2). |
| A16–A18 ownership transfer initiation | ownership-transfer initiation | Two-step handover; the intermediate state is expected and displayed (§21.3). |
| A19 UtexoLZAdapter | deploy | EID↔OFT routes and trusted-entrypoint slots; trusted entrypoints are registered later through governance. |
| E1 Ethereum entrypoint | deploy | Consumes the Arbitrum adapter as `bytes32` (§16). |
| T1 TRON entrypoint | TRON-orchestrated deployment | Deferred with TRON execution; product semantics defined in §8. |
| P1–P3 ownership acceptances | governance proposal preparation | Executed later (X1–X3). |
| P4 enclave signer sets (optional) | governance proposal preparation | Conditional on additional signer sets being required. |
| P5 additional outflow buckets (optional) | governance proposal preparation | Conditional. |
| P6–P8 adapter pointer, Bridge adapter pointer, global commission defaults | governance proposal preparation | Derived from the deployed adapter and desired configuration. |
| P9 route-specific commissions (optional) | governance proposal preparation | Conditional. |
| Pn route registration (one per directional route) | governance proposal preparation | Routes derived from configured route pairs; chain ids are operator inputs (§10.3). |
| Pn+1, Pn+2 trusted entrypoints (Ethereum EID, TRON EID) | governance proposal preparation | Require deployed entrypoint addresses; TRON carries the open address-form item (§28). |
| Phase 8 timelock wait | governance execution gate | Distinct pending governance state; never inside `apply` (§21.2). |
| X1–Xn+2 proposal execution | governance execution | Separate command after federation signatures and timelock. |
| Phase 9 final verification | verification | Ownership and pending owners; Bridge dependencies and adapter pointers; signer sets and thresholds; outflow buckets; commission and oracle configuration; every directional route; per-EID OFT routes; trusted entrypoints; EID↔business-chain mappings; plus explorer/source verification (§22). |

## Appendix B — Source-Snapshot Claim Register

Every code-level claim in this document is one of the following. Repositories: `UTEXO-Protocol/bridge-smart-contracts` (branch `dev`, revision `dcb9d395c109d16d7afd2e5c96464f947d303953`) and `UTEXO-Protocol/usdt0-smart-contracts` (branch `dev`, revision `872548276f48cd8e71a8c1c626654a3691243aec`), as inspected in the source snapshot dated 2026-09-30.

| Claim | Repository / revision |
| --- | --- |
| Full-deployment script deploys CommissionManager, RouteRegistry, Bridge implementation, canonical Bridge proxy, plugins, MultisigProxy, initial outflow configuration, optional oracle configuration, and initiates two-step ownership handover. | bridge-smart-contracts @ `dcb9d395c109d16d7afd2e5c96464f947d303953` |
| Current nonce layout of the full deployment: CommissionManager `n`, RouteRegistry `n+1`, Bridge implementation `n+2`, canonical BridgeProxy `n+3`; the proxy is the canonical Bridge address. | bridge-smart-contracts @ `dcb9d395c109d16d7afd2e5c96464f947d303953` |
| `CommissionManager` and `RouteRegistry` are wired to the canonical Bridge proxy address rather than to the implementation. | bridge-smart-contracts @ `dcb9d395c109d16d7afd2e5c96464f947d303953` |
| Routes are not registered by the full-deployment script; federation governance performs route setup later. | bridge-smart-contracts @ `dcb9d395c109d16d7afd2e5c96464f947d303953` |
| A separate `MinimalBridge` deployment path exists, and a step-by-step deployment path exists. | bridge-smart-contracts @ `dcb9d395c109d16d7afd2e5c96464f947d303953` |
| Configuration is consumed from an environment-file style surface with required, optional and conditionally required values (no values reproduced here). | bridge-smart-contracts @ `dcb9d395c109d16d7afd2e5c96464f947d303953` |
| `UtexoLZAdapter` is deployed on Arbitrum with endpoint, token, Bridge, MultisigProxy, and arrays of EIDs and local OFTs; it stores per-EID OFT routes and trusted source entrypoints; Ethereum EID `30101`, TRON legacy EID `30420`, Arbitrum destination EID `30110` appear as examples. | usdt0-smart-contracts @ `872548276f48cd8e71a8c1c626654a3691243aec` |
| The EVM source entrypoint deployment is non-upgradeable and takes source token, source-chain OFT, destination EID, the Arbitrum adapter as `bytes32`, and the initial owner. | usdt0-smart-contracts @ `872548276f48cd8e71a8c1c626654a3691243aec` |
| TRON material includes the source entrypoint contract, a deployment script, toolchain configuration, package metadata, documentation and tests; the documented toolchain is TronBox 4.7.1, solc 0.8.20, `viaIR`, `evmVersion: paris` (TVM has no `PUSH0`), Node.js >= 18, deployed through the TronBox migration command. | usdt0-smart-contracts @ `872548276f48cd8e71a8c1c626654a3691243aec` |
| The TRON entrypoint deployment takes token, OFT, destination EID, the Arbitrum adapter as `bytes32`, and the initial owner. | usdt0-smart-contracts @ `872548276f48cd8e71a8c1c626654a3691243aec` |
| The inspected snapshot does **not** contain the TRON business chain id `728126428`. | Both repositories @ the revisions above |
| The target deployment spans two repositories and two toolchains, and therefore cannot be attributed to a single repository or revision. | Both repositories @ the revisions above |

Statements marked **[diagram intent]** — the phase structure, the step identifiers, the `CREATE(n + 2)` note, the proposal and execution sets, the TRON EID and business chain id values, the route-pair chain ids, and the completion invariant — come from the developer-provided deployment sequence diagram and are **not** claims about current code behaviour.
