# Architecture Decision Records (ADRs)

**Purpose**: Provide a historical timeline of structural or design decisions made in this repository.  
**Audience**: Architects / Maintainers  

## Index

* [0001 - Record Architecture Decisions](0001-record-architecture-decisions.md)

## Process: Adding a New ADR

When to write an ADR:
- When a change drastically shifts the networking topography (e.g., swapping CNI).
- When a change alters how state is stored or backed up.
- When you adopt a new critical dependency (e.g. migrating from bash logic to Terraform).

### ADR Template
Use the following format for new ADR files (`NNNN-short-title.md`):

```markdown
# [Short title of solved problem and solution]

- Status: [proposed | accepted | rejected | deprecated | superseded]
- Date: YYYY-MM-DD

## Context
[What is the problem? Why does it need a solution?]

## Decision
[What change is being proposed or accepted? Mention technical specifics.]

## Consequences
[What becomes easier? What becomes harder? Any operational tech debt added?]

## Alternatives Considered
[What else did you try and why was it abandoned?]
```

## References
- [Glossary](../../reference/glossary.md)
