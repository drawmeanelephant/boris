---
title: Tidewater and Ridge
status: published
tags: [gallery, specimen]
summary: Two small albums built from page-local images.
---

# Tidewater and Ridge

Two walks, eight plates. This is the specimen site for the `gallery` theme:
a Trunk index whose albums are Satellites, each carrying its own images in a
sibling `.assets/` folder.

<figure>

![A posterized seascape at evening: banded sky fading from navy to coral above dark water, with a pale sun low on the right](index.assets/tidewater.png)

<figcaption><strong>Tidewater.</strong> Cover plate, 1200 × 560 PNG. Lives in <code>index.assets/</code> beside this page.</figcaption>
</figure>

The albums below come from `{{children}}`: Boris lists the direct children of
this page, and the theme hangs them on the wall as a grid of labelled mats.
Open an album to see its figures.

<Aside kind="tip">

Every image on this site is a hand-scaled file. Boris copies page-local
assets byte for byte; it does not resize, crop, or generate thumbnails.

</Aside>

<Details summary="Why are the album tiles empty mats?">

The `{{children}}` slot emits a title link per child page and nothing else.
The theme does not invent a cover image it was never given; the plate number
and title are the label.

</Details>
