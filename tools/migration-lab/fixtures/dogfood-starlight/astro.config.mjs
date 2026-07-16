// Synthetic Starlight-like config for text-scan evidence only. Never executed.
// Shape mirrors withastro/starlight docs (root locale English).
import { defineConfig } from "astro/config";
import starlight from "@astrojs/starlight";

export default defineConfig({
  integrations: [
    starlight({
      title: "Dogfood Starlight Fixture",
      defaultLocale: "root",
      locales: {
        root: { label: "English", lang: "en" },
        de: { label: "Deutsch", lang: "de" },
        "zh-cn": { label: "简体中文", lang: "zh-CN" },
      },
      sidebar: [
        { label: "Start", items: [{ label: "Introduction", slug: "" }, { label: "Getting started", slug: "getting-started" }] },
        { label: "Guides", items: [{ autogenerate: { directory: "guides", collapsed: true } }] },
        { label: "Reference", items: [{ autogenerate: { directory: "reference", collapsed: false } }] },
        { label: "Components", items: [{ autogenerate: { directory: "components" } }] },
        { label: "Features", items: [{ autogenerate: { directory: "features" } }] },
        { label: "Installation", items: [{ autogenerate: { directory: "installation" } }] },
        { label: "Recipes", items: [{ autogenerate: { directory: "recipes" } }] },
        { label: "Blog", items: [{ autogenerate: { directory: "blog" } }] },
        { label: "Manual", slug: "manual/overview" },
        { label: "External", items: [{ label: "Astro", link: "https://astro.build" }] },
      ],
    }),
  ],
});
