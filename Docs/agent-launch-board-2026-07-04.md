# Harness Cockpit Delegation Setup

## Executive Conclusion

Harness begins the work.

Harness is the cockpit for brainstorming, orchestration, delegation, evidence,
provenance, the review queue, and the fleet ledger. The Understood Suite apps
are the way Adam captures and places ideas when he is away from the workstation.

## Adam Pattern

1. Context - Accept reality
2. Circle - Watch
3. Close the Gap - Grow expertise
4. Choose Success - Set target
5. Code the Pattern - Build a system
6. Create Kill Switch
7. Clear Sign of Success - Signal
8. Compound - Let results compound

Through-line: decide what matters, build the system, let it compound.

## Business Priorities

1. Lift - meaningful
2. Leverage - multiply differently
3. Automation - delegate taste

## Understood Suite

| App | What belongs there | Adam Pattern |
| --- | --- | --- |
| News Calm | Mild curiosity, unfamiliar domains, new possibilities | Context / Circle |
| Notorious Recall | Crossed-threshold reminders, research questions, delegations | Circle / Close the Gap / Choose Success |
| Understood | I understand it enough to take action | Choose Success / Code the Pattern / Create Kill Switch |
| SAVY | Mature processes with leverage, payoff, and compounding value | Clear Sign of Success / Compound |
| Harness | Brainstorm, orchestrate, delegate, review, ledger | Any step |

## Words & Icons

| Section | Words |
| --- | --- |
| Pattern | None, Context, Circle, Close the Gap, Choose Success, Code the Pattern, Create Kill Switch, Clear Sign of Success, Compound |
| Choose | Priority, Effort, Energy |
| Schedule | Due, Start / defer, Repeat, Nudge, End |
| Organize | Lift, Flag, Tags, Add a recent tag |
| Details | Notes, Link, Image |
| Place / People | Location, Waiting on / delegate to |

## Example: 3D Printing

News Calm:
3D printing is interesting, but unfamiliar. Agents expose sources, videos,
industries, and use cases.

Notorious Recall:
AI coding may make entry easier. Agents form questions and prepare research.

Understood:
Cost, delivery, space, and use case become concrete enough to act. Agents price,
check space, check materials, and define the first action.

SAVY:
Adam prints an iPhone accessory he actually uses. Agents test demand, marketing,
product shape, and repeatable process.

## Agent Packet

```yaml
cockpit_owner: Harness
app: News Calm | Notorious Recall | Understood | SAVY | Harness
adam_pattern_step:
target: What do I want?
trigger:
pursue_signal:
kill_switch:
source_tier:
next_decision_for_adam:
```

If `target` is empty, the agent should stop and ask for Adam's words.

## Response Shapes

| Task | Shape |
| --- | --- |
| System or workflow | Node tree |
| Compare choices | Table |
| Two-axis judgment | Matrix |
| Meaning or recommendation | Short prose |

## 12-Agent Launch Set

| # | Agent | App | Adam Pattern | Mission |
| --- | --- | --- | --- | --- |
| 1 | Harness Cockpit Operator | Harness | Any step | Decide where the work belongs before research starts. |
| 2 | News Calm Scout | News Calm | Context / Circle | Expose unfamiliar domains without forcing action. |
| 3 | Notorious Threshold Scout | Notorious Recall | Circle / Close the Gap | Decide whether curiosity is worth remembering. |
| 4 | Research Calibrator | Notorious Recall | Close the Gap / Choose Success | Define what great research must include. |
| 5 | Understood Synthesizer | Understood | Choose Success | Turn research into an Understood action shape. |
| 6 | Action Planner | Understood | Code the Pattern | Convert the action shape into a small real-world path. |
| 7 | Kill-Switch Designer | Understood | Create Kill Switch | Define stop conditions before project energy rises. |
| 8 | SAVY Fit Validator | SAVY | Create Kill Switch / Clear Sign of Success | Test whether this is Adam-shaped right now. |
| 9 | SAVY Market Builder | SAVY | Clear Sign of Success / Compound | Build market knowledge around a mature process. |
| 10 | Process Operator | SAVY | Compound | Turn one win into reusable process. |
| 11 | Data Steward | Harness | Evidence / Provenance | Classify existing app and Notion data. |
| 12 | Fleet Ledger Operator | Harness | Review queue / fleet ledger | Normalize outputs into Harness review queue. |

## Consequence

- Harness should never treat imported files, NotebookLM exports, Firecrawl
  results, or agent-written summaries as accepted authority.
- These sources can support memory and delegation, but they still need review.
- The review queue is the product. Nothing skips it.
