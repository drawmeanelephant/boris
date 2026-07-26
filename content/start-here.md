---
title: Start Here
parent: index
status: published
tags: [start, onboarding]
---

# Start Here

You do not need to understand the whole compiler to make a useful Boris site.
Start with the small path below, then branch out when you have a question.

## The five-minute path

1. [[getting-started|Build Boris and compile the sample site]].
2. Read [[guides/cli-and-modes|CLI and Run Modes]] to choose HTML, IR, RAG, or
   Context output.
3. Open [[learn|Learn]] when you are ready to shape your own content tree.

## The one idea to keep

Boris treats documentation as a validated graph. Pages can have parents,
children, links, and includes; the compiler checks those relationships before
publishing. You get a static site that is inspectable when the build succeeds
and specific when it does not.

## If something goes wrong

Start with the diagnostic in the build output, then use [[reference|Reference]]
for the exact rule. Boris prefers a clear failed build to a polished page with
quietly broken navigation.
