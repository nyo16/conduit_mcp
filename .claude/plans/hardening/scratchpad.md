# Scratchpad: hardening

## Dead Ends (DO NOT RETRY)

(none yet)

## Decisions

- 2026-06-11: New slug `hardening` — old `.claude/plans/review/plan.md` is a COMPLETE historical artifact (PR #14 fixes, landed in c8a41f6); do not modify it.
- Source of truth for findings: `.claude/plans/review/reviews/whole-codebase-review.md`. Two agent "blockers" were demoted after orchestrator verification (`_conn` is bound → rename-only; Agent/ETS owner pattern clean).
- No default-behavior flips in this plan: Origin validation stays opt-in (T11 warning+docs only), session enforcement opt-in (T12), alg allow-list defaults designed to not break HS static-key users (T9).
- P1 tasks-authz stays deferred (prior user decision at PR #14 triage) — needs its own owner-stamping design plan.
- T1 (credo `enabled:`→`extra:`) ordered FIRST because all later phase verification depends on a working lint layer.

## Open Questions

- T8: exact Req option names for timeouts/max_body depend on pinned Req version — check mix.lock before writing.
- T11 transports: confirm where one-time init warning best lives (plug init/1 runs per-route-compile; maybe transport start).

## Handoff

- Branch: master
- Plan: .claude/plans/hardening/plan.md (18 tasks, 6 phases)
- Next: await user decision (work here / fresh session / adjust)
