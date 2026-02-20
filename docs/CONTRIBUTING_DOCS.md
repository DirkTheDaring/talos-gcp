# Contributing to Documentation

**Purpose**: Establish a robust docs-as-code strategy to prevent architectural and configuration drift.  
**Audience**: Contributors / Maintainers  

## 1. Docs-Impact Checklist for Pull Requests
Every PR affecting the `talos-gcp` behavior must have these checkpoints verified:
- [ ] Are new configuration/environment variables appended to `reference/configuration.md`?
- [ ] Do any new networking topology features require updates to `architecture/overview.md`?
- [ ] Were the CLI `talos-gcp` interface options modified? (Update `reference/interfaces.md`).
- [ ] Did you introduce a new dependency? If yes, consider whether an ADR is required.

## 2. Architecture Decision Records (ADRs) Requirement
Create an ADR in `docs/architecture/decisions/` whenever introducing:
- A new core capability (e.g. swapping Traefik for Gateway API).
- A breaking change to deployment topographies (e.g. using External LBs instead of Internal).
- A new persistent storage strategy.
See the [ADR Index Guide](architecture/decisions/README.md) for templates.

## 3. Style Guide
- **Headings**: `H1` (#) for document titles only. `H2` (##) for main sections. `H3` (###) for subsections. Do not nest deeper unless absolutely necessary.
- **Procedural blocks**: Always frame them with *Purpose*, *Audience*, *Preconditions*, *Steps*, and *Validation*.
- **Diagrams**: All diagrams MUST use Mermaid. Fenced blocks should use ````mermaid`.
- **Glossary**: When introducing new acronyms (e.g., IAP, ILB, CCM), define them in `reference/glossary.md` and link them.

---

## The "Docs-Drift-Check" CI Concept
Because this deployment relies on standalone bash, we cannot assume standard compilation errors will catch drift. We propose a lightweight CI job titled `docs-drift-check`.

### How it operates
1. **Broken Links**: Scans `docs/` using an AST markdown parser to verify all relative links resolve correctly. It fails the build on 404s.
2. **Missing Mermaid**: Greps `architecture/*.md` to ensure at least one ````mermaid` block exists. Fails if diagrams are accidentally stripped.
3. **Configuration Drift**: Parses `lib/config.sh` for regex `*="${*:}` (var defaults). Compares the extracted list of keys against the markdown table in `reference/configuration.md`. If a variable exists in bash but is undocumented, CI fails.
4. **ADR Triggers**: If a commit modifies `lib/cni.sh` or `lib/controlplane.sh` significantly (>50 loc changed), CI flags a warning reminding the reviewer that an ADR might be required.
