// Hostile config — text-scanned only, never executed.
import { defineConfig } from "astro/config";
import starlight from "@astrojs/starlight";

export default defineConfig({
  integrations: [
    starlight({
      title: "Hostile Starlight",
      defaultLocale: "en",
      locales: { en: { label: "English", lang: "en" } },
      sidebar: [
        { label: "Ambiguity", items: [{ autogenerate: { directory: "clash" } }] },
        { label: "Deep", items: [{ slug: "deep/a/b/c" }] },
        { label: "Ghost", link: "/en/does-not-exist" },
      ],
    }),
  ],
});
