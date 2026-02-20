# 0001 - Record Architecture Decisions

- **Status**: accepted
- **Date**: 2026-02-20

## Context
As the `talos-gcp` project grows in complexity, the underlying bash scripts have amassed numerous specialized configurations (e.g., IP Alias native routing logic for internal load balancing, customized CSI driver mounting). Without a formal log, it’s unclear why certain GCP configurations are hardcoded or intentionally override standard Kubernetes deployments.

## Decision
We will use Architecture Decision Records (ADRs) to document significant design decisions within the `docs/architecture/decisions` directory. 

## Consequences
- **Positive**: We will have a searchable history explaining the *why* of our topology.
- **Negative**: Adds a small amount of bureaucracy to the architectural documentation process. Reviewers must enforce ADR generation during pull requests for major shifts.

## Alternatives Considered
- Documenting decisions purely in commit messages or pull request descriptions: Abandoned because they are difficult to discover longitudinally and fragment the source of truth.
