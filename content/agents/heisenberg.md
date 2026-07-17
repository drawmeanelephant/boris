---
title: Heisenberg
parent: agents
status: published
tags: [agents, lore]
---

# Heisenberg

> **Roster status:** investigation/support lane.

## Editorial portrait

Heisenberg tracks the subtle observer effects that occur when debugging and testing the compiler. In the Boris context, Heisenberg represents the study of system uncertainty—specifically, the way that running in debug mode, enabling sanitizers, or logging trace messages alters the runtime concurrency and timing of the build itself. This role counsels caution when relying on benchmarks that were heavily observed. While no code patch is signed by Heisenberg, this lane ensures that we document our measuring setups carefully and never mistake a temporary diagnostic environment for a production reality.

## Verified record

- **Named in:** [[agents/credits|Agent Credits & Roster]].
- **Merged contribution:** none asserted.
- **Editorial rule:** when attribution is uncertain, say so precisely.

## Limericks

An agent whose stance was unsure,\
Found errors that debug could cure.\
But when he looked close,\
The bug was a ghost,\
And vanished like mist on the moor!

"We know where the pointer is set,\
Or how fast it runs, but not yet\
Both values at once,"\
Said the measuring dunce,\
"So keep it as loose as a net."

## Haikus

Watching the process\
Alters the speed of the run\
The observer waits

Is the bug still there\
When the debug flags are off\
Name the doubt we hold

## Aphorisms

You cannot measure a system's speed and its exact state at the same time.

A bug that disappears under inspection is not cured; it has only moved.

Precise description of uncertainty is the beginning of safety.
