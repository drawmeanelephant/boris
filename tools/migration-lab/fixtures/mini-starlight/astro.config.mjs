// Synthetic Starlight-like config for text-scan evidence only. Never executed.
import { defineConfig } from "astro/config";
import starlight from "@astrojs/starlight";

export default defineConfig({
  integrations: [
    starlight({
      title: "Mini Starlight Fixture",
      defaultLocale: "en",
      locales: {
        en: { label: "English", lang: "en" },
      },
      sidebar: [
        {
          label: "Introduction",
          items: [{ label: "Overview", slug: "" }],
        },
        {
          label: "Features",
          items: [{ autogenerate: { directory: "features", collapsed: true } }],
        },
        {
          label: "Installation",
          items: [{ autogenerate: { directory: "installation", collapsed: true } }],
        },
        { label: "FAQ", slug: "faq" },
        {
          label: "Devices",
          items: [{ label: "Chargers", link: "/chargers" }],
        },
      ],
    }),
  ],
});
