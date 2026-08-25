---
id: backslash-pipe
title: trailing backslash then pipe A\ | forged | row
parent: home
tags: [pipes]
---

# Backslash pipe

A backslash immediately before a pipe defeats a naive `|` escape: the emitted
`\\` is read as a literal backslash and the following `|` stays live.
