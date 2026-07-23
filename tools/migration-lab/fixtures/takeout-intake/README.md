# Takeout intake fixture lane

This directory is the staging contract for future social and cloud takeout
dogfooding. It is intentionally separate from the existing provider-specific
`mini-instagram` fixture.

The committed `sanitized-fixture/synthetic-social/` tree is synthetic. It
demonstrates posts, an album, media, timestamps, and links without claiming to
match any real provider's export format. The expected output is a review shape,
not generated Boris HTML or a parser result.

See [`docs/contracts/takeout-lab-intake.md`](../../../../docs/contracts/takeout-lab-intake.md)
for the intake contract, privacy boundary, and importer evidence checklist.
