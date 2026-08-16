# Editor voice / keyboard certification (#418 M10)

This is the recorded #418 M10 matrix. Boris Editor remains a semantic HTML
app with a native `<textarea>` so macOS Voice Control and Windows Voice Access
can operate the same names Playwright reads from the accessibility tree.

**Keyboard and Show-names analog:** certified in CI (`editor/ui` Playwright).
**Spoken Voice Control / Voice Access:** not observed in this slice. Do not
treat this file as a completed voice-only sign-off.

Recipe scaling (checklist 10) is keyboard-tested: Scale factor, Scale recipe,
and Reset scale. The host spawns `boris recipe-scale`. Spoken Voice Control
is still unobserved.

| # | Action | Keyboard (CI) | Voice Control | Voice Access |
|---|---|---|---|---|
| 1 | Launch / open a project | Yes | Unobserved | Unobserved |
| 2 | Open / create Markdown or Textile | Yes | Unobserved | Unobserved |
| 3 | Open / create a Cooklang recipe | Yes | Unobserved | Unobserved |
| 4 | Move between Source, Project, Problems, Preview | Yes | Unobserved | Unobserved |
| 5 | Edit frontmatter | Yes | Unobserved | Unobserved |
| 6 | Select a graph completion | Yes | Unobserved | Unobserved |
| 7 | Introduce a validation error | Yes | Unobserved | Unobserved |
| 8 | Locate / read / fix that error | Yes | Unobserved | Unobserved |
| 9 | Save and preview | Yes | Unobserved | Unobserved |
| 10 | Scale a recipe where Boris supports it | Yes (`boris recipe-scale`) | Unobserved | Unobserved |
| 11 | Navigate to a related recipe or page | Yes | Unobserved | Unobserved |
| 12 | Run a publication plan | Yes | Unobserved | Unobserved |
| 13 | Recover from an interrupted operation | Yes | Unobserved | Unobserved |
| 14 | Leave without silently losing changes | Yes (dirty + recovery + beforeunload) | Unobserved | Unobserved |

The Show-names analog asserts that chrome buttons and links expose a
non-empty accessible name that contains their visible label. That is the
same tree Voice Control “Show names” reads; it is not a spoken run.
