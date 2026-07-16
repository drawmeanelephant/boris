// Synthetic Starlight-like config for text-scan evidence only. Never executed.
import { defineConfig } from "astro/config";
import starlight from "@astrojs/starlight";

export default defineConfig({
  integrations: [
    starlight({
      title: "Mini Starlight Root Fixture",
      // Default locale content lives at the docs root (withastro/starlight shape).
      defaultLocale: "root",
      locales: {
        root: { label: "English", lang: "en" },
        de: { label: "Deutsch", lang: "de" },
      },
      sidebar: [
        {
          label: "Start Here",
          items: [{ label: "Home", slug: "" }, { label: "Getting started", slug: "getting-started" }],
        },
        {
          label: "Guides",
          items: [{ autogenerate: { directory: "guides", collapsed: true } }],
        },
        {
          label: "Components",
          items: [{ autogenerate: { directory: "components", collapsed: true } }],
        },
      ],
    }),
  ],
});
