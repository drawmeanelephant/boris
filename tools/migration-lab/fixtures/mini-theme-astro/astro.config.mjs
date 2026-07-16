// Synthetic Starlight-like config for text-scan evidence only. Never executed.
import { defineConfig } from "astro/config";
import starlight from "@astrojs/starlight";

export default defineConfig({
  integrations: [
    starlight({
      title: "Mini Theme Fixture",
      sidebar: [
        {
          label: "Start",
          items: [{ label: "Home", slug: "" }],
        },
        {
          label: "Guides",
          items: [{ autogenerate: { directory: "guides" } }],
        },
      ],
    }),
  ],
});
