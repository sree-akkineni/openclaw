# Research Loop Stress Requests

This fixture is used to stress-test `research_loop` behavior under realistic research load.

File:

- `test/fixtures/research-loop-stress-requests.jsonl`

Coverage buckets (40 total requests, 5 each):

1. contradictory claims
2. hype versus evidence
3. fast release tracking
4. security and privacy implications
5. cost and performance tradeoffs
6. act-now decision memos
7. branching followups
8. long-horizon watchlist topics

Each request includes:

- `topic`
- `task`
- `continuationCriteria`
- `stopCriteria`

Recommended usage:

1. Run deterministic stress evals (`research-loop.stress.test.ts`) in CI.
2. Use `research_loop action=list view=needs_decision` to build the decision queue.
3. Use `research_loop action=list view=needs_review` to surface weak-analysis checkpoints (low quality score, missing critique, or no citations).
4. Use `research_loop action=list view=hot` to rank urgent high-impact loops.
5. Continue or close loops explicitly after user review.
